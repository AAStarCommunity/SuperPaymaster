import { bindReceiptSummaries, evidenceEqual } from './derived-evidence.mjs';
import { EXCLUSION_REASONS, exclusionReason, sha256, stringify } from './evidence.mjs';
import { tpmAttemptRefreshed } from './trace-policy.mjs';
import { validateWindow } from './evidence-validate.mjs';
import { isDeepStrictEqual } from 'node:util';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { accumulateSlotWait, generateSchedule, REGISTERED_WINDOW, slotDecision, windowProtocolMatches } from './window-schedule.mjs';
import { dispositionErrors, feePauseErrors } from './disposition.mjs';
import { formalConfig, armOrder, inclusionErrors } from './formal.mjs';
import { createFrozenPlan } from './frozen-plan.mjs';
import { checkPVGLengths, measurePVG, PVG_MAX_SURPLUS } from './pvg.mjs';
// A6 gauge validator: re-reads a collector JSONL and recomputes every verdict from the RAW
// fields (packed op, receipt logs, A/B read-backs), with its own decoder — it does not import
// gauge-lib.mjs, so a decoding/classification bug in the collector cannot validate itself.
//
// Fails CLOSED: any missing or malformed field is an error, never a default.
//
// Scheduled runs also require --frozen-plan, --registered-seed and --registered-schedule-sha256.
// Exit: 0  consistent AND accepted (N matched triplets, no stop, every conservation check holds)
//       3  consistent but NOT accepted (fixture run / stopped / attempt budget exhausted)
//       1  INCONSISTENT: a recomputed verdict / conservation / A-B / passport result differs from
//          the record, or a conservation identity fails on the raw read-backs
//       2  unreadable input or a required field is missing (fail closed)
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { keccak256, encodeAbiParameters, toBytes, getAddress } from 'viem';

class Missing extends Error {}
function need(obj, path) {
  let v = obj;
  for (const k of path.split('.')) {
    if (v === null || typeof v !== 'object' || !(k in v)) throw new Missing(`missing field ${path}`);
    v = v[k];
  }
  if (v === undefined) throw new Missing(`missing field ${path}`);
  return v;
}
const noFixture = value => value === null;
const ZERO = '0x' + '0'.repeat(40);
const lc = (x) => String(x).toLowerCase();
const big = (x) => { if (!((typeof x === 'string' && /^\d+$/.test(x)) || (typeof x === 'number' && Number.isSafeInteger(x) && x >= 0))) throw new Missing(`not a number: ${JSON.stringify(x)}`); return BigInt(x); };

// ── independent event decoding (topic0 from the canonical signature strings) ──────────────
const sig = (s) => keccak256(toBytes(s));
const T = {
  UOE: sig('UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)'),
  REVERT: sig('UserOperationRevertReason(bytes32,address,uint256,bytes)'),
  POSTOP: sig('PostOpRevertReason(bytes32,address,uint256,bytes)'),
  PREFUND: sig('UserOperationPrefundTooLow(bytes32,address,uint256)'),
  SPONSORED: sig('TransactionSponsored(address,address,uint256,uint256)'),
  LOCK_CREATED: sig('LockCreated(address,bytes32,address,uint256,uint256)'),
  LOCK_SETTLED: sig('LockSettled(address,bytes32,uint256,uint256)'),
  CREDIT_RESERVED: sig('CreditReserved(address,bytes32,address,uint256)'),
  CREDIT_SETTLED: sig('CreditSettled(address,bytes32,uint256)'),
};
const word = (data, i) => '0x' + data.slice(2 + 64 * i, 2 + 64 * (i + 1));
const topicAddr = (t) => getAddress('0x' + t.slice(26));
function logsOf(logs, address, topic0) {
  return logs.filter((l) => lc(need(l, 'address')) === lc(address) && lc(need(l, 'topics')[0]) === lc(topic0));
}

// ── independent userOpHash (EntryPoint v0.7 UserOperationLib.encode + getUserOpHash) ──────
function hashOp(op, ep, chainId) {
  for (const k of ['sender', 'nonce', 'initCode', 'callData', 'accountGasLimits', 'preVerificationGas', 'gasFees', 'paymasterAndData']) need(op, k);
  const enc = encodeAbiParameters(
    ['address', 'uint256', 'bytes32', 'bytes32', 'bytes32', 'uint256', 'bytes32', 'bytes32'].map((type) => ({ type })),
    [op.sender, BigInt(op.nonce), keccak256(op.initCode), keccak256(op.callData), op.accountGasLimits, BigInt(op.preVerificationGas), op.gasFees, keccak256(op.paymasterAndData)]);
  return keccak256(encodeAbiParameters([{ type: 'bytes32' }, { type: 'address' }, { type: 'uint256' }], [keccak256(enc), ep, BigInt(chainId)]));
}

function verdictOf(row) {
  if (!need(row, 'sent')) return 'NOT_SENT';
  if (need(row, 'tx.status') !== 'success') return 'TX_FAILED';
  const logs = need(row, 'logs');
  const ep = need(row, 'entryPoint');
  const h = lc(need(row, 'expectedUserOpHash'));
  const uoes = logsOf(logs, ep, T.UOE).map((l) => ({ hash: lc(l.topics[1]), sender: topicAddr(l.topics[2]), paymaster: topicAddr(l.topics[3]),
    nonce: BigInt(word(l.data, 0)), success: BigInt(word(l.data, 1)) === 1n, actualGasCost: BigInt(word(l.data, 2)) }));
  const ours = uoes.filter((u) => u.hash === h);
  if (ours.length === 0) {
    return uoes.some((u) => lc(u.sender) === lc(row.sender) && u.nonce === big(row.nonce)) ? 'HASH_MISMATCH' : 'NO_EVENT';
  }
  if (ours.length > 1) return 'DUPLICATE_EVENT';
  const u = ours[0];
  if (lc(u.sender) !== lc(row.sender) || u.nonce !== big(row.nonce) || lc(u.paymaster) !== lc(row.paymaster)) return 'EVENT_FIELD_MISMATCH';
  const anyFor = (t) => logsOf(logs, ep, t).some((l) => lc(l.topics[1]) === h);
  if (!u.success) return 'USEROP_REVERTED';
  if (anyFor(T.REVERT) || anyFor(T.POSTOP) || anyFor(T.PREFUND)) return 'USEROP_REVERTED';
  return { verdict: 'USEROP_SUCCESS', u };
}

const SP_FIELDS = ['operatorBalance', 'totalSpent', 'totalTxSponsored', 'protocolRevenue', 'inflightOperator', 'inflightA0',
  'userXPNTs', 'totalSupply', 'lockedOf', 'debts', 'creditReservedOf', 'lockXLocked'];

// Attribute fixture receipt effects independently of the expected-hash verdict. Each
// executed op must bind to a packed bundle member and pass the single-op identities;
// their summed effects must explain the entire real readback delta.
function conservation(row, spAddr, tokenAddr, operator, inv, isFormal) {
  const events = logsOf(row.logs, row.entryPoint, T.UOE);
  if (row.tx.status !== 'success' || !events.length ||
      (events.length === 1 && lc(events[0].topics[1]) === lc(row.expectedUserOpHash))) {
    return conservationOne(row, spAddr, tokenAddr, operator, inv);
  }
  const failed = [], before = row.readbacks.before.A, after = row.readbacks.after.A;
  const fields = ['epDeposit', ...(row.arm === 'SP' ? SP_FIELDS : [])];
  const projected = { ...before }, hashes = new Set();
  const tokenTopics = [T.LOCK_CREATED, T.LOCK_SETTLED, T.CREDIT_RESERVED, T.CREDIT_SETTLED];
  const sponsored = logsOf(row.logs, spAddr, T.SPONSORED), usedSponsored = new Set();
  let previousEventIndex = -1;
  for (const event of events) {
    const h = lc(event.topics[1]), index = row.logs.indexOf(event);
    const op = row.bundledOps.find(op => lc(hashOp(op, row.entryPoint, row.chainId)) === h);
    if (hashes.has(h)) failed.push('receipt.duplicate_uoe');
    hashes.add(h);
    if (!op || lc(op.sender) !== lc(topicAddr(event.topics[2])) ||
        big(op.nonce) !== BigInt(word(event.data, 0)) ||
        lc(op.paymasterAndData.slice(0, 42)) !== lc(topicAddr(event.topics[3]))) {
      failed.push('receipt.uoe_bundle_identity');
      previousEventIndex = index;
      continue;
    }
    // Other paymasters cannot spend this arm's deposit or tracked SP balances.
    if (lc(topicAddr(event.topics[3])) !== lc(row.paymaster)) {
      previousEventIndex = index;
      continue;
    }
    // The recorded SP passport/readbacks cover one operator and sender. Refuse
    // attribution to a different identity without its independent state evidence.
    if (row.arm === 'SP' && (lc(op.sender) !== lc(row.sender) ||
        lc('0x' + op.paymasterAndData.slice(106, 146)) !== lc(operator))) {
      failed.push('receipt.untracked_sp_identity');
      previousEventIndex = index;
      continue;
    }
    const operationLogs = row.logs.filter((l, j) => {
      if (lc(l.address) === lc(spAddr) && lc(l.topics[0]) === lc(T.SPONSORED)) {
        const belongs = j > previousEventIndex && j < index;
        if (belongs) usedSponsored.add(l);
        return belongs;
      }
      return l.topics.some(t => lc(t) === h);
    });
    previousEventIndex = index;
    const b = { ...projected };
    // These three fields are keyed by opHash, unlike persistent aggregate state.
    if (row.arm === 'SP') Object.assign(b, { inflightOperator: ZERO, inflightA0: '0', lockXLocked: '0' });
    const a = { ...b, blockNumber: after.blockNumber, blockHash: after.blockHash };
    const add = (f, n) => { a[f] = String(big(b[f]) + n); };
    add('epDeposit', -BigInt(word(event.data, 2)));
    if (row.arm === 'SP') {
      const byHash = t => logsOf(operationLogs, tokenAddr, t);
      const locks = byHash(T.LOCK_CREATED), credits = byHash(T.CREDIT_RESERVED);
      const settlements = byHash(T.LOCK_SETTLED), creditSettlements = byHash(T.CREDIT_SETTLED);
      const charges = logsOf(operationLogs, spAddr, T.SPONSORED);
      const reservation = locks[0] ?? credits[0];
      if (!reservation) { failed.push('receipt.missing_reservation'); continue; }
      const a0 = BigInt(word(reservation.data, locks.length ? 1 : 0));
      add('totalSpent', a0);
      const postRevert = logsOf(operationLogs, row.entryPoint, T.POSTOP).length > 0;
      if (postRevert) {
        add('operatorBalance', -a0);
        a.inflightOperator = operator; a.inflightA0 = String(a0);
        if (locks.length) { const x = BigInt(word(locks[0].data, 0)); add('lockedOf', x); a.lockXLocked = String(x); }
        else add('creditReservedOf', a0);
      } else {
        if (charges.length !== 1) { failed.push('receipt.sponsored_count'); continue; }
        const charge = BigInt(word(charges[0].data, 1));
        add('operatorBalance', -charge); add('protocolRevenue', charge); add('totalTxSponsored', 1n);
        a.inflightOperator = ZERO; a.inflightA0 = '0'; a.lockXLocked = '0';
        if (settlements.length) { const burned = BigInt(word(settlements[0].data, 0)); add('userXPNTs', -burned); add('totalSupply', -burned); }
        if (creditSettlements.length) add('debts', BigInt(word(creditSettlements[0].data, 0)));
      }
    }
    const checks = conservationOne({ ...row, packedOp: op, expectedUserOpHash: h, logs: operationLogs,
      readbacks: { before: { A: { ...b, blockNumber: before.blockNumber, blockHash: before.blockHash } }, after: { A: a } } },
      spAddr, tokenAddr, operator, inv);
    failed.push(...checks.map(c => `receipt.${h}.${c}`));
    const gasFields = isFormal ? ['SP','VPM','TPM'].flatMap(a => GAS_FIELDS.map(f => `invariant.gas.${a}.${f}`)) : GAS_FIELDS.map(f => `invariant.gas.${f}`);
  for (const f of [...fields.filter(f => !f.startsWith('invariant.gas.')), ...gasFields]) {
      if (['inflightOperator', 'inflightA0', 'lockXLocked'].includes(f) && h !== lc(row.expectedUserOpHash)) continue;
      projected[f] = a[f];
    }
  }
  if (row.arm === 'SP') {
    if (sponsored.some(l => !usedSponsored.has(l))) failed.push('receipt.orphan_sponsored');
  }
  for (const t of tokenTopics) if (logsOf(row.logs, tokenAddr, t).some(l => !hashes.has(lc(l.topics[2])))) failed.push('receipt.orphan_token_event');
  for (const f of fields) if (!deepEq(need(projected, f), need(after, f))) failed.push(`receipt.unexplained.${f}`);
  // Bracketing applies even when every receipt event belongs to another paymaster.
  if (big(before.blockNumber) + 1n !== big(after.blockNumber) || big(after.blockNumber) !== big(row.tx.blockNumber)) failed.push('readback_blocks_bracket_tx');
  if (lc(after.blockHash) !== lc(row.tx.blockHash)) failed.push('readback_after_blockhash_eq_tx_block');
  return failed;
}

/** Independent conservation recomputation. Returns list of failed check ids. */
function conservationOne(row, spAddr, tokenAddr, operator, inv) {
  const failed = [];
  const b = need(row, 'readbacks.before.A'), a = need(row, 'readbacks.after.A');
  for (const f of ['epDeposit', 'blockNumber', 'blockHash']) { need(b, f); need(a, f); }
  const logs = need(row, 'logs');
  const ep = need(row, 'entryPoint');
  const h = lc(row.expectedUserOpHash);
  {
    const hashes = new Set(logsOf(logs, ep, T.UOE).map(l => lc(l.topics[1])));
    for (const t of [T.LOCK_CREATED, T.LOCK_SETTLED, T.CREDIT_RESERVED, T.CREDIT_SETTLED]) {
      if (logsOf(logs, tokenAddr, t).some(l => !hashes.has(lc(l.topics[2])))) failed.push('receipt.orphan_token_event');
    }
  }
  const uoe = logsOf(logs, ep, T.UOE).find((l) => lc(l.topics[1]) === h);
  if (big(b.blockNumber) + 1n !== big(a.blockNumber) || big(a.blockNumber) !== big(need(row, 'tx.blockNumber'))) failed.push('readback_blocks_bracket_tx');
  if (lc(a.blockHash) !== lc(need(row, 'tx.blockHash'))) failed.push('readback_after_blockhash_eq_tx_block');
  if (!uoe || row.tx.status !== 'success') {
    // A reverted transaction or receipt without relevant execution cannot justify state deltas.
    for (const f of ['epDeposit', ...(row.arm === 'SP' ? SP_FIELDS : [])]) {
      if (!deepEq(need(b, f), need(a, f))) failed.push(`no_execution.${f}`);
    }
    return failed;
  }
  const actualGasCost = BigInt(word(uoe.data, 2));
  const success = BigInt(word(uoe.data, 1)) === 1n;
  if (big(a.epDeposit) - big(b.epDeposit) !== -actualGasCost) failed.push('D1');
  if (row.arm !== 'SP') return failed;
  for (const f of SP_FIELDS) { need(b, f); need(a, f); }
  const d = (f) => big(a[f]) - big(b[f]);
  const gas = opGas(row.packedOp), pd = row.packedOp.paymasterAndData;
  const requiredGas = ['callGasLimit', 'verificationGasLimit', 'preVerificationGas'].reduce((n, f) => n + big(gas[f]), 0n)
    + BigInt('0x' + pd.slice(42, 74)) + BigInt('0x' + pd.slice(74, 106));
  const sp = inv.superPaymaster, price = big(sp.cachedPrice.price), usd = big(sp.aPNTsPriceUSD);
  const ceil = (n, d) => (n + d - 1n) / d;
  let expectedA0;
  if (price === 0n || usd === 0n || big(sp.cachedPrice.decimals) > 77n) failed.push('admission.quote');
  else expectedA0 = ceil(ceil(requiredGas * big(gas.maxFeePerGas) * price * 10n**18n,
    10n**big(sp.cachedPrice.decimals) * usd) * (10000n + big(sp.protocolFeeBPS) + 1000n), 10000n);
  for (const reservation of [...logsOf(logs, tokenAddr, T.LOCK_CREATED), ...logsOf(logs, tokenAddr, T.CREDIT_RESERVED)].filter(l => lc(l.topics[2]) === h)) {
    const a0 = BigInt(word(reservation.data, lc(reservation.topics[0]) === lc(T.LOCK_CREATED) ? 1 : 0));
    if (expectedA0 === undefined || a0 !== expectedA0) failed.push('admission.quote_a0');
  }
  // Pin 1ac0e1c5: XT:194-212; SP:313-324. Check admission for every retained lock,
  // including a postOp revert (validation writes survive that branch).
  for (const lock of logsOf(logs, tokenAddr, T.LOCK_CREATED).filter(l => lc(l.topics[2]) === h)) {
    const x = BigInt(word(lock.data, 0)), a0 = BigInt(word(lock.data, 1));
    if (a0 >= (1n << 96n) || a0 > big(inv.xPNTs.maxSingleTxLimit)) failed.push('admission.a0_bounds');
    if (x !== (a0 * big(inv.xPNTs.exchangeRate) + 10n**18n - 1n) / 10n**18n) failed.push('admission.exchange_rate');
    if (big(b.userXPNTs) < big(b.lockedOf) + x) failed.push('admission.available_balance');
    if (big(b.operatorBalance) < a0) failed.push('admission.operator_balance');
  }
  const postOpReverted = logsOf(logs, ep, T.POSTOP).some((l) => lc(l.topics[1]) === h);
  const sponsored = logsOf(logs, spAddr, T.SPONSORED);
  if (lc(b.inflightOperator) !== ZERO) failed.push('C4.before_operator');
  if (big(b.inflightA0) !== 0n) failed.push('C4.before');
  if (postOpReverted) {
    if (success) failed.push('R.success_with_postop_revert');
    if (sponsored.length) failed.push('R1.sponsored_absent');
    if (logsOf(logs, tokenAddr, T.LOCK_SETTLED).length || logsOf(logs, tokenAddr, T.CREDIT_SETTLED).length) failed.push('R.settle_events_absent');
    const locks = logsOf(logs, tokenAddr, T.LOCK_CREATED).filter(l => lc(l.topics[2]) === h);
    const credits = logsOf(logs, tokenAddr, T.CREDIT_RESERVED).filter(l => lc(l.topics[2]) === h);
    if (locks.length + credits.length !== 1) {
      if (locks.length + credits.length > 1) failed.push('R.reservation_count');
      if (d('debts') !== 0n || d('creditReservedOf') !== 0n) failed.push('R.credit_unchanged');
      failed.push('R.not_evaluable_missing_lock_created'); return failed;
    }
    const reservation = locks[0] ?? credits[0];
    const a0 = BigInt(word(reservation.data, locks.length ? 1 : 0)), xLocked = locks.length ? BigInt(word(reservation.data, 0)) : 0n;
    if (d('debts') !== 0n || d('creditReservedOf') !== (credits.length ? a0 : 0n)) failed.push('R.credit_unchanged');
    if (lc(topicAddr(reservation.topics[1])) !== lc(row.sender) || lc(topicAddr(reservation.topics[3])) !== lc(spAddr)) failed.push('R.lock_identity');
    if (lc(a.inflightOperator) !== lc(operator)) failed.push('R1.operator');
    if (big(a.inflightA0) !== a0) failed.push('R1.a0');
    if (d('operatorBalance') !== -a0) failed.push('R1.op_delta');
    if (d('lockedOf') !== xLocked || big(a.lockXLocked) !== xLocked) failed.push('R2.locked');
    if (d('protocolRevenue') !== 0n) failed.push('R1.revenue');
    if (d('totalSpent') !== a0) failed.push('R1.totalSpent');
    if (d('userXPNTs') !== 0n || d('totalSupply') !== 0n) failed.push('R2.xpnts_unchanged');
    if (d('totalTxSponsored') !== 0n) failed.push('R1.totalTxSponsored');
    return failed;
  }
  if (sponsored.length !== 1) { failed.push('C9.sponsored_count'); return failed; }
  const s = sponsored[0];
  const charge = BigInt(word(s.data, 1)), aGas = BigInt(word(s.data, 0));
  // git show 1ac0e1c5: SP:419-428 prices the PRE-postOp cost plus a buffer,
  // whereas EP:703-707,716-730 adds postOp gas and penalty before emitting UOE.
  // The archive has no postOp calldata trace or gas-parameter snapshot. Bind the
  // emitted aGas to the source-proven interval; do not equate these two costs.
  // ST:192,200-203 / Admin:297-301 bound cPostop+cWrap to [180000,2050000].
  const used = BigInt(word(uoe.data, 3));
  if (used === 0n || actualGasCost % used !== 0n) failed.push('C9.actualGasCost_gasPrice');
  else if (price > 0n && usd > 0n && big(sp.cachedPrice.decimals) <= 77n) {
    const feePerGas = actualGasCost / used;
    if (feePerGas > big(gas.maxFeePerGas) || feePerGas < (big(gas.maxPriorityFeePerGas) < big(gas.maxFeePerGas) ? big(gas.maxPriorityFeePerGas) : big(gas.maxFeePerGas))) failed.push('C9.actualGasCost_gasPrice');
    const penaltyBuffer = ceil((big(gas.callGasLimit) + BigInt('0x' + pd.slice(74, 106))) * 10n, 100n);
    const denominator = 10n ** big(sp.cachedPrice.decimals) * usd;
    const convert = wei => ceil(wei * price * 10n**18n, denominator);
    // Pre-op gas includes preVerificationGas (EP:672); final UOE cost includes
    // all gas charged before the callback, plus nonnegative wrapper/penalty gas.
    const lower = convert((big(gas.preVerificationGas) + 180000n + penaltyBuffer) * feePerGas);
    const upper = convert(actualGasCost + (2050000n + penaltyBuffer) * feePerGas);
    if (aGas < lower || aGas > upper) failed.push('C9.aGas_actualGasCost_price');
  }
  // SP at 1ac0e1c5:426-434,450 emits (aGas, min(ceil(aGas*(10000+fee)/10000), a0)).
  const reservations = [...logsOf(logs, tokenAddr, T.LOCK_CREATED), ...logsOf(logs, tokenAddr, T.CREDIT_RESERVED)]
    .filter(l => lc(l.topics[2]) === h);
  if (reservations.length === 1) {
    const reservation = reservations[0], a0 = BigInt(word(reservation.data, lc(reservation.topics[0]) === lc(T.LOCK_CREATED) ? 1 : 0));
    const withFee = (aGas * (10000n + big(inv.superPaymaster.protocolFeeBPS)) + 9999n) / 10000n;
    if (charge !== (withFee > a0 ? a0 : withFee)) failed.push('C9.aPNTsCost_fee');
  }

  if (lc(topicAddr(s.topics[1])) !== lc(operator)) failed.push('C9.operator');
  if (lc(topicAddr(s.topics[2])) !== lc(row.sender)) failed.push('C9.user');
  if (d('operatorBalance') !== -charge) failed.push('C1');
  if (d('protocolRevenue') !== charge) failed.push('C2');
  if (d('operatorBalance') + d('protocolRevenue') !== 0n) failed.push('C3');
  if (lc(a.inflightOperator) !== ZERO) failed.push('C4.after_operator');
  if (big(a.inflightA0) !== 0n) failed.push('C4.after');
  if (d('totalTxSponsored') !== 1n) failed.push('C10.count');
  const byHash = (t) => logsOf(logs, tokenAddr, t).filter((l) => lc(l.topics[2]) === h);
  const lcr = byHash(T.LOCK_CREATED), lse = byHash(T.LOCK_SETTLED), crr = byHash(T.CREDIT_RESERVED), cse = byHash(T.CREDIT_SETTLED);
  if (lcr.length === 1 && lse.length === 1 && !crr.length && !cse.length) {
    if (lc(topicAddr(lse[0].topics[1])) !== lc(row.sender)) failed.push('C8.settled_user');
    if (d('debts') !== 0n || d('creditReservedOf') !== 0n) failed.push('C8.credit_unchanged');
    const xLocked = BigInt(word(lcr[0].data, 0)), a0 = BigInt(word(lcr[0].data, 1));
    if (lc(topicAddr(lcr[0].topics[1])) !== lc(row.sender) || lc(topicAddr(lcr[0].topics[3])) !== lc(spAddr)) failed.push('C8.lock_identity');
    const xBurned = BigInt(word(lse[0].data, 0)), aCharged = BigInt(word(lse[0].data, 1));
    if (aCharged !== charge) failed.push('C8.charge');
    if (charge > a0) failed.push('C8.le_a0');
    if (d('totalSpent') !== a0) failed.push('C10.spent');
    let exp = a0 === 0n ? 0n : (charge * xLocked + a0 - 1n) / a0;
    if (exp > xLocked) exp = xLocked;
    if (xBurned !== exp) failed.push('C7');
    if (d('userXPNTs') !== -xBurned) failed.push('C5.user');
    if (d('totalSupply') !== -xBurned) failed.push('C5.supply');
    if (d('lockedOf') !== 0n) failed.push('C6.locked');
    if (big(a.lockXLocked) !== 0n) failed.push('C6.record');
  } else if (crr.length === 1 && cse.length === 1 && !lcr.length && !lse.length) {
    const reservation = BigInt(word(crr[0].data, 0)), debtAdded = BigInt(word(cse[0].data, 0));
    if (reservation <= 0n || reservation >= (1n << 96n) || charge > reservation || debtAdded > reservation) failed.push('credit.reservation_bounds');
    if (d('totalSpent') !== reservation) failed.push('credit.totalSpent');
    if (lc(topicAddr(crr[0].topics[1])) !== lc(row.sender) || lc(topicAddr(crr[0].topics[3])) !== lc(spAddr) || lc(topicAddr(cse[0].topics[1])) !== lc(row.sender)) failed.push('credit.identity');
    if (d('lockedOf') !== 0n || big(a.lockXLocked) !== 0n) failed.push('credit.lock_unchanged');
    if (d('debts') !== charge || BigInt(word(cse[0].data, 0)) !== charge) failed.push("C5'.debt");
    if (d('userXPNTs') !== 0n || d('totalSupply') !== 0n) failed.push("C5'.xpnts");
    if (d('creditReservedOf') !== 0n) failed.push("C5'.reserved");
  } else failed.push('mode');
  return failed;
}

function deepEq(x, y) { return JSON.stringify(x, (k, v) => (typeof v === 'string' ? v.toLowerCase() : v)) === JSON.stringify(y, (k, v) => (typeof v === 'string' ? v.toLowerCase() : v)); }

// Explicit collector passport schema: require every emitted leaf, including false/zero values.
const CODE_NAMES = ['entryPoint', 'superPaymasterProxy', 'superPaymasterImpl', 'xPNTsClone', 'xPNTsImpl', 'xPNTsExt', 'account', 'accountImpl', 'verifyingPaymaster', 'tokenPaymaster', 'tokenPaymasterToken', 'priceFeed'];
const GAS_FIELDS = ['callGasLimit', 'verificationGasLimit', 'preVerificationGas', 'maxFeePerGas', 'maxPriorityFeePerGas'];
const PASSPORT_FIELDS = [
  'chainId', 'block.number', 'block.hash', 'block.timestamp', 'allowSameEndpointLocal',
  'invariant.entryPoint.address', 'invariant.entryPoint.isCanonicalV07Address',
  ...CODE_NAMES.flatMap(n => ['address', 'codehash', 'size'].map(f => `invariant.code.${n}.${f}`)),
  ...['version', 'entryPoint', 'registry', 'aPNTs', 'protocolFeeBPS', 'aPNTsPriceUSD', 'priceStalenessThreshold', 'paused', 'cachedPrice.price', 'cachedPrice.decimals', 'operator.address', 'operator.isConfigured', 'operator.isPaused', 'operator.xPNTsToken', 'operator.minTxInterval', 'senderEligible', 'minPostOpGas'].map(f => `invariant.superPaymaster.${f}`),
  ...['address', 'version', 'exchangeRate', 'superPaymaster', 'maxSingleTxLimit', 'emergencyDisabled'].map(f => `invariant.xPNTs.${f}`),
  ...['SP', 'VPM', 'TPM'].flatMap(n => ['staked', 'stake', 'unstakeDelaySec', 'withdrawTime'].map(f => `invariant.stakes.${n}.${f}`)),
  ...['SP', 'VPM', 'TPM', 'account'].map(n => `invariant.armEntryPoints.${n}`),
  ...['verifyingSigner', 'sender', 'bundler', 'beneficiary', 'callDataHash'].map(f => `invariant.${f}`),
  ...GAS_FIELDS.map(f => `invariant.gas.${f}`),
  ...['SP', 'VPM', 'TPM'].flatMap(n => ['ver', 'post'].map(f => `invariant.pmGas.${n}.${f}`)),
  'volatile.cachedPriceUpdatedAt', 'volatile.operatorBalance',
];
const ADDRESS_FIELDS = new Set([
  'invariant.entryPoint.address', ...CODE_NAMES.map(n => `invariant.code.${n}.address`),
  ...['entryPoint', 'registry', 'aPNTs', 'operator.address', 'operator.xPNTsToken'].map(f => `invariant.superPaymaster.${f}`),
  'invariant.xPNTs.address', 'invariant.xPNTs.superPaymaster',
  ...['SP', 'VPM', 'TPM', 'account'].map(n => `invariant.armEntryPoints.${n}`),
  ...['verifyingSigner', 'sender', 'bundler', 'beneficiary'].map(f => `invariant.${f}`),
]);
const BOOL_FIELDS = new Set(['allowSameEndpointLocal', 'invariant.entryPoint.isCanonicalV07Address',
  ...['paused', 'operator.isConfigured', 'operator.isPaused', 'senderEligible'].map(f => `invariant.superPaymaster.${f}`),
  'invariant.xPNTs.emergencyDisabled', ...['SP', 'VPM', 'TPM'].map(n => `invariant.stakes.${n}.staked`)]);
// a6-gauge/2 adds the token's credit state (A4 Passport C2/C3). /1 runs predate it and stay readable.
const SCHEMAS = ['a6-gauge/1', 'a6-gauge/2'];
const CREDIT_FIELDS = ['policy', 'hasPendingPolicy', 'pendingPolicy', 'pendingPolicyEta', 'policyEpoch'].map(f => `invariant.credit.${f}`);
function completePassport(p, schema, isFormal, errors) {
  const fields = schema === 'a6-gauge/2' ? [...PASSPORT_FIELDS, ...CREDIT_FIELDS] : PASSPORT_FIELDS;
  const gasFields = isFormal ? ['SP','VPM','TPM'].flatMap(a => GAS_FIELDS.map(f => `invariant.gas.${a}.${f}`)) : GAS_FIELDS.map(f => `invariant.gas.${f}`);
  for (const f of [...fields.filter(f => !f.startsWith('invariant.gas.')), ...gasFields]) {
    const v = need(p, f);
    let valid;
    if (ADDRESS_FIELDS.has(f)) valid = typeof v === 'string' && /^0x[0-9a-f]{40}$/i.test(v) && !/^0x0{40}$/i.test(v);
    else if (BOOL_FIELDS.has(f) || f === 'invariant.credit.hasPendingPolicy') valid = typeof v === 'boolean';
    else if (f.endsWith('.hash') || f.endsWith('.codehash') || f.endsWith('callDataHash')) valid = typeof v === 'string' && /^0x[0-9a-f]{64}$/i.test(v);
    else if (f.endsWith('.version')) valid = typeof v === 'string' && v.trim().length > 0;
    else valid = (typeof v === 'string' && /^\d+$/.test(v)) || (typeof v === 'number' && Number.isSafeInteger(v) && v >= 0);
    if (!valid) throw new Missing(`malformed passport ${f}`);
  }
  const account = p.invariant.code.account;
  if ((big(account.size) === 0n) !== (lc(account.codehash) === keccak256('0x'))) errors.push('passport account size/codehash mismatch');
  if (big(p.invariant.superPaymaster.minPostOpGas) < 175000n || big(p.invariant.superPaymaster.minPostOpGas) > 2000000n) errors.push('passport minPostOpGas outside contract bounds');
  const inv = p.invariant, ep = inv.entryPoint.address;
  const same = (a, b, label) => { if (lc(a) !== lc(b)) errors.push(`passport binding mismatch: ${label}`); };
  same(ep, inv.code.entryPoint.address, 'EntryPoint code');
  for (const [arm, address] of Object.entries(inv.armEntryPoints)) same(ep, address, `armEntryPoints.${arm}`);
  same(ep, inv.superPaymaster.entryPoint, 'SP EntryPoint');
  same(inv.sender, inv.code.account.address, 'sender account');
  same(inv.xPNTs.address, inv.code.xPNTsClone.address, 'xPNTs clone');
  same(inv.xPNTs.address, inv.superPaymaster.operator.xPNTsToken, 'operator token');
  same(inv.xPNTs.superPaymaster, inv.code.superPaymasterProxy.address, 'token SP');
  if (inv.entryPoint.isCanonicalV07Address !== (lc(ep) === '0x0000000071727de22e5e9d8baf0edac6f37da032')) errors.push('passport canonical EntryPoint flag mismatch');
  if (schema === 'a6-gauge/2') {
    // XB:43 POLICY_OFF = 0; XT:337-339 effectiveCreditCap is 0 under OFF. A queued policy could
    // switch it on mid-window (XE:171-177), so OFF alone is not enough.
    if (big(inv.credit.policy) !== 0n) errors.push('passport credit policy is not OFF');
    if (inv.credit.hasPendingPolicy !== false) errors.push('passport credit policy change is queued');
  }
}
// Host identity ignores URL decoration and transport; loopback aliases share one host.
const endpoint = value => {
  const u = new URL(value);
  if (!['http:', 'https:'].includes(u.protocol)) throw new Missing('RPC URL must use http(s)');
  const h = u.hostname.toLowerCase().replace(/\.$/, '');
  // URL accepts empty DNS labels, underscores and other non-hostname syntax. One
  // terminal root dot is valid; repeated dots and invalid labels cannot prove identity.
  if (!h.startsWith('[') && (h.length > 253 || h.split('.').some(label =>
    !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label)))) throw new Missing('malformed RPC hostname');
  const loopback = h === 'localhost' || h.endsWith('.localhost') || /^127\./.test(h)
    || h === '0.0.0.0' || h === '[::]' || h === '[::ffff:0:0]' || h === '[::1]' || /^\[::ffff:7f[0-9a-f]{2}:[0-9a-f]{1,4}\]$/.test(h);
  return { host: loopback ? 'loopback' : h, port: u.port || (u.protocol === 'https:' ? '443' : '80') };
};
function opGas(op) {
  const split = x => [BigInt('0x' + x.slice(2, 34)).toString(), BigInt('0x' + x.slice(34)).toString()];
  const [verificationGasLimit, callGasLimit] = split(op.accountGasLimits);
  const [maxPriorityFeePerGas, maxFeePerGas] = split(op.gasFees);
  return { callGasLimit, verificationGasLimit, preVerificationGas: big(op.preVerificationGas).toString(), maxFeePerGas, maxPriorityFeePerGas };
}

const scheduleArms = {SP:'SP',VerifyingPaymaster:'VPM',TokenPaymaster:'TPM'};
const senderStateFields = ['userXPNTs','lockedOf','debts','creditReservedOf'];
const slotFailures = ['slot_deadline_exceeded','sp_valid_after_exceeds_slot_deadline'];
function passportContext(pStart) {
  const inv = need(pStart, 'invariant');
  const spAddr = need(inv, 'code.superPaymasterProxy.address');
  const armPaymasters = { SP: spAddr, VPM: inv.code.verifyingPaymaster.address, TPM: inv.code.tokenPaymaster.address };
  return {pStart,inv,spAddr,armPaymasters,tokenAddr:need(inv,'xPNTs.address'),operator:need(inv,'superPaymaster.operator.address'),chainId:need(pStart,'chainId')};
}

function frozenWindow(manifest, attempts, start, end, {path,evidenceDir,registered,completePassport,errors}) {
  if (manifest?.schema !== 'rq3-window-v1') throw new Missing('frozen provenance requires an rq3-window-v1 manifest.json');
  const bytes = readFileSync(path);
  const bundleSha256 = sha256(bytes);
  if (bundleSha256 !== need(manifest,'bundleSha256')) throw new Missing('frozen bundle SHA-256 mismatch with manifest.bundleSha256');
  if (typeof registered.seed !== 'string' || !registered.seed || !/^[0-9a-f]{64}$/.test(registered.scheduleSha256)) {
    throw new Missing('frozen window requires --registered-seed <seed> and --registered-schedule-sha256 <hex>');
  }
  if (!windowProtocolMatches(manifest,registered)) throw new Missing('manifest differs from registered window protocol');
  const {targetTriplets:target, slotCap:cap, windows, windowSlots, seed, scheduleSha256:scheduleSha} = registered;
  const payload = need(manifest,'schedule.payload');
  const {accounts} = payload;
  if (!Array.isArray(accounts) || accounts.length !== 3 || accounts.some(a => !/^0x[0-9a-f]{40}$/i.test(a))
      || new Set(accounts.map(lc)).size !== accounts.length) throw new Missing('invalid frozen schedule accounts');
  // The offline generator uses the chain's frozen timing and hashes its canonical payload.
  const regenerated = generateSchedule(seed,accounts,need(start,'passport.chainId'));
  if (!isDeepStrictEqual(payload,regenerated.payload)) throw new Missing('schedule payload differs from regenerated registered schedule');
  if (regenerated.sha256 !== scheduleSha || need(manifest,'schedule.sha256') !== scheduleSha) {
    throw new Missing('schedule SHA-256 differs from registered schedule');
  }
  const {slots} = regenerated.payload;
  if (slots.length !== cap || !Number.isSafeInteger(windowSlots) || windowSlots < 1
      || !Number.isSafeInteger(windows) || windows < 1 || cap !== windows * windowSlots
      || !Number.isSafeInteger(target) || target < 1 || target > cap) throw new Missing('invalid registered window limits');
  const windowIndex = need(manifest,'slice.windowIndex');
  const firstSlot = (windowIndex-1)*windowSlots, lastSlot = firstSlot+windowSlots-1;
  const slice = {windowIndex,firstSlot,lastSlot,slots:windowSlots};
  if (!isDeepStrictEqual(manifest.slice,slice)) throw new Missing('manifest slice differs from registered range');
  const allocations = new Map();
  for (const slot of slots.slice(0,firstSlot)) for (const name of slot.order) {
    const key = `${lc(slot.senders[name])}:${scheduleArms[name]}`;
    allocations.set(key,(allocations.get(key) ?? 0)+1);
  }
  const senders = new Map(accounts.map(account => {
    const adapter = createFrozenPlan({readBundle:()=>bytes,bundleSha256,account});
    const {digest,frozen,plan} = adapter;
    if (digest !== need(manifest,`plan_sha256.${account}`)) errors.push(`sender ${account}: manifest planDigest mismatch`);
    const path = `passports/start-${account}.json`;
    const passport = JSON.parse(readFileSync(resolve(evidenceDir,path),'utf8'));
    completePassport(passport,resolve(evidenceDir,path)+':1');
    const context = passportContext(passport);
    if (lc(context.inv.sender) !== lc(account)) errors.push(`sender ${account}: start passport sender mismatch`);
    for (const key of ['gas','pmGas']) if (!deepEq(JSON.parse(stringify(frozen[key])),context.inv[key])) errors.push(`sender ${account}: frozen ${key}/passport mismatch`);
    if (lc(keccak256(frozen.callData)) !== lc(context.inv.callDataHash)) errors.push(`sender ${account}: frozen callData/passport mismatch`);
    if (plan.chainId !== context.chainId || context.chainId !== start.passport.chainId) errors.push(`sender ${account}: frozen chainId/passport mismatch`);
    if (new Set(Object.values(context.armPaymasters).map(lc)).size !== 3) errors.push(`sender ${account}: passport arm paymasters must be distinct`);
    const endPath = `passports/end-${account}.json`;
    let pEnd;
    if (end.stop?.code === 0 || existsSync(resolve(evidenceDir,endPath))) {
      try { pEnd = JSON.parse(readFileSync(resolve(evidenceDir,endPath),'utf8')); }
      catch { errors.push(`sender ${account}: missing or invalid end passport`); }
      if (pEnd) {
        completePassport(pEnd,resolve(evidenceDir,endPath)+':1');
        if (!evidenceEqual(context.inv,pEnd.invariant)) errors.push(`sender ${account}: end passport invariant drifted`);
        if (pEnd.chainId !== passport.chainId || pEnd.allowSameEndpointLocal !== passport.allowSameEndpointLocal
            || big(pEnd.block.number) < big(passport.block.number) || big(pEnd.block.timestamp) < big(passport.block.timestamp)) {
          errors.push(`sender ${account}: end passport metadata or block mismatch`);
        }
      }
    }
    return [lc(account),{...context,path,digest,phaseC:plan.phaseC,adapter,pEnd,endPath}];
  }));
  const index = attempts.length ? readFileSync(resolve(evidenceDir,'index.ndjson'),'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [];
  if (index.length !== attempts.length) errors.push('frozen index does not retain every journal attempt');
  return {manifest,target,cap,slice,slots,scheduleSha,seed,bundleSha256,senders,index,allocationKeys:[],
    startTimestamp:big(need(manifest,'startTimestamp')),allocations};
}

function slotGatesMatch(window, row, denied) {
  const checks = row.slotChecks ?? (row.stoppedBy ? [] : null);
  // A stopped attempt may end before, between or after its gates; any gate it did reach must match.
  if (!Array.isArray(checks) || checks.length > 2 || (!row.stoppedBy && !checks.length) || (checks.length === 2 && checks[0]?.allowed !== true)) return false;
  const slot = window.slots[row.block_slot];
  const offset = window.slots[window.slice.firstSlot].start_seconds;
  const start = window.startTimestamp + BigInt(slot.start_seconds - offset);
  const deadline = window.startTimestamp + BigInt(slot.deadline_seconds - offset);
  if (!checks.every(gate => {
    const wait = gate?.wait;
    if (wait?.start !== String(start) || wait.deadline !== String(deadline)) return false;
    try {
      const timestamp = big(wait.timestamp);
      big(wait.seconds);
      big(wait.blocks);
      const validAfter = big(wait.validAfter);
      if (row.arm === 'SP' && wait.lastTimestamp != null && wait.minTxInterval != null &&
          validAfter !== big(wait.lastTimestamp)+big(wait.minTxInterval)) return false;
      const decision = slotDecision(row.arm,{timestamp,start,deadline,validAfter});
      return decision !== null && gate.allowed === decision.allowed && gate.reason === decision.reason;
    } catch (e) {
      if (e instanceof Missing) return false;
      throw e;
    }
  })) return false;
  const spWait = row.arm === 'SP' ? checks.reduce((previous,gate)=>accumulateSlotWait(previous,gate.wait),undefined) : undefined;
  if (!evidenceEqual(row.spWait,spWait)) return false;
  const gate = checks.at(-1);
  if (row.stoppedBy && !denied) return true;
  // A sent row passed both gates. A row withheld after packing but before submission (deposit floor,
  // preflight, fee pause) passed the pre-send gate and, if it got that far, the submit gate.
  if (!denied) return checks.every(g => g.allowed === true) && (row.sent ? checks.length === 2 : true);
  return gate?.allowed === false && gate.reason === row.failingCheck;
}

function frozenAttempt(window, row, i, errors) {
  const context = window.senders.get(lc(need(row,'sender')));
  if (!context) throw new Missing(`attempt ${i}: sender absent from frozen schedule accounts`);
  if (row.bundleSha256 !== window.bundleSha256) errors.push(`attempt ${i}: bundleSha256 mismatch`);
  if (row.planDigest !== context.digest) errors.push(`attempt ${i}: planDigest mismatch`);
  const index = window.index[i];
  if (index?.attempt !== i || index?.passports?.start?.path !== context.path) errors.push(`attempt ${i}: index start passport mismatch`);
  const n = need(row,'block_slot');
  const slot = Number.isSafeInteger(n) && n >= 0 ? window.slots[n] : undefined;
  if (!slot) throw new Missing(`attempt ${i}: invalid frozen schedule slot`);
  const order = slot.order.map(a => scheduleArms[a]);
  if (n !== window.slice.firstSlot + Math.floor(i / order.length) || n > window.slice.lastSlot) {
    errors.push(`attempt ${i}: window slots must be traversed in schedule order`);
  }
  if (!deepEq(row.armOrder,order) || row.arm !== order[i % order.length]) errors.push(`attempt ${i}: schedule armOrder mismatch`);
  if (row.warmup !== false) errors.push(`attempt ${i}: frozen window requires warmup:false`);
  if (lc(row.sender) !== lc(slot.senders?.[slot.order.find(a => scheduleArms[a] === row.arm)])) errors.push(`attempt ${i}: schedule sender mismatch`);
  if (row.tripletIndex !== n || typeof slot.pair_id !== 'string' || row.pair_id !== slot.pair_id) errors.push(`attempt ${i}: schedule pair_id or slot mismatch`);
  if (row.schedule_sha256 !== window.scheduleSha || row.seed !== window.seed) errors.push(`attempt ${i}: schedule hash or seed mismatch`);
  const key = `${lc(row.sender)}:${row.arm}`;
  if (Object.values(scheduleArms).includes(row.arm)) {
    const allocationIndex = window.allocations.get(key) ?? 0;
    const planned = JSON.parse(stringify(context.adapter.row(row.arm,allocationIndex)));
    for (const field of ['allocation','spPostOpRule','feeRule']) {
      if (!deepEq(row[field],planned[field])) errors.push(`attempt ${i}: frozen ${field} mismatch`);
    }
    window.allocationKeys.push(`${key}:${row.allocation?.tripletIndex}`);
    const gasSources = structuredClone(row.gasSources);
    if (row.packedOp && gasSources?.preVerification) {
      for (const field of ['bytes','overhead','value']) gasSources.preVerification[field] = null;
      for (const field of ['calldataGas','surplus','resolution','ruleValue','cycle']) delete gasSources.preVerification[field];
    }
    if (!evidenceEqual(gasSources,planned.gasSources)) errors.push(`attempt ${i}: frozen gasSources mismatch`);
    window.allocations.set(key,allocationIndex+1);
  }
  return context;
}

// ── main ──────────────────────────────────────────────────────────────────────────────────
export function validateRun(file, {evidenceDir = dirname(resolve(file)), frozenPlan, registered} = {}) {
  const errors = [], notes = [];
  const report = { formal: false, file, attempts: 0, recomputed: {}, errors, notes };
  let exit;
  try { exit = validateJournal(file,evidenceDir,frozenPlan,{...REGISTERED_WINDOW,...registered},report); }
  catch (e) {
    if (e instanceof Missing) report.missing = e.message;
    else report.crash = String(e?.stack ?? e);
    exit = 2;
  }
  return {...report, validatorExit:exit};
}

function validateJournal(file,evidenceDir,frozenPlan,registered,report) {
  const {errors,notes} = report;
  const lineNumbers = [];
  let lines;
  try { lines = readFileSync(file, 'utf8').split('\n').flatMap((l, i) => {
    if (!l.trim()) return [];
    lineNumbers.push(i+1);
    try { return [JSON.parse(l)]; } catch { throw new Missing(`line ${i + 1}: not JSON`); }
  }); }
  catch (e) { throw e instanceof Missing ? e : new Missing(`cannot read ${file}: ${e.message}`); }
  if (lines.length < 2) throw new Missing('need at least run_start and run_end');
  const start = lines[0], end = lines[lines.length - 1];
  const attempts = lines.slice(1,-1);
  const isFormal = start.formal === true;
  report.formal = isFormal;
  const markerFiles = ['trailer.json','freeze-manifest.json'].map(name=>resolve(evidenceDir,name));
  const markers = markerFiles.filter(existsSync).map(path=>JSON.parse(readFileSync(path,'utf8')).rehearsal === true);
  report.rehearsal = start.rehearsal === true || end.rehearsal === true || markers.some(Boolean);
  if (report.rehearsal) Object.assign(report,{protocolConformant:false,accepted:false,evidence:false});
  if (report.rehearsal && (start.rehearsal !== true || end.rehearsal !== true || markers.some(v=>!v))) errors.push('rehearsal marker mismatch');
  const manifestPath = resolve(evidenceDir,'manifest.json');
  const manifest = existsSync(manifestPath) ? JSON.parse(readFileSync(manifestPath,'utf8')) : null;
  const scheduled = manifest?.schema === 'rq3-window-v1' || [start,...attempts].some(row => Object.hasOwn(row,'planDigest') || Object.hasOwn(row,'bundleSha256'));
  if (scheduled && (!frozenPlan || frozenPlan.startsWith('--'))) throw new Missing('frozen window requires --frozen-plan <bundle file>');
  if (isFormal && !scheduled) errors.push(...validateWindow(evidenceDir, lines));
  if (isFormal && !scheduled) {
    const frozen = formalConfig(need(start,'frozenConfig'),need(start,'bMax'));
    for (const key of ['gas','pmGas']) if (!deepEq(JSON.parse(JSON.stringify(frozen[key],(_,v) => typeof v === 'bigint' ? String(v):v)),start.passport?.invariant[key])) errors.push(`formal frozen ${key}/passport mismatch`);
  }
  if (need(start, 'kind') !== 'run_start') throw new Missing('first line is not run_start');
  // A truncated window still reports what its archive lacks before the line check refuses it.
  if (isFormal && scheduled && end.kind !== 'run_end') for (const name of ['index.ndjson','trailer.json'])
    if (!existsSync(resolve(evidenceDir,name))) { errors.push(`missing or invalid ${name === 'trailer.json' ? 'trailer' : 'index'}: interrupted window`); break; }
  if (need(end, 'kind') !== 'run_end') throw new Missing('last line is not run_end (truncated run?)');
  const schema = need(start, 'schema');
  if (!SCHEMAS.includes(schema)) throw new Missing('unknown schema');
  for (const l of lines) { if (need(l, 'schema') !== schema) throw new Missing('schema differs between lines'); if (need(l, 'runId') !== start.runId) throw new Missing('runId differs between lines'); }
  const checkPassport = (p,location) => {
    if (scheduled && p?.volatile?.cachedPriceUpdatedAt == null) throw new Missing(`${location}: missing volatile.cachedPriceUpdatedAt`);
    completePassport(p,schema,isFormal,errors);
  };
  const window = scheduled ? frozenWindow(manifest,attempts,start,end,
    {path:frozenPlan,evidenceDir,registered,completePassport:checkPassport,errors}) : null;
  if (window) {
    if (isFormal) errors.push(...validateWindow(evidenceDir, lines, window, registered));
    if (!isFormal) errors.push('frozen window requires a formal run');
  }
  if (schema === 'a6-gauge/1') notes.push('schema a6-gauge/1: credit policy not recorded, so this run does not show credit OFF');
  if (start.protocolConformant !== true) notes.push('U-6 stake gate not applied: non-conformant run');
  const pStart = need(start, 'passport');
  const journalLocation = i => `${file}:${lineNumbers.at(i)}`;
  const checkWindowPrice = (p,location) => {
    if (p?.volatile?.cachedPriceUpdatedAt == null) errors.push(`${location}: missing volatile.cachedPriceUpdatedAt`);
    else if (!evidenceEqual(p?.invariant?.superPaymaster?.cachedPrice,pStart.invariant.superPaymaster.cachedPrice) ||
        big(p.volatile.cachedPriceUpdatedAt) !== big(pStart.volatile.cachedPriceUpdatedAt)) {
      errors.push(`${location}: cached price changed within window`);
    }
  };
  checkPassport(pStart,journalLocation(0));
  const startContext = passportContext(pStart);
  const {inv, chainId, armPaymasters} = startContext;
  if (window) {
    const lastDeadline = window.startTimestamp + BigInt(
      window.slots[window.slice.lastSlot].deadline_seconds - window.slots[window.slice.firstSlot].start_seconds);
    if (big(pStart.volatile.cachedPriceUpdatedAt) + big(inv.superPaymaster.priceStalenessThreshold) < lastDeadline) {
      errors.push('cached price expires before the last slice gate deadline');
    }
    const startPath = resolve(evidenceDir,'passports/start.json');
    if (existsSync(startPath)) checkWindowPrice(JSON.parse(readFileSync(startPath,'utf8')),`${startPath}:1`);
    if (!deepEq(pStart,window.senders.values().next().value.pStart)) errors.push('run_start passport differs from first sender start passport');
    for (const [sender,context] of window.senders) {
      checkWindowPrice(context.pStart,resolve(evidenceDir,context.path)+':1');
      if (context.pEnd) checkWindowPrice(context.pEnd,resolve(evidenceDir,context.endPath)+':1');
      if (lc(context.operator) !== lc(startContext.operator)) errors.push(`sender ${sender}: different window operator`);
    }
  }
  const arms = need(start, 'arms');
  const fixture = need(start, 'fixture');
  const count = need(start, 'count');
  const target = window?.target ?? count;
  if (!Number.isSafeInteger(count) || count < 1) throw new Missing('count must be an integer >= 1');
  if (window && (count !== window.target || start.maxAttempts !== window.slice.slots)) errors.push('run_start count or maxAttempts differs from registered window protocol');
  if (!Array.isArray(arms) || !arms.length || new Set(arms).size !== arms.length || arms.some(a => !['SP', 'VPM', 'TPM'].includes(a))) throw new Missing('invalid arms');
  if (new Set(Object.values(armPaymasters).map(lc)).size !== 3) errors.push('passport arm paymasters must be distinct');
  if (need(start, 'allowSameEndpointLocal') !== pStart.allowSameEndpointLocal) errors.push('start/passport local override mismatch');
  const endpointA = endpoint(need(start, 'rpcA')), endpointB = endpoint(need(start, 'rpcB'));
  const distinctEndpoints = endpointA.host !== endpointB.host && endpointA.host !== 'loopback' && endpointB.host !== 'loopback';
  const localOverride = start.allowSameEndpointLocal === true || pStart.allowSameEndpointLocal === true;
  if (!distinctEndpoints && !(localOverride && endpointA.port !== endpointB.port)) errors.push('RPC identities require different non-loopback hosts or different ports with explicit local override');
  const conformant = isFormal && start.rehearsal !== true && count === (window?.target ?? 50) && noFixture(fixture) && arms.length === 3 && ['SP', 'VPM', 'TPM'].every(a => arms.includes(a)) && distinctEndpoints && !localOverride;
  if (need(start, 'protocolConformant') !== conformant) errors.push('protocolConformant differs from recomputed count/fixture/arms/endpoints/override');
  if (start.protocolConformant && (!distinctEndpoints || localOverride)) errors.push('conformant run requires distinct endpoints without local override');
  // /1 never recorded credit state, so relabelling a run as /1 must not yield a conformant result.
  if (start.protocolConformant && schema !== 'a6-gauge/2') errors.push('conformant run requires a6-gauge/2 (credit OFF recorded)');
  if (isFormal) errors.push(...inclusionErrors(attempts));
  if (report.rehearsal) notes.push('rehearsal: non-compliant / non-evidence');
  // A declared state intervention (rehearsal-refresh.mjs) is valid only in a rehearsal, and only as the TPM cache-aging control.
  for (const [i, r] of attempts.entries()) if (r.rehearsalControl != null && (!report.rehearsal || r.rehearsalControl.kind !== 'tpmCacheAged' || r.arm !== 'TPM')) errors.push(`attempt ${i}: rehearsal control outside a rehearsal TPM attempt`);
  const byTriplet = new Map();
  let stoppedRows = 0;
  let previousBlock = { blockNumber: pStart.block.number, blockHash: pStart.block.hash };
  const seenTx = new Set(), seenOps = new Set(), seenBlocks = new Set(), stateByArm = new Map();
  const nonceSequences = new Map(), firstNonceSequences = new Map();
  const lastSPTimestamps = new Map();
  let lastAttemptHeight = big(pStart.block.number), lastAfterBalance = big(pStart.volatile.operatorBalance);
  const allEarlierHashes = new Set([lc(pStart.block.hash)]);
  const balanceReadbacks = new Map();
  let previousOperatorBalance = big(pStart.volatile.operatorBalance);
  const sponsorshipReady = p => !p.invariant.superPaymaster.paused && p.invariant.superPaymaster.senderEligible
    && p.invariant.superPaymaster.operator.isConfigured && !p.invariant.superPaymaster.operator.isPaused
    && !p.invariant.xPNTs.emergencyDisabled;

  attempts.forEach((row, i) => {
    const slotRows = window ? byTriplet.get(row.block_slot) ?? [] : null;
    const {pStart,inv,spAddr,armPaymasters,tokenAddr,operator,chainId,phaseC,pEnd} = window ? frozenAttempt(window,row,i,errors) : startContext;
    const endPassport = window ? pEnd : end.passport;
    if (window && (row.passport || !row.stoppedBy)) checkWindowPrice(row.passport,journalLocation(i+1));
    if (pEnd && row.passport) {
      const within = (number,time) => big(number) >= big(pStart.block.number) && big(number) <= big(pEnd.block.number)
        && big(time) >= big(pStart.block.timestamp) && big(time) <= big(pEnd.block.timestamp);
      const pin = need(row,'passport.block');
      if (!within(pin.number,pin.timestamp) || big(pin.number) >= big(pEnd.block.number)
          || (row.sent && (!within(row.tx.blockNumber,row.tx.blockTimestamp)
          || big(row.tx.blockNumber) >= big(pEnd.block.number) || big(row.tx.blockNumber) <= big(pin.number)))) {
        errors.push(`attempt ${i}: attempt outside sender passport bracket`);
      }
    }
    const slotFailure = window && slotFailures.includes(row.failingCheck);
    const gatesMatch = window && slotGatesMatch(window,row,slotFailure);
    const deniedGate = slotFailure && gatesMatch;
    if (window && !slotFailure && !gatesMatch) errors.push(`attempt ${i}: invalid slot gates`);
    const recordVerdict = recomputed => {
      report.recomputed[recomputed] = (report.recomputed[recomputed] ?? 0) + 1;
      if (recomputed !== row.verdict) errors.push(`attempt ${i} (${row.arm}): recorded ${row.verdict}, recomputed ${recomputed}`);
      if (!byTriplet.has(row.tripletIndex)) byTriplet.set(row.tripletIndex, []);
      byTriplet.get(row.tripletIndex).push({ row, recomputed });
    };
    try { if (!row.stoppedBy) bindReceiptSummaries(row); } catch (e) { errors.push(`attempt ${i}: ${e.message}`); }
    errors.push(...dispositionErrors(slotFailure && row.exclusion == null ? {...row,exclusion:row.failingCheck} : row).map(e => `attempt ${i}: ${e}`), ...feePauseErrors(row).map(e => `attempt ${i}: ${e}`));
    if (EXCLUSION_REASONS.includes(row.reason)) {
      try { exclusionReason(row); } catch (e) { errors.push(`attempt ${i}: ${e.message}`); }
    }
    if (isFormal && !window && !deepEq(row.armOrder,armOrder(row.tripletIndex))) errors.push(`attempt ${i}: formal armOrder mismatch`);
    if (slotFailure && (row.sent !== false || row.verdict !== 'NOT_SENT' || row.scheduleDisposition !== row.failingCheck
        || !deniedGate)) errors.push(`attempt ${i}: invalid schedule disposition`);
    if (row.sent === false && (need(row, 'tx') !== null || (!(slotFailure && !('logs' in row)) && (!Array.isArray(need(row, 'logs')) || row.logs.length !== 0))
        || 'readbacks' in row || !(slotFailure || ['deposit_floor', 'preflight_revert', 'basefee_above_cap'].includes(row.failingCheck)))) {
      errors.push(`attempt ${i}: NOT_SENT contradicts row evidence or failingCheck`);
    }
    if (row.sent) {
      const height = big(need(row, 'tx.blockNumber'));
      if (height > lastAttemptHeight) lastAttemptHeight = height;
      const lastAfter = row.readbacks?.after?.A;
      if (lastAfter && 'operatorBalance' in lastAfter) lastAfterBalance = big(lastAfter.operatorBalance);
    }
    if (row.readbacks) for (const side of ['before', 'after']) for (const rpc of ['A', 'B']) {
      const rb = row.readbacks[side]?.[rpc];
      if (rb?.blockHash) allEarlierHashes.add(lc(rb.blockHash));
    }
    // Apply no-execution invariance before STOPPED/unsent handling as well.
    if (row.arm === 'SP' && row.readbacks && (!row.sent || row.tx?.status !== 'success'
      || !logsOf(row.logs ?? [], row.entryPoint, T.UOE).some(l => lc(topicAddr(l.topics[3])) === lc(row.paymaster)))) {
      for (const rpc of ['A', 'B']) for (const f of ['epDeposit', ...SP_FIELDS]) {
        if (!deepEq(need(row, `readbacks.before.${rpc}.${f}`), need(row, `readbacks.after.${rpc}.${f}`))) errors.push(`attempt ${i}: no_execution.${f}`);
      }
    }
    // Stops exclude counting, but do not waive receipt-backed state attribution.
    if (row.arm === 'SP' && row.sent && row.tx?.status === 'success' && row.readbacks &&
        (row.verdict === 'STOPPED' || row.stoppedBy) && logsOf(row.logs ?? [], row.entryPoint, T.UOE).length) {
      for (const rpc of ['A', 'B']) {
        const failures = conservation({ ...row, readbacks: { before: { A: row.readbacks.before[rpc] }, after: { A: row.readbacks.after[rpc] } } }, spAddr, tokenAddr, operator, inv, isFormal);
        if (failures.length) errors.push(`attempt ${i}: stopped receipt ${rpc}: ${failures.join(',')}`);
      }
    }
    if (need(row, 'kind') !== 'attempt') throw new Missing(`line ${i + 2}: unexpected kind ${row.kind}`);
    if (need(row, 'attemptIndex') !== i) errors.push(`attemptIndex ${row.attemptIndex} at position ${i} (rows missing or reordered)`);
    for (const k of ['tripletIndex', 'arm', 'fixture', 'verdict', 'collectedAtUtc']) need(row, k);
    if (row.fixture !== fixture) errors.push(`attempt ${i}: row fixture differs from run fixture`);
    report.attempts++;
    // A stop does not waive block evidence for an already-sent transaction.
    if (row.sent && (row.verdict === 'STOPPED' || row.stoppedBy)) {
      const b = need(row, 'readbacks.before.A'), a = need(row, 'readbacks.after.A');
      if (big(need(b, 'blockNumber')) + 1n !== big(need(a, 'blockNumber')) || big(a.blockNumber) !== big(need(row, 'tx.blockNumber'))) errors.push(`attempt ${i}: readback_blocks_bracket_tx`);
      if (lc(need(a, 'blockHash')) !== lc(need(row, 'tx.blockHash'))) errors.push(`attempt ${i}: readback_after_blockhash_eq_tx_block`);
    }
    if (row.verdict === 'STOPPED' || row.stoppedBy) {
      stoppedRows++;
      notes.push(`attempt ${i}: stopped by ${need(row, 'stoppedBy.reason')}`);
      if (row.verdict === 'STOPPED') {
        if (window) byTriplet.set(row.tripletIndex,[...slotRows,{row,recomputed:'STOPPED'}]);
        return;
      }
    }
    if (slotFailure && row.sent === false) {
      if (!deniedGate || row.slotChecks.length === 1) {
        if (deniedGate && ['nonce','packedOp','guard'].some(field => Object.hasOwn(row,field))) {
          errors.push(`attempt ${i}: early gate contains packing evidence`);
        }
        recordVerdict('NOT_SENT');
        return;
      }
      if (!row.packedOp || row.nonce == null || row.guard?.allowed !== true) {
        errors.push(`attempt ${i}: submit gate missing packing evidence`);
        recordVerdict('NOT_SENT');
        return;
      }
    }
    for (const k of ['chainId', 'entryPoint', 'sender', 'nonce', 'paymaster', 'bundler', 'callDataHash', 'gas', 'pmGas',
      'expectedUserOpHash', 'epUserOpHash', 'localUserOpHash', 'bundledUserOpHashes', 'packedOp', 'bundledOps', 'guard', 'sent']) need(row, k);
    const logs = slotFailure && row.sent === false && !('logs' in row) ? [] : need(row,'logs');
    if (row.chainId !== chainId) errors.push(`attempt ${i}: chainId ${row.chainId} != passport ${chainId}`);
    if (!arms.includes(row.arm)) errors.push(`attempt ${i}: unexpected arm`);
    if (lc(row.entryPoint) !== lc(inv.entryPoint.address) || lc(row.entryPoint) !== lc(inv.armEntryPoints[row.arm])) errors.push(`attempt ${i}: EntryPoint passport mismatch`);
    if (lc(row.sender) !== lc(inv.sender)) errors.push(`attempt ${i}: sender passport mismatch`);
    if (!/^0x[0-9a-f]{40}(?:[0-9a-f]{2}){32,}$/i.test(row.packedOp.paymasterAndData)) throw new Missing('malformed packed paymasterAndData');
    // EntryPoint:427-430 at the pin rejects initCode for an existing account.
    if (big(inv.code.account.size) > 0n && row.packedOp.initCode !== '0x') errors.push(`attempt ${i}: initCode for deployed account`);
    if (row.arm === 'SP' && (row.packedOp.paymasterAndData.length < 146 || lc('0x' + row.packedOp.paymasterAndData.slice(106, 146)) !== lc(operator))) errors.push(`attempt ${i}: packed operator passport mismatch`);
    const packedPaymaster = row.packedOp.paymasterAndData.slice(0, 42);
    if (lc(row.paymaster) !== lc(packedPaymaster) || lc(row.paymaster) !== lc(armPaymasters[row.arm])) errors.push(`attempt ${i}: packed/arm/passport paymaster mismatch`);
    const pmData = row.packedOp.paymasterAndData;
    const pmGas = { ver: BigInt('0x' + pmData.slice(42, 74)), post: BigInt('0x' + pmData.slice(74, 106)) };
    if (['ver', 'post'].some(f => big(need(row.pmGas, f)) !== pmGas[f] || big(need(inv, `pmGas.${row.arm}.${f}`)) !== pmGas[f])) errors.push(`attempt ${i}: paymaster gas passport mismatch`);
    const executed = row.sent && row.tx?.status === 'success' && logsOf(row.logs, row.entryPoint, T.UOE).some(l =>
      lc(l.topics[1]) === lc(hashOp(row.packedOp, row.entryPoint, chainId)) && lc(topicAddr(l.topics[2])) === lc(row.sender)
      && BigInt(word(l.data, 0)) === big(row.nonce) && lc(topicAddr(l.topics[3])) === lc(row.paymaster));
    if (row.arm === 'SP' && executed) {
      if (pmGas.post < big(inv.superPaymaster.minPostOpGas)) errors.push(`attempt ${i}: paymaster postOp gas below contract floor`);
      if (pmData.length < 250) errors.push(`attempt ${i}: SP packed tail truncated`);
      else {
        if (lc('0x' + pmData.slice(210, 250)) !== lc(inv.superPaymaster.operator.xPNTsToken)) errors.push(`attempt ${i}: SP packed token mismatch`);
        if (BigInt('0x' + pmData.slice(146, 210)) < big(inv.xPNTs.exchangeRate)) errors.push(`attempt ${i}: SP maxRate below exchangeRate`);
        const flags = pmData.length > 250 ? parseInt(pmData.slice(250, 252), 16) : 0;
        if ((flags & 3) === 3) errors.push(`attempt ${i}: SP conflicting renewal flags`);
      }
    }
    // hash self-check, recomputed here
    const h = hashOp(row.packedOp, row.entryPoint, chainId);
    if (lc(h) !== lc(row.epUserOpHash) || lc(h) !== lc(row.localUserOpHash)) errors.push(`attempt ${i}: userOpHash recomputation ${h} != recorded ep/local`);
    if (lc(row.expectedUserOpHash) !== lc(h) && fixture !== 'wrong-hash') errors.push(`attempt ${i}: expected hash differs from the op's hash outside the wrong-hash fixture`);
    if (lc(row.sender) !== lc(row.packedOp.sender) || big(row.nonce) !== big(row.packedOp.nonce)) errors.push(`attempt ${i}: packed sender/nonce mismatch`);
    row.derivedCallDataHash = keccak256(row.packedOp.callData);
    row.derivedGas = opGas(row.packedOp);
    if (lc(row.callDataHash) !== lc(row.derivedCallDataHash)) errors.push(`attempt ${i}: callDataHash mismatch`);
    if (GAS_FIELDS.some(f => big(need(row.gas, f)) !== big(row.derivedGas[f]))) errors.push(`attempt ${i}: packed gas mismatch`);
    if (noFixture(fixture) && (lc(row.derivedCallDataHash) !== lc(inv.callDataHash) || GAS_FIELDS.some(f => (!window || f !== 'preVerificationGas') && big(row.derivedGas[f]) !== big((isFormal ? inv.gas[row.arm] : inv.gas)[f])))) errors.push(`attempt ${i}: operation callData/gas passport mismatch`);
    if (window) {
      try {
        checkPVGLengths(row.packedOp,phaseC.pvgLengths[row.arm]);
        const pvg = big(row.derivedGas.preVerificationGas);
        const surplus = pvg - measurePVG({...row.packedOp,nonce:big(row.nonce),preVerificationGas:pvg},inv.beneficiary).value;
        if (pvg > big(phaseC.pvgReserve[row.arm]) || surplus < 0n || surplus > PVG_MAX_SURPLUS || surplus !== big(row.pvgSurplus)) errors.push(`attempt ${i}: frozen preVerificationGas mismatch`);
      } catch (e) {
        if (e.message !== 'PVG_LENGTHS') throw e;
        errors.push(`attempt ${i}: ${e.message}`);
      }
    }
    const bundledHashes = row.bundledOps.map((op) => hashOp(op, row.entryPoint, chainId));
    if (!deepEq(bundledHashes, row.bundledUserOpHashes)) errors.push(`attempt ${i}: bundled hashes do not recompute`);
    if (fixture !== 'drop-op' && !row.bundledOps.some(op => deepEq(op, row.packedOp))) errors.push(`attempt ${i}: packedOp absent from bundledOps`);
    const extraEvents = logsOf(logs, row.entryPoint, T.UOE).filter(l => lc(l.topics[1]) !== lc(row.expectedUserOpHash));
    if (extraEvents.length) {
      (report.extraUserOperationEvents ??= []).push({ attemptIndex: i, logs: extraEvents });
      // This single-op gauge cannot attribute aggregate deposit deltas for extra operations.
      if (noFixture(fixture)) errors.push(`attempt ${i}: extra UserOperationEvent in single-op receipt`);
    }
    if (row.sent) for (const k of ['tx.hash', 'tx.status', 'tx.blockNumber', 'tx.blockHash', 'tx.blockTxCount', 'tx.headBefore', 'tx.from']) need(row, k);
    if (row.sent && (lc(row.bundler) !== lc(row.tx.from) || lc(row.tx.from) !== lc(inv.bundler))) errors.push(`attempt ${i}: transaction bundler mismatch`);
    const v = verdictOf(row);
    const recomputed = typeof v === 'string' ? v : v.verdict;
    recordVerdict(recomputed);
    if (recomputed === 'USEROP_SUCCESS' && lc(row.expectedUserOpHash) !== lc(h)) errors.push(`attempt ${i}: success hash is not packedOp hash`);
    if (row.sent && row.tx.status === 'success' && logsOf(row.logs, row.entryPoint, T.UOE).some(l => lc(l.topics[1]) === lc(h))) {
      const timestamp = big(need(row, 'tx.blockTimestamp'));
      if (timestamp < big(pStart.block.timestamp) || timestamp > big(need(endPassport ?? end.passport, 'block.timestamp'))) errors.push(`attempt ${i}: tx timestamp outside passport bracket`);
      if (row.arm === 'VPM') {
        if (pmData.length < 234) throw new Missing('truncated VPM validity data');
        const until = BigInt('0x' + pmData.slice(106, 170)), after = BigInt('0x' + pmData.slice(170, 234));
        if (until >= 1n << 48n || after >= 1n << 48n || timestamp < after || (until !== 0n && timestamp > until)) errors.push(`attempt ${i}: VPM validity outside block time`);
      }
      if (row.arm === 'SP') {
        const sender = window ? `${lc(operator)}:${lc(inv.sender)}` : lc(inv.sender), lastSPTimestamp = lastSPTimestamps.get(sender);
        if (lastSPTimestamp !== undefined && timestamp < lastSPTimestamp + big(inv.superPaymaster.operator.minTxInterval)) errors.push(`attempt ${i}: SP minTxInterval violated`);
        if (!logsOf(row.logs, row.entryPoint, T.POSTOP).some(l => lc(l.topics[1]) === lc(h))) lastSPTimestamps.set(sender,timestamp);
      }
    }
    if (row.sent && row.tx.status === 'success' && logsOf(row.logs, row.entryPoint, T.UOE).some(l => lc(l.topics[1]) === lc(h))) {
      // NonceManager:36-40 at the pin: sender + uint192 key, uint64 sequence.
      const nonce = big(row.packedOp.nonce), key = `${lc(row.sender)}:${nonce >> 64n}`, sequence = nonce & ((1n << 64n) - 1n);
      // A demonstrated intervening block explains external same-key activity at stop 28.
      // A stop label alone cannot excuse a nonce gap in otherwise contiguous evidence.
      const interrupted = row.stoppedBy?.reason === 'EVIDENCE_CONTINUITY_MISMATCH'
        && end.stop?.reason === 'EVIDENCE_CONTINUITY_MISMATCH' && end.stop.code === 28 && end.exitCode === 28
        && big(need(row, 'readbacks.before.A.blockNumber')) > big(previousBlock.blockNumber);
      if (!interrupted && nonceSequences.has(key) && sequence !== nonceSequences.get(key) + 1n) errors.push(`attempt ${i}: nonce sequence must advance exactly one for sender/key`);
      if (!firstNonceSequences.has(key)) firstNonceSequences.set(key, sequence);
      nonceSequences.set(key, sequence);
      if (row.arm === 'SP') {
        if ((endPassport || !window) && (!sponsorshipReady(pStart) || !sponsorshipReady(endPassport ?? need(end, 'passport')))) errors.push(`attempt ${i}: passport not sponsor-able`);
        const validUntil48 = (big(pStart.volatile.cachedPriceUpdatedAt) + big(inv.superPaymaster.priceStalenessThreshold)) % (1n << 48n);
        const quoteValidUntil = validUntil48 === 0n ? (1n << 48n) - 1n : validUntil48;
        if (window) {
          if (recomputed === 'USEROP_SUCCESS' && quoteValidUntil < big(need(row, 'tx.blockTimestamp'))) errors.push(`attempt ${i}: cached price expires before SP inclusion`);
        } else {
          const endUntil48 = (big(need(endPassport, 'volatile.cachedPriceUpdatedAt')) + big(inv.superPaymaster.priceStalenessThreshold)) % (1n << 48n);
          if ((endUntil48 === 0n ? (1n << 48n) - 1n : endUntil48) < big(endPassport.block.timestamp)) errors.push(`attempt ${i}: end cached price expires before passport block`);
          if (quoteValidUntil < big(pStart.block.timestamp) || quoteValidUntil < big(need(endPassport, 'block.timestamp'))) errors.push(`attempt ${i}: cached price expires within passport block bracket`);
        }
      }
    }
    if (row.sent && !row.stoppedBy) {
      need(row, 'readbacks.before.B'); need(row, 'readbacks.after.B');
      for (const side of ['before', 'after']) {
        if (!deepEq(row.readbacks[side].A, row.readbacks[side].B)) errors.push(`attempt ${i}: A/B read-backs (${side}) disagree in a row that was not stopped`);
      }
      if (isFormal ? big(row.tx.blockNumber) <= big(row.tx.headBefore) : row.tx.blockTxCount !== 1 || big(row.tx.blockNumber) !== big(row.tx.headBefore) + 1n) errors.push(`attempt ${i}: tx block not isolated`);
      const before = row.readbacks.before.A, after = row.readbacks.after.A;
      if (i === attempts.length - 1) need(after, 'operatorBalance');
      for (const [value, seen, label] of [[lc(row.tx.hash), seenTx, 'transaction'], [lc(h), seenOps, 'userOpHash'], [lc(row.tx.blockHash), seenBlocks, 'block']]) {
        if (seen.has(value)) errors.push(`attempt ${i}: reused ${label}`);
        seen.add(value);
      }
      if (isFormal ? big(need(before, 'blockNumber')) < big(previousBlock.blockNumber) : big(need(before, 'blockNumber')) !== big(previousBlock.blockNumber) || lc(need(before, 'blockHash')) !== lc(previousBlock.blockHash)) errors.push(`attempt ${i}: consecutive block continuity failed`);
      const previous = stateByArm.get(row.arm);
      const senderPrior = window && stateByArm.get(`${row.arm}:${lc(row.sender)}`);
      if (report.rehearsal && row.arm === 'TPM' && row.rehearsalControl?.kind === 'tpmCacheAged' && (row.rehearsalControl.cachedPriceTimestamp?.to == null || big(need(before, 'tpmCachedPriceTimestamp')) !== big(row.rehearsalControl.cachedPriceTimestamp.to))) errors.push(`attempt ${i}: rehearsal cache timestamp mismatch`);
      // Other arms use separate deposits/tokens and cannot change these fields. lockXLocked
      // and inflight state are keyed by opHash: a new op starts empty, rather than inheriting the prior reservation.
      if (previous) for (const f of ['epDeposit', ...(row.arm === 'SP' ? SP_FIELDS.filter(f => !['lockXLocked', 'inflightA0', 'inflightOperator'].includes(f)) : row.arm === 'TPM' ? ['tpmCachedPriceTimestamp', 'tpmTokenBalances'].filter(f => isFormal || f in before || f in previous) : [])]) {
        if (f === 'tpmCachedPriceTimestamp' && report.rehearsal && row.rehearsalControl?.kind === 'tpmCacheAged') {
          continue;
        }
        if (window && f === 'operatorBalance') continue;
        const value = need(before,f);
        let prior = need(previous,f);
        if (window && senderStateFields.includes(f)) prior = senderPrior ? need(senderPrior,f) : value;
        if (window && f === 'tpmTokenBalances') prior = {...prior,sender:senderPrior ? need(senderPrior,'tpmTokenBalances.sender') : need(value,'sender')};
        if (!deepEq(value,prior)) errors.push(`attempt ${i}: balance continuity failed: ${f}`);
      }
      // Shared SP balance follows chronological attempts, not the previous baseline arm.
      // Older baseline rows may omit it; SP state continuity and exact-hash passport
      // anchors remain mandatory. Every recorded baseline readback is checked.
      if (window) { need(before,'operatorBalance'); need(after,'operatorBalance'); }
      if ('operatorBalance' in before && big(before.operatorBalance) !== previousOperatorBalance) errors.push(`attempt ${i}: balance continuity failed: operatorBalance`);
      if (row.arm !== 'SP') for (const rb of [before, after]) {
        if ('operatorBalance' in rb && big(rb.operatorBalance) !== previousOperatorBalance) errors.push(`attempt ${i}: baseline changed operatorBalance`);
      }
      if (row.arm === 'SP') previousOperatorBalance = big(need(after, 'operatorBalance'));
      if (row.arm === 'SP' && big(need(before, 'lockXLocked')) !== 0n) errors.push(`attempt ${i}: new op lock must start empty`);
      for (const side of ['before', 'after']) for (const rpc of ['A', 'B']) {
        const rb = row.readbacks[side][rpc];
        if ('operatorBalance' in rb) {
          const key = lc(need(rb, 'blockHash')), value = big(rb.operatorBalance);
          if (balanceReadbacks.has(key) && balanceReadbacks.get(key) !== value) errors.push(`attempt ${i}: same-block operatorBalance readbacks disagree`);
          balanceReadbacks.set(key, value);
        }
      }
      stateByArm.set(row.arm, after);
      if (window) stateByArm.set(`${row.arm}:${lc(row.sender)}`,after);
      previousBlock = after;
      const failed = conservation(row, spAddr, tokenAddr, operator, inv, isFormal);
      const recordedOk = need(row, 'conservation.ok');
      const citations = { 'C6.locked_unchanged': 'XT:240,263', 'R2.locked_grew_by_xLocked': 'XT:240', "C5'.credit_reserved_unchanged": 'XT:305,322' };
      for (const c of need(row, 'conservation.checks')) if (c.id in citations && c.src !== citations[c.id]) errors.push(`attempt ${i}: incorrect source citation ${c.id}`);
      const notEvaluable = failed.includes('R.not_evaluable_missing_lock_created');
      if (notEvaluable) {
        (report.notEvaluable ??= []).push({ attemptIndex: i, reason: 'missing unique LockCreated or CreditReserved: R1/R2 cannot be evaluated', countable: false });
      }
      const actualFailures = failed.filter(f => f !== 'R.not_evaluable_missing_lock_created');
      if (actualFailures.length) errors.push(`attempt ${i} (${row.arm}): conservation FAILS on raw read-backs: ${actualFailures.join(',')}`);
      const evaluated = !notEvaluable && logsOf(row.logs, row.entryPoint, T.UOE).some(l => lc(l.topics[1]) === lc(row.expectedUserOpHash));
      if (need(row, 'conservation.evaluated') !== evaluated) errors.push(`attempt ${i}: conservation.evaluated mismatch`);
      if (!evaluated && recordedOk !== null && recordedOk !== false) errors.push(`attempt ${i}: unevaluated conservation cannot pass`);
      if (evaluated && (failed.length === 0) !== recordedOk) errors.push(`attempt ${i}: recorded conservation.ok=${recordedOk}, recomputed ${failed.length === 0}`);
    }
  });
  // matched triplets, recomputed
  let matched = 0;
  let triplets = [];
  let tally = Object.fromEntries(arms.map(arm => [arm, { attempts: 0, verdicts: {} }]));
  for (const row of attempts) {
    // attempt() throws after writing a stopped row, before the loop tallies it.
    if (row.verdict === 'STOPPED' || row.stoppedBy) {
      if (window && tally[row.arm]) tally[row.arm].attempts++;
      break;
    }
    if (!tally[row.arm]) continue;
    tally[row.arm].attempts++;
    tally[row.arm].verdicts[row.verdict] = (tally[row.arm].verdicts[row.verdict] ?? 0) + 1;
  }
  for (const [tripletIndex, rows] of byTriplet) {
    // A row interrupted by a stop condition never counts, whatever its receipt said.
    const okArms = arms.every((arm) => rows.some((r) => r.row.arm === arm && r.recomputed === 'USEROP_SUCCESS' && (!(isFormal || r.row.traces) || !tpmAttemptRefreshed(r.row)) && r.row.conservation?.evaluated === true && r.row.conservation?.ok === true && !r.row.stoppedBy));
    const sentRows = rows.filter(r => r.row.sent);
    const same = new Set(sentRows.map((r) => window ? r.row.derivedCallDataHash : `${r.row.derivedCallDataHash}|${JSON.stringify(isFormal ? {maxFeePerGas:r.row.derivedGas.maxFeePerGas,maxPriorityFeePerGas:r.row.derivedGas.maxPriorityFeePerGas} : r.row.derivedGas)}|${lc(r.row.tx?.from)}|${lc(r.row.entryPoint)}|${lc(r.row.sender)}`)).size <= 1;
    if (!same) errors.push('triplet callData/gas/bundler differ between arms');
    const distinct = ['paymaster', 'expectedUserOpHash'].every(f => new Set(sentRows.map(r => lc(r.row[f]))).size === sentRows.length)
      && new Set(sentRows.map(r => lc(r.row.tx?.hash))).size === sentRows.length;
    if (!distinct) errors.push('triplet paymasters/transaction hashes/userOpHashes must be distinct');
    const complete = rows.length === arms.length && rows.every(r => r.row.verdict !== 'STOPPED' && !r.row.stoppedBy);
    const ok = noFixture(fixture) && okArms && same && distinct && complete;
    const attemptIndices = rows.map(r => r.row.attemptIndex);
    if (window) triplets.push({block_slot:tripletIndex,pair_id:window.slots[tripletIndex]?.pair_id,matched:ok,attempts:attemptIndices,tripletIndex});
    else if (complete || (isFormal && rows.some(r => r.row.reason === 'basefee_above_cap'))) triplets.push({ tripletIndex, ...(isFormal ? {armOrder:armOrder(tripletIndex)}:{}), matched: ok, attempts: attemptIndices });
    if (ok) {
      matched++;
      if (!window && end.stop?.reason === 'COMPLETE' && matched === target && rows.at(-1).row.attemptIndex !== attempts.length - 1) errors.push('attempt after COMPLETE target reached');
    }
  }
  if (window) {
    const {slice, slots, scheduleSha, cap} = window;
    const exhausted = end.stop?.code === 0;
    if (exhausted && (end.stop.reason !== 'EXHAUSTED' || attempts.length !== slice.slots*3 || stoppedRows !== 0)) {
      errors.push('EXHAUSTED window must attempt all slice slots without a stop');
    }
    // A passport check after writing the last attempt can stop traversal before its verdict is tallied.
    const last = attempts.at(-1);
    const traversalStopped = !exhausted && last && (stoppedRows > 0 || attempts.length < slice.slots*3 ||
      (end.stop?.reason === 'PASSPORT_DRIFT' && end.stop.detail?.attemptIndex === last.attemptIndex));
    if (traversalStopped) {
      const finalSlot = triplets.at(-1);
      if (finalSlot?.matched) {
        finalSlot.matched = false;
        matched--;
      }
      if (!last.stoppedBy && last.verdict !== 'STOPPED' && tally[last.arm]) {
        const verdicts = tally[last.arm].verdicts;
        if (--verdicts[last.verdict] === 0) delete verdicts[last.verdict];
      }
    }
    const usedSlots = triplets.length;
    const expected = {schedule_sha256:scheduleSha,stoppingRule:registered.stoppingRule,status:exhausted?'EXHAUSTED':'STOPPED',
      targetTriplets:target,slotCap:cap,windowIndex:slice.windowIndex,firstSlot:slice.firstSlot,lastSlot:slice.lastSlot,
      scheduledSlots:slice.slots,usedSlots,completeTriplets:matched,
      unusedSlots:slots.slice(slice.firstSlot+usedSlots,slice.lastSlot+1).map(slot=>slot.block_slot)};
    if (!evidenceEqual(end.window,expected) || end.scheduledSlots !== slice.slots || end.attemptedSlots !== usedSlots
        || end.warmupAttempts !== registered.warmupAttempts) errors.push('window record differs from reconstructed slice');
  }
  // finish() can write the last row before passport@bn throws. Only that row's
  // accounting is ambiguous; select one whole summary, never mix its fields.
  const last = attempts.at(-1);
  if (!window && last && ![0, 10].includes(end.stop?.code) && Number.isInteger(end.stop?.code)
      && !attempts.some(row => row.verdict === 'STOPPED' || row.stoppedBy)) {
    const untallied = structuredClone(tally);
    const arm = untallied[last.arm];
    arm.attempts--;
    if (--arm.verdicts[last.verdict] === 0) delete arm.verdicts[last.verdict];
    const lastTriplet = triplets.at(-1);
    const completed = lastTriplet?.attempts.includes(last.attemptIndex);
    const partialTriplets = completed ? triplets.slice(0, -1) : triplets;
    const partialMatched = matched - (completed && lastTriplet.matched ? 1 : 0);
    if (deepEq(end.tally, untallied) && deepEq(end.triplets, partialTriplets) && end.matchedTriplets === partialMatched) {
      tally = untallied; triplets = partialTriplets; matched = partialMatched;
    }
  }
  if (!deepEq(need(end, 'tally'), tally)) errors.push('run_end.tally differs from recomputed tally');
  if (!deepEq(need(end, 'triplets'), triplets)) errors.push('run_end.triplets differs from recomputed triplets');
  if (need(end, 'targetTriplets') !== target) errors.push('run_end.targetTriplets differs from run_start.count');
  report.matchedTriplets = matched;
  if (need(end, 'matchedTriplets') !== matched) errors.push(`run_end.matchedTriplets ${end.matchedTriplets} != recomputed ${matched}`);
  const stop = need(end, 'stop');
  report.stop = stop.reason;
  report.exitCode = need(end, 'exitCode');
  if (report.exitCode !== need(stop, 'code')) errors.push('run_end.exitCode differs from stop.code');
  // passport drift, recomputed
  checkPassport(need(end, 'passport'),journalLocation(-1));
  // U-6 applies only to protocol-conformant runs, at both pinned passport blocks.
  if (start.protocolConformant === true) {
    const passports = [pStart,end.passport,...(window ? [...window.senders.values()].flatMap(c=>[c.pStart,c.pEnd].filter(Boolean)) : [])];
    for (const arm of ['SP', 'VPM', 'TPM']) {
      const stakes = passports.map(p => p.invariant.stakes[arm]);
      if (stakes.some(s => s.staked !== true)) errors.push(`arm ${arm}: paymaster not staked`);
      if (stakes.some(s => big(s.stake) < 1000000000000000000n)) errors.push(`arm ${arm}: paymaster stake below 1000000000000000000 wei`);
      if (stakes.some(s => big(s.unstakeDelaySec) < 86400n)) errors.push(`arm ${arm}: paymaster unstakeDelaySec below 86400`);
    }
  }
  if (window) checkWindowPrice(end.passport,journalLocation(-1));
  if (!deepEq(inv, need(end, 'passport.invariant'))) errors.push('passport invariant drifted between run_start and run_end');
  if (pStart.allowSameEndpointLocal !== end.passport.allowSameEndpointLocal) errors.push('passport local override drifted');
  if (big(end.passport.chainId) !== big(chainId)) errors.push('end passport chainId differs from start');
  if (big(end.passport.block.number) <= lastAttemptHeight) errors.push('end passport block must be strictly after last attempt');
  if (allEarlierHashes.has(lc(end.passport.block.hash))) errors.push('end passport reuses earlier block hash');
  if (big(end.passport.volatile.operatorBalance) !== lastAfterBalance) errors.push('end passport balance differs from last after');
  if (big(need(end, 'passport.block.timestamp')) < big(pStart.block.timestamp)) errors.push('end passport timestamp precedes start');
  if (!isFormal && arms.includes('SP') && attempts.some(r => r.sent)) for (const [label, p] of [['start', pStart]]) {
    const value = balanceReadbacks.get(lc(p.block.hash));
    if (value === undefined) { if (!errors.length) throw new Missing(`${label} passport requires operatorBalance readback at same block hash`); continue; }
    if (value !== big(p.volatile.operatorBalance)) errors.push(`${label} passport/readback operatorBalance mismatch`);
  }
  report.protocolConformant = conformant && errors.length === 0;
  report.consistent = errors.length === 0;
  report.accepted = !report.rehearsal && report.consistent && stop.code === 0 && stoppedRows === 0 &&
    (window ? stop.reason === 'EXHAUSTED' && conformant : stop.reason === 'COMPLETE' && matched === target && (target !== 50 || conformant));
  if (window) {
    report.evidence = report.accepted;
    if (report.accepted) report.window = {
      runId:start.runId, ...window.slice, slots:triplets.map(t=>t.block_slot),
      scheduleSha256:window.scheduleSha, bundleSha256:window.bundleSha256,
      chainId, accounts:[...window.senders.keys()], allocationKeys:window.allocationKeys,
      planSha256:window.manifest.plan_sha256, finalPassport:end.passport,
      passports:Object.fromEntries([...window.senders].map(([sender,c])=>[sender,{start:c.pStart,end:c.pEnd}])),
      nonceRanges:Object.fromEntries([...firstNonceSequences].map(([key,first])=>[key,{first:String(first),last:String(nonceSequences.get(key))}]))
    };
  }
  return !report.consistent ? 1 : report.accepted ? 0 : 3;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const file = process.argv[2];
  if (!file) {
    console.error('usage: validate.mjs <run.jsonl> [--json <report.json>] [--window <archive-dir>] [--frozen-plan <bundle file> --registered-seed <seed> --registered-schedule-sha256 <hex>]');
    process.exit(2);
  }
  const arg = flag => {
    const index = process.argv.indexOf(flag);
    return index === -1 ? undefined : process.argv[index + 1];
  };
  // Exporters may resolve the original archive separately from the captured journal.
  const report = validateRun(file,{evidenceDir:arg('--window'),frozenPlan:arg('--frozen-plan'),
    registered:{seed:arg('--registered-seed'),scheduleSha256:arg('--registered-schedule-sha256')}});
  const json = JSON.stringify(report, null, 2);
  const jsonOut = arg('--json');
  if (jsonOut) writeFileSync(jsonOut, json + '\n');
  console.log(json);
  process.exit(report.validatorExit);
}

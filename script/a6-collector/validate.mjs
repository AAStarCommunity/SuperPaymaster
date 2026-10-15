// A6 gauge validator: re-reads a collector JSONL and recomputes every verdict from the RAW
// fields (packed op, receipt logs, A/B read-backs), with its own decoder — it does not import
// gauge-lib.mjs, so a decoding/classification bug in the collector cannot validate itself.
//
// Fails CLOSED: any missing or malformed field is an error, never a default.
//
// Usage: node script/a6-collector/validate.mjs <run.jsonl> [--json <report.json>]
// Exit: 0  consistent AND accepted (N matched triplets, no stop, every conservation check holds)
//       3  consistent but NOT accepted (fixture run / stopped / attempt budget exhausted)
//       1  INCONSISTENT: a recomputed verdict / conservation / A-B / passport result differs from
//          the record, or a conservation identity fails on the raw read-backs
//       2  unreadable input or a required field is missing (fail closed)
import { readFileSync, writeFileSync } from 'node:fs';
import { keccak256, encodeAbiParameters, toBytes, getAddress } from 'viem';

const file = process.argv[2];
const jsonOut = (() => { const i = process.argv.indexOf('--json'); return i === -1 ? null : process.argv[i + 1]; })();
if (!file) { console.error('usage: validate.mjs <run.jsonl> [--json <report.json>]'); process.exit(2); }

class Missing extends Error {}
const errors = [];      // inconsistencies → exit 1
const notes = [];
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

/** Independent conservation recomputation. Returns list of failed check ids. */
function conservation(row, spAddr, tokenAddr, operator, inv) {
  const failed = [];
  const b = need(row, 'readbacks.before.A'), a = need(row, 'readbacks.after.A');
  for (const f of ['epDeposit', 'blockNumber', 'blockHash']) { need(b, f); need(a, f); }
  const logs = need(row, 'logs');
  const ep = need(row, 'entryPoint');
  const h = lc(row.expectedUserOpHash);
  const uoe = logsOf(logs, ep, T.UOE).find((l) => lc(l.topics[1]) === h);
  if (big(b.blockNumber) + 1n !== big(a.blockNumber) || big(a.blockNumber) !== big(need(row, 'tx.blockNumber'))) failed.push('readback_blocks_bracket_tx');
  if (lc(a.blockHash) !== lc(need(row, 'tx.blockHash'))) failed.push('readback_after_blockhash_eq_tx_block');
  if (!uoe || row.tx.status !== 'success') {
    // A reverted transaction or absent matching operation cannot justify any state delta.
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
    if (logsOf(logs, tokenAddr, T.LOCK_SETTLED).length || logsOf(logs, tokenAddr, T.CREDIT_SETTLED).length || logsOf(logs, tokenAddr, T.CREDIT_RESERVED).length) failed.push('R.settle_events_absent');
    if (d('debts') !== 0n || d('creditReservedOf') !== 0n) failed.push('R.credit_unchanged');
    const locks = logsOf(logs, tokenAddr, T.LOCK_CREATED).filter(l => lc(l.topics[2]) === h);
    if (locks.length !== 1) { failed.push('R.not_evaluable_missing_lock_created'); return failed; }
    const a0 = BigInt(word(locks[0].data, 1)), xLocked = BigInt(word(locks[0].data, 0));
    if (lc(topicAddr(locks[0].topics[1])) !== lc(row.sender) || lc(topicAddr(locks[0].topics[3])) !== lc(spAddr)) failed.push('R.lock_identity');
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
function completePassport(p) {
  for (const f of PASSPORT_FIELDS) {
    const v = need(p, f);
    let valid;
    if (ADDRESS_FIELDS.has(f)) valid = typeof v === 'string' && /^0x[0-9a-f]{40}$/i.test(v) && !/^0x0{40}$/i.test(v);
    else if (BOOL_FIELDS.has(f)) valid = typeof v === 'boolean';
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

// ── main ──────────────────────────────────────────────────────────────────────────────────
const report = { file, attempts: 0, recomputed: {}, errors, notes };
let exit = 0;
try {
  let lines;
  try { lines = readFileSync(file, 'utf8').split('\n').filter((l) => l.trim() !== '').map((l, i) => { try { return JSON.parse(l); } catch { throw new Missing(`line ${i + 1}: not JSON`); } }); }
  catch (e) { throw e instanceof Missing ? e : new Missing(`cannot read ${file}: ${e.message}`); }
  if (lines.length < 2) throw new Missing('need at least run_start and run_end');
  const start = lines[0], end = lines[lines.length - 1];
  if (need(start, 'kind') !== 'run_start') throw new Missing('first line is not run_start');
  if (need(end, 'kind') !== 'run_end') throw new Missing('last line is not run_end (truncated run?)');
  for (const l of lines) { if (need(l, 'schema') !== 'a6-gauge/1') throw new Missing('unknown schema'); if (need(l, 'runId') !== start.runId) throw new Missing('runId differs between lines'); }
  const pStart = need(start, 'passport');
  completePassport(pStart);
  const inv = need(pStart, 'invariant');
  const spAddr = need(inv, 'code.superPaymasterProxy.address');
  const tokenAddr = need(inv, 'xPNTs.address');
  const operator = need(inv, 'superPaymaster.operator.address');
  const chainId = need(pStart, 'chainId');
  const arms = need(start, 'arms');
  const fixture = need(start, 'fixture');
  const target = need(start, 'count');
  if (!Number.isSafeInteger(target) || target < 1) throw new Missing('count must be an integer >= 1');
  if (!Array.isArray(arms) || !arms.length || new Set(arms).size !== arms.length || arms.some(a => !['SP', 'VPM', 'TPM'].includes(a))) throw new Missing('invalid arms');
  const armPaymasters = { SP: spAddr, VPM: inv.code.verifyingPaymaster.address, TPM: inv.code.tokenPaymaster.address };
  if (new Set(Object.values(armPaymasters).map(lc)).size !== 3) errors.push('passport arm paymasters must be distinct');
  if (need(start, 'allowSameEndpointLocal') !== pStart.allowSameEndpointLocal) errors.push('start/passport local override mismatch');
  const endpointA = endpoint(need(start, 'rpcA')), endpointB = endpoint(need(start, 'rpcB'));
  const distinctEndpoints = endpointA.host !== endpointB.host && endpointA.host !== 'loopback' && endpointB.host !== 'loopback';
  const localOverride = start.allowSameEndpointLocal === true || pStart.allowSameEndpointLocal === true;
  if (!distinctEndpoints && !(localOverride && endpointA.port !== endpointB.port)) errors.push('RPC identities require different non-loopback hosts or different ports with explicit local override');
  const conformant = target === 50 && noFixture(fixture) && arms.length === 3 && ['SP', 'VPM', 'TPM'].every(a => arms.includes(a)) && distinctEndpoints && !localOverride;
  if (need(start, 'protocolConformant') !== conformant) errors.push('protocolConformant differs from recomputed count/fixture/arms/endpoints/override');
  if (start.protocolConformant && (!distinctEndpoints || localOverride)) errors.push('conformant run requires distinct endpoints without local override');
  const attempts = lines.slice(1, -1);
  const byTriplet = new Map();
  let stoppedRows = 0;
  let previousBlock = { blockNumber: pStart.block.number, blockHash: pStart.block.hash };
  const seenTx = new Set(), seenOps = new Set(), seenBlocks = new Set(), stateByArm = new Map();
  const nonceSequences = new Map();
  let lastSPTimestamp;
  let lastAttemptHeight = big(pStart.block.number), lastAfterBalance = big(pStart.volatile.operatorBalance);
  const allEarlierHashes = new Set([lc(pStart.block.hash)]);
  const balanceReadbacks = new Map();
  let previousOperatorBalance = big(pStart.volatile.operatorBalance);
  // Passports bracket all attempt blocks. Requiring the start quote to remain fresh
  // through the end block proves freshness without inventing per-tx timestamps.
  const validUntil48 = (big(pStart.volatile.cachedPriceUpdatedAt) + big(inv.superPaymaster.priceStalenessThreshold)) % (1n << 48n);
  const quoteValidUntil = validUntil48 === 0n ? (1n << 48n) - 1n : validUntil48;
  const sponsorshipReady = p => !p.invariant.superPaymaster.paused && p.invariant.superPaymaster.senderEligible
    && p.invariant.superPaymaster.operator.isConfigured && !p.invariant.superPaymaster.operator.isPaused
    && !p.invariant.xPNTs.emergencyDisabled;

  attempts.forEach((row, i) => {
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
      || !logsOf(row.logs ?? [], row.entryPoint, T.UOE).some(l => lc(l.topics[1]) === lc(row.expectedUserOpHash)))) {
      for (const rpc of ['A', 'B']) for (const f of ['epDeposit', ...SP_FIELDS]) {
        if (!deepEq(need(row, `readbacks.before.${rpc}.${f}`), need(row, `readbacks.after.${rpc}.${f}`))) errors.push(`attempt ${i}: no_execution.${f}`);
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
      if (row.verdict === 'STOPPED') return;
    }
    for (const k of ['chainId', 'entryPoint', 'sender', 'nonce', 'paymaster', 'bundler', 'callDataHash', 'gas', 'pmGas',
      'expectedUserOpHash', 'epUserOpHash', 'localUserOpHash', 'bundledUserOpHashes', 'packedOp', 'bundledOps', 'guard', 'sent', 'logs']) need(row, k);
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
    if (row.arm === 'SP') {
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
    if (noFixture(fixture) && (lc(row.derivedCallDataHash) !== lc(inv.callDataHash) || GAS_FIELDS.some(f => big(row.derivedGas[f]) !== big(inv.gas[f])))) errors.push(`attempt ${i}: operation callData/gas passport mismatch`);
    const bundledHashes = row.bundledOps.map((op) => hashOp(op, row.entryPoint, chainId));
    if (!deepEq(bundledHashes, row.bundledUserOpHashes)) errors.push(`attempt ${i}: bundled hashes do not recompute`);
    if (fixture !== 'drop-op' && !row.bundledOps.some(op => deepEq(op, row.packedOp))) errors.push(`attempt ${i}: packedOp absent from bundledOps`);
    const extraEvents = logsOf(row.logs, row.entryPoint, T.UOE).filter(l => lc(l.topics[1]) !== lc(row.expectedUserOpHash));
    if (extraEvents.length) {
      (report.extraUserOperationEvents ??= []).push({ attemptIndex: i, logs: extraEvents });
      // This single-op gauge cannot attribute aggregate deposit deltas for extra operations.
      if (noFixture(fixture)) errors.push(`attempt ${i}: extra UserOperationEvent in single-op receipt`);
    }
    if (row.sent) for (const k of ['tx.hash', 'tx.status', 'tx.blockNumber', 'tx.blockHash', 'tx.blockTxCount', 'tx.headBefore', 'tx.from']) need(row, k);
    if (row.sent && (lc(row.bundler) !== lc(row.tx.from) || lc(row.tx.from) !== lc(inv.bundler))) errors.push(`attempt ${i}: transaction bundler mismatch`);
    const v = verdictOf(row);
    const recomputed = typeof v === 'string' ? v : v.verdict;
    report.recomputed[recomputed] = (report.recomputed[recomputed] ?? 0) + 1;
    if (recomputed === 'USEROP_SUCCESS' && lc(row.expectedUserOpHash) !== lc(h)) errors.push(`attempt ${i}: success hash is not packedOp hash`);
    if (row.sent && row.tx.status === 'success' && logsOf(row.logs, row.entryPoint, T.UOE).some(l => lc(l.topics[1]) === lc(h))) {
      const timestamp = big(need(row, 'tx.blockTimestamp'));
      if (timestamp < big(pStart.block.timestamp) || timestamp > big(end.passport.block.timestamp)) errors.push(`attempt ${i}: tx timestamp outside passport bracket`);
      if (row.arm === 'VPM') {
        if (pmData.length < 234) throw new Missing('truncated VPM validity data');
        const until = BigInt('0x' + pmData.slice(106, 170)), after = BigInt('0x' + pmData.slice(170, 234));
        if (until >= 1n << 48n || after >= 1n << 48n || timestamp < after || (until !== 0n && timestamp > until)) errors.push(`attempt ${i}: VPM validity outside block time`);
      }
      if (row.arm === 'SP') {
        if (lastSPTimestamp !== undefined && timestamp < lastSPTimestamp + big(inv.superPaymaster.operator.minTxInterval)) errors.push(`attempt ${i}: SP minTxInterval violated`);
        if (!logsOf(row.logs, row.entryPoint, T.POSTOP).some(l => lc(l.topics[1]) === lc(h))) lastSPTimestamp = timestamp;
      }
    }
    if (row.sent && row.tx.status === 'success' && logsOf(row.logs, row.entryPoint, T.UOE).some(l => lc(l.topics[1]) === lc(h))) {
      // NonceManager:36-40 at the pin: sender + uint192 key, uint64 sequence.
      const nonce = big(row.packedOp.nonce), key = `${lc(row.sender)}:${nonce >> 64n}`, sequence = nonce & ((1n << 64n) - 1n);
      if (nonceSequences.has(key) && sequence !== nonceSequences.get(key) + 1n) errors.push(`attempt ${i}: nonce sequence must advance exactly one for sender/key`);
      nonceSequences.set(key, sequence);
      if (row.arm === 'SP') {
        if (!sponsorshipReady(pStart) || !sponsorshipReady(need(end, 'passport'))) errors.push(`attempt ${i}: passport not sponsor-able`);
        const endPassport = end.passport;
        const endUntil48 = (big(need(endPassport, 'volatile.cachedPriceUpdatedAt')) + big(inv.superPaymaster.priceStalenessThreshold)) % (1n << 48n);
        if ((endUntil48 === 0n ? (1n << 48n) - 1n : endUntil48) < big(endPassport.block.timestamp)) errors.push(`attempt ${i}: end cached price expires before passport block`);
        if (quoteValidUntil < big(pStart.block.timestamp) || quoteValidUntil < big(need(end, 'passport.block.timestamp'))) errors.push(`attempt ${i}: cached price expires within passport block bracket`);
      }
    }
    if (recomputed !== row.verdict) errors.push(`attempt ${i} (${row.arm}): recorded ${row.verdict}, recomputed ${recomputed}`);
    if (row.sent && !row.stoppedBy) {
      need(row, 'readbacks.before.B'); need(row, 'readbacks.after.B');
      for (const side of ['before', 'after']) {
        if (!deepEq(row.readbacks[side].A, row.readbacks[side].B)) errors.push(`attempt ${i}: A/B read-backs (${side}) disagree in a row that was not stopped`);
      }
      if (row.tx.blockTxCount !== 1 || big(row.tx.blockNumber) !== big(row.tx.headBefore) + 1n) errors.push(`attempt ${i}: tx block not isolated`);
      const before = row.readbacks.before.A, after = row.readbacks.after.A;
      if (i === attempts.length - 1) need(after, 'operatorBalance');
      for (const [value, seen, label] of [[lc(row.tx.hash), seenTx, 'transaction'], [lc(h), seenOps, 'userOpHash'], [lc(row.tx.blockHash), seenBlocks, 'block']]) {
        if (seen.has(value)) errors.push(`attempt ${i}: reused ${label}`);
        seen.add(value);
      }
      if (big(need(before, 'blockNumber')) !== big(previousBlock.blockNumber) || lc(need(before, 'blockHash')) !== lc(previousBlock.blockHash)) errors.push(`attempt ${i}: consecutive block continuity failed`);
      const previous = stateByArm.get(row.arm);
      // Other arms use separate deposits/tokens and cannot change these fields. lockXLocked
      // and inflight state are keyed by opHash: a new op starts empty, rather than inheriting the prior reservation.
      if (previous) for (const f of ['epDeposit', ...(row.arm === 'SP' ? SP_FIELDS.filter(f => !['lockXLocked', 'inflightA0', 'inflightOperator'].includes(f)) : [])]) {
        if (!deepEq(need(before, f), need(previous, f))) errors.push(`attempt ${i}: balance continuity failed: ${f}`);
      }
      // Shared SP balance follows chronological attempts, not the previous baseline arm.
      // Older baseline rows may omit it; SP state continuity and exact-hash passport
      // anchors remain mandatory. Every recorded baseline readback is checked.
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
      previousBlock = after;
      const failed = conservation(row, spAddr, tokenAddr, operator, inv);
      const recordedOk = need(row, 'conservation.ok');
      const citations = { 'C6.locked_unchanged': 'XT:240,263', 'R2.locked_grew_by_xLocked': 'XT:240', "C5'.credit_reserved_unchanged": 'XT:305,322' };
      for (const c of need(row, 'conservation.checks')) if (c.id in citations && c.src !== citations[c.id]) errors.push(`attempt ${i}: incorrect source citation ${c.id}`);
      const notEvaluable = failed.includes('R.not_evaluable_missing_lock_created');
      if (notEvaluable) {
        (report.notEvaluable ??= []).push({ attemptIndex: i, reason: 'missing unique LockCreated: R1/R2 cannot be evaluated', countable: false });
      }
      const actualFailures = failed.filter(f => f !== 'R.not_evaluable_missing_lock_created');
      if (actualFailures.length) errors.push(`attempt ${i} (${row.arm}): conservation FAILS on raw read-backs: ${actualFailures.join(',')}`);
      const evaluated = !notEvaluable && logsOf(row.logs, row.entryPoint, T.UOE).some(l => lc(l.topics[1]) === lc(row.expectedUserOpHash));
      if (need(row, 'conservation.evaluated') !== evaluated) errors.push(`attempt ${i}: conservation.evaluated mismatch`);
      if (!evaluated && recordedOk !== null && recordedOk !== false) errors.push(`attempt ${i}: unevaluated conservation cannot pass`);
      if (evaluated && (failed.length === 0) !== recordedOk) errors.push(`attempt ${i}: recorded conservation.ok=${recordedOk}, recomputed ${failed.length === 0}`);
    }
    if (!byTriplet.has(row.tripletIndex)) byTriplet.set(row.tripletIndex, []);
    byTriplet.get(row.tripletIndex).push({ row, recomputed });
  });
  // matched triplets, recomputed
  let matched = 0;
  for (const [, rows] of byTriplet) {
    // A row interrupted by a stop condition never counts, whatever its receipt said.
    const okArms = arms.every((arm) => rows.some((r) => r.row.arm === arm && r.recomputed === 'USEROP_SUCCESS' && r.row.conservation?.evaluated === true && r.row.conservation?.ok === true && !r.row.stoppedBy));
    const same = new Set(rows.map((r) => `${r.row.derivedCallDataHash}|${JSON.stringify(r.row.derivedGas)}|${lc(r.row.tx?.from)}|${lc(r.row.entryPoint)}|${lc(r.row.sender)}`)).size === 1;
    if (!same) errors.push('triplet callData/gas/bundler differ between arms');
    const distinct = ['paymaster', 'expectedUserOpHash'].every(f => new Set(rows.map(r => lc(r.row[f]))).size === rows.length)
      && new Set(rows.map(r => lc(r.row.tx?.hash))).size === rows.length;
    if (!distinct) errors.push('triplet paymasters/transaction hashes/userOpHashes must be distinct');
    if (noFixture(fixture) && okArms && same && distinct && rows.length === arms.length) matched++;
  }
  report.matchedTriplets = matched;
  if (need(end, 'matchedTriplets') !== matched) errors.push(`run_end.matchedTriplets ${end.matchedTriplets} != recomputed ${matched}`);
  const stop = need(end, 'stop');
  report.stop = stop.reason;
  report.exitCode = need(end, 'exitCode');
  if (report.exitCode !== need(stop, 'code')) errors.push('run_end.exitCode differs from stop.code');
  // passport drift, recomputed
  completePassport(need(end, 'passport'));
  if (!deepEq(inv, need(end, 'passport.invariant'))) errors.push('passport invariant drifted between run_start and run_end');
  if (pStart.allowSameEndpointLocal !== end.passport.allowSameEndpointLocal) errors.push('passport local override drifted');
  if (big(end.passport.chainId) !== big(chainId)) errors.push('end passport chainId differs from start');
  if (big(end.passport.block.number) <= lastAttemptHeight) errors.push('end passport block must be strictly after last attempt');
  if (allEarlierHashes.has(lc(end.passport.block.hash))) errors.push('end passport reuses earlier block hash');
  if (big(end.passport.volatile.operatorBalance) !== lastAfterBalance) errors.push('end passport balance differs from last after');
  if (big(end.passport.block.timestamp) < big(pStart.block.timestamp)) errors.push('end passport timestamp precedes start');
  if (arms.includes('SP')) for (const [label, p] of [['start', pStart]]) {
    const value = balanceReadbacks.get(lc(p.block.hash));
    if (value === undefined) { if (!errors.length) throw new Missing(`${label} passport requires operatorBalance readback at same block hash`); continue; }
    if (value !== big(p.volatile.operatorBalance)) errors.push(`${label} passport/readback operatorBalance mismatch`);
  }
  report.protocolConformant = conformant;
  report.consistent = errors.length === 0;
  report.accepted = report.consistent && stop.reason === 'COMPLETE' && stop.code === 0 && matched === target && stoppedRows === 0 && (target !== 50 || conformant);
  exit = !report.consistent ? 1 : report.accepted ? 0 : 3;
} catch (e) {
  if (e instanceof Missing) { report.missing = e.message; exit = 2; }
  else { report.crash = String(e?.stack ?? e); exit = 2; }
}
report.validatorExit = exit;
if (jsonOut) writeFileSync(jsonOut, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
process.exit(exit);

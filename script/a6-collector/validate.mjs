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
const lc = (x) => String(x).toLowerCase();
const big = (x) => { if (typeof x !== 'string' && typeof x !== 'number') throw new Missing(`not a number: ${JSON.stringify(x)}`); return BigInt(x); };

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
function conservation(row, spAddr, tokenAddr, operator) {
  const failed = [];
  const b = need(row, 'readbacks.before.A'), a = need(row, 'readbacks.after.A');
  for (const f of ['epDeposit', 'blockNumber', 'blockHash']) { need(b, f); need(a, f); }
  const logs = need(row, 'logs');
  const ep = need(row, 'entryPoint');
  const h = lc(row.expectedUserOpHash);
  const uoe = logsOf(logs, ep, T.UOE).find((l) => lc(l.topics[1]) === h);
  if (!uoe) return failed; // nothing to conserve for an op that never executed
  if (big(b.blockNumber) + 1n !== big(a.blockNumber) || big(a.blockNumber) !== big(need(row, 'tx.blockNumber'))) failed.push('readback_blocks_bracket_tx');
  if (lc(a.blockHash) !== lc(need(row, 'tx.blockHash'))) failed.push('readback_after_blockhash_eq_tx_block');
  const actualGasCost = BigInt(word(uoe.data, 2));
  const success = BigInt(word(uoe.data, 1)) === 1n;
  if (big(a.epDeposit) - big(b.epDeposit) !== -actualGasCost) failed.push('D1');
  if (row.arm !== 'SP') return failed;
  for (const f of SP_FIELDS) { need(b, f); need(a, f); }
  const d = (f) => big(a[f]) - big(b[f]);
  const postOpReverted = logsOf(logs, ep, T.POSTOP).some((l) => lc(l.topics[1]) === h);
  const sponsored = logsOf(logs, spAddr, T.SPONSORED);
  if (big(b.inflightA0) !== 0n) failed.push('C4.before');
  if (postOpReverted) {
    if (success) failed.push('R.success_with_postop_revert');
    if (sponsored.length) failed.push('R1.sponsored_absent');
    if (d('operatorBalance') !== -big(a.inflightA0)) failed.push('R1.op_delta');
    if (d('protocolRevenue') !== 0n) failed.push('R1.revenue');
    return failed;
  }
  if (sponsored.length !== 1) { failed.push('C9.sponsored_count'); return failed; }
  const s = sponsored[0];
  const charge = BigInt(word(s.data, 1));
  if (lc(topicAddr(s.topics[1])) !== lc(operator)) failed.push('C9.operator');
  if (lc(topicAddr(s.topics[2])) !== lc(row.sender)) failed.push('C9.user');
  if (d('operatorBalance') !== -charge) failed.push('C1');
  if (d('protocolRevenue') !== charge) failed.push('C2');
  if (d('operatorBalance') + d('protocolRevenue') !== 0n) failed.push('C3');
  if (big(a.inflightA0) !== 0n) failed.push('C4.after');
  if (d('totalTxSponsored') !== 1n) failed.push('C10.count');
  const byHash = (t) => logsOf(logs, tokenAddr, t).filter((l) => lc(l.topics[2]) === h);
  const lcr = byHash(T.LOCK_CREATED), lse = byHash(T.LOCK_SETTLED), crr = byHash(T.CREDIT_RESERVED), cse = byHash(T.CREDIT_SETTLED);
  if (lcr.length === 1 && lse.length === 1) {
    const xLocked = BigInt(word(lcr[0].data, 0)), a0 = BigInt(word(lcr[0].data, 1));
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
  } else if (crr.length === 1 && cse.length === 1) {
    if (d('debts') !== charge || BigInt(word(cse[0].data, 0)) !== charge) failed.push("C5'.debt");
    if (d('userXPNTs') !== 0n || d('totalSupply') !== 0n) failed.push("C5'.xpnts");
    if (d('creditReservedOf') !== 0n) failed.push("C5'.reserved");
  } else failed.push('mode');
  return failed;
}

function deepEq(x, y) { return JSON.stringify(x, (k, v) => (typeof v === 'string' ? v.toLowerCase() : v)) === JSON.stringify(y, (k, v) => (typeof v === 'string' ? v.toLowerCase() : v)); }

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
  const inv = need(pStart, 'invariant');
  const spAddr = need(inv, 'code.superPaymasterProxy.address');
  const tokenAddr = need(inv, 'xPNTs.address');
  const operator = need(inv, 'superPaymaster.operator.address');
  const chainId = need(pStart, 'chainId');
  const arms = need(start, 'arms');
  const fixture = need(start, 'fixture');
  const target = need(start, 'count');
  const attempts = lines.slice(1, -1);
  const byTriplet = new Map();
  let stoppedRows = 0;
  attempts.forEach((row, i) => {
    if (need(row, 'kind') !== 'attempt') throw new Missing(`line ${i + 2}: unexpected kind ${row.kind}`);
    if (need(row, 'attemptIndex') !== i) errors.push(`attemptIndex ${row.attemptIndex} at position ${i} (rows missing or reordered)`);
    for (const k of ['tripletIndex', 'arm', 'fixture', 'verdict', 'collectedAtUtc']) need(row, k);
    report.attempts++;
    if (row.verdict === 'STOPPED' || row.stoppedBy) {
      stoppedRows++;
      notes.push(`attempt ${i}: stopped by ${need(row, 'stoppedBy.reason')}`);
      if (row.verdict === 'STOPPED') return;
    }
    for (const k of ['chainId', 'entryPoint', 'sender', 'nonce', 'paymaster', 'bundler', 'callDataHash', 'gas', 'pmGas',
      'expectedUserOpHash', 'epUserOpHash', 'localUserOpHash', 'bundledUserOpHashes', 'packedOp', 'bundledOps', 'guard', 'sent', 'logs']) need(row, k);
    if (row.chainId !== chainId) errors.push(`attempt ${i}: chainId ${row.chainId} != passport ${chainId}`);
    // hash self-check, recomputed here
    const h = hashOp(row.packedOp, row.entryPoint, chainId);
    if (lc(h) !== lc(row.epUserOpHash) || lc(h) !== lc(row.localUserOpHash)) errors.push(`attempt ${i}: userOpHash recomputation ${h} != recorded ep/local`);
    if (lc(row.expectedUserOpHash) !== lc(h) && row.fixture !== 'wrong-hash') errors.push(`attempt ${i}: expected hash differs from the op's hash outside the wrong-hash fixture`);
    const bundledHashes = row.bundledOps.map((op) => hashOp(op, row.entryPoint, chainId));
    if (!deepEq(bundledHashes, row.bundledUserOpHashes)) errors.push(`attempt ${i}: bundled hashes do not recompute`);
    if (row.sent) for (const k of ['tx.hash', 'tx.status', 'tx.blockNumber', 'tx.blockHash', 'tx.blockTxCount', 'tx.headBefore']) need(row, k);
    const v = verdictOf(row);
    const recomputed = typeof v === 'string' ? v : v.verdict;
    report.recomputed[recomputed] = (report.recomputed[recomputed] ?? 0) + 1;
    if (recomputed !== row.verdict) errors.push(`attempt ${i} (${row.arm}): recorded ${row.verdict}, recomputed ${recomputed}`);
    if (row.sent && !row.stoppedBy) {
      need(row, 'readbacks.before.B'); need(row, 'readbacks.after.B');
      for (const side of ['before', 'after']) {
        if (!deepEq(row.readbacks[side].A, row.readbacks[side].B)) errors.push(`attempt ${i}: A/B read-backs (${side}) disagree in a row that was not stopped`);
      }
      if (row.tx.blockTxCount !== 1 || big(row.tx.blockNumber) !== big(row.tx.headBefore) + 1n) errors.push(`attempt ${i}: tx block not isolated`);
      const failed = conservation(row, spAddr, tokenAddr, operator);
      const recordedOk = need(row, 'conservation.ok');
      if (failed.length) errors.push(`attempt ${i} (${row.arm}): conservation FAILS on raw read-backs: ${failed.join(',')}`);
      if ((failed.length === 0) !== recordedOk) errors.push(`attempt ${i}: recorded conservation.ok=${recordedOk}, recomputed ${failed.length === 0}`);
    }
    if (!byTriplet.has(row.tripletIndex)) byTriplet.set(row.tripletIndex, []);
    byTriplet.get(row.tripletIndex).push({ row, recomputed });
  });
  // matched triplets, recomputed
  let matched = 0;
  for (const [, rows] of byTriplet) {
    // A row interrupted by a stop condition never counts, whatever its receipt said.
    const okArms = arms.every((arm) => rows.some((r) => r.row.arm === arm && r.recomputed === 'USEROP_SUCCESS' && !r.row.stoppedBy));
    const same = new Set(rows.map((r) => `${r.row.callDataHash}|${JSON.stringify(r.row.gas)}|${lc(r.row.bundler)}|${lc(r.row.entryPoint)}|${lc(r.row.sender)}`)).size === 1;
    if (!fixture && okArms && same && rows.length === arms.length) matched++;
  }
  report.matchedTriplets = matched;
  if (need(end, 'matchedTriplets') !== matched) errors.push(`run_end.matchedTriplets ${end.matchedTriplets} != recomputed ${matched}`);
  const stop = need(end, 'stop');
  report.stop = stop.reason;
  report.exitCode = need(end, 'exitCode');
  // passport drift, recomputed
  if (end.passport) {
    if (!deepEq(inv, need(end, 'passport.invariant'))) errors.push('passport invariant drifted between run_start and run_end');
  } else if (stop.reason !== 'RPC_DISAGREEMENT') throw new Missing('run_end.passport missing');
  report.protocolConformant = need(start, 'protocolConformant');
  report.consistent = errors.length === 0;
  report.accepted = report.consistent && stop.reason === 'COMPLETE' && stop.code === 0 && matched === target && stoppedRows === 0;
  exit = !report.consistent ? 1 : report.accepted ? 0 : 3;
} catch (e) {
  if (e instanceof Missing) { report.missing = e.message; exit = 2; }
  else { report.crash = String(e?.stack ?? e); exit = 2; }
}
report.validatorExit = exit;
if (jsonOut) writeFileSync(jsonOut, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
process.exit(exit);

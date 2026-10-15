// A6 per-UserOperation gauge — shared, side-effect-free helpers (CC-125 a71741ed).
//
// Used by collector.mjs (which records) and NOT by validate.mjs (which re-derives every verdict
// with its own independent decoder, so a bug here cannot silently validate itself). Everything
// in this file is a pure function of its arguments or a read-only RPC call.
//
// Source citations below are against the pinned tree this file ships with:
//   EP  = singleton-paymaster/lib/account-abstraction-v7/contracts/core/EntryPoint.sol
//   IEP = singleton-paymaster/lib/account-abstraction-v7/contracts/interfaces/IEntryPoint.sol
//   UOL = singleton-paymaster/lib/account-abstraction-v7/contracts/core/UserOperationLib.sol
//   SP  = contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol
//   XT  = contracts/src/tokens/v2/xPNTsTokenV2.sol
//   XB  = contracts/src/tokens/v2/xPNTsV2Base.sol
import {
  keccak256, encodeAbiParameters, decodeEventLog, getAddress, toEventSelector, isHex,
} from 'viem';

export const CANONICAL_EP_V07 = '0x0000000071727De22E5E9d8BAf0edAc6f37da032';

// ── EntryPoint v0.7 events (IEP:29-91) ──────────────────────────────────────────────────────
export const EP_EVENTS_ABI = [
  { type: 'event', name: 'UserOperationEvent', inputs: [
    { name: 'userOpHash', type: 'bytes32', indexed: true }, { name: 'sender', type: 'address', indexed: true },
    { name: 'paymaster', type: 'address', indexed: true }, { name: 'nonce', type: 'uint256', indexed: false },
    { name: 'success', type: 'bool', indexed: false }, { name: 'actualGasCost', type: 'uint256', indexed: false },
    { name: 'actualGasUsed', type: 'uint256', indexed: false } ] },
  { type: 'event', name: 'UserOperationRevertReason', inputs: [
    { name: 'userOpHash', type: 'bytes32', indexed: true }, { name: 'sender', type: 'address', indexed: true },
    { name: 'nonce', type: 'uint256', indexed: false }, { name: 'revertReason', type: 'bytes', indexed: false } ] },
  { type: 'event', name: 'PostOpRevertReason', inputs: [
    { name: 'userOpHash', type: 'bytes32', indexed: true }, { name: 'sender', type: 'address', indexed: true },
    { name: 'nonce', type: 'uint256', indexed: false }, { name: 'revertReason', type: 'bytes', indexed: false } ] },
  { type: 'event', name: 'UserOperationPrefundTooLow', inputs: [
    { name: 'userOpHash', type: 'bytes32', indexed: true }, { name: 'sender', type: 'address', indexed: true },
    { name: 'nonce', type: 'uint256', indexed: false } ] },
];

// ── SuperPaymaster + xPNTsTokenV2 events at the pin ─────────────────────────────────────────
//   TransactionSponsored  contracts/src/interfaces/ISuperPaymaster.sol:53 (emitted SP:450)
//   SponsorshipReleased   contracts/src/paymasters/superpaymaster/v3/SuperPaymasterStorage.sol:258 (SP:463)
//   Lock*/Credit*         XB:134-139 (emitted XT:243, XT:268, XB:320, XT:308, XT:326, XB:329)
export const SP_EVENTS_ABI = [
  { type: 'event', name: 'TransactionSponsored', inputs: [
    { name: 'operator', type: 'address', indexed: true }, { name: 'user', type: 'address', indexed: true },
    { name: 'aPNTsCost', type: 'uint256', indexed: false }, { name: 'debtAPNTs', type: 'uint256', indexed: false } ] },
  { type: 'event', name: 'SponsorshipReleased', inputs: [
    { name: 'opHash', type: 'bytes32', indexed: true }, { name: 'operator', type: 'address', indexed: true },
    { name: 'aPNTs', type: 'uint256', indexed: false } ] },
];
export const TOKEN_EVENTS_ABI = [
  { type: 'event', name: 'LockCreated', inputs: [
    { name: 'user', type: 'address', indexed: true }, { name: 'opHash', type: 'bytes32', indexed: true },
    { name: 'locker', type: 'address', indexed: true }, { name: 'xLocked', type: 'uint256', indexed: false },
    { name: 'aReserved', type: 'uint256', indexed: false } ] },
  { type: 'event', name: 'LockSettled', inputs: [
    { name: 'user', type: 'address', indexed: true }, { name: 'opHash', type: 'bytes32', indexed: true },
    { name: 'xBurned', type: 'uint256', indexed: false }, { name: 'aCharged', type: 'uint256', indexed: false } ] },
  { type: 'event', name: 'LockReleased', inputs: [
    { name: 'user', type: 'address', indexed: true }, { name: 'opHash', type: 'bytes32', indexed: true },
    { name: 'xLocked', type: 'uint256', indexed: false } ] },
  { type: 'event', name: 'CreditReserved', inputs: [
    { name: 'user', type: 'address', indexed: true }, { name: 'opHash', type: 'bytes32', indexed: true },
    { name: 'locker', type: 'address', indexed: true }, { name: 'amount', type: 'uint256', indexed: false } ] },
  { type: 'event', name: 'CreditSettled', inputs: [
    { name: 'user', type: 'address', indexed: true }, { name: 'opHash', type: 'bytes32', indexed: true },
    { name: 'debtAdded', type: 'uint256', indexed: false } ] },
  { type: 'event', name: 'CreditReleased', inputs: [
    { name: 'user', type: 'address', indexed: true }, { name: 'opHash', type: 'bytes32', indexed: true },
    { name: 'amount', type: 'uint256', indexed: false } ] },
  { type: 'event', name: 'Transfer', inputs: [
    { name: 'from', type: 'address', indexed: true }, { name: 'to', type: 'address', indexed: true },
    { name: 'value', type: 'uint256', indexed: false } ] },
];

export const VERDICTS = Object.freeze({
  USEROP_SUCCESS: 'USEROP_SUCCESS',       // our hash has exactly one UserOperationEvent, success=true
  USEROP_REVERTED: 'USEROP_REVERTED',     // our hash's UserOperationEvent has success=false
  NO_EVENT: 'NO_EVENT',                   // tx mined OK, but no UserOperationEvent for our op at all
  HASH_MISMATCH: 'HASH_MISMATCH',         // an event for our (sender, nonce) exists, but under another hash
  EVENT_FIELD_MISMATCH: 'EVENT_FIELD_MISMATCH', // hash matches, but sender/nonce/paymaster do not
  DUPLICATE_EVENT: 'DUPLICATE_EVENT',     // more than one UserOperationEvent for our hash
  TX_FAILED: 'TX_FAILED',                 // the bundle tx itself reverted (receipt.status != success)
  NOT_SENT: 'NOT_SENT',                   // withheld by the deposit guard or by a reverting preflight
});

/** Lowercase-hex, BigInt-free JSON form of anything (for the JSONL record). */
export function jsonable(v) {
  if (typeof v === 'bigint') return v.toString();
  if (Array.isArray(v)) return v.map(jsonable);
  if (v && typeof v === 'object') {
    const o = {};
    for (const [k, x] of Object.entries(v)) o[k] = jsonable(x);
    return o;
  }
  return v;
}

// ── userOpHash, computed locally (UOL:54-72, EP:363-368) ────────────────────────────────────
// Independent of EntryPoint.getUserOpHash; the collector requires the two to agree.
export function localUserOpHash(packed, entryPoint, chainId) {
  const inner = keccak256(encodeAbiParameters(
    [{ type: 'address' }, { type: 'uint256' }, { type: 'bytes32' }, { type: 'bytes32' },
      { type: 'bytes32' }, { type: 'uint256' }, { type: 'bytes32' }, { type: 'bytes32' }],
    [packed.sender, BigInt(packed.nonce), keccak256(packed.initCode), keccak256(packed.callData),
      packed.accountGasLimits, BigInt(packed.preVerificationGas), packed.gasFees, keccak256(packed.paymasterAndData)],
  ));
  return keccak256(encodeAbiParameters(
    [{ type: 'bytes32' }, { type: 'address' }, { type: 'uint256' }], [inner, entryPoint, BigInt(chainId)],
  ));
}

const eq = (a, b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();

/** Decode every log emitted by `address` against `abi`; unknown topics are kept as {unknown}. */
export function decodeLogsFrom(logs, address, abi) {
  const out = [];
  for (const l of logs) {
    if (!eq(l.address, address)) continue;
    try {
      const d = decodeEventLog({ abi, data: l.data, topics: l.topics, strict: true });
      out.push({ event: d.eventName, logIndex: Number(l.logIndex), args: jsonable(d.args) });
    } catch {
      out.push({ event: null, logIndex: Number(l.logIndex), topic0: l.topics[0] ?? null });
    }
  }
  return out;
}

/**
 * Per-UserOperation verdict from the bundle receipt. NEVER derived from receipt.status alone:
 * a successful handleOps tx says nothing about any individual op (EP:746-747 emits success=false for
 * a reverted execution inside a successful tx, EP:345 its reason; EP:135 for a reverted postOp).
 */
export function classifyAttempt({ sent, txStatus, logs, entryPoint, expectedHash, sender, nonce, paymaster }) {
  if (!sent) return { verdict: VERDICTS.NOT_SENT, failingCheck: 'not_broadcast' };
  if (txStatus !== 'success') return { verdict: VERDICTS.TX_FAILED, failingCheck: 'receipt_status' };
  const ep = decodeLogsFrom(logs, entryPoint, EP_EVENTS_ABI);
  const uoes = ep.filter((e) => e.event === 'UserOperationEvent');
  const ours = uoes.filter((e) => eq(e.args.userOpHash, expectedHash));
  const base = { epEvents: ep };
  if (ours.length === 0) {
    const sameOp = uoes.find((e) => eq(e.args.sender, sender) && BigInt(e.args.nonce) === BigInt(nonce));
    return sameOp
      ? { ...base, verdict: VERDICTS.HASH_MISMATCH, failingCheck: 'expected_hash_in_events', observedHash: sameOp.args.userOpHash }
      : { ...base, verdict: VERDICTS.NO_EVENT, failingCheck: 'user_operation_event_present' };
  }
  if (ours.length > 1) return { ...base, verdict: VERDICTS.DUPLICATE_EVENT, failingCheck: 'single_event' };
  const u = ours[0].args;
  if (!eq(u.sender, sender) || BigInt(u.nonce) !== BigInt(nonce) || !eq(u.paymaster, paymaster)) {
    return { ...base, verdict: VERDICTS.EVENT_FIELD_MISMATCH, failingCheck: 'event_sender_nonce_paymaster', event: u };
  }
  const forUs = (name) => ep.filter((e) => e.event === name && eq(e.args.userOpHash, expectedHash)).map((e) => e.args);
  const execRevert = forUs('UserOperationRevertReason');
  const postOpRevert = forUs('PostOpRevertReason');
  const prefundTooLow = forUs('UserOperationPrefundTooLow');
  const detail = { event: u, execRevert, postOpRevert, prefundTooLow };
  if (u.success) {
    if (execRevert.length || postOpRevert.length || prefundTooLow.length) {
      return { ...base, ...detail, verdict: VERDICTS.USEROP_REVERTED, failingCheck: 'revert_reason_with_success_true' };
    }
    return { ...base, ...detail, verdict: VERDICTS.USEROP_SUCCESS, failingCheck: null };
  }
  const sub = postOpRevert.length ? 'postOpReverted' : prefundTooLow.length ? 'prefundTooLow' : 'executionReverted';
  return { ...base, ...detail, verdict: VERDICTS.USEROP_REVERTED, revertKind: sub, failingCheck: 'user_operation_success' };
}

// ── SuperPaymaster conservation (derived from source at the pin) ────────────────────────────
//
// BALANCE mode, postOp completed (op succeeded OR its execution reverted — postOp runs in both,
// EP:701-712 calls postOp for both opSucceeded and opReverted):
//   validation  SP:322-325  operators[op].aPNTsBalance -= a0; _inflight[h] = (op, a0)
//               XT:239-242  lockedOf[user] += xLocked; _locks[h][user] = (xLocked, aReserved=a0)
//   postOp      SP:434      charge = min(charge, a0)
//               SP:439      settleLocked(user, h, charge)
//               XT:259-267  xBurned = min(ceil(charge * xLocked / aReserved), xLocked);
//                           lockedOf[user] -= xLocked; _burn(user, xBurned)
//               SP:445-448  delete _inflight[h]; aPNTsBalance += a0 - charge; protocolRevenue += charge
//               SP:450      emit TransactionSponsored(op, user, aGas, charge)
// Hence, over one bundle tx (before = state at block N-1, after = state at block N):
//   C1  ΔoperatorBalance           == -charge
//   C2  ΔprotocolRevenue           == +charge
//   C3  ΔoperatorBalance + ΔprotocolRevenue == 0           (aPNTs: SP-internal, nothing minted)
//   C4  inflightOf(h) == (0, 0) before AND after
//   C5  ΔuserXPNTs == ΔtotalSupply == -xBurned            (xPNTs: burned from the user, nowhere else)
//   C6  ΔlockedOf(user) == 0, lockOf(h,user) empty after
//   C7  xBurned == min(ceil(charge * xLocked / a0), xLocked)  with (xLocked, a0) from LockCreated
//   C8  LockSettled.aCharged == TransactionSponsored.debtAPNTs == charge <= a0
//   C9  TransactionSponsored.operator/user == expected operator / sender
//   C10 ΔtotalTxSponsored == 1 (SP:417), ΔtotalSpent == a0 (SP:323; BALANCE mode, a0 from LockCreated)
// NOTE: the "operator delta + revenue delta + burned == charge" phrasing in the task mixes two
// assets — burned is xPNTs (XT:267), charge/revenue/operator are aPNTs (SP:447-448). The
// type-correct identities are C1-C3 (aPNTs) and C5/C7 (xPNTs, linked to aPNTs by C7).
//
// CREDIT mode (SP:441 settleCredit, XT:313-326): C1-C4, C9 as above, plus
//   C5'  Δdebts(user) == debtAdded == charge, ΔuserXPNTs == ΔtotalSupply == 0, ΔcreditReservedOf == 0
//
// postOp REVERTED (EP:134-148: PostOpRevertReason, postOp not re-called, no TransactionSponsored):
//   the user's execution is rolled back, but the validation writes stay:
//   R1  ΔoperatorBalance == -a0, ΔprotocolRevenue == 0, inflightOf(h) == (op, a0) after
//   R2  lockedOf(user) grew by xLocked (BALANCE) — the stale lock awaits releaseStaleLock (XT:272)
//
// Every arm (VPM / TPM / SP): the paymaster's EntryPoint deposit is debited the prefund at
// validation (EP:535) and refunded prefund - actualGasCost (EP:744-745), so
//   D1  ΔdepositOf(paymaster) == -actualGasCost (from this op's UserOperationEvent)
//   (holds only when this tx is the block's ONLY tx — the collector checks that separately.)
export function spConservation({ before, after, spEvents, tokenEvents, expectedHash, sender, operator, cls }) {
  const checks = [];
  const add = (id, ok, expected, actual, src) => checks.push({ id, ok: !!ok, expected: String(expected), actual: String(actual), src });
  const B = (x) => BigInt(x);
  const eqA = (a, b) => eq(String(a), String(b));
  const dOp = B(after.operatorBalance) - B(before.operatorBalance);
  const dRev = B(after.protocolRevenue) - B(before.protocolRevenue);
  const dUser = B(after.userXPNTs) - B(before.userXPNTs);
  const dSupply = B(after.totalSupply) - B(before.totalSupply);
  const dLocked = B(after.lockedOf) - B(before.lockedOf);
  const dDebt = B(after.debts) - B(before.debts);
  const dCredRes = B(after.creditReservedOf) - B(before.creditReservedOf);

  const sponsored = spEvents.filter((e) => e.event === 'TransactionSponsored');
  const lockCreated = tokenEvents.filter((e) => e.event === 'LockCreated' && eqA(e.args.opHash, expectedHash));
  const lockSettled = tokenEvents.filter((e) => e.event === 'LockSettled' && eqA(e.args.opHash, expectedHash));
  const credRes = tokenEvents.filter((e) => e.event === 'CreditReserved' && eqA(e.args.opHash, expectedHash));
  const credSet = tokenEvents.filter((e) => e.event === 'CreditSettled' && eqA(e.args.opHash, expectedHash));
  const postOpReverted = cls.verdict === VERDICTS.USEROP_REVERTED && cls.revertKind === 'postOpReverted';

  add('C4.inflight_before_empty', B(before.inflightA0) === 0n, 0, before.inflightA0, 'SP:324,445');
  if (postOpReverted) {
    const a0 = B(after.inflightA0);
    add('R1.sponsored_absent', sponsored.length === 0, 0, sponsored.length, 'EP:134-148');
    add('R1.inflight_after_operator', eqA(after.inflightOperator, operator), operator, after.inflightOperator, 'SP:324');
    add('R1.op_delta_eq_minus_a0', dOp === -a0, -a0, dOp, 'SP:322');
    add('R1.revenue_unchanged', dRev === 0n, 0, dRev, 'SP:448 not reached');
    const lc = lockCreated[0]?.args;
    if (lc) add('R2.locked_grew_by_xLocked', dLocked === B(lc.xLocked), lc.xLocked, dLocked, 'XT:239');
    return { mode: lc ? 'BALANCE' : credRes.length ? 'CREDIT' : 'UNKNOWN', postOpReverted: true, checks, ok: checks.every((c) => c.ok) };
  }

  add('C9.sponsored_exactly_one', sponsored.length === 1, 1, sponsored.length, 'SP:450');
  const ts = sponsored[0]?.args;
  if (!ts) return { mode: 'UNKNOWN', postOpReverted: false, checks, ok: false };
  const charge = B(ts.debtAPNTs);
  add('C9.sponsored_operator', eqA(ts.operator, operator), operator, ts.operator, 'SP:450');
  add('C9.sponsored_user', eqA(ts.user, sender), sender, ts.user, 'SP:450');
  add('C1.op_delta_eq_minus_charge', dOp === -charge, -charge, dOp, 'SP:322,447');
  add('C2.revenue_delta_eq_charge', dRev === charge, charge, dRev, 'SP:448');
  add('C3.op_plus_revenue_zero', dOp + dRev === 0n, 0, dOp + dRev, 'SP:322,447,448');
  add('C4.inflight_after_empty', B(after.inflightA0) === 0n, 0, after.inflightA0, 'SP:445');
  add('C10.totalTxSponsored_plus_one', B(after.totalTxSponsored) - B(before.totalTxSponsored) === 1n, 1,
    B(after.totalTxSponsored) - B(before.totalTxSponsored), 'SP:417');

  let mode = 'UNKNOWN';
  if (lockSettled.length === 1 && lockCreated.length === 1) {
    mode = 'BALANCE';
    const { xLocked, aReserved } = lockCreated[0].args;
    const { xBurned, aCharged } = lockSettled[0].args;
    const a0 = B(aReserved);
    add('C8.lock_charge_eq_sponsored_charge', B(aCharged) === charge, charge, aCharged, 'XT:259,268');
    add('C8.charge_le_a0', charge <= a0, `<=${a0}`, charge, 'SP:434');
    add('C10.totalSpent_plus_a0', B(after.totalSpent) - B(before.totalSpent) === a0, a0,
      B(after.totalSpent) - B(before.totalSpent), 'SP:323');
    let expBurn = a0 === 0n ? 0n : (charge * B(xLocked) + a0 - 1n) / a0;
    if (expBurn > B(xLocked)) expBurn = B(xLocked);
    add('C7.xBurned_formula', B(xBurned) === expBurn, expBurn, xBurned, 'XT:259-261');
    add('C5.user_delta_eq_minus_burn', dUser === -B(xBurned), -B(xBurned), dUser, 'XT:267');
    add('C5.supply_delta_eq_minus_burn', dSupply === -B(xBurned), -B(xBurned), dSupply, 'XT:267');
    add('C6.locked_unchanged', dLocked === 0n, 0, dLocked, 'XT:239,263');
    add('C6.lock_record_cleared', B(after.lockXLocked) === 0n, 0, after.lockXLocked, 'XT:262');
  } else if (credSet.length === 1 && credRes.length === 1) {
    mode = 'CREDIT';
    const { debtAdded } = credSet[0].args;
    add("C5'.debt_delta_eq_charge", dDebt === charge && B(debtAdded) === charge, charge, `${dDebt}/${debtAdded}`, 'XT:320-325');
    add("C5'.user_xpnts_unchanged", dUser === 0n && dSupply === 0n, 0, `${dUser}/${dSupply}`, 'XT:313-326');
    add("C5'.credit_reserved_unchanged", dCredRes === 0n, 0, dCredRes, 'XT:304,322');
  } else {
    add('mode.lock_or_credit_events', false, 'LockCreated+LockSettled or CreditReserved+CreditSettled',
      `lc=${lockCreated.length} ls=${lockSettled.length} cr=${credRes.length} cs=${credSet.length}`, 'XT:243,268,308,326');
  }
  return { mode, postOpReverted: false, charge: charge.toString(), checks, ok: checks.every((c) => c.ok) };
}

/** Deep-compare two JSON-able values; returns the list of differing paths (empty = equal). */
export function diffPaths(a, b, path = '$') {
  if (typeof a !== typeof b) return [path];
  if (a === null || b === null || typeof a !== 'object') {
    const norm = (x) => (typeof x === 'string' && isHex(x) ? x.toLowerCase() : x);
    return norm(a) === norm(b) ? [] : [path];
  }
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  return [...keys].flatMap((k) => diffPaths(a[k], b[k], `${path}.${k}`));
}

export function addr(a) { return getAddress(a); }
export const TOPIC = {
  UserOperationEvent: toEventSelector(EP_EVENTS_ABI[0]),
};

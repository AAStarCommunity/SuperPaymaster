#!/usr/bin/env node
// A3a precheck v2: assemble docs/release/a3a-precheck-v2/a3a-precheck.json from the local fork
// simulation (fork-sim/), the pinned two-endpoint snapshot, and the compiled ABIs.
// Offline: reads local files only. Fails closed on any undecodable event or hash mismatch.
import { readFileSync, writeFileSync } from 'node:fs';
import { keccak256, toEventSelector, decodeEventLog, hashTypedData, getAddress } from 'viem';

const DIR = 'docs/release/a3a-precheck-v2';
const SIM = `${DIR}/fork-sim`;
const rd = (p) => JSON.parse(readFileSync(p, 'utf8'));
const nd = (p) => readFileSync(p, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l));
const snap = rd(`${DIR}/snapshot.json`);
const A = rd(`${SIM}/addresses.json`);
const roles = rd(`${SIM}/S2-roles.json`);
const rows = nd(`${SIM}/steps.ndjson`);
const negs = nd(`${SIM}/negatives.ndjson`);
const S = snap.snapshot;
const fail = (m) => { console.error('BUILD FAILED: ' + m); process.exit(1); };

if (!snap.crossCheckIdentical) fail('snapshot endpoints disagree');
if (String(S.blockNumber) !== String(A.forkBlock)) fail(`fork block ${A.forkBlock} != snapshot block ${S.blockNumber}`);
if (String(S.deployerEOA.nonce) !== String(A.deployerNonceAtPin)) fail('deployer nonce in fork-sim != snapshot');
if (String(S.multisig.nonce) !== String(A.safeNonceAtPin)) fail('Safe nonce in fork-sim != snapshot');

// --- event decoding ---------------------------------------------------------------------------
const abis = [];
for (const f of ['out/SuperPaymaster.sol/SuperPaymaster.json', 'out/APNTsCapped.sol/APNTsCapped.json', 'out/TimelockController.sol/TimelockController.default.json']) {
  abis.push(...rd(f).abi.filter((x) => x.type === 'event'));
}
abis.push(
  // live SP is 5.4.2 (events from main's source)
  { type: 'event', name: 'APNTsTokenChangeCancelled', inputs: [{ name: 'pendingToken', type: 'address', indexed: true }] },
  { type: 'event', name: 'APNTsTokenChangeQueued', inputs: [{ name: 'pendingToken', type: 'address', indexed: true }, { name: 'eta', type: 'uint256', indexed: false }] },
  // Safe 1.4.1
  { type: 'event', name: 'ApproveHash', inputs: [{ name: 'approvedHash', type: 'bytes32', indexed: true }, { name: 'owner', type: 'address', indexed: true }] },
  { type: 'event', name: 'ExecutionSuccess', inputs: [{ name: 'txHash', type: 'bytes32', indexed: true }, { name: 'payment', type: 'uint256', indexed: false }] },
  { type: 'event', name: 'ExecutionFailure', inputs: [{ name: 'txHash', type: 'bytes32', indexed: true }, { name: 'payment', type: 'uint256', indexed: false }] },
  // the Sepolia Safe is a SafeL2 singleton: execTransaction also emits SafeMultiSigTransaction
  { type: 'event', name: 'SafeMultiSigTransaction', inputs: [
    { name: 'to', type: 'address' }, { name: 'value', type: 'uint256' }, { name: 'data', type: 'bytes' }, { name: 'operation', type: 'uint8' },
    { name: 'safeTxGas', type: 'uint256' }, { name: 'baseGas', type: 'uint256' }, { name: 'gasPrice', type: 'uint256' }, { name: 'gasToken', type: 'address' },
    { name: 'refundReceiver', type: 'address' }, { name: 'signatures', type: 'bytes' }, { name: 'additionalInfo', type: 'bytes' }] },
);
const byTopic = {};
for (const e of abis) { try { byTopic[toEventSelector(e)] ??= e; } catch {} }
const big = (x) => JSON.parse(JSON.stringify(x, (_, v) => (typeof v === 'bigint' ? v.toString() : v)));
const decode = (log) => {
  const e = byTopic[log.topics[0]];
  if (!e) fail(`undecodable event topic0 ${log.topics[0]} from ${log.address}`);
  const d = decodeEventLog({ abi: [e], data: log.data, topics: log.topics });
  return { emitter: getAddress(log.address), name: e.name, args: big(d.args) };
};

// --- Safe EIP-712 cross-check (independent of the contract's getTransactionHash) ---------------
const SAFE = getAddress(S.multisig.address);
const Z = '0x0000000000000000000000000000000000000000';
const safeTx = (data, nonce) => hashTypedData({
  domain: { chainId: Number(S.chainId), verifyingContract: SAFE },
  types: { SafeTx: [
    { name: 'to', type: 'address' }, { name: 'value', type: 'uint256' }, { name: 'data', type: 'bytes' }, { name: 'operation', type: 'uint8' },
    { name: 'safeTxGas', type: 'uint256' }, { name: 'baseGas', type: 'uint256' }, { name: 'gasPrice', type: 'uint256' },
    { name: 'gasToken', type: 'address' }, { name: 'refundReceiver', type: 'address' }, { name: 'nonce', type: 'uint256' }] },
  primaryType: 'SafeTx',
  message: { to: A.newTimelock, value: 0n, data, operation: 0, safeTxGas: 0n, baseGas: 0n, gasPrice: 0n, gasToken: Z, refundReceiver: Z, nonce: BigInt(nonce) },
});
const sched = readFileSync(`${SIM}/S5-schedule.calldata`, 'utf8').trim();
const exec = readFileSync(`${SIM}/S6-execute.calldata`, 'utf8').trim();
const h5 = safeTx(sched, A.safeNonceAtPin), h6 = safeTx(exec, A.safeNonceAtPin + 1);
if (h5 !== A.safeTxHashS5) fail(`S5 safeTxHash EIP-712 ${h5} != contract ${A.safeTxHashS5}`);
if (h6 !== A.safeTxHashS6) fail(`S6 safeTxHash EIP-712 ${h6} != contract ${A.safeTxHashS6}`);

// --- per-step metadata -------------------------------------------------------------------------
const N = Number(A.deployerNonceAtPin), SN = Number(A.safeNonceAtPin);
const EOA = getAddress(S.deployerEOA.address);
const [OA, OB] = ['0x871608cBA092105b91e91295A1d79fFC539BFb48', '0x8c3499252232105A1615767C459DB9BBbf1273D6'];
const nonceAbort = (who, n) => `re-read nonce of ${who} immediately before signing/sending; if it is not ${n}, ABORT — every address/calldata/hash below is invalid; regenerate the packet`;
const meta = {
  'S1-cancel': { id: 'S1', purpose: 'runbook 1① — cancel the pending aPNTs switch to 0xBb46… (XPNTs-3.5.0 aPNTs)', signer: `deployer EOA ${EOA} (SP owner)`, fn: 'SuperPaymaster.cancelAPNTsTokenChange()', args: [],
    requiredSenderNonce: N, pre: [`SP.owner() == ${EOA}`, `SP.pendingAPNTsToken() == ${S.sp.pendingAPNTsToken}`, `SP.version() == ${S.sp.version}`],
    post: ['SP.pendingAPNTsToken() == 0x0', 'SP.pendingAPNTsTokenEta() == 0', `SP.APNTS_TOKEN() == ${S.sp.APNTS_TOKEN} (unchanged)`],
    abort: 'revert, or any post read-back differs → stop; nothing else has happened yet', recovery: 'idempotent; re-send (it consumes a nonce, so every later address shifts — regenerate before S2)' },
  'S2-deploy-timelock': { id: 'S2', purpose: 'deploy the Safe-only GOV-1 48h TimelockController — the single canonical GOV-1 timelock (DSR default)', signer: `deployer EOA ${EOA}`, fn: 'CREATE TimelockController(uint256 minDelay, address[] proposers, address[] executors, address admin)', args: ['172800', `[${SAFE}]`, `[${SAFE}]`, Z],
    requiredSenderNonce: N + 1, pre: [`predicted address = keccak(rlp(${EOA}, ${N + 1})) = ${A.newTimelock}`],
    post: ['address == predicted', 'getMinDelay() == 172800', 'EXACT role sets (event history + hasRole): DEFAULT_ADMIN = [timelock itself], PROPOSER = CANCELLER = EXECUTOR = [Safe]; deployer, Safe owners, 0x0, SP and old timelock 0x86C8… hold none'],
    abort: 'address/minDelay/role-set differs → do NOT use it (an unused timelock is inert)', recovery: 'deploy again with correct args (shifts later nonces: regenerate S3+)' },
  'S3-deploy-apnts-capped': { id: 'S3', purpose: 'runbook 1② — deploy APNTsCapped via DeployAPNTsCapped.s.sol (TIMELOCK = S2)', signer: `deployer EOA ${EOA}`, fn: 'CREATE APNTsCapped(string name, string symbol, uint256 cap, address owner, address minter, address capGuardian)', args: ['AAStar PNTs', 'aPNTs', '10000000000000000000000000 (TEST_CAP_SEPOLIA — author question #1)', EOA, SAFE, SAFE],
    requiredSenderNonce: N + 2, pre: ['DeployAPNTsCapped._checkTimelock(S2) passes', `predicted address = keccak(rlp(${EOA}, ${N + 2})) = ${A.apntsCapped}`],
    post: ['address == predicted', 'runtime == profile.default artifact (script T-4)', 'cap == 10,000,000e18, minter == capGuardian == Safe, totalSupply == 0, version == APNTsCapped-1.0.0'],
    abort: 'script check fails / address differs → do NOT continue to S4/S7', recovery: 'unused token is inert (supply 0); redeploy and regenerate' },
  'S4-transfer-ownership': { id: 'S4', purpose: 'start Ownable2Step handover of APNTsCapped to the S2 timelock (2nd tx of the same script)', signer: `deployer EOA ${EOA} (APNTsCapped owner)`, fn: 'APNTsCapped.transferOwnership(address)', args: [A.newTimelock],
    requiredSenderNonce: N + 3, pre: ['APNTsCapped.owner() == deployer'], post: ['owner() == deployer (still)', `pendingOwner() == ${A.newTimelock}`],
    abort: 'pendingOwner differs → stop', recovery: 'owner re-calls transferOwnership(correct timelock)' },
  'S5a-approveHash': { id: 'S5a', purpose: `Safe owner #1 approves the S5 safeTxHash (Safe nonce ${SN}). Equivalent off-chain route: an EIP-712 signature over the same safeTxHash in Safe{Wallet}`, signer: `Safe owner ${OB}`, fn: 'Safe.approveHash(bytes32)', args: [A.safeTxHashS5],
    requiredSenderNonce: null, requiredSafeNonce: SN, pre: [`Safe.nonce() == ${SN}`, `Safe.getTransactionHash(timelock, 0, scheduleData, 0, 0, 0, 0, 0x0, 0x0, ${SN}) == ${A.safeTxHashS5} (also recomputed offline via EIP-712)`],
    post: [`Safe.approvedHashes(${OB}, safeTxHash) == 1`, `Safe.nonce() == ${SN} (unchanged)`],
    abort: 'Safe nonce differs → the hash is for the wrong nonce; do not approve', recovery: 'an approval of a stale hash is harmless (it can only execute that exact payload at that exact nonce)' },
  'S5b-safe-exec-schedule': { id: 'S5b', purpose: 'Safe owner #2 executes Safe.execTransaction → timelock.schedule(APNTsCapped, 0, acceptOwnership(), 0x0, salt, 172800)', signer: `Safe owner ${OA} (msg.sender; its signature is the v=1 pre-validated form)`, fn: 'Safe.execTransaction(to, value, data, operation, safeTxGas, baseGas, gasPrice, gasToken, refundReceiver, signatures)', args: [A.newTimelock, '0', '<S5-schedule.calldata>', '0', '0', '0', '0', Z, Z, A.signatures],
    requiredSenderNonce: null, requiredSafeNonce: SN, pre: [`Safe.nonce() == ${SN}`, `approvedHashes(${OB}, ${A.safeTxHashS5}) == 1`, `APNTsCapped.pendingOwner() == ${A.newTimelock}`, 'signatures sorted ascending by owner address'],
    post: [`Safe.nonce() == ${SN + 1}`, 'ExecutionSuccess(safeTxHash) emitted (NOT ExecutionFailure)', `isOperationPending(${A.acceptOperationId}) == true`, 'getTimestamp(opId) == execution block ts + 172800'],
    abort: 'wrong target/salt/delay in the decoded payload → do not execute', recovery: 'Safe (CANCELLER) executes timelock.cancel(opId) and re-schedules (another 48h)' },
  'S6a-approveHash': { id: 'S6a', purpose: `≥ 48h after S5b: Safe owner #1 approves the S6 safeTxHash (Safe nonce ${SN + 1})`, signer: `Safe owner ${OB}`, fn: 'Safe.approveHash(bytes32)', args: [A.safeTxHashS6],
    requiredSenderNonce: null, requiredSafeNonce: SN + 1, pre: [`Safe.nonce() == ${SN + 1}`, `block.timestamp >= readyAt (${A.readyAt} in the simulation)`], post: [`approvedHashes(${OB}, safeTxHash) == 1`],
    abort: 'Safe nonce differs → regenerate', recovery: 'as S5a' },
  'S6b-safe-exec-execute': { id: 'S6b', purpose: 'Safe owner #2 executes Safe.execTransaction → timelock.execute(APNTsCapped, 0, acceptOwnership(), 0x0, salt)', signer: `Safe owner ${OA}`, fn: 'Safe.execTransaction(...)', args: [A.newTimelock, '0', '<S6-execute.calldata>', '0', '0', '0', '0', Z, Z, A.signatures],
    requiredSenderNonce: null, requiredSafeNonce: SN + 1, pre: [`Safe.nonce() == ${SN + 1}`, 'isOperationReady(opId) == true'],
    post: [`Safe.nonce() == ${SN + 2}`, 'ExecutionSuccess emitted', `APNTsCapped.owner() == ${A.newTimelock}`, 'pendingOwner() == 0x0', 'isOperationDone(opId) == true', 'DeployAPNTsCapped.verify → ALL PASS'],
    abort: 'GS013 / ExecutionFailure / owner != timelock → stop', recovery: 'before execution the deployer is still owner: nothing is lost; fix and retry' },
  'S7-queue': { id: 'S7', purpose: 'runbook 1③ — re-queue SP.setAPNTsToken(APNTsCapped) only AFTER S6 (DSR default order); ETA = queue block ts + 7d', signer: `deployer EOA ${EOA} (SP owner)`, fn: 'SuperPaymaster.setAPNTsToken(address)', args: [A.apntsCapped],
    requiredSenderNonce: N + 4, pre: ['S6 done: APNTsCapped.owner() == S2 timelock', 'SP.pendingAPNTsToken() == 0 and eta == 0', `SP.version() == ${S.sp.version}`, 'V55_APNTS_DECISION=queue'],
    post: [`SP.pendingAPNTsToken() == ${A.apntsCapped}`, 'SP.pendingAPNTsTokenEta() == queue block ts + 604800', 'SP.APNTS_TOKEN() unchanged'],
    abort: 'wrong token queued → do not wait for ETA', recovery: 'cancelAPNTsTokenChange() then re-queue — another 7 days' },
};

const steps = [];
for (const row of rows) {
  const m = meta[row.label];
  if (!m) continue; // negative-control setup transactions are listed separately
  const tx = rd(`${SIM}/${row.label}.tx.json`);
  const r = rd(`${SIM}/${row.label}.receipt.json`);
  if (getAddress(tx.from) !== getAddress(row.from)) fail(`${row.label}: from mismatch`);
  if (m.requiredSenderNonce != null && row.senderNonceBefore !== m.requiredSenderNonce) fail(`${row.label}: sender nonce ${row.senderNonceBefore} != planned ${m.requiredSenderNonce}`);
  if (m.requiredSafeNonce != null && row.safeNonceBefore !== m.requiredSafeNonce) fail(`${row.label}: Safe nonce ${row.safeNonceBefore} != planned ${m.requiredSafeNonce}`);
  const gas = BigInt(r.gasUsed);
  steps.push({
    ...m, label: row.label, chainId: S.chainId,
    nonceCheck: m.requiredSenderNonce != null ? nonceAbort('the deployer EOA', m.requiredSenderNonce) : nonceAbort('the Safe (Safe.nonce())', m.requiredSafeNonce), from: getAddress(tx.from), to: tx.to ? getAddress(tx.to) : null, createdAddress: r.contractAddress ? getAddress(r.contractAddress) : null,
    value: BigInt(tx.value).toString(), calldata: tx.input, calldataKeccak256: keccak256(tx.input), calldataBytes: (tx.input.length - 2) / 2,
    senderNonce: { before: row.senderNonceBefore, after: row.senderNonceAfter }, safeNonce: { before: row.safeNonceBefore, after: row.safeNonceAfter },
    gasUsedInFork: gas.toString(), suggestedGasLimit: ((gas * 13n) / 10n).toString(),
    expectedEvents: r.logs.map(decode), forkTxHash: tx.hash, forkBlockTimestamp: row.timestamp,
  });
}
if (steps.length !== 9) fail(`expected 9 execution steps, got ${steps.length}`);
const ex = (id) => steps.find((s) => s.id === id);
for (const id of ['S5b', 'S6b']) if (!ex(id).expectedEvents.some((e) => e.name === 'ExecutionSuccess')) fail(`${id}: no ExecutionSuccess`);
const setup = rows.filter((r) => !meta[r.label]);

const gasBy = (pred) => steps.filter(pred).reduce((a, s) => a + BigInt(s.gasUsedInFork), 0n);
const gwei = 20n;
const eoaGas = gasBy((s) => s.from === EOA), approverGas = gasBy((s) => s.from === getAddress(OB)), execGas = gasBy((s) => s.from === getAddress(OA));
const out = {
  status: 'NOT EXECUTED — nothing in this packet has been broadcast to any public network; executing any step needs the author\'s separate go for A3a',
  validity: `Every address, calldata, operation id and safeTxHash below is valid ONLY for deployer EOA nonce ${N} and Safe nonce ${SN} (Sepolia block ${S.blockNumber}). If either nonce moves, ALL of it must be regenerated. Per-tx abort rule: re-read the nonce before every tx and abort on mismatch.`,
  scope: 'A3a only = 03-final-spec §6 step 1 ①–③ + the Safe-only GOV-1 timelock. EXCLUDES A3b (step 1④ executeAPNTsTokenChange / withdraw / redeposit, steps 2–7c, SP/Registry upgrades, stake top-up).',
  canonicalTimelock: 'DSR default (CC-122 v4): the S2 Safe-only timelock is the single canonical GOV-1 timelock (APNTsCapped now; later SP / Registry / AOAProtocolRegistry / Factory). Author confirmation still open (question #2).',
  pinnedBlock: S.blockNumber, pinnedTimestamp: S.blockTimestamp, snapshotCrossCheckIdentical: snap.crossCheckIdentical,
  liveNoncesAtPin: { deployerEOA: N, safe: SN },
  nonceSchedule: { deployerEOA: { S1: N, S2: N + 1, S3: N + 2, S4: N + 3, S7: N + 4, after: N + 5 }, safe: { S5b: SN, S6b: SN + 1, after: SN + 2 } },
  simulatedAddresses: A,
  safeTxHashCrossCheck: { S5: { contract: A.safeTxHashS5, eip712Offline: h5 }, S6: { contract: A.safeTxHashS6, eip712Offline: h6 } },
  safeTxParams: { operation: 0, safeTxGas: 0, baseGas: 0, gasPrice: 0, gasToken: Z, refundReceiver: Z, signatureNote: 'fork used approveHash (owner OB) + msg.sender pre-validated signature (owner OA), concatenated in ascending owner order; off-chain EIP-712 ECDSA signatures over the same safeTxHash are the equivalent Safe{Wallet} route (not exercisable on a fork without owner keys)' },
  timelockRoles: roles,
  timing: { order: 'default (DSR): S1–S4 → S5 → wait ≥ 48h → S6 → S7 → wait 7d → earliest A3b', t0: A.t0, scheduleTs: A.scheduleTs, readyAt: A.readyAt, queueTs: A.queueTs, eta: A.eta, etaMinusT0Seconds: A.eta - A.t0, earliestA3b: 'T0 + 9 days (+ the time between S5b and S7 beyond the 48h minimum)' },
  steps,
  negativeControlSetupTransactions: setup,
  negativeControls: negs,
  gas: {
    deployerEOA_totalGas: eoaGas.toString(), safeApprover_totalGas: approverGas.toString(), safeExecutor_totalGas: execGas.toString(),
    innerCallEstimates: { schedule: A.innerScheduleGasEstimate, execute: A.innerExecuteGasEstimate },
    safeWrapperOverhead: { S5b: (BigInt(ex('S5b').gasUsedInFork) - BigInt(A.innerScheduleGasEstimate)).toString(), S6b: (BigInt(ex('S6b').gasUsedInFork) - BigInt(A.innerExecuteGasEstimate)).toString(), note: 'execTransaction gasUsed minus eth_estimateGas of the bare inner call (estimate includes the 21000 base, so this is a lower bound of the wrapper overhead)' },
    conservativeGasPriceGwei: gwei.toString(),
    deployerEOA_costAtConservativeWei: (eoaGas * gwei * 10n ** 9n).toString(), deployerEOA_balanceWei: S.deployerEOA.balanceWei,
    safeOwners: S.multisigOwners, baseFeeAtPinWei: S.baseFeePerGas,
  },
};
writeFileSync(`${DIR}/a3a-precheck.json`, JSON.stringify(out, null, 1) + '\n');
console.log('| # | signer | to | function | sender nonce | Safe nonce | fork gas | events |');
console.log('|---|---|---|---|---|---|---|---|');
for (const s of steps) {
  console.log(`| ${s.id} | \`${s.from.slice(0, 6)}…${s.from.slice(-4)}\` | ${s.to ? '`' + s.to.slice(0, 6) + '…' + s.to.slice(-4) + '`' : 'CREATE → `' + s.createdAddress + '`'} | ${s.fn.split('(')[0]} | ${s.senderNonce.before}→${s.senderNonce.after} | ${s.safeNonce.before}→${s.safeNonce.after} | ${Number(s.gasUsedInFork).toLocaleString('en-US')} | ${s.expectedEvents.map((e) => e.name).join(', ')} |`);
}
console.log('eoaGas', eoaGas.toString(), 'approverGas', approverGas.toString(), 'execGas', execGas.toString());

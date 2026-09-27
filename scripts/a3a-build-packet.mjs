#!/usr/bin/env node
// A3a precheck: assemble docs/release/a3a-precheck/a3a-precheck.json from the local fork
// simulation (fork-sim/*.tx.json, *.receipt.json), the pinned snapshot and the Safe payloads.
// Offline: reads local files only.
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { keccak256, toEventSelector, decodeEventLog } from 'viem';

const DIR = 'docs/release/a3a-precheck';
const SIM = `${DIR}/fork-sim`;
const rd = (p) => JSON.parse(readFileSync(p, 'utf8'));
const snap = rd(`${DIR}/snapshot.json`);
const safe = rd(`${DIR}/safe-payloads.json`);
const addrs = rd(`${SIM}/addresses.json`);

// topic0 -> {name, abiItem} from the compiled artifacts involved
const abis = [];
for (const f of ['out/SuperPaymaster.sol/SuperPaymaster.json', 'out/SuperPaymasterAdmin.sol/SuperPaymasterAdmin.json',
  'out/APNTsCapped.sol/APNTsCapped.json', 'out/TimelockController.sol/TimelockController.default.json']) {
  abis.push(...rd(f).abi.filter((x) => x.type === 'event')); // missing artifact = hard error (run forge build first)
}
// The live SP is 5.4.2; its events come from main's source. Add the 5.4.2 APNTs events explicitly.
abis.push(
  { type: 'event', name: 'APNTsTokenChangeCancelled', inputs: [{ name: 'pendingToken', type: 'address', indexed: true }] },
  { type: 'event', name: 'APNTsTokenChangeQueued', inputs: [{ name: 'pendingToken', type: 'address', indexed: true }, { name: 'eta', type: 'uint256', indexed: false }] },
);
const byTopic = {};
for (const e of abis) { try { byTopic[toEventSelector(e)] ??= e; } catch {} }
const decode = (log) => {
  const e = byTopic[log.topics[0]];
  if (!e) throw new Error(`undecodable event topic0 ${log.topics[0]} from ${log.address}: add its ABI before publishing the packet`);
  try {
    const d = decodeEventLog({ abi: [e], data: log.data, topics: log.topics });
    return { emitter: log.address, topic0: log.topics[0], name: e.name, args: JSON.parse(JSON.stringify(d.args, (_, v) => (typeof v === 'bigint' ? v.toString() : v))) };
  } catch (err) { throw new Error(`event ${e.name} from ${log.address} failed to decode: ${err.message}`); }
};

const S = snap.snapshot;
const meta = {
  S1: { purpose: 'runbook 1① — cancel the pending aPNTs switch to 0xBb46… (XPNTs-3.5.0 aPNTs)', signer: 'deployer EOA (SP owner)', role: 'SuperPaymaster.owner()', fn: 'cancelAPNTsTokenChange()',
    pre: [`SP.owner() == ${S.sp.owner}`, `SP.pendingAPNTsToken() == ${S.sp.pendingAPNTsToken}`, `SP.pendingAPNTsTokenEta() == ${S.sp.pendingAPNTsTokenEta}`, `SP.version() == ${S.sp.version}`],
    post: ['SP.pendingAPNTsToken() == 0x0', 'SP.pendingAPNTsTokenEta() == 0', `SP.APNTS_TOKEN() == ${S.sp.APNTS_TOKEN} (unchanged)`],
    abort: 'tx reverts, or any post read-back differs → stop; nothing else has happened yet',
    recovery: 'idempotent; re-send. If skipped, setAPNTsToken(S7) would overwrite pending anyway, but S7 script refuses while a switch is pending (by design)' },
  S2: { purpose: 'deploy a GOV-1-shaped 48h TimelockController for the APNTsCapped owner handover (live TL 0x86C8… has no role for the multisig)', signer: 'deployer EOA', role: 'none (CREATE)', fn: 'CREATE TimelockController(172800, [SAFE], [SAFE], address(0))',
    pre: ['live TL 0x86C8…: multisig holds no PROPOSER/CANCELLER/EXECUTOR role (snapshot)', `deployer nonce == ${S.deployerEOA.nonce} → predicted address ${addrs.newTimelock}`],
    post: ['getMinDelay() == 172800', 'SAFE has PROPOSER, CANCELLER, EXECUTOR', 'deployer EOA has none of them and no DEFAULT_ADMIN', 'address == predicted CREATE address'],
    abort: 'any role/minDelay read-back differs → do NOT use this timelock; deploy a new one',
    recovery: 'an unused timelock is inert; redeploy with correct args' },
  S3: { purpose: 'runbook 1② — deploy APNTsCapped (DeployAPNTsCapped.s.sol)', signer: 'deployer EOA', role: 'none (CREATE)', fn: 'CREATE APNTsCapped("AAStar PNTs","aPNTs", cap=10,000,000e18 TEST, owner=deployer, minter=SAFE, capGuardian=SAFE)',
    pre: ['TIMELOCK env = S2 address; DeployAPNTsCapped._checkTimelock passes', `deployer nonce == ${Number(S.deployerEOA.nonce) + 1}`],
    post: ['runtime == profile.default artifact (script T-4 check)', 'cap() == 10,000,000e18', 'minter() == capGuardian() == SAFE', 'totalSupply() == 0', 'version() == APNTsCapped-1.0.0'],
    abort: 'script check fails or any param differs → do NOT queue this token',
    recovery: 'unused token is inert (supply 0); redeploy' },
  S4: { purpose: 'start Ownable2Step handover of APNTsCapped to the S2 timelock (same script, 2nd tx)', signer: 'deployer EOA', role: 'APNTsCapped.owner()', fn: 'APNTsCapped.transferOwnership(S2 timelock)',
    pre: ['APNTsCapped.owner() == deployer'], post: ['owner() == deployer (still)', 'pendingOwner() == S2 timelock'],
    abort: 'pendingOwner differs → stop', recovery: 'owner re-calls transferOwnership(correct timelock)' },
  S5: { purpose: 'multisig schedules APNTsCapped.acceptOwnership() on the S2 timelock (48h delay)', signer: 'Safe 0x51eD…E114 (2-of-3) via execTransaction', role: 'TimelockController PROPOSER', fn: 'TimelockController.schedule(APNTsCapped, 0, acceptOwnership(), 0x0, keccak256("APNTsCapped-1.0.0/acceptOwnership"), 172800)',
    pre: ['APNTsCapped.pendingOwner() == S2 timelock', 'Safe nonce matches the signed payload'], post: ['isOperationPending(opId) == true', 'getTimestamp(opId) == schedule block ts + 172800'],
    abort: 'wrong target/salt/delay → do not execute; cancel via Safe (CANCELLER)', recovery: 'Safe calls cancel(opId), reschedule (another 48h)' },
  S6: { purpose: 'after ≥48h the multisig executes the scheduled acceptOwnership()', signer: 'Safe 0x51eD…E114 (2-of-3) via execTransaction', role: 'TimelockController EXECUTOR (only the Safe)', fn: 'TimelockController.execute(APNTsCapped, 0, acceptOwnership(), 0x0, salt)',
    pre: ['block.timestamp ≥ readyAt', 'operation still pending'], post: ['APNTsCapped.owner() == S2 timelock', 'pendingOwner() == 0x0', 'DeployAPNTsCapped.verify → ALL PASS'],
    abort: 'executes but owner != timelock → stop, investigate', recovery: 'before execution the deployer is still owner (natural abort point: nothing lost if the timelock is misconfigured)' },
  S7: { purpose: 'runbook 1③ — re-queue SP.setAPNTsToken(APNTsCapped); ETA = queue block ts + 7 days', signer: 'deployer EOA (SP owner)', role: 'SuperPaymaster.owner()', fn: 'setAPNTsToken(APNTsCapped)',
    pre: ['SP.pendingAPNTsToken() == 0 and eta == 0 (S1 done)', 'APNTsCapped has code', `SP.version() == ${S.sp.version} (script refuses otherwise)`, 'V55_APNTS_DECISION=queue (author decision gate)'],
    post: ['SP.pendingAPNTsToken() == APNTsCapped', 'SP.pendingAPNTsTokenEta() == queue block ts + 604800', 'SP.APNTS_TOKEN() unchanged'],
    abort: 'wrong token queued → do not wait for ETA', recovery: 'cancelAPNTsTokenChange() and re-queue — costs another 7 days' },
};

const files = readdirSync(SIM);
const steps = [];
for (const id of ['S1', 'S2', 'S3', 'S4', 'S5', 'S6', 'S7']) {
  const base = files.find((f) => f.startsWith(id + '-') && f.endsWith('.tx.json'));
  const tx = rd(`${SIM}/${base}`); const r = rd(`${SIM}/${base.replace('.tx.json', '.receipt.json')}`);
  const safeStep = safe.steps.find((s) => s.step === id);
  steps.push({
    id, ...meta[id], chainId: S.chainId,
    from_in_simulation: tx.from, to: tx.to ?? null, createdAddress: r.contractAddress ?? null, value: BigInt(tx.value).toString(),
    calldata: tx.input, calldataKeccak256: keccak256(tx.input), calldataBytes: (tx.input.length - 2) / 2,
    gasUsedInFork: BigInt(r.gasUsed).toString(),
    events: r.logs.map(decode),
    ...(safeStep ? { safePayload: { to: safeStep.to, value: 0, data: safeStep.data, operation: 0, ...safe.safeTxParams, safeNonceAtPin: safeStep.safeNonce, safeTxHashAtPin: safeStep.safeTxHash } } : {}),
    forkTxHash: tx.hash,
  });
}
const eoaGas = steps.filter((s) => !s.safePayload).reduce((a, s) => a + BigInt(s.gasUsedInFork), 0n);
const safeGas = steps.filter((s) => s.safePayload).reduce((a, s) => a + BigInt(s.gasUsedInFork), 0n);
const conservativeGwei = 20n;
const out = {
  status: 'DELIVERED, NOT EXECUTED — nothing in this packet has been broadcast to any public network',
  scope: 'A3a only = 03-final-spec §6 step 1 ①–③ + GOV-1 timelock for APNTsCapped. EXCLUDES A3b (step 1④ executeAPNTsTokenChange / withdraw / redeposit, step 2–7c, SP/Registry upgrades, stake top-up).',
  sourceCommit: 'feat/aoa-balance-mode-5.5.0 @ a81e659d (contracts == v5.5.0-rc.2 @ 1ac0e1c5)',
  pinnedBlock: S.blockNumber, pinnedTimestamp: S.blockTimestamp,
  snapshotCrossCheckIdentical: snap.crossCheckIdentical,
  simulatedAddresses: addrs,
  valuesThatChangeAtExecution: [
    `deployer nonce (pinned ${S.deployerEOA.nonce}) → S2/S3 CREATE addresses; recompute with cast compute-address <deployer> --nonce <n>`,
    'APNTsCapped address → S5/S6 calldata, timelock operation id, Safe tx hashes',
    `Safe nonce (pinned ${safe.safeNonceAtPin}) → safeTxHash; recompute with Safe.getTransactionHash(...)`,
    'schedule block timestamp → readyAt (= ts + 172800); queue block timestamp → ETA (= ts + 604800)',
    'gas used by the Safe execTransaction wrapper (fork impersonated the Safe directly, so Safe overhead is not included)',
  ],
  steps,
  gas: {
    deployerEOA_totalGas: eoaGas.toString(), safeInnerCalls_totalGas: safeGas.toString(),
    safeExecOverheadAllowancePerTx: '60000',
    conservativeGasPriceGwei: conservativeGwei.toString(),
    deployerEOA_costAtConservativeWei: (eoaGas * conservativeGwei * 10n ** 9n).toString(),
    safeExecutor_costAtConservativeWei: ((safeGas + 120000n) * conservativeGwei * 10n ** 9n).toString(),
    deployerEOA_balanceWei: S.deployerEOA.balanceWei, safeOwners: safe.owners,
    baseFeeAtPinWei: safe.baseFeePerGasAtPin,
  },
};
writeFileSync(`${DIR}/a3a-precheck.json`, JSON.stringify(out, null, 1) + '\n');
console.log('steps', steps.length, 'eoaGas', eoaGas.toString(), 'safeGas', safeGas.toString());
for (const s of steps) console.log(s.id, s.to ?? `CREATE→${s.createdAddress}`, s.calldataKeccak256.slice(0, 18), s.gasUsedInFork, s.events.map((e) => e.name).join(','));

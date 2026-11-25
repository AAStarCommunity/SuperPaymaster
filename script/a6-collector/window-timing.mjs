#!/usr/bin/env node
// No-send timing probe for one window slot (three arms) on the real provider pair. Per arm, in
// slot-0 order, it makes the reads of a window attempt in collector order: pre-gate pin + Passport,
// slot gate, nonce, one PVG iteration's hash reads, deposit, both frozen-plan beforeSend checks with
// their fee pins, a preflight simulation sample, the submit gate with its pin and pending-nonce
// reads, the inclusion block, the read-backs and the post-inclusion Passport. It never signs or
// sends: the runtime is read-only (no signer, wallet or keychain) and takes no bundler lock. Output
// goes to a fresh --out-dir named timing-*, so it cannot be a later window directory.
//
// Usage: node script/a6-collector/window-timing.mjs --frozen-plan <bundle> --bundle-sha256 <hex>
//   --seed <seed> --formal-config <json> --config <deployment json> --baselines <json>
//   --rpc-a-file <file> --rpc-b-file <file> --out-dir <new dir> [--cap-a N] [--cap-b N]
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, resolve } from 'node:path';
import { getAddress, keccak256, concat, pad, toHex } from 'viem';
import { formalRuntime, DEFAULT_FACTORY, EP_ABI } from './formal.mjs';
import { createWindow, waitForSlot } from './window-schedule.mjs';
import { diffPaths, jsonable } from './gauge-lib.mjs';
import { READ_CAP, readPool, readPassport, readReadbacks, EP_DEPOSIT_ABI, SP_ABI } from './window-reads.mjs';

const argVal = flag => { const i = process.argv.indexOf(flag); return i === -1 ? undefined : process.argv[i + 1]; };
const die = msg => { console.error(`window-timing: ${msg}`); process.exit(2); };
for (const f of ['--frozen-plan', '--bundle-sha256', '--seed', '--formal-config', '--config', '--baselines', '--rpc-a-file', '--rpc-b-file', '--out-dir'])
  if (!argVal(f) || argVal(f).startsWith('--')) die(`${f} is required`);
if (!/^[0-9a-f]{64}$/.test(argVal('--bundle-sha256'))) die('--bundle-sha256 must be 64 lowercase hex');
const cap = (flag, d) => { const v = argVal(flag) ?? String(d); if (!/^[1-9]\d?$/.test(v)) die(`${flag} must be 1..99`); return Number(v); };
const caps = { A: cap('--cap-a', READ_CAP.A), B: cap('--cap-b', READ_CAP.B) };
const outDir = resolve(argVal('--out-dir'));
if (!/^timing-/.test(basename(outDir))) die('--out-dir basename must start with timing-');
if (existsSync(outDir)) die('--out-dir must not exist');

const formalInput = JSON.parse(readFileSync(argVal('--formal-config'), 'utf8'));
formalInput.factory ??= DEFAULT_FACTORY;
if (!Array.isArray(formalInput.senders) || formalInput.senders.length !== 3) die('formal config requires three senders');
const senderConfigs = formalInput.senders.map(s => ({ ...formalInput, sender: getAddress(s.sender), salt: s.salt, accounts: { ...formalInput.accounts, owner: s.owner } }));
const cfg = JSON.parse(readFileSync(argVal('--config'), 'utf8')), baselines = JSON.parse(readFileSync(argVal('--baselines'), 'utf8'));
const window = createWindow({ readBundle: () => readFileSync(argVal('--frozen-plan')), bundleSha256: argVal('--bundle-sha256'), seed: argVal('--seed'),
  chainId: formalInput.chainId, accounts: senderConfigs.map(c => c.sender) });
for (const c of senderConfigs) window.adapters.get(c.sender).bind(c, cfg, baselines, 1n, 20);
const EP = getAddress(cfg.entryPoint), SPA = getAddress(cfg.superPaymaster);
const pmAddrOf = arm => getAddress(arm === 'SP' ? SPA : arm === 'VPM' ? baselines.verifyingPaymaster.address : baselines.tokenPaymaster.address);
const ARM = { SP: 'SP', VerifyingPaymaster: 'VPM', TokenPaymaster: 'TPM' };

mkdirSync(outDir, { recursive: false });
const runtime = await formalRuntime({ config: senderConfigs[0], rpcAFile: argVal('--rpc-a-file'), rpcBFile: argVal('--rpc-b-file'),
  outPath: resolve(outDir, 'timing.jsonl'), readOnly: true, pendingNonce: true });
if (Object.keys(runtime.accounts).length) die('timing runtime must hold no signer');
const { pubA, pubB } = runtime;
const pools = new Map([[pubA, readPool(caps.A)], [pubB, readPool(caps.B)]]);
async function readAB(label, fn) {
  const [a, b] = await Promise.all([fn(pubA), fn(pubB)]);
  const diff = diffPaths(jsonable(a), jsonable(b));
  if (diff.length) throw new Error(`RPC_DISAGREEMENT at ${label}: ${JSON.stringify(diff).slice(0, 300)}`);
  return a;
}
// Count archived requests and HTTP statuses since the previous mark, per endpoint.
const cursor = [0, 0];
function mark() {
  return Object.fromEntries(runtime.archives.map((arc, i) => {
    const rs = arc.records.slice(cursor[i]); cursor[i] = arc.records.length;
    const status = {}, methods = {};
    for (const r of rs) { const k = r.transportError ? 'transport_error' : String(r.httpStatus); status[k] = (status[k] ?? 0) + 1; methods[r.method] = (methods[r.method] ?? 0) + 1; }
    return [i ? 'B' : 'A', { requests: rs.length, status, methods }];
  }));
}
const operator = getAddress(formalInput.operator);
await runtime.refreshPin();
const spToken = getAddress((await readAB('operator', p => p.readContract({ address: SPA, abi: SP_ABI, functionName: 'operators', args: [operator] })))[3]);
mark();
const env = (sender, frozen) => ({ EP, SPA, spToken, sender, operator, baselines, formal: true, allowSameEndpointLocal: false, pmAddrOf,
  bundler: getAddress(formalInput.accounts.bundler.address), gas: frozen.gas, pmGas: frozen.pmGas, callDataHash: keccak256(frozen.callData) });
const ZERO_HASH = '0x' + '00'.repeat(32), u128 = v => pad(toHex(v), { size: 16 });
const bundlerAddress = getAddress(formalInput.accounts.bundler.address);
const HANDLE_OPS_ABI = [{ type: 'function', name: 'handleOps', stateMutability: 'nonpayable', inputs: [{ name: 'ops', type: 'tuple[]', components: EP_ABI.find(x => x.name === 'getUserOpHash').inputs[0].components }, { name: 'beneficiary', type: 'address' }], outputs: [] }];
// One gate iteration: with deadline 0 waitForSlot returns after its first pin and reads.
const gate = (arm, sender) => waitForSlot({ runtime, arm, operator, sender, paymaster: SPA, start: 0n, deadline: 0n });

const slot = window.manifest.schedule.payload.slots[0], arms = [];
const t0 = performance.now();
for (const armName of slot.order) {
  const arm = ARM[armName], sender = getAddress(slot.senders[armName]), adapter = window.adapters.get(sender), frozen = adapter.frozen, e = env(sender, frozen);
  const gas = frozen.gas[arm], pmGas = frozen.pmGas[arm], phases = {};
  const phase = async (name, fn) => { const t = performance.now(); const value = await fn(); phases[name] = { seconds: +((performance.now() - t) / 1000).toFixed(3), ...mark() }; return value; };
  await phase('preGatePassport', async () => { const b = await runtime.refreshPin(); await readAB('passport', p => readPassport(p, b.number, e, pools.get(p))); });
  await phase('slotGate', () => gate(arm, sender));
  const nonce = await phase('nonce', () => readAB('getNonce', p => p.readContract({ address: EP, abi: EP_ABI, functionName: 'getNonce', args: [sender, 0n] })));
  const packed = { sender, nonce, initCode: '0x', callData: frozen.callData, accountGasLimits: concat([u128(gas.verificationGasLimit), u128(gas.callGasLimit)]),
    preVerificationGas: gas.preVerificationGas, gasFees: concat([u128(gas.maxPriorityFeePerGas), u128(gas.maxFeePerGas)]),
    paymasterAndData: concat([pmAddrOf(arm), u128(pmGas.ver), u128(pmGas.post)]), signature: '0x' };
  // One PVG iteration's reads (VPM getHash on A, getUserOpHash on A and B); signing is excluded.
  await phase('pvgIterationReads', async () => {
    if (arm === 'VPM') await pubA.readContract({ address: baselines.verifyingPaymaster.address, abi: baselines.verifyingPaymaster.abi, functionName: 'getHash', args: [packed, 0n, 0n] });
    await readAB('getUserOpHash', p => p.readContract({ address: EP, abi: EP_ABI, functionName: 'getUserOpHash', args: [packed] }));
  });
  await phase('preSendChecks', async () => {
    await readAB('epDeposit', p => p.readContract({ address: EP, abi: EP_DEPOSIT_ABI, functionName: 'balanceOf', args: [pmAddrOf(arm)] }));
    await adapter.beforeSend(runtime); await runtime.refreshPin();
    // Preflight sample: the unsigned op reverts; this times one handleOps simulation call on A.
    await pubA.simulateContract({ address: EP, abi: HANDLE_OPS_ABI, functionName: 'handleOps', args: [[packed], bundlerAddress], account: bundlerAddress }).catch(() => null);
    await pubA.getBlockNumber({ cacheTime: 0 });
    await adapter.beforeSend(runtime); await runtime.refreshPin();
  });
  await phase('submitGate', async () => {
    await gate(arm, sender); await runtime.refreshPin();
    await Promise.all(runtime.archives.map(a => a.request({ method: 'eth_getTransactionCount', params: [bundlerAddress, 'pending'] })));
  });
  const bn = (await runtime.refreshPin()).number; mark();
  await phase('inclusionBlock', () => readAB('attempt block', p => p.getBlock({ blockNumber: bn })));
  await phase('readbacks', async () => {
    for (const n of [bn - 1n, bn]) await readAB('readbacks', p => readReadbacks(p, arm, n, ZERO_HASH, sender, e, pools.get(p)));
  });
  await phase('postInclusionPassport', () => readAB('passport@bn', p => readPassport(p, bn, e, pools.get(p))));
  arms.push({ arm, sender, phases, totalSeconds: +Object.values(phases).reduce((s, x) => s + x.seconds, 0).toFixed(3) });
}
const result = { schema: 'a6-window-timing/1', caps, slot: { block_slot: slot.block_slot, order: slot.order.map(a => ARM[a]) },
  slotPeriodSeconds: window.manifest.schedule.payload.slot_period_seconds, maxElapsedSeconds: window.manifest.schedule.payload.max_elapsed_seconds,
  arms, slotSeconds: +((performance.now() - t0) / 1000).toFixed(3),
  maxInFlight: { A: pools.get(pubA).maxInFlight, B: pools.get(pubB).maxInFlight },
  excluded: ['signing (owner and VPM signer) per PVG iteration', 'PVG iterations after the first (reads per iteration are pvgIterationReads)',
    'transaction broadcast', 'receipt polling and inclusion', 'transaction read', 'wait for both heads past inclusion before the next attempt'],
  note: 'preflight simulation is timed on an unsigned op (it reverts); the real op is signed' };
writeFileSync(resolve(outDir, 'timing.json'), JSON.stringify(result, null, 1) + '\n');
console.log(JSON.stringify(result, null, 1));

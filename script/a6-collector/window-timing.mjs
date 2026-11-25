#!/usr/bin/env node
// No-send timing probe for one window slot (three arms) on the real provider pair. It runs, per
// arm and in slot-0 order, the reads a window attempt makes: the pre-gate pin + Passport, one
// slot-gate iteration, the pre-send nonce/deposit/fee-pin reads, the read-backs before and after a
// block, and the post-inclusion Passport. It never signs or sends: the runtime is read-only (no
// signer, no wallet, no keychain), it takes no bundler lock, and it writes only to a fresh
// --out-dir that is refused if it already exists, so it cannot block a later window directory.
//
// Usage: node script/a6-collector/window-timing.mjs --frozen-plan <bundle> --bundle-sha256 <hex>
//   --seed <seed> --formal-config <json> --config <deployment json> --baselines <json>
//   --rpc-a-file <file> --rpc-b-file <file> --out-dir <new dir> [--cap-a N] [--cap-b N]
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { getAddress, keccak256 } from 'viem';
import { formalRuntime, DEFAULT_FACTORY } from './formal.mjs';
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
  outPath: resolve(outDir, 'timing.jsonl'), readOnly: true });
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
const EP_NONCE_ABI = [{ type: 'function', name: 'getNonce', stateMutability: 'view', inputs: [{ name: 'sender', type: 'address' }, { name: 'key', type: 'uint192' }], outputs: [{ type: 'uint256' }] }];
const ZERO_HASH = '0x' + '00'.repeat(32);

const slot = window.manifest.schedule.payload.slots[0], arms = [];
const t0 = performance.now();
for (const armName of slot.order) {
  const arm = ARM[armName], sender = getAddress(slot.senders[armName]), e = env(sender, window.adapters.get(sender).frozen);
  const phases = {};
  const phase = async (name, fn) => { const t = performance.now(); const value = await fn(); phases[name] = { seconds: +((performance.now() - t) / 1000).toFixed(3), ...mark() }; return value; };
  const pin = await phase('preGatePassport', async () => { const b = await runtime.refreshPin(); await readAB('passport', p => readPassport(p, b.number, e, pools.get(p))); return b; });
  // One gate iteration: a deadline already passed returns after the first pin and reads.
  await phase('slotGateIteration', () => waitForSlot({ runtime, arm, operator, sender, paymaster: SPA, start: 0n, deadline: pin.timestamp - 1n }));
  await phase('preSendReads', async () => {
    await readAB('getNonce', p => p.readContract({ address: EP, abi: EP_NONCE_ABI, functionName: 'getNonce', args: [sender, 0n] }));
    await readAB('epDeposit', p => p.readContract({ address: EP, abi: EP_DEPOSIT_ABI, functionName: 'balanceOf', args: [pmAddrOf(arm)] }));
    await runtime.refreshPin(); await runtime.refreshPin();
  });
  const bn = (await runtime.refreshPin()).number; mark();
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
  note: 'no signature, simulation or send; send, receipt and inclusion waits are not included' };
writeFileSync(resolve(outDir, 'timing.json'), JSON.stringify(result, null, 1) + '\n');
console.log(JSON.stringify(result, null, 1));

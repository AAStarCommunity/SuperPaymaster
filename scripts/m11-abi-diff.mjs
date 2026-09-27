#!/usr/bin/env node
// M-11 downstream change list: OLD (what is deployed today) vs NEW (5.5.0 candidate).
// Compares ABIs by FULL shape (functions keyed by selector, events by topic0, errors by selector),
// and checks that each OLD artifact is really the code on chain (immutable ranges masked).
//
// Usage:
//   node scripts/m11-abi-diff.mjs <oldOutDir> <newOutDir> <onchainJson> > m11-abi-diff.json
//     oldOutDir   forge `out/` built from the OLD source (e.g. `git archive origin/main`, forge build --skip test)
//     newOutDir   forge `out/` built from the NEW source (profile.default)
//     onchainJson output of scripts/m11-onchain-versions.mjs (needs RPC_URL for the code reads below)
// Env: RPC_URL (read-only eth_getCode at the block recorded in onchainJson).
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { createPublicClient, http, keccak256, toFunctionSelector, toEventSelector, toBytes } from 'viem';

const [oldOut, newOut, onchainPath] = process.argv.slice(2);
if (!oldOut || !newOut || !onchainPath) { console.error('usage: oldOut newOut onchainJson'); process.exit(2); }
const onchain = JSON.parse(readFileSync(onchainPath, 'utf8'));
const client = process.env.RPC_URL ? createPublicClient({ transport: http(process.env.RPC_URL, { retryCount: 3, timeout: 30000 }) }) : null;
const BLOCK = BigInt(onchain.block);

const art = (dir, file, name) => {
  const p = join(dir, `${file}.sol`, `${name ?? file}.json`);
  return existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : null;
};
const pinnedAbi = (p) => { const j = JSON.parse(readFileSync(p, 'utf8')); return Array.isArray(j) ? j : (j.abi ?? j); };

const canon = (p) => {
  if (p.type.startsWith('tuple')) return `(${(p.components || []).map(canon).join(',')})${p.type.slice(5)}`;
  return p.type;
};
const sig = (e) => `${e.name}(${(e.inputs || []).map(canon).join(',')})`;
function index(abi) {
  const fn = {}, ev = {}, er = {}, other = new Set();
  for (const e of abi) {
    if (e.type === 'function') fn[toFunctionSelector(sig(e))] = { sig: sig(e), shape: `${(e.outputs || []).map(canon).join(',')}|${e.stateMutability}` };
    else if (e.type === 'event') ev[toEventSelector(sig(e))] = { sig: sig(e), shape: `${(e.inputs || []).map((i) => (i.indexed ? 'i' : '-')).join('')}|anon=${!!e.anonymous}` };
    else if (e.type === 'error') er[toFunctionSelector(sig(e))] = { sig: sig(e) };
    else other.add(`${e.type}${e.stateMutability ? ':' + e.stateMutability : ''}`);
  }
  return { fn, ev, er, other: [...other].sort() };
}
function diffMaps(o, n, withShape) {
  const added = [], removed = [], shapeChanged = [];
  for (const k of Object.keys(n)) if (!o[k]) added.push(n[k].sig);
  for (const k of Object.keys(o)) if (!n[k]) removed.push(o[k].sig);
  if (withShape) for (const k of Object.keys(o)) if (n[k] && o[k].shape !== n[k].shape) shapeChanged.push({ sig: o[k].sig, selector: k, old: o[k].shape, new: n[k].shape });
  return { added: added.sort(), removed: removed.sort(), shapeChanged };
}
function union(...abis) {
  const seen = new Set(), out = [];
  for (const a of abis) for (const e of a) {
    const k = `${e.type}:${e.name ? sig(e) : e.type}`;
    if (!seen.has(k)) { seen.add(k); out.push(e); }
  }
  return out;
}
function diff(oldAbi, newAbi) {
  if (!oldAbi && !newAbi) return null;
  const o = index(oldAbi || []), n = index(newAbi || []);
  return {
    functions: diffMaps(o.fn, n.fn, true),
    events: diffMaps(o.ev, n.ev, true),
    errors: diffMaps(o.er, n.er, false),
    special: { old: o.other, new: n.other },
    counts: { oldFunctions: Object.keys(o.fn).length, newFunctions: Object.keys(n.fn).length },
  };
}
// Mask immutable ranges of the artifact in BOTH the artifact and the chain code, then compare.
function masked(hex, refs) {
  const b = Buffer.from(hex.replace(/^0x/, ''), 'hex');
  for (const ranges of Object.values(refs || {})) for (const r of ranges) b.fill(0, r.start, r.start + r.length);
  return b;
}
async function chainMatch(artifact, address) {
  if (!client || !artifact || !address) return { checked: false };
  const code = await client.getCode({ address, blockNumber: BLOCK });
  if (!code || code === '0x') return { checked: true, match: false, reason: 'no code' };
  const a = artifact.deployedBytecode.object, refs = artifact.deployedBytecode.immutableReferences;
  const aLen = (a.length - 2) / 2, cLen = (code.length - 2) / 2;
  if (aLen !== cLen) return { checked: true, match: false, artifactSize: aLen, chainSize: cLen, reason: 'size differs' };
  const A = masked(a, refs), C = masked(code, refs);
  return { checked: true, match: A.length === C.length && A.equals(C), artifactSize: A.length, chainSize: C.length };
}
const runtimeHash = (artifact) => artifact ? keccak256(artifact.deployedBytecode.object) : null;
const oc = (k) => onchain.contracts[k] || {};

// rows: [label, inRollout, oldAbi, newAbi, chainKey (impl-or-address), oldArtifact, note]
const O = (f, n) => art(oldOut, f, n), N = (f, n) => art(newOut, f, n);
const rows = [];
const add = async (r) => {
  const chainAddr = r.chainKey ? (oc(r.chainKey).erc1967Impl || oc(r.chainKey).address) : null;
  rows.push({
    contract: r.label, rollout: r.rollout,
    versionOnChain: r.chainKey ? oc(r.chainKey).version ?? null : null,
    oldSource: r.oldSrc, newSource: r.newSrc,
    oldArtifactMatchesChain: r.verify === false ? { checked: false, reason: r.verifyReason } : await chainMatch(r.oldArt, chainAddr),
    newRuntimeKeccak: r.newHash ?? null,
    abi: diff(r.oldAbi, r.newAbi),
    note: r.note || null,
  });
};

const spOld = O('SuperPaymaster'), spNew = N('SuperPaymaster'), spAdm = N('SuperPaymasterAdmin');
await add({ label: 'SuperPaymaster (proxy)', rollout: 'UUPS upgrade 5.4.2 -> 5.5.0 (runbook step 5)', chainKey: 'superPaymaster',
  oldSrc: 'SuperPaymaster-5.4.2', newSrc: 'SuperPaymaster-5.5.0 (core + SuperPaymasterAdmin via fallback)',
  oldArt: spOld, oldAbi: spOld?.abi, newAbi: union(spNew.abi, spAdm.abi), newHash: runtimeHash(spNew),
  note: 'NEW ABI = SuperPaymaster core UNION SuperPaymasterAdmin (EXTENSION deployed in the SP constructor, reached through fallback()). newRuntimeKeccak is of the artifact (immutables zero-filled).' });
const regOld = O('Registry'), regNew = N('Registry');
await add({ label: 'Registry (proxy)', rollout: 'UUPS upgrade 5.8.0 -> 5.9.0 (runbook step 5c)', chainKey: 'registry',
  oldSrc: 'Registry-5.8.0', newSrc: 'Registry-5.9.0', oldArt: regOld, oldAbi: regOld?.abi, newAbi: regNew?.abi, newHash: runtimeHash(regNew) });
const blsNew = N('BLSAggregator');
await add({ label: 'BLSAggregator', rollout: 'NOT redeployed by the 5.5.0 runbook (BLS three legs unchanged)', chainKey: 'blsAggregator',
  oldSrc: 'BLSAggregator-4.11.0 (pinned abis/BLSAggregator-4.11.0.deployed.json)', newSrc: 'BLSAggregator-4.12.0 (source only, not deployed)',
  verify: false, verifyReason: 'OLD ABI taken from the pinned deployed-ABI file (#423); OLD source on main is 4.12.0, not the deployed 4.11.0',
  oldAbi: pinnedAbi(join(newOut, '..', 'abis', 'BLSAggregator-4.11.0.deployed.json')), newAbi: blsNew?.abi,
  note: 'Only relevant if/when 4.12.0 is deployed; not part of 5.5.0.' });
const tOld = O('xPNTsToken'), tNew = N('xPNTsTokenV2'), tExt = N('xPNTsTokenV2Ext');
await add({ label: 'xPNTsToken v1 -> xPNTsTokenV2 (+Ext)', rollout: 'NEW template; communities issue new v2 tokens (runbook step 7a); old v1 clones stay', chainKey: null,
  oldSrc: 'XPNTs-3.5.0 (source on main); live official aPNTs/PNTs clones report XPNTs-3.4.0', newSrc: 'xPNTsTokenV2 core UNION xPNTsTokenV2Ext',
  verify: false, verifyReason: 'EIP-1167 clones; the live aPNTs/PNTs are 3.4.0 while main source is 3.5.0 -> OLD ABI is approximate for them',
  oldAbi: tOld?.abi, newAbi: union(tNew.abi, tExt.abi), newHash: runtimeHash(tNew) });
const fOld = O('xPNTsFactory'), fNew = N('xPNTsFactoryV2');
await add({ label: 'xPNTsFactory -> xPNTsFactoryV2', rollout: 'NEW contract (runbook step 4); SP.setXPNTsFactory switches to it (step 6)', chainKey: 'xPNTsFactory',
  oldSrc: 'xPNTsFactory-2.3.0-clone-optimized', newSrc: 'xPNTsFactoryV2', oldArt: fOld, oldAbi: fOld?.abi, newAbi: fNew?.abi, newHash: runtimeHash(fNew) });
for (const [label, file, note] of [
  ['APNTsCapped', 'APNTsCapped', 'NEW token replacing aPNTs as SP.APNTS_TOKEN (runbook step 1)'],
  ['SuperPaymasterLens', 'SuperPaymasterLens', 'NEW read-only helper (dryRunValidation) (runbook step 4)'],
  ['AOAProtocolRegistry', 'AOAProtocolRegistry', 'NEW whitelist registry (SP / spender / tier-source kinds) (runbook step 4)'],
  ['GlobalTierSource', 'GlobalTierSource', 'NEW default tier source -> Registry.getCreditLimit (runbook step 4)'],
]) { const a = N(file); await add({ label, rollout: note, chainKey: null, oldSrc: '(none)', newSrc: label, verify: false, verifyReason: 'new deployment', oldAbi: [], newAbi: a?.abi, newHash: runtimeHash(a) }); }
// Contracts NOT touched by the 5.5.0 rollout: report source drift OLD->NEW so nobody assumes a change on chain.
for (const [label, file, key] of [
  ['DVTValidator', 'DVTValidator', 'dvtValidator'], ['GTokenStaking', 'GTokenStaking', 'staking'], ['GToken', 'GToken', 'gToken'],
  ['MySBT', 'MySBT', 'sbt'], ['ReputationSystem', 'ReputationSystem', 'reputationSystem'], ['PaymasterFactory', 'PaymasterFactory', 'paymasterFactory'],
  ['Paymaster (V4)', 'Paymaster', 'paymasterV4Impl'], ['X402Facilitator', 'X402Facilitator', 'x402Facilitator'],
  ['LivenessRegistry', 'LivenessRegistry', 'livenessRegistry'], ['PolicyRegistry', 'PolicyRegistry', 'policyRegistry'],
]) { const o = O(file), n = N(file); await add({ label, rollout: 'not redeployed by the 5.5.0 runbook', chainKey: key, oldSrc: 'main', newSrc: 'feat HEAD', oldArt: o, oldAbi: o?.abi, newAbi: n?.abi, newHash: runtimeHash(n) }); }

console.log(JSON.stringify({ generatedAt: new Date().toISOString(), onchainBlock: onchain.block, chainId: onchain.chainId, rows }, null, 1));

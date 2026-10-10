#!/usr/bin/env node
// READ-ONLY: compare the runtime code DEPLOYED at given addresses with a release attestation
// (docs/release/v5.5.0-rc.2-attestation.json). The attestation's runtimeKeccak is keccak256 of the forge
// artifact's deployedBytecode, whose immutable slots are ZERO (see its `hashNote`), so it is not an
// on-chain codehash. This script therefore:
//   1. loads the artifact named by the attestation from <outDir> and checks keccak256(artifact runtime)
//      == attestation.runtimeKeccak (i.e. the local build reproduces the attested build);
//   2. reads eth_getCode(address, block), requires the same length, zeroes every immutableReferences
//      range of the artifact in the ON-CHAIN bytes, and requires keccak256(masked on-chain code) ==
//      attestation.runtimeKeccak, and masked bytes == artifact bytes;
//   3. reports the raw on-chain codehash (keccak256 of the unmasked code) and the immutable words.
// Clone mode (--clone Label=addr:impl): requires the code to be exactly the EIP-1167 minimal proxy
// pointing at <impl> (the v2 community tokens are clones of the attested xPNTsTokenV2 template).
// Expected-mismatch mode (--expect-mismatch Contract=addr): a NEGATIVE CONTROL — it passes only if the
// comparison FAILS (shows the comparator can say "no").
//
// Usage: node script/evidence/verify-attested-runtime.mjs --rpc <url> --attestation <json> --out-dir <out>
//          [--block <n>] [--target Contract=0xaddr ...] [--clone Label=0xaddr:0ximpl ...]
//          [--expect-mismatch Contract=0xaddr ...] [--report <out.json>]
// Exit: 0 = every target matched and every expected mismatch mismatched; 1 otherwise; 2 = usage.
import { readFileSync, existsSync, writeFileSync } from 'node:fs';
import { keccak256 } from 'viem';

const args = process.argv.slice(2);
const opt = { target: [], clone: [], 'expect-mismatch': [] };
for (let i = 0; i < args.length; i++) {
  const k = args[i].replace(/^--/, '');
  const v = args[i + 1];
  if (Array.isArray(opt[k])) opt[k].push(v); else opt[k] = v;
  i++;
}
if (!opt.rpc || !opt.attestation || !opt['out-dir']) {
  console.error('usage: --rpc <url> --attestation <json> --out-dir <out> [--block n] [--target C=addr] [--clone L=addr:impl] [--expect-mismatch C=addr] [--report f]');
  process.exit(2);
}
const att = JSON.parse(readFileSync(opt.attestation, 'utf8'));
let id = 0;
async function rpc(method, params) {
  const r = await fetch(opt.rpc, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(`${method}: ${JSON.stringify(j.error)}`);
  return j.result;
}
const block = opt.block ? '0x' + BigInt(opt.block).toString(16) : 'latest';
const blockNumber = BigInt(opt.block ? block : await rpc('eth_blockNumber', []));
const report = { attestation: opt.attestation, attestedCommit: att.attestedCommit, block: blockNumber.toString(), results: [] };
let bad = 0;

function artifactFor(name) {
  const e = att.contracts.find((c) => c.contract === name);
  if (!e) throw new Error(`contract ${name} not in attestation`);
  let p = `${opt['out-dir']}/${e.artifact}`;
  if (!existsSync(p)) p = p.replace(/\.json$/, '.default.json');
  const a = JSON.parse(readFileSync(p, 'utf8'));
  return { e, p, a };
}

async function compare(name, addr) {
  const { e, p, a } = artifactFor(name);
  const art = a.deployedBytecode.object.toLowerCase();
  const artKeccak = keccak256(art);
  const code = (await rpc('eth_getCode', [addr, block])).toLowerCase();
  const r = { contract: name, address: addr, artifact: p, attestedRuntimeKeccak: e.runtimeKeccak,
    artifactRuntimeKeccak: artKeccak, buildReproducesAttestation: artKeccak === e.runtimeKeccak.toLowerCase(),
    onchainBytes: (code.length - 2) / 2, artifactBytes: (art.length - 2) / 2, onchainCodehash: keccak256(code), immutables: [] };
  let hex = code.slice(2).split('');
  if (code.length === art.length) {
    for (const [astId, ranges] of Object.entries(a.deployedBytecode.immutableReferences || {})) {
      for (const { start, length } of ranges) {
        r.immutables.push({ astId, start, value: '0x' + code.slice(2 + start * 2, 2 + (start + length) * 2) });
        for (let i = start * 2; i < (start + length) * 2; i++) hex[i] = '0';
      }
    }
  }
  const masked = '0x' + hex.join('');
  r.maskedOnchainKeccak = keccak256(masked);
  r.match = code.length === art.length && masked === art && r.maskedOnchainKeccak === e.runtimeKeccak.toLowerCase();
  return r;
}

for (const t of opt.target) {
  const [name, addr] = t.split('=');
  const r = await compare(name, addr);
  if (!r.match || !r.buildReproducesAttestation) bad++;
  report.results.push({ mode: 'target', ...r });
  console.log(`${r.match && r.buildReproducesAttestation ? 'MATCH   ' : 'MISMATCH'} ${name} @ ${addr}: masked on-chain keccak ${r.maskedOnchainKeccak} vs attested ${e_short(r.attestedRuntimeKeccak)} (${r.onchainBytes} B, raw codehash ${r.onchainCodehash}) @block ${blockNumber}`);
}
for (const t of opt['expect-mismatch']) {
  const [name, addr] = t.split('=');
  const r = await compare(name, addr);
  if (r.match) bad++;
  report.results.push({ mode: 'expect-mismatch (negative control)', ...r });
  console.log(`${r.match ? 'NEGATIVE CONTROL FAILED (matched)' : 'negative ok (mismatch as expected)'} ${name} vs ${addr}: masked keccak ${r.maskedOnchainKeccak}, ${r.onchainBytes} B vs artifact ${r.artifactBytes} B @block ${blockNumber}`);
}
for (const t of opt.clone) {
  const [label, rest] = t.split('=');
  const [addr, impl] = rest.split(':');
  const code = (await rpc('eth_getCode', [addr, block])).toLowerCase();
  const expect = ('0x363d3d373d3d3d363d73' + impl.slice(2) + '5af43d82803e903d91602b57fd5bf3').toLowerCase();
  const ok = code === expect;
  if (!ok) bad++;
  report.results.push({ mode: 'clone', label, address: addr, impl, onchainCodehash: keccak256(code), expectedCodehash: keccak256(expect), match: ok });
  console.log(`${ok ? 'MATCH   ' : 'MISMATCH'} ${label} @ ${addr}: EIP-1167 clone of ${impl} (codehash ${keccak256(code)}) @block ${blockNumber}`);
}
function e_short(h) { return h; }
report.result = bad === 0 ? 'PASS' : 'FAIL';
if (opt.report) writeFileSync(opt.report, JSON.stringify(report, null, 2) + '\n');
console.log(`ATTESTED RUNTIME CHECK ${report.result} (${opt.target.length} targets, ${opt.clone.length} clones, ${opt['expect-mismatch'].length} negative controls) @block ${blockNumber}`);
process.exit(bad === 0 ? 0 : 1);

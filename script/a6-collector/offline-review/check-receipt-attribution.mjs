// Receipt attribution controls derived from recorded fixture runs. No RPC access.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { keccak256, toBytes } from 'viem';
import { localUserOpHash } from '../gauge-lib.mjs';
import { syntheticAnchors } from './synthetic-anchors.mjs';
import { freshEnd } from './current-fixture.mjs';
const root = process.env.A6_REVIEW_ARCHIVE ?? 'docs/design/aoa-balance-mode/data/a6-gauge-local';
const out = 'script/a6-collector/offline-review';
const load = name => freshEnd(syntheticAnchors(readFileSync(`${root}/${name}.jsonl`, 'utf8').trim().split('\n').map(JSON.parse)));
const sig = s => keccak256(toBytes(s));
const UOE = sig('UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)');
const SPONSORED = sig('TransactionSponsored(address,address,uint256,uint256)');
const LOCK = sig('LockCreated(address,bytes32,address,uint256,uint256)');
const word = n => BigInt(n).toString(16).padStart(64, '0');
const results = [];
function check(name, a, exit, proof) {
  const file = `${out}/fixtures/receipt-${name}.jsonl`;
  writeFileSync(file, a.map(JSON.stringify).join('\n') + '\n');
  const r = spawnSync(process.execPath, ['script/a6-collector/validate.mjs', file], { encoding: 'utf8' });
  assert.ifError(r.error);
  const report = JSON.parse(r.stdout);
  assert.equal(r.status, exit, `${name}: ${r.stdout}`);
  assert.equal(report.accepted, false, name);
  if (exit === 3) { assert.equal(report.consistent, true); assert.equal(report.matchedTriplets, 0); }
  if (proof) assert.match(report.errors.join('; '), proof, name);
  results.push([name, r.status, report.errors.join('; ')]);
}
// Shift later baseline readbacks and end passport coherently to isolate receipt
// accounting from the separate continuity/passport-balance checks.
function shiftBalance(a, amount) {
  for (const rpc of ['A', 'B']) a[1].readbacks.after[rpc].operatorBalance = String(BigInt(a[1].readbacks.after[rpc].operatorBalance) + amount);
  for (const row of a.slice(2, -1)) for (const side of ['before', 'after']) for (const rpc of ['A', 'B']) {
    const rb = row.readbacks[side][rpc];
    if ('operatorBalance' in rb) rb.operatorBalance = String(BigInt(rb.operatorBalance) + amount);
  }
  a.at(-1).passport.volatile.operatorBalance = String(BigInt(a.at(-1).passport.volatile.operatorBalance) + amount);
}
for (const [label, archive] of [['foreign', 'b-drop-op'], ['hash-mismatch', 'c-wrong-hash']]) {
  check(`${label}-honest`, load(archive), 3);
  for (const field of ['epDeposit', 'operatorBalance', 'totalSpent', 'totalTxSponsored', 'protocolRevenue', 'userXPNTs', 'totalSupply', 'lockedOf', 'debts', 'creditReservedOf', 'lockXLocked', 'inflightA0']) {
    const a = load(archive);
    if (field === 'operatorBalance') shiftBalance(a, 10n ** 18n);
    else for (const rpc of ['A', 'B']) a[1].readbacks.after[rpc][field] = String(BigInt(a[1].readbacks.after[rpc][field]) + 10n ** 18n);
    check(`${label}-unexplained-${field}`, a, 1, new RegExp(`receipt.unexplained.${field}`));
  }
  const inflight = load(archive);
  for (const rpc of ['A', 'B']) inflight[1].readbacks.after[rpc].inflightOperator = '0x' + '22'.repeat(20);
  check(`${label}-unexplained-inflightOperator`, inflight, 1, /receipt.unexplained.inflightOperator/);
  for (const mutation of ['missing-sponsor', 'bad-lock', 'wrong-emitter', 'unbound-uoe', 'reverted', 'no-uoe']) {
    const a = load(archive), r = a[1];
    if (mutation === 'missing-sponsor') r.logs = r.logs.filter(l => l.topics[0] !== SPONSORED);
    if (mutation === 'bad-lock') r.logs.find(l => l.topics[0] === LOCK).topics[3] = '0x' + '22'.repeat(32);
    if (mutation === 'wrong-emitter') r.logs.find(l => l.topics[0] === UOE).address = '0x' + '22'.repeat(20);
    if (mutation === 'unbound-uoe') r.logs.find(l => l.topics[0] === UOE).topics[1] = '0x' + '22'.repeat(32);
    if (mutation === 'no-uoe') { r.logs = []; r.verdict = 'NO_EVENT'; }
    if (mutation === 'reverted') { r.tx.status = 'reverted'; r.verdict = 'TX_FAILED'; }
    check(`${label}-${mutation}`, a, 1, /receipt\.|no_execution\./);
  }
}
// Two executed foreign ops: each event set is checked, then aggregate state is
// compared. A bad second operation must not hide behind a valid first operation.
function twoForeign() {
  const a = load('b-drop-op'), r = a[1], op = structuredClone(r.bundledOps[0]);
  const oldHash = r.bundledUserOpHashes[0];
  op.nonce = String(BigInt(op.nonce) + 1n);
  const h = localUserOpHash(op, r.entryPoint, r.chainId);
  r.bundledOps.push(op); r.bundledUserOpHashes.push(h);
  const extra = structuredClone(r.logs);
  for (const l of extra) {
    l.topics = l.topics.map(t => t.toLowerCase() === oldHash.toLowerCase() ? h : t);
    if (l.topics[0] === UOE) l.data = '0x' + word(op.nonce) + l.data.slice(66);
  }
  // EntryPoint validates every reservation before executing the operations.
  r.logs = [...r.logs.filter(l => l.topics[0] === LOCK), ...extra.filter(l => l.topics[0] === LOCK),
    ...r.logs.filter(l => l.topics[0] !== LOCK), ...extra.filter(l => l.topics[0] !== LOCK)];
  r.logs.forEach((l, i) => { l.logIndex = i; });
  const b = r.readbacks.before.A, after = r.readbacks.after.A;
  const balanceDelta = BigInt(after.operatorBalance) - BigInt(b.operatorBalance);
  shiftBalance(a, balanceDelta);
  for (const f of ['epDeposit', 'totalSpent', 'totalTxSponsored', 'protocolRevenue', 'userXPNTs', 'totalSupply']) {
    const value = String(BigInt(after[f]) * 2n - BigInt(b[f]));
    for (const rpc of ['A', 'B']) r.readbacks.after[rpc][f] = value;
  }
  return a;
}
const multiple = twoForeign();
check('two-foreign-honest', multiple, 3);
const tampered = structuredClone(multiple);
shiftBalance(tampered, 10n ** 18n);
check('two-foreign-unexplained', tampered, 1, /receipt.unexplained.operatorBalance/);
const badSecond = structuredClone(multiple);
badSecond[1].logs.filter(l => l.topics[0] === LOCK).at(-1).data = '0x' + word(1) + badSecond[1].logs.filter(l => l.topics[0] === LOCK).at(-1).data.slice(66);
check('two-foreign-second-lock', badSecond, 1, /admission.exchange_rate|C7/);
writeFileSync(`${out}/receipt-attribution-results.tsv`, 'control\texit\tproof\n' + results.map(r => r.join('\t')).join('\n') + '\n');
console.log(`PASS: ${results.length} receipt attribution controls; honest foreign/hash-mismatch rows stay non-countable, unexplained and unbacked deltas reject`);

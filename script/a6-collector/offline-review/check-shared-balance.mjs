import { syntheticSummary } from './synthetic-summary.mjs';
import { freshEnd } from './current-fixture.mjs';
// Offline regression: SP owns operatorBalance even on baseline readbacks.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { operatorBalanceContinuity } from '../gauge-lib.mjs';
const out = 'script/a6-collector/offline-review';
// The round-4 suite emits this explicitly synthetic conformant N=50 fixture.
const base = readFileSync(`${out}/fixtures/r4-n50.jsonl`, 'utf8').trim().split('\n').map(JSON.parse);
freshEnd(base);
let balance = base[0].passport.volatile.operatorBalance;
for (const row of base.slice(1, -1)) {
  for (const rpc of ['A', 'B']) {
    row.readbacks.before[rpc].operatorBalance ??= balance;
    if (row.arm !== 'SP') row.readbacks.after[rpc].operatorBalance ??= balance;
  }
  balance = row.readbacks.after.A.operatorBalance;
}
function collectorChecks(rows) {
  let previous = rows[0].passport.volatile.operatorBalance;
  const checks = [];
  for (const row of rows.slice(1, -1)) {
    checks.push(...operatorBalanceContinuity(row.arm, row.readbacks.before.A, row.readbacks.after.A, previous));
    previous = row.readbacks.after.A.operatorBalance;
  }
  return checks;
}
const results = [];
function control(name, rows, expected, reason) {
  syntheticSummary(rows);
  const file = `${out}/fixtures/shared-balance-${name}.jsonl`;
  writeFileSync(file, rows.map(JSON.stringify).join('\n') + '\n');
  const r = spawnSync(process.execPath, ['script/a6-collector/validate.mjs', file], { encoding: 'utf8', maxBuffer: 16*1024*1024 });
  assert.ifError(r.error);
  assert.equal(r.status, expected, r.stdout);
  assert.equal(collectorChecks(rows).every(c => c.ok), expected === 0, name);
  if (reason) assert.match(r.stdout, reason);
  results.push([name, expected === 0 ? 'pass' : 'reject', r.status]);
}
// This is the old collector's precise stale per-arm comparison at attemptIndex 4.
assert.equal(base[5].arm, 'VPM');
assert.notEqual(base[5].readbacks.before.A.operatorBalance, base[2].readbacks.after.A.operatorBalance);
assert.equal(base[5].readbacks.before.A.operatorBalance, base[4].readbacks.after.A.operatorBalance);
control('legitimate-n50', base, 0);
const jump = structuredClone(base);
// Shift every subsequent readback/passport together: per-op deltas still balance,
// and A/B still agree. No recorded transaction explains this boundary jump.
for (const row of jump.slice(5, -1)) for (const side of ['before','after']) for (const rpc of ['A','B']) {
  const rb = row.readbacks[side][rpc]; rb.operatorBalance = String(BigInt(rb.operatorBalance) + 1n);
}
jump.at(-1).passport.volatile.operatorBalance = String(BigInt(jump.at(-1).passport.volatile.operatorBalance) + 1n);
control('unexplained-jump', jump, 1, /balance continuity failed: operatorBalance/);
const baseline = structuredClone(base);
for (const rpc of ['A','B']) baseline[5].readbacks.after[rpc].operatorBalance = String(BigInt(baseline[5].readbacks.after[rpc].operatorBalance) + 1n);
control('baseline-mutation', baseline, 1, /baseline changed operatorBalance/);
writeFileSync(`${out}/shared-balance-results.tsv`, 'control\tcollector_check\tvalidator_exit\n' + results.map(r=>r.join('\t')).join('\n') + '\n');
console.log('PASS: shared-balance legitimate N=50; unexplained boundary jump and baseline mutation rejected by collector checks and independent validator');

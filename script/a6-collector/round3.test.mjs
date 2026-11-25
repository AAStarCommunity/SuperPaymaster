import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { feesWithinRule } from './fee-policy.mjs';
import { requirePostGas } from './formal.mjs';
const rule={baseFee:'101',factor:{numerator:3,denominator:2},ceiling:160};
const fees={maxFeePerGas:159n,maxPriorityFeePerGas:7n};
test('formal requires bundle and digest before reading any config or keystore',()=>{
 for(const flags of [[],['--frozen-plan','/missing'],['--bundle-sha256','a'.repeat(64)]]) {
  const r=spawnSync(process.execPath,['script/a6-collector/collector.mjs','--formal',...flags],{encoding:'utf8'});
  assert.equal(r.status,2);assert.match(r.stderr,/requires --frozen-plan and --bundle-sha256/);
 }
});
test('frozen collection requires slice arguments and accepts the 20-attempt budget with count 50',()=>{
 const run=flags=>spawnSync(process.execPath,['script/a6-collector/collector.mjs','--frozen-plan','unused.json',
  '--bundle-sha256','a'.repeat(64),'--count','50','--b-max','1',...flags],{encoding:'utf8'});
 for(const flags of [[],['--seed','s'],['--seed','s','--max-attempts','60'],['--seed','--max-attempts','20']]) {
  const r=run(flags);
  assert.equal(r.status,2);assert.match(r.stderr,/requires --seed, --count 50 and --max-attempts 20/);
 }
 for(const index of [[],['0'],['4'],['2.5'],['02']]) {
  const r=run(['--seed','s','--max-attempts','20','--window-index',...index]);
  assert.equal(r.status,2);assert.match(r.stderr,/requires --window-index in 1\.\.3/);
 }
 const flags=['--seed','s','--max-attempts','20','--window-index','2'];
 const accepted=run(flags);
 assert.equal(accepted.status,2);assert.match(accepted.stderr,/--out <run\.jsonl> is required/);
});
test('shared fee predicate rejects invalid and repository-exceeding ceilings',()=>{
 for(const ceiling of [undefined,0,-1,'nope','20000000001']) {
  assert.equal(feesWithinRule({maxFeePerGas:0n,maxPriorityFeePerGas:0n},{...rule,baseFee:0,ceiling}),false);
 }
 assert.equal(feesWithinRule({maxFeePerGas:20000000001n,maxPriorityFeePerGas:1n},{baseFee:10000000000n,factor:{numerator:2,denominator:1},ceiling:20000000001n}),false);
});
test('exact factor frozen derivation plus independent current inclusion cost',()=>{
 assert.equal(feesWithinRule(fees,rule),true);
 assert.equal(feesWithinRule({...fees,maxFeePerGas:160n},rule),false);
 assert.equal(feesWithinRule(fees,rule,152n),true);
 assert.equal(feesWithinRule(fees,rule,153n),false);
 for(const factor of [undefined,{numerator:0,denominator:1},{numerator:3,denominator:0}])assert.equal(feesWithinRule(fees,{...rule,factor}),false);
});
test('pinned postOp minimum must meet committed release expectation',()=>{
 const release=JSON.parse(readFileSync('docs/release/rq3-runtime-expectations.json'));
 for(const min of [0,-1,release.GP_MINPOST_MIN-1])assert.throws(()=>requirePostGas(9999999n,min),/pinned/);
 assert.throws(()=>requirePostGas(9999999n,undefined));
 requirePostGas(release.GP_MINPOST_MIN,release.GP_MINPOST_MIN);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import * as policy from './fee-policy.mjs';
test('chain fee derivation scales base, adds priority and caps at the supplied ceiling',()=>{
  assert.throws(()=>policy.deriveFees(null,7n,{factor:{numerator:3,denominator:2},ceiling:'160'}),/fee/);
  assert.deepEqual(policy.deriveFees(101n,7n,{factor:{numerator:3,denominator:2},ceiling:'160'}),
    {maxFeePerGas:159n,maxPriorityFeePerGas:7n});
  assert.equal(policy.deriveFees(101n,7n,{factor:{numerator:3,denominator:2},ceiling:'150'}).maxFeePerGas,150n);
  assert.throws(()=>policy.deriveFees(101n,7n,{factor:{numerator:3,denominator:2},ceiling:'107'}),/fee/);
});

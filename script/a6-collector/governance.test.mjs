import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import * as formal from './formal.mjs';
const address = n => '0x'+n.toString(16).padStart(40,'0');
const base = {creditPolicy:0,hasPendingPolicy:false,pendingPolicyEta:0n};
function client(values=base,token=address(3),configured=true) {
  return {async readContract(args) {
    assert.equal(args.blockNumber,123n);
    if(args.functionName==='operators') {
      assert.equal(args.address,address(1)); assert.deepEqual(args.args,[address(2)]);
      return [0n,configured,false,token,0,0,address(2),0n,0n];
    }
    assert.equal(args.address,token);
    if(values instanceof Error) throw values;
    return values[args.functionName];
  }};
}
test('SEC-09: records both pinned providers and blocks non-OFF or queued enable',async()=>{
  for(const bad of [{creditPolicy:1},{hasPendingPolicy:true},{pendingPolicyEta:1n}]) {
    for(const both of [false,true]) {
      const records=[];
      await assert.rejects(formal.checkExperimentCreditPolicy({clients:[client(both?{...base,...bad}:base),client({...base,...bad})],superPaymaster:address(1),operator:address(2),block:{number:123n,hash:'0xabc'},record:r=>records.push(r)}),/SEC-09/);
      assert.equal(records.at(-1).passed,false);
    }
  }
  let record;
  await formal.checkExperimentCreditPolicy({clients:[client(),client()],superPaymaster:address(1),operator:address(2),block:{number:123n,hash:'0xabc'},record:r=>record=r});
  assert.equal(record.passed,true); assert.equal(record.token,address(3));
  assert.deepEqual(record.A,base); assert.deepEqual(record.B,base);
  assert.equal(record.blockNumber,'123');
});
test('SEC-09: missing token, mismatched binding, malformed values and reverts fail closed',async()=>{
  for(const peer of [client(base,address(4)),client(base,address(0)),client(base,address(3),false),client(new Error('revert')),client({...base,hasPendingPolicy:0}),client({...base,pendingPolicyEta:undefined})]) {
    let record;
    await assert.rejects(formal.checkExperimentCreditPolicy({clients:[client(),peer],superPaymaster:address(1),operator:address(2),block:{number:123n,hash:'0xabc'},record:r=>record=r}),/SEC-09/);
    assert.equal(record.passed,false);
  }
});
test('SEC-09: collector installs final-send hook and attaches evidence to attempt row',()=>{
  const runtime=readFileSync(new URL('./formal.mjs',import.meta.url),'utf8');
  const collector=readFileSync(new URL('./collector.mjs',import.meta.url),'utf8');
  assert.match(runtime,/await beforeSend\?\.\(\{ clients: \[pubA, pubB\], block \}\)/);
  assert.match(collector,/beforeSend:.*checkExperimentCreditPolicy/);
  assert.match(collector,/governanceRow\.creditPolicyGuard = record/);
  assert.match(collector,/governanceRow = st\.row/);
});

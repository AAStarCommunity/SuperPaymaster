import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import * as setup from './setup.mjs';
import {parse} from '../a6-collector/frozen-plan.mjs';
import {feesWithinRule} from '../a6-collector/fee-policy.mjs';
test('integer-only rule ceiling and factor',()=>{
 const fees={maxFeePerGas:21,maxPriorityFeePerGas:1},rule={baseFee:10,ceiling:100,factor:{numerator:2,denominator:1}};
 assert.equal(feesWithinRule(fees,{...rule,ceiling:'100'},10),false);
 assert.equal(feesWithinRule(fees,{...rule,factor:{numerator:'2',denominator:1}},10),false);
});
test('setup lossless protocol 2^53+1',async()=>{
 const p={kind:'balance',target:'0x'+'11'.repeat(20),expected:0};
 const bundle=parse('{"steps":[{"id":"0/C20","tx":{},"initial":['+JSON.stringify(p)+'],"target":['+JSON.stringify({...p,expected:'BIG'}).replace('"BIG"','9007199254740993')+']}],"plans":{"a":{"planIndex":0,"steps":[]}}}');
 bundle.plans.a.steps=[{...bundle.steps[0],id:'C20'}];
 await assert.rejects(setup.gateWorker(bundle,0,'precheck',0,async()=> '0x20000000000001'),e=>{assert.match(e.message,/setup_state_STOP/);assert.match(e.message,/9007199254740993/);return true;});
 const values=await setup.gateWorker(bundle,0,'readback',0,async()=> '0x20000000000001');
 assert.equal(values[0].observed,9007199254740993n);
 await assert.rejects(setup.gateWorker(bundle,0,'readback',0,async()=> '0x20000000000000'));
});
test('SDK-only gate',()=>{
 assert.throws(()=>setup.requireSDKClearance({shared:{sdkLive:{status:'provisional'}}},{id:'0/C8.extra.0.mint'}));
 assert.doesNotThrow(()=>setup.requireSDKClearance({shared:{}},{id:'0/C8'}));
});
test('shared fee vectors',()=>{
 for(const v of JSON.parse(readFileSync(new URL('../fee-rule-vectors.json',import.meta.url))))assert.equal(feesWithinRule(v.fees,v.rule,v.current),v.valid,v.name);
});
test('Safe entry gate emits only initial transaction',async()=>{
 const step={id:'C1',to:'0x'+'11'.repeat(20),value:'0x0',data:'0x1234',operation:0};
 for(const status of ['initial','already-satisfied','STOP']){
  const emitted=[];
  const deps={authorize:async()=>({}),gate:async()=>{if(status==='STOP')throw Error('STOP');return {status};},emit:v=>emitted.push(v)};
  if(status==='STOP')await assert.rejects(setup.emitSafe(step,'a'.repeat(64),deps));
  else await setup.emitSafe(step,'a'.repeat(64),deps);
  assert.equal(emitted.length,status==='initial'?1:0);
  if(emitted.length)assert.deepEqual(emitted[0].transaction,{to:step.to,value:step.value,data:step.data,operation:0});
 }
});

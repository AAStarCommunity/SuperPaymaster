import test from 'node:test';
import assert from 'node:assert/strict';
import { executeStep } from './setup.mjs';
const tx={from:'0x'+'11'.repeat(20),to:'0x'+'22'.repeat(20),data:'0x',value:'0x0',nonce:'0x0',chainId:'0xa',gas:'0x10000',maxFeePerGas:'0x100',maxPriorityFeePerGas:'0x1'};
function fixture(){
 const events=[];
 const deps={precheck:async()=>events.push('precheck'), readback:async()=>events.push('readback'),
  signer:{address:tx.from}, send:async t=>{events.push('send');assert.equal(t.gas,65536n);return '0xhash';},
  receipt:async()=>({status:'success',blockHash:'0xblock',blockNumber:1n}),
  chain:async()=>10, pendingNonce:async()=>0};
 return {events,deps};
}
test('precheck, frozen send, both receipts, readback',async()=>{const {events,deps}=fixture();await executeStep({tx},deps);assert.deepEqual(events,['precheck','send','readback']);});
for(const [name,change] of [
 ['signer',d=>d.signer.address=tx.to],['chain',d=>d.chain=async()=>1],
 ['pending nonce',d=>d.pendingNonce=async()=>1],['precheck',d=>d.precheck=async()=>{throw Error('C_gas_tuple');}],
 ['receipt',d=>d.receipt=async i=>({status:'success',blockHash:i?'different':'0xblock',blockNumber:1n})]]) {
 test('reject '+name,async()=>{const {events,deps}=fixture();change(deps);await assert.rejects(executeStep({tx},deps));assert.equal(events.includes('readback'),false);if(name!=='receipt')assert.equal(events.includes('send'),false);});
}

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseAbi } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { formalRuntime } from './formal.mjs';
const w=await import('./window-schedule.mjs').catch(e=>{if(e.code==='ERR_MODULE_NOT_FOUND') return {};throw e;});
test('formal transport waits at submission and a deadline refusal never signs or sends',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'rq3-submit-'));
 const signer=privateKeyToAccount('0x'+'11'.repeat(32)), hash='0x'+'ab'.repeat(32);
 let signed=0,sent=0,time=110n,gateCalls=0,baseFee=1n;
 const config={chainId:10,bundlerGasLimit:100000n,accounts:Object.fromEntries(['owner','bundler','verifyingSigner'].map(r=>[r,{name:r,address:signer.address}])),fees:{maxFeePerGas:5n,maxPriorityFeePerGas:1n},feeRule:{baseFee:1,factor:{numerator:4,denominator:1},ceiling:5}};
 try {
  for(const endpoint of ['a','b']) writeFileSync(join(dir,endpoint),`https://${endpoint}.invalid/test`);
  const runtime=await formalRuntime({config,frozenPlan:true,rpcAFile:join(dir,'a'),rpcBFile:join(dir,'b'),outPath:join(dir,'run'),
   resolver:async h=>[{address:h.startsWith('a')?'8.8.8.8':'1.1.1.1'}],
   createSigner:()=>({...signer,signTransaction:async(...args)=>{signed++;assert.ok(time>=117n);return signer.signTransaction(...args);}}),
   fetchImpl:async(_,{body})=>{
    const r=JSON.parse(body);
    if(r.method==='eth_sendRawTransaction') sent++;
    const results={eth_chainId:'0xa',eth_blockNumber:'0x2a',eth_getTransactionCount:'0x4',eth_sendRawTransaction:hash,
      eth_getBlockByNumber:{number:'0x2a',hash,baseFeePerGas:'0x'+baseFee.toString(16),timestamp:'0x'+time.toString(16),transactions:[]}};
    assert.ok(r.method in results);
    return new Response(JSON.stringify({jsonrpc:'2.0',id:r.id,result:results[r.method]}));
   }});
  const client={getBlock:async()=>({number:42n,hash,timestamp:time}),readContract:async({functionName})=>functionName==='operators'?[0n,true,false,signer.address,0n,17n]:[100n,false]};
  const fake={refreshPin:client.getBlock,pubA:client,pubB:client};
  const args={address:signer.address,abi:parseAbi(['function go()']),functionName:'go'};
  const gate=deadline=>async()=>{
   gateCalls++;
   const result=await w.waitForSlot({runtime:fake,arm:'SP',operator:signer.address,sender:signer.address,paymaster:signer.address,start:110n,deadline,sleep:async()=>{time=117n;}});
   if(!result.allowed) throw Error(result.reason);
  };
  await assert.rejects(runtime.writeContract({...args,beforeSubmit:gate(116n)}),/sp_valid_after_exceeds_slot_deadline/);
  assert.equal(signed,0);assert.equal(sent,0);
  await assert.rejects(runtime.writeContract({...args,beforeSubmit:async()=>{await gate(120n)();baseFee=9n;}}),/basefee_above_cap/);
  assert.equal(signed,0);assert.equal(sent,0);baseFee=1n;
  await runtime.writeContract({...args,beforeSubmit:gate(120n)});
  assert.equal(gateCalls,3);assert.equal(signed,1);assert.equal(sent,1);assert.equal(time,117n);
 } finally {rmSync(dir,{recursive:true,force:true});}
});
test('stop rule through the formal transport: after the 50th complete triplet the next slot signs, sends and writes nothing',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'rq3-stop-'));
 const signer=privateKeyToAccount('0x'+'22'.repeat(32)), hash='0x'+'cd'.repeat(32);
 let signed=0,sent=0;const rows=[];
 const config={chainId:10,bundlerGasLimit:100000n,accounts:Object.fromEntries(['owner','bundler','verifyingSigner'].map(r=>[r,{name:r,address:signer.address}])),fees:{maxFeePerGas:5n,maxPriorityFeePerGas:1n},feeRule:{baseFee:1,factor:{numerator:4,denominator:1},ceiling:5}};
 try {
  for(const endpoint of ['a','b']) writeFileSync(join(dir,endpoint),`https://${endpoint}.invalid/test`);
  const runtime=await formalRuntime({config,frozenPlan:true,rpcAFile:join(dir,'a'),rpcBFile:join(dir,'b'),outPath:join(dir,'run'),
   resolver:async h=>[{address:h.startsWith('a')?'8.8.8.8':'1.1.1.1'}],
   createSigner:()=>({...signer,signTransaction:async(...args)=>{signed++;return signer.signTransaction(...args);}}),
   fetchImpl:async(_,{body})=>{
    const r=JSON.parse(body);
    if(r.method==='eth_sendRawTransaction') sent++;
    const results={eth_chainId:'0xa',eth_blockNumber:'0x2a',eth_getTransactionCount:'0x'+(4+sent).toString(16),eth_sendRawTransaction:hash,
      eth_getBlockByNumber:{number:'0x2a',hash,baseFeePerGas:'0x1',timestamp:'0x6e',transactions:[]}};
    assert.ok(r.method in results);
    return new Response(JSON.stringify({jsonrpc:'2.0',id:r.id,result:results[r.method]}));
   }});
  const accounts=[200,201,202].map(n=>'0x'+n.toString(16).padStart(40,'0'));
  const s=w.generateSchedule('public',accounts,10);
  const args={address:signer.address,abi:parseAbi(['function go()']),functionName:'go'};
  // Slots 0..2 incomplete: the 50th complete triplet lands in slot 52.
  const result=await w.runSlots(s,async(slot,arm)=>{
   await runtime.writeContract(args);
   const row={attemptIndex:rows.length,block_slot:slot.block_slot,arm,ok:slot.block_slot>=3};rows.push(row);return row;
  },rs=>rs.every(r=>r.ok));
  assert.equal(result.status,'COMPLETE');assert.equal(result.complete,50);
  assert.equal(signed,159);assert.equal(sent,159);assert.equal(rows.length,159);
  assert.ok(rows.every(r=>r.block_slot<=52));
  const rec=w.windowRecord(s,result);
  assert.deepEqual(rec.unusedSlots,[53,54,55,56,57,58,59]);assert.equal(rec.schedule_sha256,s.sha256);
 } finally {rmSync(dir,{recursive:true,force:true});}
});

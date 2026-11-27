import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import vm from 'node:vm';
import { parseAbi } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { formalRuntime } from './formal.mjs';
const w=await import('./window-schedule.mjs').catch(e=>{if(e.code==='ERR_MODULE_NOT_FOUND') return {};throw e;});
const source=readFileSync(new URL('./collector.mjs',import.meta.url),'utf8');
const accounts=[200,201,202].map(n=>'0x'+n.toString(16).padStart(40,'0'));
const schedule=w.generateSchedule('public',accounts,10);
const manifestFor=windowIndex=>({schedule,slice:{windowIndex,firstSlot:(windowIndex-1)*20,lastSlot:windowIndex*20-1,slots:20}});

test('collector gates windows 2 and 3 on their own start timestamps',async()=>{
 const gate=source.slice(source.indexOf('async function slotGate('));
 for(const windowIndex of [2,3]) {
  const manifest=manifestFor(windowIndex),windowStart=BigInt(10000*windowIndex);
  for(const offset of [0,1,19]) {
   const activeSlot=schedule.payload.slots[manifest.slice.firstSlot+offset];
   const row={}, start=windowStart+BigInt(120*offset),deadline=start+100n;
   const result=await vm.runInNewContext(`${gate}\nslotGate('TPM',row)`,{
    window:{manifest},windowStart,activeSlot,row,runtime:{},ctx:{account:{address:accounts[0]}},sender:accounts[1],SPA:accounts[2],
    waitForSlot:async args=>{
     assert.equal(args.start,start);
     assert.equal(args.deadline,deadline);
     return {allowed:true};
    },
   });
   assert.equal(row.slotChecks.length,1);
   assert.equal(row.slotChecks[0],result);
  }
 }
});

test('collector setup requires the remaining scheduled sender transfers plus one',async()=>{
 const setup=source.slice(source.indexOf('async function setup('),source.indexOf('  const salt = 9001n;'));
 const recipient='recipient';
 async function run(windowIndex,account,senderBalance,recipientBalance) {
  return vm.runInNewContext(`${setup}}\nsetup()`,{
   window:{manifest:manifestFor(windowIndex)},formal:true,formalInput:{task:{token:'task',recipient}},
   runtime:{},SPA:'SP',TOKEN_ABI:[],SP_ABI:[],ctx:{account:{address:'operator'}},cfg:{aPNTs:'aPNTs'},
   baselines:{tokenPaymaster:{token:'tpmToken'}},getAddress:x=>x,
   prepareSimpleAccount:async()=>({sender:account}),
   readAB:async(_label,read)=>({value:await read({readContract:async({functionName,args})=>
    functionName==='operators'?[0n,true,false,'spToken']:args[0]===account?senderBalance:recipientBalance})}),
  });
 }
 for(const [i,minimum] of [61n,41n,21n].entries()) for(const account of accounts) {
  await run(i+1,account,minimum,1n);
  await assert.rejects(run(i+1,account,minimum-1n,1n),/task requires warmed, funded token balances/);
 }
 await assert.rejects(run(3,accounts[0],21n,0n),/task requires warmed, funded token balances/);
});

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
test('formal transport signs and sends only the 20 slots of the selected slice',async()=>{
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
  const manifest=manifestFor(2);
  const args={address:signer.address,abi:parseAbi(['function go()']),functionName:'go'};
  const result=await w.runSlots(manifest,async(slot,arm)=>{
   await runtime.writeContract(args);
   const row={attemptIndex:rows.length,block_slot:slot.block_slot,arm,ok:slot.block_slot>=23};rows.push(row);return row;
  },rs=>rs.every(r=>r.ok));
  assert.equal(result.status,'EXHAUSTED');assert.equal(result.complete,17);
  assert.equal(signed,60);assert.equal(sent,60);
  assert.deepEqual(rows.map(r=>r.block_slot),Array.from({length:60},(_,i)=>20+Math.floor(i/3)));
  const rec=w.windowRecord(manifest,result);
  assert.deepEqual(rec.unusedSlots,[]);assert.equal(rec.schedule_sha256,schedule.sha256);
 } finally {rmSync(dir,{recursive:true,force:true});}
});

test('frozen transport checks first-use freshness on both sides of bundler signing',async t=>{
 const dir=mkdtempSync(join(tmpdir(),'rq3-first-sign-'));
 t.after(()=>rmSync(dir,{recursive:true,force:true}));
 const signer=privateKeyToAccount('0x'+'33'.repeat(32)), hash='0x'+'ab'.repeat(32);
 const config={chainId:10,bundlerGasLimit:100000n,accounts:Object.fromEntries(['owner','bundler','verifyingSigner'].map(r=>[r,{name:r,address:signer.address}])),
  fees:{maxFeePerGas:5n,maxPriorityFeePerGas:1n},feeRule:{baseFee:1,factor:{numerator:4,denominator:1},ceiling:5}};
 for(const endpoint of ['a','b']) writeFileSync(join(dir,endpoint),`https://${endpoint}.invalid/test`);
 let time=100n, expireWhileSigning=true, sends=0, signatures=0, pendingChecks=0;
 const runtime=await formalRuntime({config,frozenPlan:true,deferPendingNonce:true,rpcAFile:join(dir,'a'),rpcBFile:join(dir,'b'),outPath:join(dir,'run'),
  resolver:async h=>[{address:h.startsWith('a')?'8.8.8.8':'1.1.1.1'}],
  createSigner:()=>({...signer,signTransaction:async(...args)=>{
   signatures++;
   if(expireWhileSigning) time=101n;
   return signer.signTransaction(...args);
  }}),
  fetchImpl:async(_,{body})=>{
   const r=JSON.parse(body);
   if(r.method==='eth_sendRawTransaction') sends++;
   if(r.method==='eth_getTransactionCount') pendingChecks++;
   const results={eth_chainId:'0xa',eth_blockNumber:'0x2a',eth_getTransactionCount:'0x4',eth_sendRawTransaction:hash,
    eth_getBlockByNumber:{number:'0x2a',hash,baseFeePerGas:'0x1',timestamp:'0x'+time.toString(16),transactions:[]}};
   assert.ok(r.method in results);
   return new Response(JSON.stringify({jsonrpc:'2.0',id:r.id,result:results[r.method]}));
  }});
 const signed=[];
 const args={address:signer.address,abi:parseAbi(['function go()']),functionName:'go',
  beforeBroadcast:async candidate=>{
   assert.ok(pendingChecks>=4);
   if((await runtime.refreshPin()).timestamp>=101n) throw Error('FIRST_USE_PRICE_STALE');
   if(candidate) signed.push(candidate);
  }};
 assert.equal(pendingChecks,0);
 const {beforeBroadcast,...baseline}=args;
 await assert.rejects(runtime.writeContract(baseline),/PENDING_NONCE_UNINITIALIZED/);
 await runtime.preparePendingNonce();
 assert.equal(pendingChecks,2);
 time=101n;
 await assert.rejects(runtime.writeContract(args),/FIRST_USE_PRICE_STALE/);
 assert.equal(signatures,0);
 time=100n;
 await assert.rejects(runtime.writeContract(args),/FIRST_USE_PRICE_STALE/);
 assert.equal(signatures,1);
 assert.equal(sends,0);
 assert.deepEqual(signed,[]);
 expireWhileSigning=false;time=100n;
 await runtime.writeContract(args);
 assert.equal(sends,1);
 assert.equal(signed.length,1);
});

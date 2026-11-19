import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdirSync,mkdtempSync,writeFileSync,readFileSync,rmSync} from 'node:fs';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {encodeFunctionData,encodeAbiParameters,parseAbi,toEventSelector} from 'viem';
import {main as runMain,gateWorker} from './setup.mjs';
import {verifyReceipt,completionEntry,appendCompletion,safeTxHash,chainHead} from './completion.mjs';
const main=runMain;
const address='0x'+'11'.repeat(20),to='0x'+'22'.repeat(20),hash='0x'+'ab'.repeat(32),blockHash='0x'+'cd'.repeat(32);
const tx={from:address,to,value:'0x1',data:'0x1234',nonce:'0x0',chainId:'0xa',gas:'0x10000',maxFeePerGas:'0x2',maxPriorityFeePerGas:'0x1'};
const abi=parseAbi(['function execTransaction(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,bytes signatures) returns (bool success)']);
function fixture(safe){
 mkdirSync('cache/3arm/fix',{recursive:true});const dir=mkdtempSync(resolve('cache/3arm/fix/completion-'));
 const p={kind:'balance',target:to,expected:0};
 const step=safe?{id:'C1',...tx,operation:0}:{id:'0/C20',tx};
 step.initial=[p];step.target=[{...p,expected:1}];
 const bundle={chainId:10,shared:{experiment:"0x"+"77".repeat(20)},steps:safe?[]:[step],safeTransactions:safe?[step]:[],plans:{a:{planIndex:0,steps:safe?[]:[{...step,id:'C20'}]}}};
 const raw=Buffer.from(JSON.stringify(bundle)),digest=createHash('sha256').update(raw).digest('hex');
 writeFileSync(dir+'/bundle',raw);writeFileSync(dir+'/signers',JSON.stringify({[address]:{address}}));
 const receipt={status:'0x1',transactionHash:hash,blockNumber:'0x3',blockHash,logs:[{address,topics:[toEventSelector('ExecutionSuccess(bytes32,uint256)')],data:encodeAbiParameters([{type:'bytes32'},{type:'uint256'}],[safeTxHash(address,10,{to,value:1n,data:tx.data,operation:0,safeTxGas:0,baseGas:0,gasPrice:0,gasToken:'0x'+'00'.repeat(20),refundReceiver:'0x'+'00'.repeat(20),nonce:7}),0n])}]};
 receipt.logs[0].topics.push(receipt.logs[0].data.slice(0,66));receipt.logs[0].data='0x'+'00'.repeat(32);
 const transaction=safe?{to:address,blockHash,input:encodeFunctionData({abi,functionName:'execTransaction',args:[to,1n,tx.data,0,0n,0n,0n,'0x'+'00'.repeat(20),'0x'+'00'.repeat(20),'0x']})}:{...tx,input:tx.data,blockHash};
 let balance=0,sends=0,height=1n;
 const read=async(method,params)=>{
  if(method==='eth_call')return params[0].data===encodeFunctionData({abi:parseAbi(['function VERSION() view returns (string)']),functionName:'VERSION'})?encodeAbiParameters([{type:'string'}],['1.4.1']):encodeAbiParameters([{type:'uint256'}],[7n]);
  if(method==='eth_chainId')return '0xa';
  if(method==='eth_getBalance')return '0x'+balance;
  if(method==='eth_getTransactionCount')return sends?'0x1':'0x0';
  if(method==='eth_getTransactionReceipt')return receipt;
  if(method==='eth_getTransactionByHash')return transaction;
  if(method==='eth_getBlockByNumber')return {number:params[0],hash:blockHash,timestamp:'0x'+(100n+(BigInt(params[0])-1n)*12n).toString(16)};
  throw Error(method);
 };
 const archive={request:({method,params})=>read(method,params)};
 const block={number:1n,hash:blockHash,timestamp:100n};
 const pub={getBlock:async({blockNumber}={})=>({...block,number:blockNumber??block.number,timestamp:100n+((blockNumber??block.number)-1n)*12n}),waitForTransactionReceipt:async()=>({status:'success',blockNumber:1n,blockHash})};
 const emitted=[];
 const deps={regenerate:async()=>raw,emit:r=>emitted.push(r),emitStatus:r=>emitted.push(r),send:async()=>{sends++;balance=1;return hash;},runtime:async()=>({archives:[archive,archive],accounts:{bundler:{address}},pubA:pub,pubB:pub,refreshPin:async()=>({...block,number:balance?3n:height,timestamp:100n+((balance?3n:height)-1n)*12n})})};
 const args=[dir+'/bundle',digest,'0',dir+'/signers',dir+'/a',dir+'/b',dir+'/audit',dir+'/config',dir+'/inputs','--expect-head','0'.repeat(64)];
 return {dir,args,deps,step,receipt,transaction,read,emitted,balance:v=>balance=v,sends:()=>sends,advance:()=>height++,close:()=>rmSync(dir,{recursive:true,force:true})};
}
for(const safe of [false,true])test(`${safe?'Safe':'EOA'} receipt-recorded completion, unlogged target, failed receipt`,async()=>{
 const f=fixture(safe);try{
  // Avoid unrelated phase-C gates in this protocol fixture; tri-state still runs in Python.
  const b=JSON.parse(readFileSync(f.args[0]));
  if(!safe){
   f.deps.gate=async(bundle,index,action,time,read,options)=>gateWorker({...bundle,safeTransactions:[bundle.steps[index]]},0,action,time,read,{...options,safe:true});
  }
  f.balance(1);
  await assert.rejects(main(safe?['safe',...f.args]:[...f.args],f.deps),/setup_state_STOP/);
  assert.equal(f.sends(),0);assert.deepEqual(f.emitted,[]);
  f.balance(0);
  if(safe){
   await main(['safe',...f.args],f.deps);assert.equal(f.emitted.length,1);
   assert.deepEqual(f.emitted[0].transaction,{to,value:'0x1',data:'0x1234',operation:0});
   f.args[f.args.length-1]=f.emitted.at(-1).recordDigest;
   f.advance();await main(['safe-clear',...f.args],f.deps);
   f.args[f.args.length-1]=f.emitted.at(-1).recordDigest;
   f.balance(1);await main(['safe-record',...f.args,hash],f.deps);
  }else await main([...f.args],f.deps);
  const entry=completionEntry(f.args[0]+'.completions.jsonl',f.args[1],f.step.id);
  if(safe){assert.equal(entry.clearanceDigest,entry.clearance.recordDigest);assert.equal(entry.clearance.authorizationDigest,entry.authorizationDigest);}
  f.args[f.args.length-1]=entry.recordDigest;
  assert.equal(entry.txHash,hash);assert.equal(entry.timestamp,'124');assert.equal(entry.readback[0].observed,1);
  await main(safe?['safe',...f.args]:[...f.args],f.deps);
  if(safe)assert.equal(f.emitted.at(-1),'already-satisfied');else assert.equal(f.sends(),1);
  f.receipt.status='0x0';
  await assert.rejects(main(safe?['safe',...f.args]:[...f.args],f.deps),/receipt missing or failed/);
 }finally{f.close();}
});
for(const mutation of ['missing','reorg','wrong data','inner failure'])test('completion rejects '+mutation,async()=>{
 const f=fixture(true);try{
  let read=f.read;
  if(mutation==='missing')read=async(m,p)=>m==='eth_getTransactionReceipt'?null:f.read(m,p);
  if(mutation==='reorg')f.receipt.blockHash='0x'+'99'.repeat(32);
  if(mutation==='wrong data')f.transaction.input='0x12345678';
  if(mutation==='inner failure')f.receipt.logs=[];
  await assert.rejects(verifyReceipt(read,f.step,hash,true));
 }finally{f.close();}
});
test('append-only log refuses foreign digest, duplicates and truncated records',()=>{
 const f=fixture(true);try{
  const path=f.args[0]+'.completions.jsonl',entry={id:'C1',bundleSha256:f.args[1]};
  appendCompletion(path,entry);assert.throws(()=>appendCompletion(path,entry));
  assert.throws(()=>completionEntry(path,'0'.repeat(64),'C1'));
  writeFileSync(path,'{');assert.throws(()=>completionEntry(path,f.args[1],'C1'));
 }finally{f.close();}
});
test('H safe-record refuses execution without gate authorization',async()=>{
 const f=fixture(true);try{f.balance(1);await assert.rejects(main(['safe-record',...f.args,hash],f.deps),/transaction not authorized by the gate/);}finally{f.close();}
});
test('M1 rerun compares historical receipt-block readbacks',async()=>{
 const f=fixture(false);try{
  f.deps.gate=async(bundle,index,action,time,read,options)=>gateWorker({...bundle,safeTransactions:[bundle.steps[index]]},0,action,time,read,{...options,safe:true});
  await main([...f.args],f.deps);
  f.args[f.args.length-1]=completionEntry(f.args[0]+'.completions.jsonl',f.args[1],f.step.id).recordDigest;
  const gate=f.deps.gate;
  f.deps.gate=async(...args)=>args[2]==='readback'?[{observed:999}]:gate(...args);
  await assert.rejects(main([...f.args],f.deps),/completion readback mismatch/);
 }finally{f.close();}
});
for(const mode of ['safe','safe-clear','safe-record'])test(`${mode} STOPs when pinned provider timestamps disagree`,async()=>{
 const f=fixture(true);try{
  if(mode!=='safe'){await main(['safe',...f.args],f.deps);f.args[f.args.length-1]=f.emitted.at(-1).recordDigest;f.advance();if(mode==='safe-record')f.balance(1);}
  const runtime=f.deps.runtime;
  f.deps.runtime=async()=>{
   const r=await runtime();
   r.archives=[r.archives[0],{request:async request=>{
    const result=await r.archives[0].request(request);
    return request.method==='eth_getBlockByNumber'?{...result,timestamp:'0x65'}:result;
   }}];
   return r;
  };
  await assert.rejects(main([mode,...f.args,...(mode==='safe-record'?[hash]:[])],f.deps),/setup read disagreement/);
  assert.equal(f.emitted.length,mode==='safe'?0:1);
  assert.equal(completionEntry(f.args[0]+'.completions.jsonl',f.args[1],f.step.id),null);
 }finally{f.close();}
});
test('authorization timestamp comes from agreeing pinned header',async()=>{
 const f=fixture(true);try{
  const runtime=f.deps.runtime;
  f.deps.runtime=async()=>{const r=await runtime(),refresh=r.refreshPin;r.refreshPin=async()=>({...await refresh(),timestamp:999n});return r;};
  await main(['safe',...f.args],f.deps);
  assert.equal(f.emitted[0].blockTimestamp,'100');
  assert.equal(f.emitted[0].expiresAtTimestamp,'86500');
  assert.equal(f.emitted[0].blockNumber,'1');assert.equal(f.emitted[0].blockHash,blockHash);
 }finally{f.close();}
});

test('R8 safe-clear refuses explicitly saved stale digest',async()=>{
 const f=fixture(true);try{
  const saved=f.args.at(-1);
  await main(['safe',...f.args],f.deps);f.advance();
  assert.equal(f.args.at(-1),saved);
  await assert.rejects(main(['safe-clear',...f.args],f.deps),/chain head mismatch/);
 }finally{f.close();}
});
for(const mode of ['changed','disagreement'])test('R8 safe-record VERSION '+mode,async()=>{
 const f=fixture(true);try{
  await main(['safe',...f.args],f.deps);f.args[f.args.length-1]=f.emitted.at(-1).recordDigest;
  f.advance();await main(['safe-clear',...f.args],f.deps);f.args[f.args.length-1]=f.emitted.at(-1).recordDigest;
  f.balance(1);
  const runtime=f.deps.runtime,calls=[];
  const selector=encodeFunctionData({abi:parseAbi(['function VERSION() view returns (string)']),functionName:'VERSION'});
  f.deps.runtime=async()=>{const r=await runtime();r.archives=r.archives.map((a,i)=>({request:async q=>{
   if(q.method==='eth_call'&&q.params[0].data===selector){calls.push(q.params[1]);return encodeAbiParameters([{type:'string'}],[mode==='changed'||i===1?'1.3.0':'1.4.1']);}
   return a.request(q);
  }}));return r;};
  await assert.rejects(main(['safe-record',...f.args,hash],f.deps),mode==='changed'?/Safe VERSION/:/setup read disagreement/);
  assert.deepEqual(calls,['0x3','0x3']);
  assert.equal(completionEntry(f.args[0]+'.completions.jsonl',f.args[1],f.step.id),null);
 }finally{f.close();}
});

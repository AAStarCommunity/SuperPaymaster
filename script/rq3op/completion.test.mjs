import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdirSync,mkdtempSync,writeFileSync,readFileSync,rmSync} from 'node:fs';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {encodeFunctionData,parseAbi,toEventSelector} from 'viem';
import {main,gateWorker} from './setup.mjs';
import {verifyReceipt,completionEntry,appendCompletion} from './completion.mjs';
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
 const receipt={status:'0x1',transactionHash:hash,blockNumber:'0x1',blockHash,logs:[{address,topics:[toEventSelector('ExecutionSuccess(bytes32,uint256)')]}]};
 const transaction=safe?{to:address,blockHash,input:encodeFunctionData({abi,functionName:'execTransaction',args:[to,1n,tx.data,0,0n,0n,0n,address,address,'0x']})}:{...tx,input:tx.data,blockHash};
 let balance=0,sends=0;
 const read=async(method)=>{
  if(method==='eth_chainId')return '0xa';
  if(method==='eth_getBalance')return '0x'+balance;
  if(method==='eth_getTransactionCount')return sends?'0x1':'0x0';
  if(method==='eth_getTransactionReceipt')return receipt;
  if(method==='eth_getTransactionByHash')return transaction;
  if(method==='eth_getBlockByNumber')return {number:'0x1',hash:blockHash,timestamp:'0x64'};
  throw Error(method);
 };
 const archive={request:({method,params})=>read(method,params)};
 const block={number:1n,hash:blockHash,timestamp:100n};
 const pub={getBlock:async()=>block,waitForTransactionReceipt:async()=>({status:'success',blockNumber:1n,blockHash})};
 const emitted=[];
 const deps={regenerate:async()=>raw,emit:r=>emitted.push(r),emitStatus:r=>emitted.push(r),send:async()=>{sends++;balance=1;return hash;},runtime:async()=>({archives:[archive,archive],accounts:{bundler:{address}},pubA:pub,pubB:pub,refreshPin:async()=>block})};
 const args=[dir+'/bundle',digest,'0',dir+'/signers',dir+'/a',dir+'/b',dir+'/audit',dir+'/config',dir+'/inputs'];
 return {dir,args,deps,step,receipt,transaction,read,emitted,balance:v=>balance=v,sends:()=>sends,close:()=>rmSync(dir,{recursive:true,force:true})};
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
   f.balance(1);await main(['safe-record',...f.args,hash],f.deps);
  }else await main([...f.args],f.deps);
  const entry=completionEntry(f.args[0]+'.completions.jsonl',f.args[1],f.step.id);
  assert.equal(entry.txHash,hash);assert.equal(entry.timestamp,'100');assert.equal(entry.readback[0].observed,1);
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

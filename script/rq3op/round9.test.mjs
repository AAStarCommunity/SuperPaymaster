import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdirSync,mkdtempSync,writeFileSync,readFileSync,rmSync,symlinkSync} from 'node:fs';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {encodeFunctionData,encodeAbiParameters,parseAbi,toEventSelector} from 'viem';
import {main as runMain,gateWorker} from './setup.mjs';
import {verifyReceipt,completionEntry,appendCompletion,safeTxHash,chainHead,canonical,appendAuthorization,appendClearance} from './completion.mjs';
const main=runMain;
const address='0x'+'11'.repeat(20),to='0x'+'22'.repeat(20),hash='0x'+'ab'.repeat(32),blockHash='0x'+'cd'.repeat(32);
const tx={from:address,to,value:'0x1',data:'0x1234',nonce:'0x0',chainId:'0xa',gas:'0x10000',maxFeePerGas:'0x2',maxPriorityFeePerGas:'0x1'};
const abi=parseAbi(['function execTransaction(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,bytes signatures) returns (bool success)']);
function fixture(safe){
 mkdirSync('cache/3arm/fix',{recursive:true});const dir=mkdtempSync(resolve('cache/3arm/fix/completion-'));
 const p={kind:'balance',target:to,expected:0};
 const step=safe?{id:'C1',...tx,operation:0}:{id:'0/C20',tx};
 step.initial=[p];step.target=[{...p,expected:1}];
 const bundle={chainId:10,shared:{experiment:"0x"+"89".repeat(20)},steps:safe?[]:[step],safeTransactions:safe?[step]:[],plans:{a:{planIndex:0,steps:safe?[]:[{...step,id:'C20'}]}}};
 const raw=Buffer.from(JSON.stringify(bundle)),digest=createHash('sha256').update(raw).digest('hex');
 writeFileSync(dir+'/bundle',raw);writeFileSync(dir+'/signers',JSON.stringify({[address]:{address}}));
 const receipt={status:'0x1',transactionHash:hash,blockNumber:'0x3',blockHash,logs:[{address,topics:[toEventSelector('ExecutionSuccess(bytes32,uint256)')],data:encodeAbiParameters([{type:'bytes32'},{type:'uint256'}],[safeTxHash(address,10,{to,value:1n,data:tx.data,operation:0,safeTxGas:0,baseGas:0,gasPrice:0,gasToken:'0x'+'00'.repeat(20),refundReceiver:'0x'+'00'.repeat(20),nonce:7}),0n])}]};
 receipt.logs[0].topics.push(receipt.logs[0].data.slice(0,66));receipt.logs[0].data='0x'+'00'.repeat(32);
 const transaction=safe?{to:address,blockHash,input:encodeFunctionData({abi,functionName:'execTransaction',args:[to,1n,tx.data,0,0n,0n,0n,'0x'+'00'.repeat(20),'0x'+'00'.repeat(20),'0x']})}:{...tx,input:tx.data,blockHash};
 let balance=0,sends=0,height=1n;
 const times=new Map([[1n,100n],[2n,200n],[3n,210n],[4n,86501n]]);
 const read=async(method,params)=>{
  if(method==='eth_call')return params[0].data===encodeFunctionData({abi:parseAbi(['function VERSION() view returns (string)']),functionName:'VERSION'})?encodeAbiParameters([{type:'string'}],['1.4.1']):encodeAbiParameters([{type:'uint256'}],[7n]);
  if(method==='eth_chainId')return '0xa';
  if(method==='eth_getBalance')return '0x'+balance;
  if(method==='eth_getTransactionCount')return sends?'0x1':'0x0';
  if(method==='eth_getTransactionReceipt')return receipt;
  if(method==='eth_getTransactionByHash')return transaction;
  if(method==='eth_getBlockByNumber')return {number:params[0],hash:blockHash,timestamp:'0x'+times.get(BigInt(params[0])).toString(16)};
  throw Error(method);
 };
 const archive={request:({method,params})=>read(method,params)};
 const block={number:1n,hash:blockHash,timestamp:100n};
 const pub={getBlock:async({blockNumber}={})=>({...block,number:blockNumber??block.number,timestamp:times.get(blockNumber??block.number)}),waitForTransactionReceipt:async()=>({status:'success',blockNumber:1n,blockHash})};
 const emitted=[];
 const deps={regenerate:async()=>raw,emit:r=>emitted.push(r),emitStatus:r=>emitted.push(r),send:async()=>{sends++;balance=1;return hash;},runtime:async()=>({archives:[archive,archive],accounts:{bundler:{address}},pubA:pub,pubB:pub,refreshPin:async()=>({...block,number:height})})};
 const args=[dir+'/bundle',digest,'0',dir+'/signers',dir+'/a',dir+'/b',dir+'/audit',dir+'/config',dir+'/inputs','--expect-head','0'.repeat(64)];
 return {dir,args,deps,times,step,receipt,transaction,read,emitted,balance:v=>balance=v,sends:()=>sends,advance:()=>height++,close:()=>rmSync(dir,{recursive:true,force:true})};
}

const pathOf=f=>f.args[0]+'.completions.jsonl';
const update=f=>f.args[f.args.length-1]=chainHead(pathOf(f),f.args[1]);
async function authorize(f){await main(['safe',...f.args],f.deps);update(f);f.advance();}
async function clear(f){await authorize(f);await main(['safe-clear',...f.args],f.deps);update(f);f.advance();f.balance(1);}
function rewrite(f,mutate){
 const path=pathOf(f),entries=readFileSync(path,'utf8').trim().split('\n').map(JSON.parse);
 mutate(entries);let previous='0'.repeat(64);
 for(const e of entries){delete e.recordDigest;e.previousDigest=previous;if(e.type==='EXECUTION_CLEARANCE')e.authorizationDigest=previous;e.recordDigest=createHash('sha256').update(canonical(e)).digest('hex');previous=e.recordDigest;}
 writeFileSync(path,entries.map(canonical).join('\n')+'\n');writeFileSync(path+'.head',canonical({count:entries.length,digest:previous})+'\n');update(f);
}
test('F1 late recording succeeds, execution after authorization expiry refuses',async()=>{
 const f=fixture(true);try{await clear(f);f.advance();await main(['safe-record',...f.args,hash],f.deps);assert.equal(completionEntry(pathOf(f),f.args[1],'C1').timestamp,'210');}finally{f.close();}
 const g=fixture(true);try{await clear(g);g.times.set(3n,86501n);await assert.rejects(main(['safe-record',...g.args,hash],g.deps),/not authorized/);}finally{g.close();}
});
for(const kind of ['authorization timestamp','authorization expiry','clearance timestamp'])test('F2 rewritten '+kind+' refuses',async()=>{
 const f=fixture(true);try{await clear(f);
 rewrite(f,([a,c])=>{if(kind==='authorization timestamp'){a.blockTimestamp='110';a.expiresAtTimestamp='86510';}
 else if(kind==='authorization expiry')a.expiresAtTimestamp='90000';
 else {c.blockTimestamp='300';c.expiresAtTimestamp='900';}});
 await assert.rejects(main(['safe-record',...f.args,hash],f.deps),/anchor|expiry/);
 }finally{f.close();}
});
for(const mode of ['safe','safe-clear','safe-record'])test('F2 append rechecks head '+mode,async()=>{
 const f=fixture(true);try{
 if(mode==='safe-clear')await authorize(f);if(mode==='safe-record')await clear(f);
 let changed=false;f.deps.anchor=async()=>{if(!changed){changed=true;appendCompletion(pathOf(f),{bundleSha256:f.args[1],id:'other'});}};
 await assert.rejects(main([mode,...f.args,...(mode==='safe-record'?[hash]:[])],f.deps),/head mismatch/);
 assert.equal(readFileSync(pathOf(f),'utf8').trim().split('\n').map(JSON.parse).filter(e=>e.id==='C1').length,mode==='safe'?0:mode==='safe-clear'?1:2);
 }finally{f.close();}
});
test('F3 preplanted head temp symlink refuses without touching target or log',()=>{
 const f=fixture(true);try{const target=f.dir+'/target';writeFileSync(target,'untouched');symlinkSync(target,pathOf(f)+'.head.tmp');
 assert.throws(()=>appendCompletion(pathOf(f),{bundleSha256:f.args[1],id:'C1'}),/symlink/);
 assert.equal(readFileSync(target,'utf8'),'untouched');
 assert.equal(chainHead(pathOf(f),f.args[1]),'0'.repeat(64));
 }finally{f.close();}
});
test('F4 clearance with 59 seconds remaining refuses and reports expiry',async()=>{
 const f=fixture(true);try{await authorize(f);f.times.set(2n,86441n);await assert.rejects(main(['safe-clear',...f.args],f.deps),/DO NOT EXECUTE.*86500/);assert.equal(f.emitted.length,1);}finally{f.close();}
});
test('F5 flags before parsed safe-clear still say DO NOT EXECUTE',async()=>{
 const f=fixture(true);try{await assert.rejects(main(['--expect-head','f'.repeat(64),'safe-clear',...f.args.slice(0,-2)],f.deps),/DO NOT EXECUTE/);}finally{f.close();}
});
test('F5 persisted clearance with audit failure never instructs execution',async()=>{
 const f=fixture(true);try{await authorize(f);rmSync(f.dir+'/audit');mkdirSync(f.dir+'/audit');
 await assert.rejects(main(['safe-clear',...f.args],f.deps),/clearance was recorded.*audit write failed/);
 assert.equal(JSON.parse(readFileSync(pathOf(f),'utf8').trim().split('\n').at(-1)).type,'EXECUTION_CLEARANCE');
 assert.equal(f.emitted.some(e=>e.instruction?.includes('Execute immediately')),false);
 }finally{f.close();}
});
for(const suffix of ['', '.head'])for(const alias of [false,true])test('F6 audit collision '+suffix+' alias '+alias,async()=>{
 const f=fixture(true);try{await authorize(f);const target=pathOf(f)+suffix,before=readFileSync(target);
 if(alias)symlinkSync(target,f.dir+'/alias');
 f.args[6]=alias?f.dir+'/alias':target;
 await assert.rejects(main(['safe-clear',...f.args],f.deps),/audit.*completion/);
 assert.deepEqual(readFileSync(target),before);
 }finally{f.close();}
});

import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,readFileSync,writeFileSync,rmSync,existsSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {resolve} from 'node:path';
import {encodeFunctionData,encodeAbiParameters,parseAbi} from 'viem';
import {appendCompletion} from './completion.mjs';
import {main} from './setup.mjs';
const genesis='0'.repeat(64),safe='0x'+'11'.repeat(20),to='0x'+'22'.repeat(20),hash='0x'+'ab'.repeat(32);
function fixture(otherBalance=0n){
 const dir=mkdtempSync(resolve('cache/3arm/fix/round7-'));
 const p={kind:'balance',target:to,expected:0};
 const step={id:'C1',from:safe,to,data:'0x1234',value:'0x0',initial:[p],target:[{...p,expected:1}]};
 const bundle={chainId:10,shared:{experiment:safe},steps:[],safeTransactions:[step,{...step,id:'C2',initial:[{...p,target:safe}],target:[{...p,target:safe,expected:1}]}],plans:{}};
 const raw=Buffer.from(JSON.stringify(bundle)),digest=createHash('sha256').update(raw).digest('hex');
 writeFileSync(dir+'/bundle',raw);
 let height=1n,time=100n,balance=0n,nonce=7n;
 const archive={request:async({method,params})=>{
  if(method==='eth_chainId')return '0xa';
  if(method==='eth_getBlockByNumber')return {number:params[0],hash,timestamp:'0x'+time.toString(16)};
  if(method==='eth_getBalance')return '0x'+(params[0]===safe?otherBalance:balance).toString(16);
  if(method==='eth_call')return params[0].data===encodeFunctionData({abi:parseAbi(['function VERSION() view returns (string)']),functionName:'VERSION'})?encodeAbiParameters([{type:'string'}],['1.4.1']):encodeAbiParameters([{type:'uint256'}],[nonce]);
  throw Error(method);
 }};
 const heads=[],emitted=[];
 const deps={regenerate:async()=>raw,emit:x=>emitted.push(x),emitHead:x=>heads.push(x),runtime:async()=>({archives:[archive,archive],refreshPin:async()=>({number:height,hash})})};
 const path=dir+'/bundle.completions.jsonl';
 const args=[dir+'/bundle',digest,'0','-',dir+'/a',dir+'/b',dir+'/audit',dir+'/config',dir+'/inputs'];
 const head=()=>existsSync(path)?JSON.parse(readFileSync(path,'utf8').trim().split('\n').at(-1)).recordDigest:genesis;
 const run=(mode,flags=['--expect-head',head()])=>main([mode,...args,...flags],deps);
 return {path,dir,args,deps,heads,emitted,head,run,advance:()=>{height++;time+=12n;},state:v=>balance=v,nonce:v=>nonce=v,close:()=>rmSync(dir,{recursive:true,force:true})};
}
for(const change of ['state','nonce'])test('H safe-clear DO NOT EXECUTE on changed '+change,async()=>{
 const f=fixture();try{
  await f.run('safe');const before=readFileSync(f.path,'utf8');f.advance();
  if(change==='state')f.state(2n);else f.nonce(8n);
  await assert.rejects(f.run('safe-clear'),change==='state'?/DO NOT EXECUTE.*setup_state_STOP/:/DO NOT EXECUTE.*nonce changed/);
  assert.equal(readFileSync(f.path,'utf8'),before);
 }finally{f.close();}
});
test('H clearance binds authorization, expires in 600 seconds, and cannot duplicate',async()=>{
 const f=fixture();try{
  await f.run('safe');const authorization=f.head();f.advance();await f.run('safe-clear');
  const clearance=JSON.parse(readFileSync(f.path,'utf8').trim().split('\n').at(-1));
  assert.equal(clearance.type,'EXECUTION_CLEARANCE');assert.equal(clearance.authorizationDigest,authorization);
  assert.equal(clearance.expiresAtTimestamp,'712');
  f.advance();await assert.rejects(f.run('safe-clear'),/DO NOT EXECUTE.*clearance already outstanding/);
 }finally{f.close();}
});
for(const mode of ['missing','wrong','deleted','rollback'])test('B head anchor refuses '+mode,async()=>{
 const f=fixture();try{
  let flags=[];
  if(mode==='wrong')flags=['--expect-head','f'.repeat(64)];
  if(mode==='deleted'||mode==='rollback'){
   await f.run('safe');const old=readFileSync(f.path),oldHead=readFileSync(f.path+'.head');
   appendCompletion(f.path,{bundleSha256:f.args[1],id:'other'});flags=['--expect-head',f.head()];
   if(mode==='deleted'){rmSync(f.path);rmSync(f.path+'.head');}
   else{writeFileSync(f.path,old);writeFileSync(f.path+'.head',oldHead);}
  }
  await assert.rejects(f.run('safe',flags),/expect-head|head mismatch/);
 }finally{f.close();}
});
for(const state of [1n,2n])test('B first-run refuses target or partial '+state,async()=>{
 const f=fixture();try{
  f.state(state);await assert.rejects(f.run('safe',['--first-run']),/use --expect-head/);
  assert.equal(existsSync(f.path),false);
 }finally{f.close();}
});
test('B every invocation publishes current head and first-run cannot reset history',async()=>{
 const f=fixture();try{
  await f.run('safe',['--first-run']);assert.equal(f.heads.at(-1),f.head());
  await assert.rejects(f.run('safe',['--first-run']),/use --expect-head/);
  assert.equal(f.heads.at(-1),f.head());
 }finally{f.close();}
});

test('B first-run checks unselected steps at the same pin',async()=>{
 const f=fixture(2n);try{
  await assert.rejects(f.run('safe',['--first-run']),/use --expect-head/);
  assert.equal(existsSync(f.path),false);
 }finally{f.close();}
});

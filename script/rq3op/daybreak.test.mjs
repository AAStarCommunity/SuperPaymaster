import test from 'node:test';
import assert from 'node:assert/strict';
import * as setup from './setup.mjs';
import {createHash} from 'node:crypto';
import {mkdirSync,mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {resolve} from 'node:path';
const tx={from:'0x'+'11'.repeat(20),to:'0x'+'22'.repeat(20),value:'0x1',data:'0x',nonce:'0x0',chainId:'0xa',gas:'0x100',maxFeePerGas:'0x2',maxPriorityFeePerGas:'0x1'};
function fixture(){
 mkdirSync('cache/3arm/fix',{recursive:true});const dir=mkdtempSync(resolve('cache/3arm/fix/main-'));
 const step={id:'0/C20',tx:{...tx}};
 const bundle={chainId:10,steps:[step],plans:{account:{planIndex:0,steps:[{...step,id:'C20'}]}},shared:{experiment:tx.from}};
 const raw=Buffer.from(JSON.stringify(bundle));writeFileSync(dir+'/bundle',raw);writeFileSync(dir+'/signers',JSON.stringify({[tx.from]:{address:tx.from}}));
 const events=[];let nonce=0,chain=10;
 const hash='0x'+'ab'.repeat(32);
 const archive={request:async({method})=>{
 if(method==='eth_getTransactionReceipt')return {status:'0x1',transactionHash:hash,blockHash:'hash',blockNumber:'0x1'};
 if(method==='eth_getTransactionByHash')return {...tx,input:tx.data,blockHash:'hash'};
 if(method==='eth_getBlockByNumber')return {hash:'hash',timestamp:'0x1'};
 return method==='eth_chainId'?chain:nonce;}};
 const pub={waitForTransactionReceipt:async()=>({status:'success',blockHash:'hash',blockNumber:1n}),getBlock:async()=>({number:1n,hash:'hash',timestamp:1n})};
 const deps={regenerate:async()=>raw,runtime:async()=>({accounts:{bundler:{address:tx.from}},archives:[archive,archive],pubA:pub,pubB:pub,refreshPin:async()=>({number:1n,hash:'hash'})}),send:async()=>{events.push('send');return '0x'+'ab'.repeat(32);},gate:async()=>{},anchor:async()=>{},};
 const args=[dir+'/bundle',createHash('sha256').update(raw).digest('hex'),'0',dir+'/signers',dir+'/rpcA',dir+'/rpcB',dir+'/log',dir+'/config',dir+'/inputs','--expect-head','0'.repeat(64)];
 return {dir,bundle,raw,args,deps,events,nonce:v=>nonce=v,chain:v=>chain=v,close:()=>rmSync(dir,{recursive:true,force:true})};
}
for(const mode of ['valid','digest','tamper','signer','association','nonce','chain'])test('main offline '+mode,async()=>{
 const f=fixture();try{
  if(mode==='digest')f.args[1]='0'.repeat(64);
  if(mode==='tamper'){f.bundle.steps[0].tx.to='0x'+'33'.repeat(20);f.bundle.plans.account.steps[0].tx.to=f.bundle.steps[0].tx.to;const raw=JSON.stringify(f.bundle);writeFileSync(f.args[0],raw);f.args[1]=createHash('sha256').update(raw).digest('hex');}
  if(mode==='signer')writeFileSync(f.args[3],'{}');
  if(mode==='association'){f.bundle.plans.account.steps=[];const raw=Buffer.from(JSON.stringify(f.bundle));writeFileSync(f.args[0],raw);f.args[1]=createHash('sha256').update(raw).digest('hex');f.deps.regenerate=async()=>raw;}
  if(mode==='nonce')f.deps.gate=async()=>f.nonce(1);
  if(mode==='chain')f.deps.gate=async()=>f.chain(1);
  if(mode==='valid'){await setup.main(f.args,f.deps);assert.deepEqual(f.events,['send']);}
  else {await assert.rejects(()=>setup.main(f.args,f.deps));assert.deepEqual(f.events,[]);}
 }finally{f.close();}
});
test('exclusive lock refuses existing and stale locks',async()=>{const f=fixture();try{const release=setup.acquireLock(f.dir,tx.from);assert.throws(()=>setup.acquireLock(f.dir,tx.from));release();writeFileSync(f.dir+'/'+tx.from+'.lock','{"pid":999999999}');assert.throws(()=>setup.acquireLock(f.dir,tx.from));}finally{f.close();}});
for(const field of Object.keys(tx))test('main refuses post-precheck mutation of '+field,async()=>{
 const f=fixture();try{
  let live;
  f.deps.regenerate=async({bundle})=>{live=bundle;return f.raw;};
  f.deps.gate=async()=>{live.steps[0].tx[field]=field==='to'||field==='from'?'0x'+'99'.repeat(20):'0x9';};
  await assert.rejects(()=>setup.main(f.args,f.deps));assert.deepEqual(f.events,[]);
 }finally{f.close();}
});
test('main records already-satisfied reads with advanced nonce and no send',async()=>{
 const f=fixture();try{
  const reads=[{predicate:{kind:'balance',target:tx.to,expected:100},observed:100}];
  f.nonce(1);f.deps.gate=async()=>({status:'already-satisfied',reads});
  await setup.main(f.args,f.deps);
  const {readFileSync}=await import('node:fs');
  const entry=JSON.parse(readFileSync(f.dir+'/log','utf8'));
  assert.equal(entry.status,'already-satisfied');assert.deepEqual(entry.reads,reads);assert.deepEqual(f.events,[]);
 }finally{f.close();}
});
test('main records partial-state STOP observations without send',async()=>{
 const f=fixture();try{
  const record={gate:'setup_state_STOP',actual:{reads:[{observed:99}]}};
  f.deps.gate=async()=>{throw Object.assign(Error('state STOP'),{record});};
  await assert.rejects(setup.main(f.args,f.deps));
  const {readFileSync}=await import('node:fs');
  const entry=JSON.parse(readFileSync(f.dir+'/log','utf8'));
  assert.equal(entry.status,'stopped');assert.deepEqual(entry.error,record);assert.deepEqual(f.events,[]);
 }finally{f.close();}
});

test('main uses lossless parser for 2^53+1 plan amounts',async()=>{
 const f=fixture();try{
  f.bundle.shared.xAmount='LARGE';
  const raw=Buffer.from(JSON.stringify(f.bundle).replace('"LARGE"','9007199254740993'));
  writeFileSync(f.args[0],raw);f.args[1]=createHash('sha256').update(raw).digest('hex');
  f.deps.regenerate=async()=>raw;
  f.deps.gate=async bundle=>{assert.equal(bundle.shared.xAmount,9007199254740993n);throw Error('verified-exact-amount');};
  await assert.rejects(mainCall(),/verified-exact-amount/);
  function mainCall(){return setup.main(f.args,f.deps);}
  assert.deepEqual(f.events,[]);
 }finally{f.close();}
});

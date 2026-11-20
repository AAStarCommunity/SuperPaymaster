import test from 'node:test';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import {mkdtempSync,readFileSync,writeFileSync,rmSync} from 'node:fs';
import * as c from './completion.mjs';
import {hashTypedData,encodeFunctionData,encodeAbiParameters,parseAbi,toEventSelector} from 'viem';
const safe='0x'+'11'.repeat(20),to='0x'+'22'.repeat(20),zero='0x'+'00'.repeat(20),digest='a'.repeat(64);
const step={id:'C1',from:safe,to,value:'0x1',data:'0x1234'};
const pin={number:100n,hash:'0x'+'cd'.repeat(32)};
const transaction={to,value:'0x1',data:'0x1234',operation:0,safeTxGas:'0',baseGas:'0',gasPrice:'0',gasToken:zero,refundReceiver:zero,nonce:'7'};
function temp(fn){const dir=mkdtempSync('cache/3arm/fix/round6-');try{return fn(dir+'/log');}finally{rmSync(dir,{recursive:true,force:true});}}
test('M2 Safe hash matches independent typed-data vector',()=>{
 const types={SafeTx:[['to','address'],['value','uint256'],['data','bytes'],['operation','uint8'],['safeTxGas','uint256'],['baseGas','uint256'],['gasPrice','uint256'],['gasToken','address'],['refundReceiver','address'],['nonce','uint256']].map(([name,type])=>({name,type}))};
 const expected='0x69c955960061a19c54e8456a0a73f453cd4d7dc193b7d65cdfd2db59695aea65';
 assert.equal(hashTypedData({domain:{chainId:10,verifyingContract:safe},types,primaryType:'SafeTx',message:transaction}),expected);
 assert.equal(c.safeTxHash(safe,10,transaction),expected);
 for(const [address,chain,tx] of [[to,10,transaction],[safe,11,transaction],[safe,10,{...transaction,nonce:'8'}]])assert.notEqual(c.safeTxHash(address,chain,tx),expected);
});
for(const mutation of ['field','delete','reorder','truncate','remove-log'])test('M1 chain rejects '+mutation,()=>temp(path=>{
 for(let i=0;i<3;i++)c.appendCompletion(path,{id:String(i),bundleSha256:digest,readback:[{observed:i}]});
 const lines=readFileSync(path,'utf8').trim().split('\n');
 if(mutation==='field'){const e=JSON.parse(lines[0]);e.readback[0].observed=99;lines[0]=JSON.stringify(e);}
 if(mutation==='delete')lines.splice(1,1);
 if(mutation==='reorder')lines.reverse();
 if(mutation==='truncate')lines.pop();
 if(mutation==='remove-log')rmSync(path);else writeFileSync(path,lines.join('\n')+'\n');
 assert.throws(()=>c.completionEntry(path,digest,'2'));
}));
test('H gate authorization required, unique, expiring and consumed',()=>temp(path=>{
 assert.throws(()=>c.authorizationEntry(path,digest,step,10,{number:101n,timestamp:102n}),/transaction not authorized by the gate/);
 const a={type:'AUTHORIZATION',id:step.id,bundleSha256:digest,safe,chainId:'10',transaction,transactionSha256:'b'.repeat(64),safeTxHash:'0x'+'aa'.repeat(32),blockNumber:'100',blockHash:pin.hash,blockTimestamp:'100',expiresAtTimestamp:'86500'};
 c.appendAuthorization(path,a);
 assert.throws(()=>c.appendAuthorization(path,a));
 const found=c.authorizationEntry(path,digest,step,10,{number:101n,timestamp:102n});assert.equal(found.safe,safe);
 assert.throws(()=>c.authorizationEntry(path,digest,step,11,{number:101n,timestamp:102n}),/transaction not authorized/);
 assert.throws(()=>c.authorizationEntry(path,digest,step,10,{number:101n,timestamp:86501n}),/transaction not authorized/);
 c.appendCompletion(path,{id:step.id,bundleSha256:digest,authorizationDigest:found.recordDigest});
 assert.throws(()=>c.authorizationEntry(path,digest,step,10,{number:101n,timestamp:102n}),/transaction not authorized/);
}));

for(const version of ['1.2.0','1.3.0','1.4.0','1.5.0','unknown'])test('M2 refuses unsupported Safe VERSION '+version,async()=>{
 const read=async()=>encodeAbiParameters([{type:'string'}],[version]);
 await assert.rejects(c.safeSigning(step,10,pin,read),/unsupported Safe VERSION/);
});
test('M2 reads nonce and version at pinned block',async()=>{
 const calls=[];
 const read=async(method,params)=>{calls.push([method,params]);return calls.length===1?encodeAbiParameters([{type:'string'}],['1.4.1']):encodeAbiParameters([{type:'uint256'}],[7n]);};
 const signing=await c.safeSigning(step,10,pin,read);
 assert.equal(signing.safeTxHash,'0x69c955960061a19c54e8456a0a73f453cd4d7dc193b7d65cdfd2db59695aea65');
 assert.equal(calls.length,2);for(const [method,params] of calls){assert.equal(method,'eth_call');assert.equal(params[0].to,safe);assert.equal(params[1],'0x64');}
});
for(const mutation of ['nonce','event','gas','refund','expired-execution','before-gate','at-expiry','old-signing-fresh-clearance','two-hours-old-clearance','forged-expiry'])test('M2 execution timing and hash: '+mutation,async()=>{
 const hash='0x'+'ef'.repeat(32),safeHash='0x69c955960061a19c54e8456a0a73f453cd4d7dc193b7d65cdfd2db59695aea65';
 const auth={recordDigest:'a'.repeat(64),version:'1.4.1',safe,chainId:'10',blockNumber:'99',blockHash:pin.hash,blockTimestamp:'100',expiresAtTimestamp:'86500',transaction:{...transaction},safeTxHash:safeHash};
 const clearance={authorizationDigest:auth.recordDigest,blockNumber:'100',blockHash:pin.hash,blockTimestamp:'101',expiresAtTimestamp:'701'};
 const args=[to,1n,'0x1234',0,0n,0n,0n,zero,zero,'0x'];
 const receipt={transactionHash:hash,status:'0x1',blockNumber:'0x65',blockHash:pin.hash,logs:[{address:safe,topics:[toEventSelector('ExecutionSuccess(bytes32,uint256)'),safeHash],data:encodeAbiParameters([{type:'uint256'}],[0n])}]};
 if(mutation==='nonce')auth.transaction.nonce='8';
 if(mutation==='event')receipt.logs[0].topics[1]='0x'+'00'.repeat(32);
 if(mutation==='gas')args[4]=1n;
 if(mutation==='refund')args[8]=to;
 let timestamp=102n;
 if(mutation==='expired-execution'){receipt.blockNumber='0xa8c5';timestamp=86501n;}
 if(mutation==='at-expiry'){receipt.blockNumber='0xa924';timestamp=86500n;clearance.blockTimestamp='86400';clearance.expiresAtTimestamp='86500';}
 if(mutation==='old-signing-fresh-clearance'){receipt.blockNumber='0xe74';timestamp=7312n;clearance.blockTimestamp='7300';clearance.expiresAtTimestamp='7900';}
 if(mutation==='two-hours-old-clearance')timestamp=7300n;
 if(mutation==='forged-expiry')clearance.expiresAtTimestamp='86500';
 if(mutation==='before-gate')receipt.blockNumber='0x64';
 const abi=parseAbi(['function execTransaction(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,bytes signatures) returns (bool success)']);
 const read=async (method,params)=>({eth_call:encodeAbiParameters([{type:'string'}],['1.4.1']),eth_chainId:'0xa',eth_getTransactionReceipt:receipt,eth_getBlockByNumber:{hash:pin.hash,timestamp:'0x'+(method==='eth_getBlockByNumber' && BigInt(params[0])===99n?100n:method==='eth_getBlockByNumber' && BigInt(params[0])===100n?BigInt(clearance.blockTimestamp):timestamp).toString(16)},eth_getTransactionByHash:{to:safe,blockHash:pin.hash,input:encodeFunctionData({abi,functionName:'execTransaction',args})}}[method]);
 if(['at-expiry','old-signing-fresh-clearance'].includes(mutation))assert.equal((await c.verifyReceipt(read,step,hash,true,null,auth,clearance)).timestamp,String(timestamp));
 else await assert.rejects(c.verifyReceipt(read,step,hash,true,null,auth,clearance));
});
test('H emission persists authorization before releasing transaction',async()=>{
 const calls=[];
 const result=await c.emitSafe(step,digest,{gate:async()=>({status:'initial'}),authorize:async value=>{calls.push('persist');assert.equal(value.id,step.id);return {recordDigest:'durable'};},emit:value=>{calls.push('emit');assert.equal(value.recordDigest,'durable');}});
 assert.deepEqual(calls,['persist','emit']);assert.equal(result.recordDigest,'durable');
 await assert.rejects(c.emitSafe(step,digest,{gate:async()=>({status:'initial'}),authorize:async()=>{throw Error('disk failure');},emit:()=>assert.fail('must not release')}),/disk failure/);
});
test('M1 changing every field in every earlier record fails',()=>temp(path=>{
 for(let i=0;i<3;i++)c.appendCompletion(path,{id:String(i),bundleSha256:digest,readback:[{predicate:{expected:i},observed:i}],timestamp:'100'});
 const raw=readFileSync(path,'utf8'),entries=raw.trim().split('\n').map(JSON.parse);
 for(let i=0;i<2;i++)for(const field of Object.keys(entries[i])){
  const edited=structuredClone(entries);edited[i][field]='edited';
  writeFileSync(path,edited.map(JSON.stringify).join('\n')+'\n');
  assert.throws(()=>c.completionEntry(path,digest,'2'),`${i}:${field}`);
 }
 writeFileSync(path,raw);
 assert.equal(c.completionEntry(path,digest,'2').id,'2');
}));
test('M1 integer and string readback values have distinct chain content',()=>temp(path=>{
 c.appendCompletion(path,{id:'0',bundleSha256:digest,readback:[{observed:9007199254740993n}]});
 const entry=c.completionEntry(path,digest,'0');
 assert.equal(entry.readback[0].observed,9007199254740993n);
 const raw=readFileSync(path,'utf8');
 writeFileSync(path,raw.replace('9007199254740993','"9007199254740993"'));
 assert.throws(()=>c.completionEntry(path,digest,'0'));
}));
test('recording head and renewed authorization use inclusive timestamp expiry',()=>temp(path=>{
 const a={id:step.id,bundleSha256:digest,safe,chainId:'10',blockNumber:'100',blockHash:pin.hash,blockTimestamp:'100',expiresAtTimestamp:String(100n+c.AUTH_WINDOW_SECONDS)};
 c.appendAuthorization(path,a);
 for(const head of [{number:100n,timestamp:100n},{number:43301n,timestamp:86501n}])assert.throws(()=>c.authorizationEntry(path,digest,step,10,head),/transaction not authorized/);
 for(const head of [{number:3700n,timestamp:7300n},{number:43300n,timestamp:86500n}])assert.equal(c.authorizationEntry(path,digest,step,10,head).blockNumber,'100');
 assert.throws(()=>c.appendAuthorization(path,{...a,blockNumber:'43300',blockTimestamp:'86500'}),/authorization already outstanding/);
 c.appendAuthorization(path,{...a,blockNumber:'43301',blockTimestamp:'86501',expiresAtTimestamp:String(86501n+c.AUTH_WINDOW_SECONDS)});
 assert.equal(c.authorizationEntry(path,digest,step,10,{number:43302n,timestamp:86503n}).blockTimestamp,'86501');
}));
test('1.3.0 unindexed ExecutionSuccess layout is refused (no real receipt backs it)',()=>{
 const h='0x'+'ab'.repeat(32);
 const ev13={topics:[toEventSelector('ExecutionSuccess(bytes32,uint256)')],data:encodeAbiParameters([{type:'bytes32'},{type:'uint256'}],[h,0n])};
 assert.throws(()=>c.safeEventHash(ev13,'1.3.0'),/unsupported Safe VERSION or event layout/);
 assert.throws(()=>c.safeEventHash(ev13,'1.4.1'),/unsupported Safe VERSION or event layout/);
 assert.deepEqual([...c.SUPPORTED_SAFE_VERSIONS],['1.4.1']);
});

for(const change of ['longer','shorter','missing-timestamp'])test('R8 clearance selection refuses '+change,()=>temp(path=>{
 const auth=c.appendAuthorization(path,{id:step.id,bundleSha256:digest,blockNumber:'1',blockTimestamp:'100',expiresAtTimestamp:'86500'});
 const cleared=c.appendClearance(path,auth,{number:2n,hash:pin.hash,timestamp:112n});
 const {recordDigest,...content}=cleared;
 if(change==='missing-timestamp')delete content.blockTimestamp;
 else content.expiresAtTimestamp=change==='longer'?'86500':'711';
 const forged={...content,recordDigest:createHash('sha256').update(c.canonical(content)).digest('hex')};
 writeFileSync(path,c.canonical(auth)+'\n'+c.canonical(forged)+'\n');
 writeFileSync(path+'.head',c.canonical({count:2,digest:forged.recordDigest})+'\n');
 assert.throws(()=>c.clearanceEntry(path,digest,auth,{number:3n,timestamp:113n}),/execution not cleared/);
}));

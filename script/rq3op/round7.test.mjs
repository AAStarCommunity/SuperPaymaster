import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {decodeFunctionData,parseAbi,encodeAbiParameters} from 'viem';
import * as c from './completion.mjs';
const load=p=>JSON.parse(readFileSync(p));
const base='docs/release/a3a-testsafe-12025632/';
function live(){
 const receipt=load(base+'live/S5b/receipt.json'),tx=load(base+'live/S5b/decoded.json'),plan=load(base+'a3a-plan/plan.json');
 const abi=parseAbi(['function execTransaction(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,bytes signatures) returns (bool)']);
 const names=['to','value','data','operation','safeTxGas','baseGas','gasPrice','gasToken','refundReceiver'];
 const args=decodeFunctionData({abi,data:tx.input}).args;
 const transaction=Object.fromEntries(names.map((n,i)=>[n,args[i]]));transaction.nonce=plan.pin.safeNonce;
 const auth={recordDigest:'a'.repeat(64),safe:tx.to,chainId:plan.chainId,version:'1.4.1',transaction,safeTxHash:plan.safeTxHashes[0],blockNumber:'1',blockHash:receipt.blockHash,expiresAtTimestamp:'2000'};
 const clearance={authorizationDigest:auth.recordDigest,blockNumber:'2',blockHash:receipt.blockHash,expiresAtTimestamp:'1600'};
 const step={id:'C1',from:tx.to,...transaction};
 const read=async(m,p)=>({eth_chainId:tx.chainId,eth_getTransactionReceipt:receipt,eth_getTransactionByHash:{...tx,blockHash:receipt.blockHash},eth_getBlockByNumber:{hash:receipt.blockHash,timestamp:'0x3e8'}}[m]);
 return {receipt,auth,clearance,step,read};
}
test('A real Sepolia 1.4.1 S5b receipt records indexed hash',async()=>{
 const f=live();assert.equal(c.safeTxHash(f.step.from,f.auth.chainId,f.auth.transaction),f.auth.safeTxHash);
 await c.verifyReceipt(f.read,f.step,f.receipt.transactionHash,true,null,f.auth,f.clearance);
});
test('A unproven 1.4.0 refuses signing',async()=>{
 const f=live();let reads=0;
 await assert.rejects(c.safeSigning(f.step,10,{number:1n},async()=>++reads===1?encodeAbiParameters([{type:'string'}],['1.4.0']):encodeAbiParameters([{type:'uint256'}],[1n])),/unsupported Safe VERSION/);
});
for(const change of ['missing','expired','before-pin','at-pin','wrong-authorization','outlives-authorization'])test('H execution not cleared: '+change,async()=>{
 const f=live();
 if(change==='missing')f.clearance=null;
 if(change==='expired')f.clearance.expiresAtTimestamp='999';
 if(change==='before-pin')f.clearance.blockNumber=String(BigInt(f.receipt.blockNumber)+1n);
 if(change==='at-pin')f.clearance.blockNumber=String(BigInt(f.receipt.blockNumber));
 if(change==='wrong-authorization')f.clearance.authorizationDigest='b'.repeat(64);
 if(change==='outlives-authorization')f.clearance.expiresAtTimestamp='2001';
 await assert.rejects(c.verifyReceipt(f.read,f.step,f.receipt.transactionHash,true,null,f.auth,f.clearance),/execution not cleared/);
});

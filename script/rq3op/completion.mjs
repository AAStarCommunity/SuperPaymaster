import {readFileSync,openSync,writeSync,fsyncSync,closeSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {decodeFunctionData,parseAbi,toEventSelector} from 'viem';
import {parse} from '../a6-collector/frozen-plan.mjs';
export const json = value=>JSON.stringify(value,(_,v)=>typeof v==='bigint'?v.toString():v);
const equal=(a,b)=>json(a)===json(b);
const same=(a,b)=>String(a).toLowerCase()===String(b).toLowerCase();
export function completionEntry(path,digest,id) {
 let raw;
 try {raw=readFileSync(path,'utf8');} catch(e){if(e.code==='ENOENT')return null;throw e;}
 if(raw && !raw.endsWith('\n'))throw Error('incomplete completion log');
 const entries=raw.trim()?raw.trim().split('\n').map(parse):[];
 if(entries.some(e=>e.bundleSha256!==digest))throw Error('completion digest mismatch');
 const matches=entries.filter(e=>e.id===id);
 if(matches.length>1)throw Error('duplicate completion entry');
 return matches[0]??null;
}
export function appendCompletion(path,entry) {
 if(completionEntry(path,entry.bundleSha256,entry.id))throw Error('completion already recorded');
 const fd=openSync(path,'a',0o600);
 try {writeSync(fd,json(entry)+'\n');fsyncSync(fd);} finally{closeSync(fd);}
}
export function safeTransaction(step) {
 if(step.operation!==undefined && step.operation!==0)throw Error('Safe operation must be CALL');
 return {to:step.to,value:step.value,data:step.data,operation:0};
}
export async function emitSafe(step,digest,{gate,emit}) {
 const state=await gate();
 if(state?.status==='already-satisfied')return state;
 if(state?.status!=='initial')throw Error('Safe gate STOP');
 const transaction=safeTransaction(step);
 const transactionSha256=createHash('sha256').update(json(transaction)).digest('hex');
 const result={bundleSha256:digest,id:step.id,transaction,transactionSha256};
 emit(result);return result;
}
const safeABI=parseAbi(['function execTransaction(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,bytes signatures) returns (bool success)']);
export async function verifyReceipt(read,step,hash,safe=false,record=null) {
 if(!/^0x[0-9a-fA-F]{64}$/.test(hash))throw Error('completion transaction hash');
 const receipt=await read('eth_getTransactionReceipt',[hash]);
 if(!receipt || BigInt(receipt.status)!==1n || !same(receipt.transactionHash,hash))throw Error('completion receipt missing or failed');
 if(record && (!same(receipt.blockHash,record.blockHash)||BigInt(receipt.blockNumber)!==BigInt(record.blockNumber)||record.receiptStatus!=='success'))throw Error('completion receipt changed');
 const block=await read('eth_getBlockByNumber',[receipt.blockNumber,false]);
 if(!same(block.hash,receipt.blockHash))throw Error('completion receipt reorg');
 const tx=await read('eth_getTransactionByHash',[hash]);
 if(!tx || !same(tx.blockHash,receipt.blockHash))throw Error('completion transaction missing');
 if(safe) {
  if(!same(tx.to,step.from))throw Error('wrong Safe');
  const decoded=decodeFunctionData({abi:safeABI,data:tx.input});
  const [to,value,data,operation]=decoded.args;
  const planned=safeTransaction(step);
  if(!same(to,planned.to)||value!==BigInt(planned.value)||!same(data,planned.data)||operation!==planned.operation)throw Error('Safe transaction mismatch');
  const successes=receipt.logs.filter(l=>same(l.address,step.from)&&same(l.topics[0],toEventSelector('ExecutionSuccess(bytes32,uint256)')));
  if(successes.length!==1)throw Error('Safe inner execution not successful');
 } else {
  const planned=step.tx;
  for(const k of ['from','to'])if(!same(tx[k],planned[k]))throw Error('completion transaction identity mismatch');
  if(!same(tx.input,planned.data))throw Error('completion calldata mismatch');
  for(const k of ['value','nonce','gas','maxFeePerGas','maxPriorityFeePerGas','chainId'])if(BigInt(tx[k])!==BigInt(planned[k]))throw Error('completion transaction field mismatch');
 }
 const timestamp=BigInt(block.timestamp).toString();
 if(record && String(record.timestamp)!==timestamp)throw Error('completion timestamp mismatch');
 return {txHash:hash,blockNumber:BigInt(receipt.blockNumber).toString(),blockHash:receipt.blockHash,receiptStatus:'success',timestamp};
}

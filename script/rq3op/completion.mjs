import {readFileSync,openSync,writeFileSync,fsyncSync,closeSync,renameSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {dirname} from 'node:path';
import {decodeFunctionData,parseAbi,toEventSelector,encodeFunctionData,decodeFunctionResult,encodeAbiParameters,keccak256,stringToHex,concat} from 'viem';
import {parse} from '../a6-collector/frozen-plan.mjs';
// One day allows human multi-owner signing; gate state and the hash-bound Safe nonce bound staleness.
export const AUTH_WINDOW_SECONDS = 86400n;
export const json = value=>JSON.stringify(value,(_,v)=>typeof v==='bigint'?v.toString():v);
const same=(a,b)=>String(a).toLowerCase()===String(b).toLowerCase();
export function canonical(value) {
 if(typeof value==='bigint')return value.toString();
 if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';
 if(value && typeof value==='object')return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')+'}';
 return JSON.stringify(value);
}
const sha=value=>createHash('sha256').update(canonical(value)).digest('hex');
const genesis='0'.repeat(64);
function optional(path){try{return readFileSync(path,'utf8');}catch(e){if(e.code==='ENOENT')return null;throw e;}}
function records(path,digest) {
 const raw=optional(path),head=optional(path+'.head');
 if(raw===null && head===null)return [];
 if(raw===null || head===null || !raw.endsWith('\n'))throw Error('incomplete completion log');
 const entries=raw.trim()?raw.trim().split('\n').map(parse):[];
 let previous=genesis;
 for(const entry of entries){
  const {recordDigest,...content}=entry;
  if(content.previousDigest!==previous || sha(content)!==recordDigest)throw Error('completion chain mismatch');
  if(entry.bundleSha256!==digest)throw Error('completion digest mismatch');
  previous=recordDigest;
 }
 if(head!==canonical({count:entries.length,digest:previous})+'\n')throw Error('completion tail mismatch');
 return entries;
}
export function completionEntry(path,digest,id) {
 const matches=records(path,digest).filter(e=>e.type==='COMPLETION' && e.id===id);
 if(matches.length>1)throw Error('duplicate completion entry');
 return matches[0]??null;
}
function durable(path,data,mode){const fd=openSync(path,mode,0o600);try{writeFileSync(fd,data);fsyncSync(fd);}finally{closeSync(fd);}}
function append(path,entry){
 const entries=records(path,entry.bundleSha256);
 const content={...entry,previousDigest:entries.at(-1)?.recordDigest??genesis};
 const record={...content,recordDigest:sha(content)};
 durable(path,canonical(record)+'\n','a');
 durable(path+'.head.tmp',canonical({count:entries.length+1,digest:record.recordDigest})+'\n','w');
 renameSync(path+'.head.tmp',path+'.head');
 const directory=openSync(dirname(path),'r');try{fsyncSync(directory);}finally{closeSync(directory);}
 return record;
}
export function appendCompletion(path,entry) {
 if(completionEntry(path,entry.bundleSha256,entry.id))throw Error('completion already recorded');
 return append(path,{...entry,type:'COMPLETION'});
}
export function appendAuthorization(path,entry){
 const entries=records(path,entry.bundleSha256);
 if(entries.some(e=>e.id===entry.id && (e.type==='COMPLETION' || (e.type==='AUTHORIZATION' && BigInt(e.expiresAtTimestamp)>=BigInt(entry.blockTimestamp)))))throw Error('authorization already outstanding or completed');
 return append(path,{...entry,type:'AUTHORIZATION'});
}
export function authorizationEntry(path,digest,step,chainId,head){
 const entries=records(path,digest);
 const matches=entries.filter(e=>e.type==='AUTHORIZATION' && e.id===step.id && same(e.safe,step.from) && BigInt(e.chainId)===BigInt(chainId) && BigInt(e.blockNumber)<BigInt(head.number) && BigInt(head.timestamp)<=BigInt(e.expiresAtTimestamp) && !entries.some(c=>c.type==='COMPLETION' && c.authorizationDigest===e.recordDigest));
 if(matches.length!==1)throw Error('transaction not authorized by the gate');
 return matches[0];
}
const zero='0x'+'00'.repeat(20);
const fields=[['to','address'],['value','uint256'],['data','bytes'],['operation','uint8'],['safeTxGas','uint256'],['baseGas','uint256'],['gasPrice','uint256'],['gasToken','address'],['refundReceiver','address'],['nonce','uint256']];
export function safeTxHash(safe,chainId,transaction){
 const domain=keccak256(encodeAbiParameters([{type:'bytes32'},{type:'uint256'},{type:'address'}],[keccak256(stringToHex('EIP712Domain(uint256 chainId,address verifyingContract)')),BigInt(chainId),safe]));
 const typeHash=keccak256(stringToHex('SafeTx('+fields.map(([name,type])=>type+' '+name).join(',')+')'));
 const struct=keccak256(encodeAbiParameters([{type:'bytes32'},...fields.map(([,type])=>({type:type==='bytes'?'bytes32':type}))],[typeHash,...fields.map(([name,type])=>type==='bytes'?keccak256(transaction[name]):type.startsWith('uint')?BigInt(transaction[name]):transaction[name])]));
 return keccak256(concat(['0x1901',domain,struct]));
}
const getters=parseAbi(['function nonce() view returns (uint256)','function VERSION() view returns (string)']);
export async function safeSigning(step,chainId,pin,read){
 const get=async functionName=>decodeFunctionResult({abi:getters,functionName,data:await read('eth_call',[{to:step.from,data:encodeFunctionData({abi:getters,functionName})},'0x'+BigInt(pin.number).toString(16)])});
 const version=await get('VERSION');
 if(!['1.3.0','1.4.0','1.4.1'].includes(version))throw Error('unsupported Safe VERSION');
 const transaction={...safeTransaction(step),...Object.fromEntries(['safeTxGas','baseGas','gasPrice'].map(k=>[k,String(step[k]??0)])),gasToken:step.gasToken??zero,refundReceiver:step.refundReceiver??zero,nonce:String(await get('nonce'))};
 return {safe:step.from,chainId:String(chainId),version,transaction,transactionSha256:sha({safe:step.from,chainId:String(chainId),transaction}),safeTxHash:safeTxHash(step.from,chainId,transaction)};
}
export function safeTransaction(step) {
 if(step.operation!==undefined && step.operation!==0)throw Error('Safe operation must be CALL');
 return {to:step.to,value:step.value,data:step.data,operation:0};
}
export async function emitSafe(step,digest,{gate,authorize,emit}) {
 const state=await gate();
 if(state?.status==='already-satisfied')return state;
 if(state?.status!=='initial')throw Error('Safe gate STOP');
 const transaction=safeTransaction(step);
 const result={bundleSha256:digest,id:step.id,transaction};
 const authorization=await authorize(result);
 const output={...result,...authorization,signingTransaction:authorization.transaction,transaction};
 emit(output);return output;
}
const safeABI=parseAbi(['function execTransaction(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,bytes signatures) returns (bool success)']);
export async function verifyReceipt(read,step,hash,safe=false,record=null,authorization=null) {
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
  const auth=authorization??record?.authorization;
  if(!auth)throw Error('transaction not authorized by the gate');
  if(BigInt(receipt.blockNumber)<=BigInt(auth.blockNumber) || BigInt(block.timestamp)>BigInt(auth.expiresAtTimestamp))throw Error('transaction not authorized by the gate');
  const anchor=await read('eth_getBlockByNumber',['0x'+BigInt(auth.blockNumber).toString(16),false]);
  if(!same(anchor.hash,auth.blockHash))throw Error('authorization anchor changed');
  const chain=await read('eth_chainId',[]);
  if(BigInt(chain)!==BigInt(auth.chainId)||!same(auth.safe,step.from))throw Error('authorization domain mismatch');
  // The consumed nonce is bound by the signed hash and authenticated ExecutionSuccess event.
  const executed=Object.fromEntries(fields.slice(0,-1).map(([name],i)=>[name,decoded.args[i]]));
  executed.nonce=auth.transaction.nonce;
  const executedHash=safeTxHash(step.from,chain,executed);
  if(!same(executedHash,auth.safeTxHash)||!same(successes[0].data?.slice(0,66),executedHash))throw Error('Safe signing hash mismatch');
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

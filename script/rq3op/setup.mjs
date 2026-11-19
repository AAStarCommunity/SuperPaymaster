// RQ3 setup only. formal.mjs owns endpoint validation, archiving and cast keystore signing.
import { parse } from '../a6-collector/frozen-plan.mjs';
import {json,completionEntry,appendCompletion,verifyReceipt,emitSafe} from './completion.mjs';
export {emitSafe} from './completion.mjs';
import { readFileSync, appendFileSync, mkdirSync, openSync, closeSync, unlinkSync, writeFileSync, realpathSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { spawn, execFile } from 'node:child_process';
import { createInterface } from 'node:readline';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify, isDeepStrictEqual } from 'node:util';

export async function executeStep(step, deps) {
  const tx=structuredClone(step.tx);
  if (deps.signer.address.toLowerCase()!==tx.from.toLowerCase()) throw Error('setup signer mismatch');
  const chains=await Promise.all([deps.chain(0),deps.chain(1)]);
  if (chains.some(c=>BigInt(c)!==BigInt(tx.chainId))) throw Error('setup chain mismatch');
  const state=await deps.precheck();
  if (state?.status==='already-satisfied') return state;
  const nonces=await Promise.all([deps.pendingNonce(0),deps.pendingNonce(1)]);
  if (nonces.some(n=>BigInt(n)!==BigInt(tx.nonce))) throw Error('setup pending nonce mismatch');
  if (deps.expected && !isDeepStrictEqual(step.tx,deps.expected.tx)) throw Error('regenerated transaction mismatch');
  const freshChains=await Promise.all([deps.chain(0),deps.chain(1)]);
  const freshNonces=await Promise.all([deps.pendingNonce(0),deps.pendingNonce(1)]);
  if(freshChains.some(c=>BigInt(c)!==BigInt(tx.chainId))) throw Error('setup chain changed');
  if(freshNonces.some(n=>BigInt(n)!==BigInt(tx.nonce))) throw Error('setup pending nonce changed');
  if (!isDeepStrictEqual(step.tx,tx)) throw Error('transaction changed before signing');
  const transaction={...tx};
  for(const key of ['gas','value','maxFeePerGas','maxPriorityFeePerGas']) transaction[key]=BigInt(tx[key]);
  transaction.chainId=Number(BigInt(tx.chainId)); transaction.nonce=Number(BigInt(tx.nonce));
  delete transaction.from;
  if(transaction.to===null) delete transaction.to;
  const hash=await deps.send(transaction);
  const [A,B]=await Promise.all([deps.receipt(0,hash),deps.receipt(1,hash)]);
  if(A.status!=='success'||B.status!==A.status||B.blockHash!==A.blockHash||B.blockNumber!==A.blockNumber) throw Error('setup receipt mismatch or revert');
  await deps.readback(A,hash);
  return {hash,receipt:A};
}

export async function gateWorker(bundle,index,action,timestamp,read,options={}) {
  const child=spawn('python3',['-B',fileURLToPath(new URL('./gate_worker.py',import.meta.url))],{stdio:['pipe','pipe','pipe']});
  child.stdin.write(JSON.stringify({bundle,index,action,timestamp:String(timestamp??0),...options},(_,v)=>typeof v==='bigint'?{$integer:v.toString()}:v)+'\n');
  let done=false;
  try {
    for await (const line of createInterface({input:child.stdout})) {
      const message=parse(line);
      if(message.error) throw Object.assign(Error('setup gate: '+json(message.error)),{record:message.error});
      if(message.done) {done=true;return message.result;}
      const result=await read(message.method,message.params);
      child.stdin.write(JSON.stringify({result})+'\n');
    }
    if(!done) throw Error('setup gate worker failed');
  } finally { child.stdin.end(); child.kill(); }
}

export function acquireLock(directory,address) {
  if(!/^0x[0-9a-f]{40}$/.test(address.toLowerCase())) throw Error('invalid lock address');
  mkdirSync(directory,{recursive:true});
  const path=resolve(directory,address.toLowerCase()+'.lock');
  let fd;
  try {fd=openSync(path,'wx',0o600);} catch {throw Error('experiment lock exists; active or stale lock requires operator review');}
  try {writeFileSync(fd,JSON.stringify({pid:process.pid,address}));} catch(error) {closeSync(fd);unlinkSync(path);throw error;}
  return ()=>{closeSync(fd);unlinkSync(path);};
}

export function associatedPlan(bundle,index) {
  const step=bundle.steps[index],parts=step.id.split('/');
  if(parts.length!==2 || !/^[0-2]$/.test(parts[0])) throw Error('invalid plan association');
  const candidates=Object.values(bundle.plans).filter(p=>p.steps.some(s=>s.id===parts[1] && isDeepStrictEqual(s.tx,step.tx)));
  if(candidates.length!==1 || candidates[0].planIndex!==Number(parts[0])) throw Error('ambiguous or missing plan association');
  const plan=candidates[0];
  if(plan.externalInputs && plan.externalInputs.data.phaseC.account!==Object.keys(bundle.plans).find(k=>bundle.plans[k]===plan)) throw Error('plan account association mismatch');
  return plan;
}

export function requireSDKClearance(bundle,step) {
  if (/^\d+\/C8\.extra\.\d+\.(approve|role|mint)$/.test(step.id) &&
      (bundle.shared.sdkLive?.status!=='cleared' || !/^[0-9a-f]{40}$/.test(bundle.shared.sdkLive?.sdkCostCapCommit??''))) throw Error('SDK live setup not cleared');
}

export async function main(args=process.argv.slice(2),deps={}) {
  const mode=['safe','safe-record','record'].includes(args[0])?args.shift():'send';
  const safe=mode.startsWith('safe'),recording=mode.endsWith('record');
  const transactionHash=args[9];
  const [bundleArg,digest,indexArg,signersArg,rpcAFile,rpcBFile,logArg,configArg,inputsArg]=args;
  const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
  const inside=p=>{const path=resolve(p);if(!path.startsWith(root+'/'))throw Error('path outside worktree');const existing=(()=>{try{return realpathSync(path);}catch{return realpathSync(dirname(path));}})();if(!existing.startsWith(root+'/') && existing!==root)throw Error('path outside worktree');return path;};
  const bundlePath=inside(bundleArg), raw=readFileSync(bundlePath);
  if(createHash('sha256').update(raw).digest('hex')!==digest) throw Error('reviewed bundle digest mismatch');
  const bundle=parse(raw),index=Number(indexArg);
  const selected=safe?bundle.safeTransactions:bundle.steps;
  if(!Number.isSafeInteger(index)||index<0||index>=selected.length) throw Error('setup index required');
  const step=selected[index];
  requireSDKClearance(bundle,step);
  const completionPath=inside(bundlePath+'.completions.jsonl');
  const experiment=bundle.shared.experiment;
  const lockDir=inside(root+'/cache/3arm');
  mkdirSync(lockDir+'/locks',{recursive:true});
  const release=acquireLock(inside(lockDir+'/locks'),experiment);
  try {
  const regenerate=deps.regenerate ?? (async()=>{
    const block=Object.values(bundle.plans)[0].pin.block;
    const result=await promisify(execFile)('python3',['-B',fileURLToPath(new URL('./plan_three_arm.py',import.meta.url)),
      inside(configArg),inside(inputsArg),'-','--rpc-a-file',inside(rpcAFile),'--rpc-b-file',inside(rpcBFile),'--block',block],
      {cwd:root,encoding:'buffer',maxBuffer:64*1024*1024});
    return result.stdout;
  });
  const regenerated=Buffer.from(await regenerate({config:configArg,inputs:inputsArg,bundle}));
  if(!raw.equals(regenerated)) throw Error('regenerated bundle bytes mismatch');
  if(createHash('sha256').update(regenerated).digest('hex')!==digest) throw Error('regenerated bundle digest mismatch');
  const expected=(safe?parse(regenerated).safeTransactions:parse(regenerated).steps)[index];
  if(!safe)associatedPlan(bundle,index);
  const readOnly=safe||recording;
  let signerConfig;
  if(!readOnly){
    const signers=JSON.parse(readFileSync(inside(signersArg),'utf8'));
    signerConfig=signers[step.tx.from.toLowerCase()];
    if(!signerConfig||signerConfig.address.toLowerCase()!==step.tx.from.toLowerCase()) throw Error('keystore mapping missing');
  }
  const formalRuntime=deps.runtime ?? (await import('../a6-collector/formal.mjs')).formalRuntime;
  const runtime=await formalRuntime({readOnly,pendingNonce:!readOnly,config:{chainId:bundle.chainId,accounts:{owner:signerConfig,bundler:signerConfig,verifyingSigner:signerConfig}},
    rpcAFile:inside(rpcAFile),rpcBFile:inside(rpcBFile),outPath:inside(logArg)});
  let send=deps.send;
  if(!send && !readOnly){const {createWalletClient,custom}=await import('viem');const wallet=createWalletClient({account:runtime.accounts.bundler,transport:custom(runtime.archives[0],{retryCount:0})});send=tx=>wallet.sendTransaction({...tx,chain:null,type:'eip1559'});}
  let pin;
  const pairRead=async(method,params)=>{
    const values=await Promise.all(runtime.archives.map(r=>r.request({method,params})));
    if(json(values[0])!==json(values[1])) throw Error('setup read disagreement');
    return values[0];
  };
  const read=async(method,params)=>{
    if(!['eth_chainId','eth_getBlockByNumber','eth_call','eth_getCode','eth_getStorageAt','eth_getTransactionCount','eth_getBalance'].includes(method)) throw Error('setup non-read gate request');
    if(method==='eth_getBlockByNumber' && params[0]==='latest') params=[`0x${pin.number.toString(16)}`,false];
    else if(['eth_call','eth_getCode','eth_getStorageAt','eth_getTransactionCount','eth_getBalance'].includes(method)) params=[...params.slice(0,-1),`0x${pin.number.toString(16)}`];
    return pairRead(method,params);
  };
  const checkAnchor=deps.anchor ?? (async()=>{
    const head=await read('eth_getBlockByNumber',[`0x${pin.number.toString(16)}`,false]);
    if(head.hash!==pin.hash) throw Error('setup anchor changed');
  });
  const gate=deps.gate ?? gateWorker;
  const precheck=async()=>{
    pin=await runtime.refreshPin();
    const chains=await pairRead('eth_chainId',[]);
    if(BigInt(chains)!==BigInt(bundle.chainId))throw Error('setup chain mismatch');
    const entry=completionEntry(completionPath,digest,step.id);
    const completion=entry?await verifyReceipt(pairRead,step,entry.txHash,safe,entry):null;
    if(completion && BigInt(completion.blockNumber)>pin.number)throw Error('completion after pinned head');
    const state=await gate(bundle,index,'precheck',0,read,{safe,completion});
    await checkAnchor();return state;
  };
  const recordCompletion=async hash=>{
    if(completionEntry(completionPath,digest,step.id))throw Error('completion already recorded');
    if(BigInt(await pairRead('eth_chainId',[]))!==BigInt(bundle.chainId))throw Error('setup chain mismatch');
    const receipt=await verifyReceipt(pairRead,step,hash,safe);
    pin=await runtime.pubA.getBlock({blockNumber:BigInt(receipt.blockNumber)});
    if(pin.hash!==receipt.blockHash)throw Error('receipt block changed');
    const readback=await gate(bundle,index,'readback',receipt.timestamp,read,{safe});
    await checkAnchor();
    const entry={id:step.id,bundleSha256:digest,...receipt,readback};
    appendCompletion(completionPath,entry);return entry;
  };
  let result;
  if(recording) result=await recordCompletion(transactionHash);
  else if(safe) {
    result=await emitSafe(step,digest,{gate:precheck,emit:deps.emit??(v=>process.stdout.write(json(v)+'\n'))});
    if(result.status==='already-satisfied')(deps.emitStatus??(s=>process.stdout.write(s+'\n')))('already-satisfied');
  } else result=await executeStep(step,{
    signer:runtime.accounts.bundler,expected,
    chain:async i=>runtime.archives[i].request({method:'eth_chainId',params:[]}),
    pendingNonce:async i=>runtime.archives[i].request({method:'eth_getTransactionCount',params:[step.tx.from,'pending']}),
    precheck,
    send,
    receipt:async(i,hash)=>[runtime.pubA,runtime.pubB][i].waitForTransactionReceipt({hash}),
    readback:async (receipt,hash)=>recordCompletion(hash)
  });
  appendFileSync(inside(logArg),JSON.stringify({id:step.id,bundleSha256:digest,...result},(_,v)=>typeof v==='bigint'?v.toString():v)+'\n');
  } catch(error) {
    appendFileSync(inside(logArg),json({id:step.id,bundleSha256:digest,status:'stopped',error:error.record??{gate:'setup_execution_stopped'}})+'\n');
    throw error;
  } finally {release();}
}
if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) main().catch(()=>{process.stderr.write('RQ3 setup stopped; inspect archived evidence (credentials redacted).\n');process.exitCode=1;});

// RQ3 setup only. formal.mjs owns endpoint validation, archiving and cast keystore signing.
import { parse } from '../a6-collector/frozen-plan.mjs';
import {json,completionEntry,appendCompletion,verifyReceipt,emitSafe,canonical,appendAuthorization,authorizationEntry,safeSigning,AUTH_WINDOW_SECONDS,chainHead,requireHead,appendClearance,clearanceEntry} from './completion.mjs';
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
  const context={};
  try{return await runMain([...args],deps,context);}
  catch(error){
    if(context.mode==='safe-clear'){
      if(!error.message.startsWith('DO NOT EXECUTE'))error.message='DO NOT EXECUTE: '+error.message;
      process.stderr.write(error.message+'\n');
    }
    throw error;
  }
  finally{
    let head='unavailable';
    if(context.path)try{head=chainHead(context.path,context.digest);}catch{}
    (deps.emitHead??(v=>process.stdout.write('CHAIN_HEAD '+v+'\n')))(head);
  }
}
async function runMain(args,deps,context) {
  const flags={};
  for(let i=0;i<args.length;i++){
    if(args[i]==='--first-run'){if(flags.firstRun)throw Error('duplicate --first-run');flags.firstRun=true;args.splice(i--,1);}
    else if(args[i]==='--expect-head'){if(flags.expected!==undefined)throw Error('duplicate --expect-head');flags.expected=args[i+1];args.splice(i,2);i--;}
  }
  if(flags.firstRun && flags.expected!==undefined)throw Error('choose --first-run or --expect-head');
  const mode=['safe','safe-clear','safe-record','record'].includes(args[0])?args.shift():'send';
  context.mode=mode;
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
  context.path=completionPath;context.digest=digest;
  const auditPath=inside(logArg);
  const resolvedPath=p=>{try{return realpathSync(p);}catch(error){if(error.code!=='ENOENT')throw error;return resolve(realpathSync(dirname(p)),p.slice(p.lastIndexOf('/')+1));}};
  const checkAuditPath=()=>{
    if([completionPath,completionPath+'.head'].some(p=>resolvedPath(p)===resolvedPath(auditPath)))throw Error('audit path conflicts with completion log or head');
  };
  checkAuditPath();
  const appendAudit=value=>{checkAuditPath();appendFileSync(auditPath,json(value)+'\n');};
  const checkAppend=()=>requireHead(completionPath,digest,flags);
  const experiment=bundle.shared.experiment;
  const lockDir=inside(root+'/cache/3arm');
  mkdirSync(lockDir+'/locks',{recursive:true});
  const release=acquireLock(inside(lockDir+'/locks'),experiment);
  try {
  requireHead(completionPath,digest,flags);
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
  const refreshPin=async()=>{
    const selected=await runtime.refreshPin();
    const header=await pairRead('eth_getBlockByNumber',[`0x${selected.number.toString(16)}`,false]);
    if(header.hash!==selected.hash || BigInt(header.number)!==selected.number)throw Error('setup anchor changed');
    return {...selected,timestamp:BigInt(header.timestamp)};
  };
  const read=async(method,params)=>{
    if(!['eth_chainId','eth_getBlockByNumber','eth_call','eth_getCode','eth_getStorageAt','eth_getTransactionCount','eth_getBalance'].includes(method)) throw Error('setup non-read gate request');
    if(method==='eth_getBlockByNumber' && params[0]==='latest') params=[`0x${pin.number.toString(16)}`,false];
    else if(['eth_call','eth_getCode','eth_getStorageAt','eth_getTransactionCount','eth_getBalance'].includes(method)) params=[...params.slice(0,-1),`0x${pin.number.toString(16)}`];
    return pairRead(method,params);
  };
  const checkAnchor=deps.anchor ?? (async()=>{
    const head=await read('eth_getBlockByNumber',[`0x${pin.number.toString(16)}`,false]);
    if(head.hash!==pin.hash || (pin.timestamp!==undefined && BigInt(head.timestamp)!==pin.timestamp)) throw Error('setup anchor changed');
  });
  const gate=deps.gate ?? gateWorker;
  if(flags.firstRun){
    pin=await refreshPin();
    if(BigInt(await pairRead('eth_chainId',[]))!==BigInt(bundle.chainId))throw Error('setup chain mismatch');
    try{
      for(const isSafe of [false,true])for(let i=0;i<(isSafe?bundle.safeTransactions??[]:bundle.steps).length;i++){
        const state=await gate(bundle,i,'initial',0,read,{safe:isSafe});
        if(state?.status!=='initial')throw Error('step not initial');
      }
      await checkAnchor();
    }catch(error){throw Error('first-run requires every step initial; use --expect-head: '+error.message);}
  }
  const precheck=async()=>{
    pin=safe?await refreshPin():await runtime.refreshPin();
    const chains=await pairRead('eth_chainId',[]);
    if(BigInt(chains)!==BigInt(bundle.chainId))throw Error('setup chain mismatch');
    const entry=completionEntry(completionPath,digest,step.id);
    const completion=entry?await verifyReceipt(pairRead,step,entry.txHash,safe,entry):null;
    if(completion && BigInt(completion.blockNumber)>pin.number)throw Error('completion after pinned head');
    if(entry){
      const head=pin;
      pin={number:BigInt(entry.blockNumber),hash:entry.blockHash};
      const observed=await gate(bundle,index,'readback',entry.timestamp,read,{safe});
      await checkAnchor();
      if(canonical(observed)!==canonical(entry.readback))throw Error('completion readback mismatch');
      pin=head;
    }
    const state=await gate(bundle,index,'precheck',0,read,{safe,completion});
    await checkAnchor();return state;
  };
  const recordCompletion=async hash=>{
    if(completionEntry(completionPath,digest,step.id))throw Error(safe?'transaction not authorized by the gate':'completion already recorded');
    if(BigInt(await pairRead('eth_chainId',[]))!==BigInt(bundle.chainId))throw Error('setup chain mismatch');
    let authorization,clearance;
    if(safe){
      pin=await refreshPin();
      await checkAnchor();
    }
    if(safe){
      const rawReceipt=await pairRead('eth_getTransactionReceipt',[hash]);
      if(!rawReceipt)throw Error('completion receipt missing');
      const block=await pairRead('eth_getBlockByNumber',[rawReceipt.blockNumber,false]);
      authorization=authorizationEntry(completionPath,digest,step,bundle.chainId,{number:rawReceipt.blockNumber,timestamp:block.timestamp});
      clearance=clearanceEntry(completionPath,digest,authorization,{number:rawReceipt.blockNumber,timestamp:block.timestamp});
    }
    const receipt=await verifyReceipt(pairRead,step,hash,safe,null,authorization,clearance);
    if(safe && BigInt(receipt.blockNumber)>pin.number)throw Error('completion after pinned head');
    pin=await runtime.pubA.getBlock({blockNumber:BigInt(receipt.blockNumber)});
    if(pin.hash!==receipt.blockHash)throw Error('receipt block changed');
    const readback=await gate(bundle,index,'readback',receipt.timestamp,read,{safe});
    await checkAnchor();
    const entry={id:step.id,bundleSha256:digest,...receipt,readback,...(safe?{authorization,authorizationDigest:authorization.recordDigest,clearance,clearanceDigest:clearance.recordDigest}:{})};
    checkAppend();
    appendCompletion(completionPath,entry);return entry;
  };
  let result;
  if(recording) result=await recordCompletion(transactionHash);
  else if(mode==='safe-clear') {
    try{
      const state=await precheck();
      if(state?.status!=='initial')throw Error('step is not initial');
      const authorization=authorizationEntry(completionPath,digest,step,bundle.chainId,pin);
      const signing=await safeSigning(step,bundle.chainId,pin,read);
      if(signing.transaction.nonce!==authorization.transaction.nonce)throw Error('Safe nonce changed');
      if(signing.safeTxHash!==authorization.safeTxHash || signing.version!==authorization.version)throw Error('Safe signing hash or VERSION changed');
      const anchor=await pairRead('eth_getBlockByNumber',['0x'+BigInt(authorization.blockNumber).toString(16),false]);
      if(anchor.hash!==authorization.blockHash || BigInt(anchor.timestamp)!==BigInt(authorization.blockTimestamp) || BigInt(authorization.expiresAtTimestamp)!==BigInt(authorization.blockTimestamp)+AUTH_WINDOW_SECONDS)throw Error('authorization anchor changed');
      await checkAnchor();
      checkAppend();
      result=appendClearance(completionPath,authorization,pin);
      context.clearanceRecorded=true;
    }catch(error){throw Object.assign(Error('DO NOT EXECUTE: '+error.message),{record:error.record});}
  }
  else if(safe) {
    result=await emitSafe(step,digest,{gate:precheck,authorize:async result=>{
      const signing=await safeSigning(step,bundle.chainId,pin,read);
      await checkAnchor();
      const entry={...result,...signing,instruction:'safe -> verify hash in Safe UI and collect signatures -> safe-clear -> execute immediately -> safe-record',type:'AUTHORIZATION',blockNumber:String(pin.number),blockHash:pin.hash,blockTimestamp:String(pin.timestamp),expiresAtTimestamp:String(pin.timestamp+AUTH_WINDOW_SECONDS)};
      checkAppend();
      return appendAuthorization(completionPath,entry);
    },emit:deps.emit??(v=>process.stdout.write(json(v)+'\n'))});
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
  try{appendAudit({id:step.id,bundleSha256:digest,...result});}
  catch(error){if(context.clearanceRecorded)throw Error('clearance was recorded; audit write failed: '+error.message);throw error;}
  if(context.clearanceRecorded)(deps.emit??(v=>process.stdout.write(json(v)+'\n')))({...result,instruction:'Execute immediately, then safe-record'});
  } catch(error) {
    try{appendAudit({id:step.id,bundleSha256:digest,status:'stopped',error:error.record??{gate:'setup_execution_stopped'}});}catch{}
    throw error;
  } finally {release();}
}
if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) main().catch(()=>{process.stderr.write('RQ3 setup stopped; inspect archived evidence (credentials redacted).\n');process.exitCode=1;});

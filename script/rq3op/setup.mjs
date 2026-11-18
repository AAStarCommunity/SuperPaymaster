// RQ3 setup only. formal.mjs owns endpoint validation, archiving and cast keystore signing.
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
  const nonces=await Promise.all([deps.pendingNonce(0),deps.pendingNonce(1)]);
  if (nonces.some(n=>BigInt(n)!==BigInt(tx.nonce))) throw Error('setup pending nonce mismatch');
  await deps.precheck();
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
  await deps.readback(A);
  return {hash,receipt:A};
}

export async function gateWorker(bundle,index,action,timestamp,read) {
  const child=spawn('python3',['-B',fileURLToPath(new URL('./gate_worker.py',import.meta.url))],{stdio:['pipe','pipe','pipe']});
  child.stdin.write(JSON.stringify({bundle,index,action,timestamp:String(timestamp??0)})+'\n');
  let done=false;
  try {
    for await (const line of createInterface({input:child.stdout})) {
      const message=JSON.parse(line);
      if(message.error) throw Error('setup gate: '+JSON.stringify(message.error));
      if(message.done) {done=true;break;}
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

export async function main(args=process.argv.slice(2),deps={}) {
  const [bundleArg,digest,indexArg,signersArg,rpcAFile,rpcBFile,logArg,configArg,inputsArg]=args;
  const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
  const inside=p=>{const path=resolve(p);if(!path.startsWith(root+'/'))throw Error('path outside worktree');const existing=(()=>{try{return realpathSync(path);}catch{return realpathSync(dirname(path));}})();if(!existing.startsWith(root+'/') && existing!==root)throw Error('path outside worktree');return path;};
  const bundlePath=inside(bundleArg), raw=readFileSync(bundlePath);
  if(createHash('sha256').update(raw).digest('hex')!==digest) throw Error('reviewed bundle digest mismatch');
  const bundle=JSON.parse(raw),index=Number(indexArg);
  if(!Number.isSafeInteger(index)||index<0||index>=bundle.steps.length) throw Error('setup index required');
  const step=bundle.steps[index];
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
  const expected=JSON.parse(regenerated).steps[index];
  associatedPlan(bundle,index);
  const signers=JSON.parse(readFileSync(inside(signersArg),'utf8'));
  const signerConfig=signers[step.tx.from.toLowerCase()];
  if(!signerConfig||signerConfig.address.toLowerCase()!==step.tx.from.toLowerCase()) throw Error('keystore mapping missing');
  const formalRuntime=deps.runtime ?? (await import('../a6-collector/formal.mjs')).formalRuntime;
  const runtime=await formalRuntime({pendingNonce:true,config:{chainId:bundle.chainId,accounts:{owner:signerConfig,bundler:signerConfig,verifyingSigner:signerConfig}},
    rpcAFile:inside(rpcAFile),rpcBFile:inside(rpcBFile),outPath:inside(logArg)});
  let send=deps.send;
  if(!send){const {createWalletClient,custom}=await import('viem');const wallet=createWalletClient({account:runtime.accounts.bundler,transport:custom(runtime.archives[0],{retryCount:0})});send=tx=>wallet.sendTransaction({...tx,chain:null,type:'eip1559'});}
  let pin;
  const read=async(method,params)=>{
    if(!['eth_chainId','eth_getBlockByNumber','eth_call','eth_getCode','eth_getStorageAt','eth_getTransactionCount','eth_getBalance'].includes(method)) throw Error('setup non-read gate request');
    if(method==='eth_getBlockByNumber' && params[0]==='latest') params=[`0x${pin.number.toString(16)}`,false];
    else if(['eth_call','eth_getCode','eth_getStorageAt','eth_getTransactionCount','eth_getBalance'].includes(method)) params=[...params.slice(0,-1),`0x${pin.number.toString(16)}`];
    const values=await Promise.all(runtime.archives.map(r=>r.request({method,params})));
    if(JSON.stringify(values[0])!==JSON.stringify(values[1])) throw Error('setup read disagreement');
    return values[0];
  };
  const checkAnchor=deps.anchor ?? (async()=>{
    const head=await read('eth_getBlockByNumber',[`0x${pin.number.toString(16)}`,false]);
    if(head.hash!==pin.hash) throw Error('setup anchor changed');
  });
  const result=await executeStep(step,{
    signer:runtime.accounts.bundler,expected,
    chain:async i=>runtime.archives[i].request({method:'eth_chainId',params:[]}),
    pendingNonce:async i=>runtime.archives[i].request({method:'eth_getTransactionCount',params:[step.tx.from,'pending']}),
    precheck:async()=>{pin=await runtime.refreshPin();await (deps.gate ?? gateWorker)(bundle,index,'precheck',0,read);await checkAnchor();},
    send,
    receipt:async(i,hash)=>[runtime.pubA,runtime.pubB][i].waitForTransactionReceipt({hash}),
    readback:async receipt=>{pin=await runtime.pubA.getBlock({blockNumber:receipt.blockNumber});await (deps.gate ?? gateWorker)(bundle,index,'readback',pin.timestamp,read);await checkAnchor();}
  });
  appendFileSync(inside(logArg),JSON.stringify({id:step.id,bundleSha256:digest,...result},(_,v)=>typeof v==='bigint'?v.toString():v)+'\n');
  } finally {release();}
}
if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) main().catch(()=>{process.stderr.write('RQ3 setup stopped; inspect archived evidence (credentials redacted).\n');process.exitCode=1;});

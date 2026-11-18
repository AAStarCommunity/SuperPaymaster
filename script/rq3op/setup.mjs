// RQ3 setup only. formal.mjs owns endpoint validation, archiving and cast keystore signing.
import { readFileSync, appendFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

export async function executeStep(step, deps) {
  const tx=step.tx;
  if (deps.signer.address.toLowerCase()!==tx.from.toLowerCase()) throw Error('setup signer mismatch');
  const chains=await Promise.all([deps.chain(0),deps.chain(1)]);
  if (chains.some(c=>BigInt(c)!==BigInt(tx.chainId))) throw Error('setup chain mismatch');
  const nonces=await Promise.all([deps.pendingNonce(0),deps.pendingNonce(1)]);
  if (nonces.some(n=>BigInt(n)!==BigInt(tx.nonce))) throw Error('setup pending nonce mismatch');
  await deps.precheck();
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

async function main() {
  const [bundleArg,digest,indexArg,signersArg,rpcAFile,rpcBFile,logArg]=process.argv.slice(2);
  const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
  const inside=p=>{const path=resolve(p);if(!path.startsWith(root+'/'))throw Error('path outside worktree');return path;};
  const bundlePath=inside(bundleArg), raw=readFileSync(bundlePath);
  if(createHash('sha256').update(raw).digest('hex')!==digest) throw Error('reviewed bundle digest mismatch');
  const bundle=JSON.parse(raw),index=Number(indexArg);
  if(!Number.isSafeInteger(index)||index<0||index>=bundle.steps.length) throw Error('setup index required');
  const step=bundle.steps[index];
  const signers=JSON.parse(readFileSync(inside(signersArg),'utf8'));
  const signerConfig=signers[step.tx.from.toLowerCase()];
  if(!signerConfig||signerConfig.address.toLowerCase()!==step.tx.from.toLowerCase()) throw Error('keystore mapping missing');
  const {formalRuntime}=await import('../a6-collector/formal.mjs');
  const {createWalletClient,custom}=await import('viem');
  const runtime=await formalRuntime({pendingNonce:true,config:{chainId:bundle.chainId,accounts:{owner:signerConfig,bundler:signerConfig,verifyingSigner:signerConfig}},
    rpcAFile:inside(rpcAFile),rpcBFile:inside(rpcBFile),outPath:inside(logArg)});
  const wallet=createWalletClient({account:runtime.accounts.bundler,transport:custom(runtime.archives[0],{retryCount:0})});
  let pin;
  const read=async(method,params)=>{
    if(!['eth_chainId','eth_getBlockByNumber','eth_call','eth_getCode','eth_getStorageAt','eth_getTransactionCount','eth_getBalance'].includes(method)) throw Error('setup non-read gate request');
    if(method==='eth_getBlockByNumber' && params[0]==='latest') params=[`0x${pin.number.toString(16)}`,false];
    else if(['eth_call','eth_getCode','eth_getStorageAt','eth_getTransactionCount','eth_getBalance'].includes(method)) params=[...params.slice(0,-1),`0x${pin.number.toString(16)}`];
    const values=await Promise.all(runtime.archives.map(r=>r.request({method,params})));
    if(JSON.stringify(values[0])!==JSON.stringify(values[1])) throw Error('setup read disagreement');
    return values[0];
  };
  const checkAnchor=async()=>{
    const head=await read('eth_getBlockByNumber',[`0x${pin.number.toString(16)}`,false]);
    if(head.hash!==pin.hash) throw Error('setup anchor changed');
  };
  const result=await executeStep(step,{
    signer:runtime.accounts.bundler,
    chain:async i=>runtime.archives[i].request({method:'eth_chainId',params:[]}),
    pendingNonce:async i=>runtime.archives[i].request({method:'eth_getTransactionCount',params:[step.tx.from,'pending']}),
    precheck:async()=>{pin=await runtime.refreshPin();await gateWorker(bundlePath,index,'precheck',0,read);await checkAnchor();},
    send:async tx=>wallet.sendTransaction({...tx,chain:null,type:'eip1559'}),
    receipt:async(i,hash)=>[runtime.pubA,runtime.pubB][i].waitForTransactionReceipt({hash}),
    readback:async receipt=>{pin=await runtime.pubA.getBlock({blockNumber:receipt.blockNumber});await gateWorker(bundlePath,index,'readback',pin.timestamp,read);await checkAnchor();}
  });
  appendFileSync(inside(logArg),JSON.stringify({id:step.id,bundleSha256:digest,...result},(_,v)=>typeof v==='bigint'?v.toString():v)+'\n');
}
if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) main().catch(()=>{process.stderr.write('RQ3 setup stopped; inspect archived evidence (credentials redacted).\n');process.exitCode=1;});

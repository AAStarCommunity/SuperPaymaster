// Synthetic ABI-realistic evidence, never a chain measurement.
import { encodeAbiParameters, encodeEventTopics, encodeFunctionData, encodeFunctionResult } from 'viem';
import { EP_EVENTS_ABI, SP_EVENTS_ABI } from '../a6-collector/gauge-lib.mjs';
import { POSTOP_ABI, TPM_ABI, TASK_ABI, LOCK_ABI, spFormula, json, extract } from './extract.mjs';
import { STATE_ABI, qualificationFor } from './evidence.mjs';
import { baselineFor, runtimeFor } from './baseline.mjs';
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
export const address = n => '0x' + n.toString(16).padStart(40, '0');
export const hash = n => '0x' + n.toString(16).padStart(64, '0');
const encode = (types, values) => encodeAbiParameters(types.map(type => ({type})), values);
export function reads(address, blockHash, functionName, result, args=[]) {
  return ['rpc-a','rpc-b'].map(endpoint=>({endpoint, method:'eth_call',
    params:[{to:address,data:encodeFunctionData({abi:STATE_ABI,functionName,args})},{blockHash,requireCanonical:true}],
    result:encodeFunctionResult({abi:STATE_ABI,functionName,result})}));
}
export function logReads(address, blockHash, logs=[]) {
  return ['rpc-a','rpc-b'].map(endpoint=>({endpoint,method:'eth_getLogs',
    params:[{address,blockHash}],result:structuredClone(logs)}));
}
export function fixture(slot = 0, arm = 'SP', legacy = false) {
  const sender = address(2 + (slot + ['SP','VerifyingPaymaster','TokenPaymaster'].indexOf(arm)) % 3), ep = address(1), pm = address(10 + 100 * ['SP','VerifyingPaymaster','TokenPaymaster'].indexOf(arm)), token = address(12), operator = address(13);
  const call = 100001n, post = 480000n, cPre = 3000004n, pOp = 7n;
  const opHash = hash(1000 + slot * 3 + ['SP','VerifyingPaymaster','TokenPaymaster'].indexOf(arm));
  const txHash = hash(2000 + slot * 3 + ['SP','VerifyingPaymaster','TokenPaymaster'].indexOf(arm));
  const context = arm === 'SP' ? encode(['address','address','uint256','bytes32','address','uint8','uint128','uint128','int256','uint8','uint256',...(legacy?[]:['uint256'])],
    [token,sender,999999999999999999999n,opHash,operator,1,call,post,200000000001n,8,300000001n,
      ...(legacy?[]:[480000n | (160000n<<32n) | (30000n<<64n) | (170000n<<96n) | (251n<<128n)])]) : encode(['uint256','address'],[9000000n,sender]);
  const operation = {sender,entryPoint:ep,paymaster:pm,userOpHash:opHash,nonce:'0',callGasLimit:String(call),paymasterPostOpGasLimit:String(post),preVerificationGas:'50000'};
  const event = (abi,name,args,types,values,who) => ({address:who,topics:encodeEventTopics({abi,eventName:name,args}),data:encode(types,values),logIndex:0});
  const logs = [event(EP_EVENTS_ABI,'UserOperationEvent',{userOpHash:opHash,sender,paymaster:pm},['uint256','bool','uint256','uint256'],[0n,true,3941000n,563000n],ep)];
  const task = {token:address(20),recipient:address(21),amount:'17',recipientBalanceBefore:'1000'};
  operation.callData=encodeFunctionData({abi:TASK_ABI,functionName:'execute',args:[task.token,0n,encodeFunctionData({abi:TASK_ABI,functionName:'transfer',args:[task.recipient,17n]})]});
  logs.push(event(TASK_ABI,'Transfer',{from:sender,to:task.recipient},['uint256'],[17n],task.token));
  const state = {phase:'postOp',transactionHash:txHash,blockHash:hash(9000+slot),refundPostopCost:'40000',postOpCachedPrice:String(3n*10n**26n),priceMarkup:String(11n*10n**25n)};
  if (arm==='SP') {
    const f=legacy ? spFormula(fixture(slot,'SP').validationContext,cPre,pOp) : spFormula(context,cPre,pOp);
    const reserve=f.a0APNTs, locked=2n*reserve, charge=f.expectedChargeAPNTs;
    logs.push(event(LOCK_ABI,'LockCreated',{user:sender,opHash,locker:pm},['uint256','uint256'],[locked,reserve],token));
    logs.push(event(LOCK_ABI,'LockSettled',{user:sender,opHash},['uint256','uint256'],[charge*2n,charge],token));
    const config=balance=>[balance,true,false,token,0,60,address(14),0n,0n];
    state.reserveBefore=reads(pm,hash(8999+slot),'operators',config(reserve),[operator]);
    state.reserveAfter=reads(pm,hash(9000+slot),'operators',config(reserve-charge),[operator]);
    logs.splice(2,0,event(SP_EVENTS_ABI,'TransactionSponsored',{operator,user:sender},['uint256','uint256'],[f.aGas,f.expectedChargeAPNTs],pm));
  }
  if (arm==='TokenPaymaster') {
    const marked=BigInt(state.postOpCachedPrice)*10n**26n/BigInt(state.priceMarkup);
    logs.push(event(TPM_ABI,'UserOperationSponsored',{user:sender},['uint256','uint256','uint256'],[(cPre+40000n*pOp)*10n**26n/marked,cPre,marked],pm));
  }
  state.config=reads(pm,hash(9000+slot),'tokenPaymasterConfig',[BigInt(state.priceMarkup),0n,40000,3600]);
  state.cachedPrice=reads(pm,hash(9000+slot),'cachedPrice',BigInt(state.postOpCachedPrice));
  const immutables={entryPoint:ep,token,wrappedNative:address(30),uniswap:address(31)};
  const runtime=runtimeFor(immutables), baseline=baselineFor(immutables);
  state.runtime=['rpc-a','rpc-b'].map(endpoint=>({endpoint,method:'eth_getCode',
    params:[pm,{blockHash:hash(9000+slot),requireCanonical:true}],result:runtime}));
  const words=[512n,BigInt(sender),0n,300n,call,400n,post,60n,BigInt(pm),20n,2n,BigInt(opHash),999999999n,0n,100000n,544n,0n,BigInt((context.length-2)/2)];
  const inner='0x0042dc53'+words.map(w=>w.toString(16).padStart(64,'0')).join('')+context.slice(2);
  return {metadata:{paper_id:'AOA',experiment_id:'synthetic-rq3',window_id:'fixture-1',protocol_version:'rq3-draft',git_commit:'661d058cb76a61b439f9e7ce020a28beeb321b55',runtime_codehashes:'synthetic-only',arm,pair_id:`block-${String(slot).padStart(2,'0')}`,block_slot:slot,prior_formal_slots:0,attempt_index:slot,warmup:false,injected:false,invalid_reason:'',exclusion_reason:'',precheck_refused:false},operation,
    qualification:qualificationFor('op-mainnet'),
    confirmation:{broadcastAt:0,observedAt:30,headNumber:110,rereadBlockNumber:100,rereadHeadNumber:110,rereadBlockHash:hash(9000+slot)},
    transactionHash:txHash,validationContext:context,state,task,baseline,
    reserveLogs:{entryPoint:logReads(ep,hash(9000+slot),logs.filter(l=>l.address===ep).map(l=>({...l,blockHash:hash(9000+slot)}))),
      paymaster:logReads(pm,hash(9000+slot),logs.filter(l=>l.address===pm).map(l=>({...l,blockHash:hash(9000+slot)})))},
    tpmWindow:{window_id:'fixture-1',address:pm,firstBlockHash:hash(9000+slot),lastBlockHash:hash(9000+slot),
      configFirst:state.config,configLast:structuredClone(state.config),
      blocks:[{hash:hash(9000+slot),number:100,parentHash:hash(8999+slot),logs:logReads(pm,hash(9000+slot))}]},
    receiptBlock:{hash:hash(9000+slot),parentHash:hash(8999+slot),transactions:[txHash]},
    receipt:{blockNumber:100,transactionHash:txHash,blockHash:hash(9000+slot),status:'0x1',gasUsed:'0x927c0',logs},
    trace:{transactionHash:txHash,blockHash:hash(9000+slot),tracer:'callTracer',result:{type:'CALL',to:ep,calls:[{type:'CALL',from:ep,to:ep,input:inner,calls:[{type:'CALL',from:ep,to:pm,input:encodeFunctionData({abi:POSTOP_ABI,functionName:'postOp',args:[0,context,cPre,pOp]})}]}]}}};
}

export function windowFixture() {
  const archives=[];
  const schedule=JSON.parse(readFileSync(new URL('./examples/schedule.json',import.meta.url),'utf8'));
  for(let slot=0;slot<52;slot++) for(const arm of schedule.payload.slots[slot].order) {
    // One incomplete block with no TPM attempt, independently of the refusal/timeout.
    if(slot===50 && arm==='TokenPaymaster') continue;
    const a=fixture(slot,arm);
    if(slot===48 && arm==='SP') {
      a.metadata.precheck_refused=true;
      delete a.receipt; delete a.trace; delete a.validationContext;
    }
    if(slot===49 && arm==='TokenPaymaster') {
      a.confirmation.observedAt=120;
      a.metadata.failure_reason='receipt_timeout'; delete a.receipt; delete a.trace; delete a.validationContext;
    }
    if(slot===51) a.metadata.retry_of='block-48';
    archives.push(a);
  }
  // One shared, complete window evidence envelope for all TPM rows.
  const tpm=archives.find(a=>a.metadata.arm==='TokenPaymaster');
  const w={window_id:'fixture-1',address:tpm.operation.paymaster,firstBlockHash:hash(9000),lastBlockHash:hash(9051),
    configFirst:reads(tpm.operation.paymaster,hash(9000),'tokenPaymasterConfig',[11n*10n**25n,0n,40000,3600]),
    configLast:reads(tpm.operation.paymaster,hash(9051),'tokenPaymasterConfig',[11n*10n**25n,0n,40000,3600]),
    blocks:Array.from({length:52},(_,slot)=>({number:100+slot,hash:hash(9000+slot),parentHash:hash(8999+slot),
      logs:logReads(tpm.operation.paymaster,hash(9000+slot),archives.filter(a=>a.metadata.block_slot===slot)
        .flatMap(a=>a.receipt?.logs??[]).filter(l=>l.address===tpm.operation.paymaster)
        .map(l=>({...l,blockHash:hash(9000+slot)})))}))};
  for(const a of archives) {
    const slot=a.metadata.block_slot;
    if(a.receipt) a.receipt.blockNumber=100+slot;
    Object.assign(a.confirmation,{headNumber:110+slot,rereadBlockNumber:100+slot,rereadHeadNumber:110+slot});
    a.tpmWindow=w;
    if(a.metadata.arm==='SP') {
      const logs=archives.filter(other=>other.metadata.block_slot===slot)
        .flatMap(other=>other.receipt?.logs??[]).map(l=>({...l,blockHash:hash(9000+slot)}));
      a.reserveLogs={
        entryPoint:logReads(a.operation.entryPoint,hash(9000+slot),logs.filter(l=>l.address===a.operation.entryPoint)),
        paymaster:logReads(a.operation.paymaster,hash(9000+slot),logs.filter(l=>l.address===a.operation.paymaster)),
      };
    }
  }
  return archives;
}
if(process.argv[1] && import.meta.url===pathToFileURL(process.argv[1]).href) {
  writeFileSync(process.argv[2],json(windowFixture().map(extract))+'\n');
}

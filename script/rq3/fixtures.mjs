// Synthetic ABI-realistic evidence, never a chain measurement.
import { encodeAbiParameters, encodeEventTopics, encodeFunctionData, parseAbi } from 'viem';
import { EP_EVENTS_ABI, SP_EVENTS_ABI } from '../a6-collector/gauge-lib.mjs';
import { POSTOP_ABI, TPM_ABI, TASK_ABI, spFormula, json, extract } from './extract.mjs';
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
export const address = n => '0x' + n.toString(16).padStart(40, '0');
const hash = n => '0x' + n.toString(16).padStart(64, '0');
const encode = (types, values) => encodeAbiParameters(types.map(type => ({type})), values);
export function fixture(slot = 0, arm = 'SP', legacy = false) {
  const sender = address(2 + (slot + ['SP','VerifyingPaymaster','TokenPaymaster'].indexOf(arm)) % 3), ep = address(1), pm = address(10), token = address(12), operator = address(13);
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
  const state = {phase:'postOp',transactionHash:txHash,blockHash:hash(9000+slot),postOpProtocolFeeBPS:'250',refundPostopCost:'40000',postOpCachedPrice:String(3n*10n**26n),priceMarkup:String(11n*10n**25n)};
  if (arm==='SP') {
    const f=spFormula(context,cPre,pOp,250);
    logs.push(event(SP_EVENTS_ABI,'TransactionSponsored',{operator,user:sender},['uint256','uint256'],[f.aGas,f.expectedChargeAPNTs],pm));
  }
  if (arm==='TokenPaymaster') {
    const marked=BigInt(state.postOpCachedPrice)*10n**26n/BigInt(state.priceMarkup);
    logs.push(event(TPM_ABI,'UserOperationSponsored',{user:sender},['uint256','uint256','uint256'],[(cPre+40000n*pOp)*10n**26n/marked,cPre,marked],pm));
  }
  const words=[512n,BigInt(sender),0n,300n,call,400n,post,60n,BigInt(pm),20n,2n,BigInt(opHash),999999999n,0n,100000n,544n,0n,BigInt((context.length-2)/2)];
  const inner='0x0042dc53'+words.map(w=>w.toString(16).padStart(64,'0')).join('')+context.slice(2);
  return {metadata:{paper_id:'AOA',experiment_id:'synthetic-rq3',window_id:'fixture-1',protocol_version:'rq3-draft',git_commit:'661d058cb76a61b439f9e7ce020a28beeb321b55',runtime_codehashes:'synthetic-only',arm,pair_id:`block-${String(slot).padStart(2,'0')}`,block_slot:slot,prior_formal_slots:0,attempt_index:slot,warmup:false,injected:false,invalid_reason:'',exclusion_reason:'',precheck_refused:false},operation,
    transactionHash:txHash,validationContext:context,state,task,
    receipt:{transactionHash:txHash,blockHash:hash(9000+slot),status:'0x1',gasUsed:'0x927c0',logs},
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
      a.metadata.failure_reason='receipt_timeout'; delete a.receipt; delete a.trace; delete a.validationContext;
    }
    if(slot===51) a.metadata.retry_of='block-48';
    archives.push(a);
  }
  return archives;
}
if(process.argv[1] && import.meta.url===pathToFileURL(process.argv[1]).href) {
  writeFileSync(process.argv[2],json(windowFixture().map(extract))+'\n');
}

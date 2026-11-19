import { decomposeGas, exactClaimMatches } from './gas-decomposition.mjs';
import { readFileSync } from 'node:fs';
import { encodeFunctionData, parseAbi } from 'viem';
export const pvgRule=JSON.parse(readFileSync(new URL('../rq3op/pvg-rule.json',import.meta.url),'utf8'));
const abi=parseAbi(['function handleOps((address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature)[] ops,address beneficiary)']);
function counts(hex) {
  const bytes=Buffer.from(hex.slice(2),'hex'), zero=bytes.filter(b=>b===0).length;
  return {total:bytes.length,zero,nonZero:bytes.length-zero};
}
const cost=b=>BigInt(b.zero*4+b.nonZero*16);
export function measurePVG(op,beneficiary) {
  const input=encodeFunctionData({abi,functionName:'handleOps',args:[[op],beneficiary]});
  // Selector + two argument words + array length + single tuple offset = 132 bytes.
  // The remaining bytes are exactly the tuple as encoded inside handleOps.
  const bytes=counts('0x'+input.slice(2+132*2));
  const overhead={transaction:21000n,handleOps:cost(counts(input.slice(0,2+132*2)))};
  const calldataGas=cost(bytes);
  return {...pvgRule,bytes,calldataGas,overhead,value:calldataGas+overhead.transaction+overhead.handleOps};
}
export function computePVG(op,beneficiary) {
  let value=0n;
  const seen=new Set();
  while(!seen.has(value)) {
    seen.add(value);
    const r=measurePVG({...op,signature:op.signature==='0x'?'0x'+'ff'.repeat(65):op.signature,preVerificationGas:value},beneficiary);
    if(r.value===value) return r;
    value=r.value;
  }
  throw Error('PVG_FIXED_POINT');
}
export async function finalizePVG(sign,beneficiary,plan=null) {
  let value=0n;
  const seen=new Set();
  while(!seen.has(value) && seen.size<64) {
    seen.add(value);
    const result=await sign(value);
    if(plan) checkPVGLengths(result.packed,plan.lengths);
    if(result.packed.preVerificationGas!==value || result.packed.signature.length!==132) throw Error('PVG_SIGNED_BYTES');
    const pvg=measurePVG(result.packed,beneficiary);
    if(plan && pvg.value>BigInt(plan.reserve)) throw Error('PVG_RESERVE');
    if(pvg.value===value) return {...result,pvg};
    value=pvg.value;
  }
  throw Error('PVG_SIGNED_FIXED_POINT');
}
export function checkPVGLengths(op,lengths) {
  for(const field of ['initCode','callData','paymasterAndData','signature']) {
    if(!Number.isSafeInteger(lengths?.[field]) || !/^0x(?:[0-9a-f]{2})*$/i.test(op[field]) ||
      (op[field].length-2)/2!==lengths[field]) throw Error('PVG_LENGTHS');
  }
}
export function reservePVG(lengths) {
  const word='0x'+'ff'.repeat(32), address='0x'+'ff'.repeat(20);
  const op={sender:address,nonce:BigInt(word),accountGasLimits:word,preVerificationGas:BigInt(word),gasFees:word};
  for(const field of ['initCode','callData','paymasterAndData','signature']) op[field]='0x'+'ff'.repeat(lengths[field]);
  checkPVGLengths(op,lengths);
  return measurePVG(op,address).value;
}
export const nullPVGColumns=()=>Object.fromEntries(['pvgConsistency','bundlerNetGas','unusedGasPenalty',
  'unusedGasPenaltyReason','bundlerNetGasExPenalty','opGasPrice','outerEffectiveGasPrice',
  'calldataFloorGas','calldataFloorBinding','outerGasUsed','l1DataFee'].map(k=>[k,null]));
export function recordPVG(row,pvg,input=null,receipt=null,event=null) {
  Object.assign(row,nullPVGColumns());
  row.gasSources={...row.gasSources,preVerification:{...row.gasSources?.preVerification,...pvg}};
  if(input===null) return;
  const bytes=counts(input);
  row.pvgConsistency=BigInt(pvg.value)-(21000n+cost(bytes))/BigInt(pvg.ops);
  row.calldataFloorGas=21000n+10n*BigInt(bytes.zero+4*bytes.nonZero);
  row.outerGasUsed=receipt?.gasUsed==null?null:BigInt(receipt.gasUsed);
  row.calldataFloorBinding=row.outerGasUsed===null?null:row.outerGasUsed===row.calldataFloorGas;
  row.outerEffectiveGasPrice=receipt?.effectiveGasPrice??null;
  row.l1DataFee=receipt?.l1Fee??null;
  const derived=decomposeGas(row,event);
  if(!exactClaimMatches(row.gasDecomposition,derived)) Object.assign(derived,{
    status:'mismatch',reason:'stored exact claim differs from trace derivation',unusedGasPenalty:null,reconstructionMatches:false});
  row.gasDecomposition=derived;
  row.unusedGasPenalty=derived.status==='exact'?BigInt(derived.unusedGasPenalty):null;
  row.unusedGasPenaltyReason=derived.reason;
  if(event?.actualGasUsed!=null) {
    const actual=BigInt(event.actualGasUsed);
    row.bundlerNetGas=row.outerGasUsed===null?null:actual-row.outerGasUsed;
    row.opGasPrice=actual>0n && event.actualGasCost!=null?BigInt(event.actualGasCost)/actual:null;
    row.bundlerNetGasExPenalty=row.bundlerNetGas===null || row.unusedGasPenalty===null?null:row.bundlerNetGas-row.unusedGasPenalty;
  }
  if(row.pvgConsistency!==0n) throw Error('PVG_CONSISTENCY');
}

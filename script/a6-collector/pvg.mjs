import { readFileSync } from 'node:fs';
import { encodeFunctionData, parseAbi } from 'viem';
export const pvgRule=JSON.parse(readFileSync(new URL('../rq3op/pvg-rule.json',import.meta.url),'utf8'));
const abi=parseAbi(['function handleOps((address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature)[] ops,address beneficiary)']);
function counts(hex) {
  const bytes=Buffer.from(hex.slice(2),'hex'), zero=bytes.filter(b=>b===0).length;
  return {total:bytes.length,zero,nonZero:bytes.length-zero};
}
const cost=b=>BigInt(b.zero*4+b.nonZero*16);
function measure(op,beneficiary) {
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
    const r=measure({...op,signature:op.signature==='0x'?'0x'+'ff'.repeat(65):op.signature,preVerificationGas:value},beneficiary);
    if(r.value===value) return r;
    value=r.value;
  }
  throw Error('PVG_FIXED_POINT');
}
export async function finalizePVG(sign,beneficiary) {
  let value=0n;
  const seen=new Set();
  while(!seen.has(value) && seen.size<64) {
    seen.add(value);
    const result=await sign(value);
    if(result.packed.preVerificationGas!==value || result.packed.signature.length!==132) throw Error('PVG_SIGNED_BYTES');
    const pvg=measure(result.packed,beneficiary);
    if(pvg.value===value) return {...result,pvg};
    value=pvg.value;
  }
  throw Error('PVG_SIGNED_FIXED_POINT');
}
export function recordPVG(row,pvg,input=null,receipt=null) {
  row.l1DataFee=receipt?.l1Fee??null;
  row.gasSources={...row.gasSources,preVerification:pvg};
  // No real calldata exists for NOT_SENT rows.
  row.pvgDelta=input===null?null:BigInt(pvg.value)-cost(counts(input));
}

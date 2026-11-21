import test from 'node:test';
import assert from 'node:assert/strict';
import { encodeFunctionData, parseAbi } from 'viem';
import * as p from './pvg.mjs';

const address='0x'+'11'.repeat(20), word='0x'+'00'.repeat(32);
const abi=parseAbi(['function handleOps((address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature)[] ops,address beneficiary)']);
const signature=zeros=>'0x'+'00'.repeat(zeros)+'ff'.repeat(65-zeros);
const op=arm=>({sender:address,nonce:0n,initCode:'0x',callData:'0x'+'11'.repeat(228),accountGasLimits:word,preVerificationGas:0n,gasFees:word,paymasterAndData:'0x'+'11'.repeat({SP:125,VPM:181,TPM:52}[arm]),signature:signature(0)});
const input=packed=>encodeFunctionData({abi,functionName:'handleOps',args:[[packed],address]});
function scenario(arm,zeros) {
  const base=op(arm);
  const values=zeros.map(n=>p.computePVG({...base,signature:signature(n)},address).value);
  const sign=async value=>{
    const i=values.indexOf(value), next=i<0?0:(i+1)%values.length;
    return {packed:{...base,preVerificationGas:value,signature:signature(zeros[next])}};
  };
  const lengths=Object.fromEntries(['initCode','callData','paymasterAndData','signature'].map(k=>[k,(base[k].length-2)/2]));
  return {values,sign,plan:{lengths,reserve:p.reservePVG(lengths)}};
}

// Collector attemptInner uses this same finalizePVG -> recordPVG path for SP, VPM and TPM.
for(const arm of ['SP','VPM','TPM']) {
  test(`${arm}: exact fixed point records zero surplus and reason before and after input`,async()=>{
    const {sign,plan}=scenario(arm,[0]);
    const result=await p.finalizePVG(sign,address,plan);
    assert.equal(result.pvg.value,p.measurePVG(result.packed,address).value);
    for(const data of [null,input(result.packed)]) {
      const row={}; p.recordPVG(row,result.pvg,data);
      assert.equal(row.pvgSurplus,0n);
      assert.equal(row.pvgSurplusReason,'fixed-point');
    }
  });
  test(`${arm}: two-cycle accepts exactly 48 gas and records cycle-max`,async()=>{
    const {sign,plan,values}=scenario(arm,[0,4]);
    assert.equal(values[0]-values[1],48n);
    const result=await p.finalizePVG(sign,address,plan);
    assert.equal(result.pvg.value,values[0]);
    assert.equal(result.pvg.surplus,48n);
    for(const data of [null,input(result.packed)]) {
      const row={}; p.recordPVG(row,result.pvg,data);
      assert.equal(row.pvgSurplus,48n);
      assert.equal(row.pvgSurplusReason,'cycle-max');
      if(data!==null) assert.equal(row.pvgConsistency,row.pvgSurplus);
    }
  });
  test(`${arm}: two-cycle rejects 60 gas surplus`,async()=>{
    const {sign,plan,values}=scenario(arm,[0,5]);
    assert.equal(values[0]-values[1],60n);
    await assert.rejects(p.finalizePVG(sign,address,plan),{message:'PVG_SURPLUS_BOUND'});
  });
  test(`${arm}: three-cycle stops even within surplus bound`,async()=>{
    const {sign,plan,values}=scenario(arm,[0,1,2]);
    assert.equal(new Set(values).size,3);
    await assert.rejects(p.finalizePVG(sign,address,plan),{message:'PVG_SIGNED_CYCLE_LENGTH'});
  });
}
test('PVG row schema includes surplus and reason even before signing',()=>{
  const row=p.nullPVGColumns();
  assert.equal(row.pvgSurplus,null);
  assert.equal(row.pvgSurplusReason,null);
});
test('named surplus bound is four zero-byte flips',()=>assert.equal(p.PVG_MAX_SURPLUS,48n));

import test from 'node:test';
import assert from 'node:assert/strict';
import { encodeFunctionData, parseAbi } from 'viem';
import * as p from './pvg.mjs';
import { readFileSync } from 'node:fs';

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
  test(`${arm}: three-cycle is accepted at its maximum within the surplus bound`,async()=>{
    const {sign,plan,values}=scenario(arm,[0,1,2]);
    assert.equal(new Set(values).size,3);
    const result=await p.finalizePVG(sign,address,plan);
    assert.equal(result.pvg.value,values[0]);
    assert.equal(result.pvg.surplus,values[0]-values[1]);
    assert.equal(result.pvg.resolution,'cycle-max');
    assert.equal(result.pvg.cycle.length,3);
  });
}
// Real OP Sepolia sequence: calibration verify run 2026-11-21, VPM arm, sender S2 (0x7060...), round 1:
// signing at 0 measured 28404, at 28404 -> 28428, 28428 -> 28440, 28440 -> 28416, 28416 -> 28428 (a 3-cycle).
// The op bytes here are synthetic: callData length is chosen so that signature zero-byte counts reproduce
// exactly these rule values (each signature zero byte costs 12 gas less); every transition is measured, not assumed.
const REAL_VPM_3CYCLE=[0n,28404n,28428n,28440n,28416n,28428n];
function recorded(seq) {
  const next=new Map(); for(let i=0;i+1<seq.length;i++) next.set(seq[i],seq[i+1]);
  for(let n=0;n<4000;n++) {
    const base={...op('VPM'),callData:'0x'+'11'.repeat(n)};
    // The rule counts the op's own preVerificationGas word, so the all-nonzero-signature value depends on v.
    const zerosFor=(v,t)=>{const top=p.measurePVG({...base,preVerificationGas:v,signature:signature(0)},address).value;
      return (top-t)%12n===0n && t<=top && (top-t)/12n<=65n ? Number((top-t)/12n) : null;};
    if([...next].some(([v,t])=>zerosFor(v,t)===null)) continue;
    const sign=async v=>({packed:{...base,preVerificationGas:v,signature:signature(zerosFor(v,next.get(v)))}});
    const lengths=Object.fromEntries(['initCode','callData','paymasterAndData','signature'].map(k=>[k,(base[k].length-2)/2]));
    return {sign,next,plan:{lengths,reserve:p.reservePVG(lengths)}};
  }
  throw Error('no synthetic op reproduces the recorded sequence');
}
test('real OP Sepolia VPM 3-cycle: resolved at 28440 with surplus 24',async()=>{
  const {sign,next,plan}=recorded(REAL_VPM_3CYCLE);
  for(const [from,to] of next) assert.equal(p.measurePVG((await sign(from)).packed,address).value,to);
  const result=await p.finalizePVG(sign,address,plan);
  assert.equal(result.pvg.value,28440n);
  assert.equal(result.pvg.ruleValue,28416n);
  assert.equal(result.pvg.surplus,24n);
  assert.deepEqual(result.pvg.cycle,['28428','28440','28416']);
  const row={}; p.recordPVG(row,result.pvg,input(result.packed));
  assert.equal(row.pvgSurplus,24n); assert.equal(row.pvgSurplusReason,'cycle-max'); assert.equal(row.pvgConsistency,row.pvgSurplus);
});
test('PVG_SIGNED_CYCLE_LENGTH no longer exists',()=>{
  assert.equal(readFileSync(new URL('./pvg.mjs',import.meta.url),'utf8').includes('PVG_SIGNED_CYCLE_LENGTH'),false);
});
test('PVG row schema includes surplus and reason even before signing',()=>{
  const row=p.nullPVGColumns();
  assert.equal(row.pvgSurplus,null);
  assert.equal(row.pvgSurplusReason,null);
});
test('named surplus bound is four zero-byte flips',()=>assert.equal(p.PVG_MAX_SURPLUS,48n));

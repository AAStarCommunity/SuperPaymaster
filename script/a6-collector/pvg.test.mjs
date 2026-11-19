import test from 'node:test';
import assert from 'node:assert/strict';
import { encodeFunctionData, parseAbi } from 'viem';
const abi=parseAbi(['function handleOps((address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature)[] ops,address beneficiary)']);
const address='0x'+'11'.repeat(20), word='0x'+'00'.repeat(32);
const op=(arm='TPM')=>({sender:address,nonce:0n,initCode:'0x',callData:'0x00',accountGasLimits:word,preVerificationGas:0n,gasFees:word,paymasterAndData:'0x'+'11'.repeat({SP:125,VPM:181,TPM:52}[arm]),signature:'0x'+'ff'.repeat(65)});
const input=o=>encodeFunctionData({abi,functionName:'handleOps',args:[[o],address]});
const cost=hex=>BigInt(Buffer.from(hex.slice(2),'hex').reduce((n,b)=>n+(b===0?4:16),0));
test('shared PVG fixed point includes its own word and is independent of gasFactor',async()=>{
 const {computePVG}=await import('./pvg.mjs');
 for(const arm of ['SP','VPM','TPM']) {
  const values=[1,1.5,2].map(gasFactor=>computePVG(op(arm),address,{gasFactor}));
  assert.deepEqual(values[0],values[1]); assert.deepEqual(values[1],values[2]);
  const r=values[0];
  assert.equal(r.value,21000n+cost(input({...op(arm),preVerificationGas:r.value})));
  assert.notEqual(r.value,21000n+cost(input(op(arm))));
  assert.equal(r.bytes.total,r.bytes.zero+r.bytes.nonZero);
  assert.equal(r.value,r.calldataGas+r.overhead.transaction+r.overhead.handleOps);
 }
});
test('zero to nonzero op byte adds 12 gas',async()=>{
 const {computePVG}=await import('./pvg.mjs');
 assert.equal(computePVG({...op(),callData:'0x01'},address).value-computePVG(op(),address).value,12n);
});
test('signed exact bytes converge and data row records rule and real transaction delta',async()=>{
 const {finalizePVG,recordPVG}=await import('./pvg.mjs');
 const result=await finalizePVG(async value=>({packed:{...op('VPM'),preVerificationGas:value}}),address);
 const row={gasSources:{call:{limit:123}}};
 recordPVG(row,result.pvg,input(result.packed));
 assert.deepEqual(row.gasSources.preVerification,result.pvg);
 assert.equal(row.pvgDelta,result.pvg.value-cost(input(result.packed)));
 assert.deepEqual(row.gasSources.call,{limit:123});
 assert.equal(result.pvg.factor.numerator,1);
});
test('signature dependent PVG cycle refuses to send',async()=>{
 const {finalizePVG}=await import('./pvg.mjs');
 await assert.rejects(finalizePVG(async value=>({packed:{...op(),preVerificationGas:value+1n}}),address),/PVG/);
});
test('receipt L1 data fee is separate from PVG and absent evidence stays null',async()=>{
 const {computePVG,recordPVG}=await import('./pvg.mjs');
 const r=computePVG(op(),address), row={};
 recordPVG(row,r);
 assert.equal(row.pvgDelta,null);
 assert.equal(row.l1DataFee,null);
 recordPVG(row,r,input({...op(),preVerificationGas:r.value}),{l1Fee:123456n});
 assert.equal(row.l1DataFee,123456n);
 assert.equal(row.gasSources.preVerification.value,r.value);
});

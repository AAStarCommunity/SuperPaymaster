import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {encodeFunctionData,parseAbi} from 'viem';
import * as p from './pvg.mjs';
import {syntheticTrace} from './gas-decomposition.test.mjs';
const abi=parseAbi(['function handleOps((address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature)[] ops,address beneficiary)']);
const address='0x'+'ff'.repeat(20), word='0x'+'ff'.repeat(32);
const op={sender:address,nonce:BigInt(word),initCode:'0x',callData:'0x'+'ff'.repeat(228),accountGasLimits:word,preVerificationGas:BigInt(word),gasFees:word,paymasterAndData:'0x'+'ff'.repeat(125),signature:'0x'+'ff'.repeat(65)};
const input=o=>encodeFunctionData({abi,functionName:'handleOps',args:[[o],address]});
const lengths={initCode:0,callData:228,paymasterAndData:125,signature:65};
test('R2 tight reserve agrees with Python and raw rule for every arm',()=>{
 const bundle=JSON.parse(execFileSync('python3',['-B','script/a6-collector/frozen-fixture.py']));
 for(const pc of Object.values(bundle.plans).map(p=>p.phaseC)) for(const arm of ['SP','VPM','TPM']) {
  const fixed=pc.pvgLengths[arm];
  const o={...op,...Object.fromEntries(Object.entries(fixed).map(([k,n])=>[k,'0x'+'ff'.repeat(n)]))};
  assert.equal(p.measurePVG(o,address).value,BigInt(pc.pvgReserve[arm]));
  assert.equal(p.reservePVG(fixed),BigInt(pc.pvgReserve[arm]));
 }
});
test('R2 signing rejects each changed dynamic length and reserve overflow',async()=>{
 for(const field of Object.keys(lengths)) {
  await assert.rejects(p.finalizePVG(async value=>({packed:{...op,preVerificationGas:value,[field]:op[field]+'ff'}}),address,{lengths,reserve:999999n}),/PVG_LENGTHS/);
 }
 await assert.rejects(p.finalizePVG(async value=>({packed:{...op,preVerificationGas:value}}),address,{lengths,reserve:1n}),/PVG_RESERVE/);
});
test('R2 consistency floor prices net gas and unique penalty',()=>{
 const {row,uoe}=syntheticTrace();
 const r=p.computePVG(op,address), data=input({...op,preVerificationGas:r.value});
 const bytes=Buffer.from(data.slice(2),'hex'), floor=21000n+10n*BigInt([...bytes].reduce((a,b)=>a+(b?4:1),0));
 p.recordPVG(row,r,data,{gasUsed:floor,effectiveGasPrice:7n,l1Fee:123n},{...uoe,actualGasCost:BigInt(uoe.actualGasUsed)*3n});
 assert.equal(row.pvgConsistency,0n); assert.equal(row.calldataFloorBinding,true);
 assert.equal(row.calldataFloorGas,floor); assert.equal(row.outerGasUsed,floor);
 assert.equal(row.unusedGasPenalty,19n); assert.equal(row.bundlerNetGas,1124n-floor);
 assert.equal(row.bundlerNetGasExPenalty,1105n-floor);
 assert.equal(row.opGasPrice,3n); assert.equal(row.outerEffectiveGasPrice,7n); assert.equal(row.l1DataFee,123n);
 assert.equal('pvgDelta' in row,false);
 assert.throws(()=>p.recordPVG({},r,data+'ff',{gasUsed:floor}),/PVG_CONSISTENCY/);
});
test('R2 missing ambiguous and mismatched traces never guess penalty',()=>{
 for(const kind of ['missing','ambiguous','mismatch','claim']) {
  const {row,uoe}=syntheticTrace({execution:kind==='ambiguous'?100n:105n});
  if(kind==='missing') delete row.gasTrace;
  if(kind==='mismatch') row.gasTrace.blockHash='0x00';
  if(kind==='claim') row.gasDecomposition={status:'exact',unusedGasPenalty:'999'};
  const r=p.computePVG(op,address);
  p.recordPVG(row,r,input({...op,preVerificationGas:r.value}),{gasUsed:1000n,effectiveGasPrice:2n},uoe);
  assert.equal(row.unusedGasPenalty,null); assert.equal(row.bundlerNetGasExPenalty,null);
  assert.ok(row.unusedGasPenaltyReason);
  if(['mismatch','claim'].includes(kind)) assert.equal(row.gasDecomposition.status,'mismatch');
 }
});
test('R2 NOT_SENT has null measured columns',()=>{
 const row={}; p.recordPVG(row,p.computePVG(op,address));
 for(const k of ['pvgConsistency','bundlerNetGas','unusedGasPenalty','bundlerNetGasExPenalty','opGasPrice','outerEffectiveGasPrice','calldataFloorBinding','calldataFloorGas','outerGasUsed','l1DataFee']) assert.equal(row[k],null,k);
});

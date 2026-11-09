import test from 'node:test';
import assert from 'node:assert/strict';
import { extract, spFormula } from './extract.mjs';
import { encodeAbiParameters } from 'viem';
import { fixture, address } from './fixtures.mjs';

test('raw trace cPre and preOpGas; G stays empty rather than inverse estimation',()=>{
  const row=extract(fixture());
  assert.equal(row.cPreWei,3000004n);
  assert.equal(row.preOpGas,100000n);
  assert.equal(row.gasBeforePenalty,null);
  assert.equal(row.contextLength,384);
  assert.equal(row.feeBps,250n);
  assert.equal(row.gBufGas,200000n);
  assert.equal(row.bufWei,1806007n);
  assert.equal(row.chargeAPNTs,row.chargeHatAPNTs);
});
test('SP source rounding example uses two ceilings; legacy uses live fee and postOp limit',()=>{
  // Hand calculation: ceil((3 + (2 + ceil(11/10))*7)*1/3)=11;
  // ceil(11*10250/10000)=12. Cap 10 -> 10.
  const ceil=(n,d)=>(n+d-1n)/d;
  assert.equal(ceil((3n+(2n+ceil(11n,10n))*7n),3n),11n);
  const row=extract(fixture(0,'SP',true));
  assert.equal(row.contextLength,352);
  assert.equal(row.gBufGas,510000n);
  assert.equal(row.bufWei,3976007n);
  assert.equal(row.C_POSTOP,null);
  assert.throws(()=>spFormula(fixture(0,'SP',true).validationContext,1n,1n),/live fee/);
  // Independent literal result checked with integer arithmetic from source.
  assert.equal(extract(fixture()).chargeHatAPNTs,32841075057360621853n);
});
test('TPM integer conversion uses updated pre-markup cached price',()=>{
  const row=extract(fixture(0,'TokenPaymaster'));
  assert.equal(row.refundPostopCost,40000n);
  assert.equal(row.actualTokenNeeded,1202668n);
  assert.equal(row.tokenChargeWei,3608004n);
  const a=fixture(0,'TokenPaymaster'); a.state.postOpCachedPrice='1';
  assert.throws(()=>extract(a),/price mismatch/);
});
test('refusal, timeout and unavailable trace retain rows with empty evidence',()=>{
  const a=fixture(); a.metadata.precheck_refused=true;
  assert.throws(()=>extract(a),/broadcast evidence/);
  delete a.receipt; delete a.trace; delete a.validationContext;
  assert.equal(extract(a).cPreWei,null);
  a.metadata.precheck_refused=false;
  assert.equal(extract(a).failure_reason,'receipt_timeout');
  const b=fixture(); delete b.trace;
  assert.equal(extract(b).cPreWei,null);
});
test('bindings, changed context and wrong event charge fail closed',()=>{
  for(const mutate of [a=>a.trace.blockHash='0x00',a=>a.operation.nonce='1',
    a=>a.validationContext='0x',a=>a.receipt.logs[2].data='0x'+'0'.repeat(128)]) {
    const a=fixture(); mutate(a); assert.throws(()=>extract(a));
  }
});

test('real transfer task rejects wrong amount and missing Transfer log',()=>{
  const a=fixture(); a.task.amount='18'; assert.throws(()=>extract(a),/calldata mismatch/);
  const b=fixture(); b.receipt.logs.splice(1,1); assert.throws(()=>extract(b),/Transfer event/);
});

test('small source-formula vector distinguishes nested ceilings and cap',()=>{
  const types=['address','address','uint256','bytes32','address','uint8','uint128','uint128','int256','uint8','uint256','uint256'];
  const context=encodeAbiParameters(types.map(type=>({type})),
    [address(1),address(2),10n,'0x'+'11'.repeat(32),address(3),1,5n,6n,1n,18,3n,
      (1n<<96n)|(1n<<64n)|(251n<<128n)]);
  const result=spFormula(context,3n,7n);
  assert.equal(result.aGas,11n);
  assert.equal(result.chargeHatAPNTs,12n);
  assert.equal(result.expectedChargeAPNTs,10n);
});

test('settlement is required with or without a trace; VPM needs none',()=>{
  for (const arm of ['SP','TokenPaymaster']) for (const traced of [true,false]) {
    const a=fixture(0,arm);
    if (!traced) delete a.trace;
    assert.equal(extract(a).success,true);
    a.receipt.logs.pop();
    const row=extract(a);
    assert.equal(row.success,false);
    assert.equal(row.failure_reason,'missing_settlement_event');
    for (const field of ['chargeAPNTs','actualTokenNeeded','tokenChargeWei']) assert.equal(row[field],null);
  }
  const vpm=fixture(0,'VerifyingPaymaster'); delete vpm.trace;
  assert.equal(extract(vpm).success,true);
});
test('receipt settlement binds paymaster and sender and must be unique',()=>{
  for (const arm of ['SP','TokenPaymaster']) {
    const a=fixture(0,arm); delete a.trace;
    a.receipt.logs.push(a.receipt.logs[2]);
    assert.throws(()=>extract(a),/ambiguous settlement/);
    a.receipt.logs.pop();
    a.receipt.logs[2].address=address(99);
    assert.equal(extract(a).success,false);
    a.receipt.logs[2]=fixture(1,arm).receipt.logs[2];
    assert.throws(()=>extract(a),/settlement operation mismatch/);
    const b=fixture(0,arm); delete b.trace; b.receipt.status='0x0';
    assert.equal(extract(b).success,false);
  }
});

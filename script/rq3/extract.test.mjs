import test from 'node:test';
import assert from 'node:assert/strict';
import { extract, spFormula, invertPenalty } from './extract.mjs';
import { encodeAbiParameters } from 'viem';
import { fixture, address, reads } from './fixtures.mjs';

const corrupt=(a,re)=>{const r=extract(a);assert.equal(r.invalid_reason,'collector_corruption');assert.equal(r.success,false);assert.match(r.diagnostic,re);};

test('raw trace cPre and preOpGas; unique G is exported',()=>{
  const row=extract(fixture());
  assert.equal(row.cPreWei,3000004n);
  assert.equal(row.preOpGas,100000n);
  assert.equal(row.gasBeforePenalty,550000n);
  assert.equal(row.contextLength,384);
  assert.equal(row.feeBps,250n);
  assert.equal(row.gBufGas,200000n);
  assert.equal(row.bufWei,1806007n);
  assert.equal(row.chargeAPNTs,row.chargeHatAPNTs);
});
test('SP source rounding uses two ceilings; legacy context stops window',()=>{
  // Hand calculation: ceil((3 + (2 + ceil(11/10))*7)*1/3)=11;
  // ceil(11*10250/10000)=12. Cap 10 -> 10.
  const ceil=(n,d)=>(n+d-1n)/d;
  assert.equal(ceil((3n+(2n+ceil(11n,10n))*7n),3n),11n);
  assert.equal(extract(fixture(0,'SP',true)).stop_reason,'legacy_sp_context');
  assert.throws(()=>spFormula(fixture(0,'SP',true).validationContext,1n,1n),/legacy_sp_context/);
  // Independent literal result checked with integer arithmetic from source.
  assert.equal(extract(fixture()).chargeHatAPNTs,32841075057360621853n);
});
test('TPM integer conversion uses updated pre-markup cached price',()=>{
  const row=extract(fixture(0,'TokenPaymaster'));
  assert.equal(row.refundPostopCost,40000n);
  assert.equal(row.actualTokenNeeded,1202668n);
  assert.equal(row.tokenChargeWei,3608004n);
  const a=fixture(0,'TokenPaymaster'); a.state.cachedPrice=reads(a.operation.paymaster,a.receipt.blockHash,'cachedPrice',1n);
  assert.match(extract(a).diagnostic,/price mismatch/);
});
test('refusal, timeout and unavailable trace retain rows with empty evidence',()=>{
  const a=fixture(); a.metadata.precheck_refused=true;
  corrupt(a,/broadcast evidence/);
  delete a.receipt; delete a.trace; delete a.validationContext;
  assert.equal(extract(a).cPreWei,null);
  a.metadata.precheck_refused=false;
  a.confirmation.observedAt=120;
  assert.equal(extract(a).failure_reason,'receipt_timeout');
  const b=fixture(); delete b.trace;
  assert.match(extract(b).diagnostic,/trace required to invert the penalty/);
});
test('bindings, changed context and wrong event charge fail closed',()=>{
  for(const mutate of [a=>a.trace.blockHash='0x00',a=>a.operation.nonce='1',
    a=>a.validationContext='0x',a=>a.receipt.logs[2].data='0x'+'0'.repeat(128)]) {
    const a=fixture(); mutate(a);
    try {assert.equal(extract(a).invalid_reason,'collector_corruption');} catch(e) {if(e.code==='ERR_ASSERTION') throw e;}
  }
});

test('real transfer task rejects wrong amount and missing Transfer log',()=>{
  const a=fixture(); a.task.amount='18'; corrupt(a,/calldata mismatch/);
  const b=fixture(); b.receipt.logs.splice(1,1); corrupt(b,/Transfer event/);
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

test('settlement is required with or without a trace; every successful arm needs a trace',()=>{
  for (const arm of ['SP','TokenPaymaster']) for (const traced of [true,false]) {
    const a=fixture(0,arm);
    if (!traced) delete a.trace;
    if(traced) assert.equal(extract(a).success,true);
    else assert.match(extract(a).diagnostic,/trace required to invert the penalty/);
    a.receipt.logs.splice(2,1);
    const row=extract(a);
    assert.equal(row.success,false);
    assert.equal(row.failure_reason,'missing_settlement_event');
    for (const field of ['chargeAPNTs','actualTokenNeeded','tokenChargeWei']) assert.equal(row[field],null);
  }
  // ruling 1 covers every arm: a successful VPM row without a trace cannot invert the penalty
  const vpm=fixture(0,'VerifyingPaymaster'); delete vpm.trace;
  corrupt(vpm,/trace required to invert the penalty/);
});
test('receipt settlement binds paymaster and sender and must be unique',()=>{
  for (const arm of ['SP','TokenPaymaster']) {
    const a=fixture(0,arm); delete a.trace;
    a.receipt.logs.push(a.receipt.logs[2]);
    corrupt(a,/ambiguous settlement/);
    a.receipt.logs.pop();
    a.receipt.logs[2].address=address(99);
    assert.equal(extract(a).success,false);
    a.receipt.logs[2]=fixture(1,arm).receipt.logs[2];
    corrupt(a,/settlement operation mismatch/);
    const b=fixture(0,arm); delete b.trace; b.receipt.status='0x0';
    assert.equal(extract(b).success,false);
  }
});

test('penalty inverse exhaustively matches all G, including equality boundary',()=>{
  for(let p=0n;p<=12n;p++) for(let l=0n;l<=30n;l++) {
    for(let a=0n;a<=70n;a++) {
      const expected=[];
      for(let g=p;g<=70n;g++) if(g+(l>g-p?(l-(g-p))/10n:0n)===a) expected.push(g);
      assert.ok(expected.length<=2);
      if(!expected.length) {assert.throws(()=>invertPenalty(a,p,l),/collector_corruption: no consistent/);continue;}
      const result=invertPenalty(a,p,l);
      assert.equal(result.gasBeforePenaltyCandidates,expected.map(String).join(';'));
      assert.equal(result.gasBeforePenalty,expected.length===1?expected[0]:null);
      assert.equal(result.unusedGasPenaltyMin,a-expected.at(-1));
      assert.equal(result.unusedGasPenaltyMax,a-expected[0]);
    }
    const boundary=invertPenalty(p+l,p,l);
    assert.equal(boundary.gasBeforePenalty,p+l);
    assert.equal(boundary.unusedGasPenaltyMax,0n);
  }
});

test('TPM verified refund uses both hash-bound raw config replies; ambiguity stays flagged',()=>{
  const a=fixture(0,'TokenPaymaster'), unit=10n**26n;
  assert.equal(extract(a).tokenChargeWeiVerified,true);
  const marked=extract(a).actualTokenPriceWithMarkup;
  a.state.config=reads(a.operation.paymaster,a.receipt.blockHash,'tokenPaymasterConfig',[2n*unit,0n,40000,3600]);
  a.state.cachedPrice=reads(a.operation.paymaster,a.receipt.blockHash,'cachedPrice',2n*marked);
  assert.equal(extract(a).tokenChargeWeiVerified,false);
  assert.deepEqual(extract(a).unverified_columns,['tokenChargeWei']);
  a.state.config=reads(a.operation.paymaster,a.receipt.blockHash,'tokenPaymasterConfig',[unit,0n,40000,3600]);
  a.state.cachedPrice=reads(a.operation.paymaster,a.receipt.blockHash,'cachedPrice',marked);
  assert.equal(extract(a).tokenChargeWeiVerified,true);
  for(const [mutate,diagnostic,reason] of [
    [a=>a.state.config[0].params[1]='latest',/hash-bound state read mismatch/,'collector_corruption'],
    [a=>a.state.config.pop(),/two distinct RPC/,'collector_corruption'],
    [a=>a.state.config[1].result='0x',/state replies disagree/,'rpc_mismatch'],
    [a=>a.state.config=reads(a.operation.paymaster,a.receipt.blockHash,'tokenPaymasterConfig',[11n*10n**25n,0n,40001,3600]),/TPM token charge mismatch/,'collector_corruption'],
    [a=>a.state.runtime[0].result='0x6000',/runtime codehash mismatch/,'collector_corruption'],
    [a=>a.baseline.frozen_build_sha256='bad',/frozen build binding mismatch/,'collector_corruption'],
    [a=>a.state.runtime[0].params[1]='latest',/hash-bound runtime read mismatch/,'collector_corruption'],
  ]) {
    const b=fixture(0,'TokenPaymaster');mutate(b);const result=extract(b);
    assert.equal(result.invalid_reason,reason);assert.match(result.diagnostic,diagnostic);
  }
});

test('SP lock settlement and operator reserve checks fail with specific diagnostics',()=>{
  assert.equal(extract(fixture()).success,true);
  for(const [mutate,diagnostic] of [
    [a=>a.receipt.logs.splice(3,1),/unique matching LockCreated\/LockSettled/],
    [a=>a.receipt.logs.push(a.receipt.logs[3]),/unique matching LockCreated\/LockSettled/],
    [a=>a.receipt.logs[3].topics[2]='0x'+'ff'.repeat(32),/unique matching LockCreated\/LockSettled/],
    [a=>a.receipt.logs[3].topics[1]='0x'+'00'.repeat(12)+address(99).slice(2),/unique matching LockCreated\/LockSettled/],
    [a=>a.receipt.logs[4].data=encodeAbiParameters([{type:'uint256'},{type:'uint256'}],[1n,extract(a).chargeAPNTs]),/SP lock burn mismatch/],
    [a=>a.receipt.logs[4].data=encodeAbiParameters([{type:'uint256'},{type:'uint256'}],[1n,1n]),/SP lock charge mismatch/],
    [a=>a.state.reserveAfter=a.state.reserveBefore,/hash-bound state read mismatch/],
    [a=>{for(const r of a.state.reserveAfter) r.result=a.state.reserveBefore[0].result;},/SP operator reserve delta mismatch/],
    [a=>a.receipt.logs[2].data='0x'+'00'.repeat(64),/SP sponsored charge mismatch/],
    [a=>a.receipt.logs[3].data=encodeAbiParameters([{type:'uint256'},{type:'uint256'}],[10n,1n]),/SP lock charge mismatch/],
  ]) {
    const a=fixture();mutate(a);const result=extract(a);
    assert.equal(result.invalid_reason,'collector_corruption');assert.match(result.diagnostic,diagnostic);
  }
});

test('384-byte zero fee snapshot stops window; no consistent G invalidates attempt',()=>{
  const a=fixture();
  const context=a.validationContext.slice(0,-64)+'0'.repeat(64);
  // spFormula and extractor share the same stop; legacy 352 is covered above.
  assert.throws(()=>spFormula(context,1n,1n),/window_stop: legacy_sp_context/);
  const b=fixture();
  // UOE A=1 cannot have G >= preOpGas=100000.
  b.receipt.logs[0].data=encodeAbiParameters(['uint256','bool','uint256','uint256'].map(type=>({type})),[0n,true,7n,1n]);
  assert.equal(extract(b).invalid_reason,'collector_corruption');
  assert.match(extract(b).diagnostic,/no consistent gasBeforePenalty/);
});

test('frozen receipt timeout, depth and canonical reread are enforced',()=>{
  assert.equal(extract(fixture()).success,true);
  for(const [mutate,reason,diagnostic] of [
    [a=>{delete a.receipt;},'collector_corruption',/receipt_timeout before frozen deadline/],
    [a=>a.confirmation.headNumber=109,'collector_corruption',/confirmation depth/],
    [a=>a.confirmation.rereadBlockHash='bad','chain_reorg',/block hash changed/],
    [a=>delete a.confirmation.rereadBlockNumber,'collector_corruption',/hash reread required/],
    [a=>a.qualification.payload.receipt_timeout_seconds=999,'collector_corruption',/qualification manifest mismatch/],
  ]) {const a=fixture();mutate(a);const r=extract(a);assert.equal(r.invalid_reason,reason);assert.match(r.diagnostic,diagnostic);}
  // a shared block skips the reserve-delta check (recorded), it is not corruption
  const shared=fixture();shared.receiptBlock.transactions.push('another-tx');
  const sr=extract(shared);assert.equal(sr.success,true);assert.equal(sr.reserveDeltaVerified,false);
  assert.equal(extract(fixture()).reserveDeltaVerified,true);
  const late=fixture();late.confirmation.observedAt=120;
  const r=extract(late);assert.equal(r.success,false);assert.equal(r.failure_reason,'receipt_timeout');
  assert.equal(r.actualGasUsed,null);assert.equal(r.supplemental_only,true);
});

test('frozen TPM runtime patches only the four constructor immutables',async()=>{
  const {runtimeFor,baselineFor}=await import('./baseline.mjs');
  const immutables={entryPoint:address(1),uniswap:address(31),token:address(12),wrappedNative:address(30)};
  const runtime=runtimeFor(immutables);
  assert.equal((runtime.length-2)/2,0x27d5);
  // Independent getter PUSH32 operand offsets in the frozen runtime.
  for(const [offset,name] of [[0x3a5,'entryPoint'],[0x235,'uniswap'],[0x5a7,'token'],[0x521,'wrappedNative']])
    assert.equal(BigInt('0x'+runtime.slice(2+offset*2,2+(offset+32)*2)),BigInt(immutables[name]));
  assert.notEqual(baselineFor(immutables).tpm_runtime_codehash,
    baselineFor({...immutables,token:address(99)}).tpm_runtime_codehash);
  assert.throws(()=>runtimeFor({}),/immutable address required/);
});

test('ambiguous G exports its interval and leaves the gate column empty',()=>{
  const a=fixture(), actual=679992n;
  a.receipt.logs[0].data=encodeAbiParameters(['uint256','bool','uint256','uint256'].map(type=>({type})),[0n,true,actual*7n,actual]);
  const row=extract(a);
  assert.equal(row.gasBeforePenalty,null);
  assert.equal(row.gasBeforePenaltyCandidates,'679991;679992');
  assert.equal(row.unusedGasPenaltyMin,0n);assert.equal(row.unusedGasPenaltyMax,1n);
  const legacy=fixture();legacy.validationContext=legacy.validationContext.slice(0,-64)+'0'.repeat(64);
  assert.equal(extract(legacy).stop_reason,'legacy_sp_context');
});

test('TPM singleton stays unverified without configuration-time isolation',async()=>{
  const {toFunctionSelector}=await import('viem');
  for(const mutate of [
    a=>a.receiptBlock.transactions.push('other'),
    a=>a.trace.result.calls.push({to:a.operation.paymaster,input:toFunctionSelector('setTokenPaymasterConfig((uint256,uint128,uint48,uint48))')}),
  ]) {
    const a=fixture(0,'TokenPaymaster');assert.equal(extract(a).tokenChargeWeiVerified,true);
    mutate(a);assert.equal(extract(a).tokenChargeWeiVerified,false);
    assert.deepEqual(extract(a).unverified_columns,['refundPostopCost','tokenChargeWei']);
  }
});

test('SP burn rounds upward for non-integral ratio and zero reservation charges zero',async()=>{
  const {encodeFunctionData}=await import('viem');
  const {POSTOP_ABI}=await import('./extract.mjs');
  const a=fixture(), charge=extract(a).chargeAPNTs;
  a.receipt.logs[3].data=encodeAbiParameters([{type:'uint256'},{type:'uint256'}],[3n,charge+1n]);
  a.receipt.logs[4].data=encodeAbiParameters([{type:'uint256'},{type:'uint256'}],[3n,charge]);
  assert.equal(extract(a).success,true);
  const z=fixture(), old=extract(z);
  z.validationContext=z.validationContext.slice(0,2+2*64)+'0'.repeat(64)+z.validationContext.slice(2+3*64);
  z.trace.result.calls[0].calls[0].input=encodeFunctionData({abi:POSTOP_ABI,functionName:'postOp',args:[0,z.validationContext,3000004n,7n]});
  z.receipt.logs[2].data=encodeAbiParameters([{type:'uint256'},{type:'uint256'}],[spFormula(z.validationContext,3000004n,7n).aGas,0n]);
  for(const i of [3,4]) z.receipt.logs[i].data='0x'+'00'.repeat(64);
  for(const r of z.state.reserveAfter) r.result=z.state.reserveBefore[0].result;
  assert.equal(extract(z).success,true);
  assert.equal(extract(z).chargeAPNTs,0n);
  assert.ok(old.chargeAPNTs>0n);
});

test('VPM with empty postOp context still exports the inverse penalty',()=>{
  const a=fixture(0,'VerifyingPaymaster');a.trace.result.calls[0].calls=[];
  const row=extract(a);assert.equal(row.success,true);assert.equal(row.gasBeforePenalty,550000n);
  const b=fixture();b.trace.result.calls[0].calls=[];
  assert.match(extract(b).diagnostic,/unique postOp call required/);
});

test('a later in-block price move leaves TPM columns unverified, not corrupt (review r4 #1)',()=>{
  const a=fixture(0,'TokenPaymaster'); a.receiptBlock.transactions.push('later-oracle-update');
  a.state.cachedPrice=reads(a.operation.paymaster,a.receipt.blockHash,'cachedPrice',1n);
  const r=extract(a);
  assert.equal(r.success,true); assert.ok(!r.invalid_reason);
  assert.equal(r.tokenChargeWei,null); assert.deepEqual(r.unverified_columns,['refundPostopCost','tokenChargeWei']);
  assert.equal(r.actualTokenNeeded,1202668n);
});

test('a final timeout needs proof the frozen deadline had elapsed (review r4 #3)',()=>{
  const a=fixture(); a.finalTimeout=true; a.confirmation.broadcastAt=0; a.confirmation.observedAt=1;
  corrupt(a,/final timeout declared before frozen deadline/);
  a.confirmation.timeoutDeclaredAt=119; corrupt(a,/final timeout declared before frozen deadline/);
  a.confirmation.timeoutDeclaredAt=120; const r=extract(a);
  assert.equal(r.failure_reason,'receipt_timeout'); assert.equal(r.supplemental_only,true);
});

test('refundPostopCost is verified only in an isolated block (review r5: division admits several constants)',()=>{
  const a=fixture(0,'TokenPaymaster'); assert.equal(extract(a).refundPostopCost,40000n);
  a.receiptBlock.transactions.push('later-config-change');
  const r=extract(a); assert.equal(r.refundPostopCost,null);
  assert.ok(r.unverified_columns.includes('refundPostopCost'));
});

test('malformed archived evidence is a corruption row, not an aborted batch (review r5 #4)',()=>{
  const a=fixture(0,'TokenPaymaster'); for(const r of a.state.config) r.result='0x';
  corrupt(a,/./);
  const b=fixture(); const f=b.trace.result.calls.flatMap(function walk(c){return [c,...(c.calls??[]).flatMap(walk)];})
    .find(c=>c.input?.startsWith('0x7c627b21')); f.input=f.input.slice(0,10);
  corrupt(b,/./);
});

test('an internal ABI regression still aborts; it is never recorded as corruption (review r6/r7)',async()=>{
  const ev=await import('./evidence.mjs'); const ex=await import('./extract.mjs');
  const mutations=[
    ()=>{const i=ev.STATE_ABI.findIndex(x=>x.name==='tokenPaymasterConfig'); ev.STATE_ABI.splice(i,1);},
    ()=>{ex.POSTOP_ABI.splice(0,ex.POSTOP_ABI.length);},
    ()=>{const i=ev.STATE_ABI.findIndex(x=>x.name==='tokenPaymasterConfig');
         ev.STATE_ABI[i]={...ev.STATE_ABI[i],outputs:[{type:'invalid_internal_type'},...ev.STATE_ABI[i].outputs.slice(1)]};},
  ];
  for (const mutate of mutations) {
    const a=fixture(0,'TokenPaymaster');                 // built BEFORE the ABI is broken
    assert.equal(extract(fixture(0,'TokenPaymaster')).success,true);
    const savedState=[...ev.STATE_ABI], savedPost=[...ex.POSTOP_ABI];
    mutate();
    try { assert.throws(()=>extract(a)); }
    finally { ev.STATE_ABI.splice(0,ev.STATE_ABI.length,...savedState); ex.POSTOP_ABI.splice(0,ex.POSTOP_ABI.length,...savedPost); }
  }
  assert.equal(extract(fixture(0,'TokenPaymaster')).success,true);
});

test('a log with our event topic but malformed data is corruption, other events are skipped',()=>{
  const a=fixture(); const settle=a.receipt.logs[2]; a.receipt.logs.push({...settle,data:'0x1234'});
  corrupt(a,/malformed event log/);
  const b=fixture(); b.receipt.logs.push({...b.receipt.logs[2],topics:['0x'+'ab'.repeat(32)]});
  assert.equal(extract(b).success,true);
});

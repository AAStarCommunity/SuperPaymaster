import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { runInNewContext } from 'node:vm';
import { getAddress, keccak256 } from 'viem';
import { aggregateWindows } from './aggregate-windows.mjs';
import { stringify } from './evidence.mjs';
import { validateRun } from './validate.mjs';
import { accumulateSlotWait, waitForSlot } from './window-schedule.mjs';

const script = 'script/a6-collector/collector.mjs';
const src = readFileSync(script,'utf8');
const between = (a,b) => src.slice(src.indexOf(a),src.indexOf(b,src.indexOf(a)));
const helpers = src.slice(src.indexOf('function firstUsePlans()'));
const attempt = between('async function attempt(', 'async function attemptInner(');
const readAB = between('async function readAB(', 'async function rawCall(');
const stop = between('class Stop extends Error', '// ── A/B read-backs');
const signGuard = between('  if (firstUse) {\n    const block = await runtime.refreshPin();', '  packed.signature = await');
const receiptGuard = between('  if (firstUse) {\n    if (blk.hash', '  const rawTx = await readAB');
const first = '0x'+'22'.repeat(20), skipped = '0x'+'33'.repeat(20), second = '0x'+'11'.repeat(20);
const senderConfigs = [first,skipped,second].map(sender=>({sender,accounts:{owner:{address:sender}}}));
const block = {number:10n,timestamp:100n,hash:'0x'+'55'.repeat(32)};
const signed = '0x01';

async function run(options={}) {
  const reads=[], sends=[], rows=[], messages=[];
  let pendingChecks=0;
  const pending = options.pending ?? new Map();
  // sender -> key-0 EntryPoint nonce ops already included (warm-up before this run via
  // options.presend, plus ops sent in this run)
  const sent = new Map(Object.entries(options.presend ?? {}).map(([k,v])=>[k,BigInt(v)]));
  let head=block;
  const client=endpoint=>({
    getBlock:async()=>head,
    readContract:async({functionName,args,blockNumber})=>{
      if (functionName==='operators') return [0,0,0,0,0,options.interval??0n];
      if (functionName==='userOpState') return [options.lastTimestamp??0n];
      assert.equal(functionName,'getNonce');
      assert.equal(args[1],0n);
      reads.push([endpoint,args[0],blockNumber]);
      if (blockNumber>block.number) { // inclusion block: nonce = ops included so far
        const after = options.inclusionNonce ?? sent.get(args[0]) ?? 1n;
        return endpoint==='B'&&options.inclusionDisagreement?2n:after;
      }
      if (args[0]===skipped) return endpoint==='B'&&options.disagree?2n:3n;
      if (options.none) return 3n;
      if (options.changed && reads.length>6) return 1n;
      if (options.changedAfter && reads.length>options.changedAfter) return 9n;
      return sent.get(args[0]) ?? 0n;
    }
  });
  const pubA=client('A'), pubB=client('B');
  const context={
    senderConfigs, owners:new Map(), formalInput:{chainId:10}, lockRoot:'/locks', resolve, keccak256, runId:'setup', outPath:'/offline/run.jsonl',
    EP:'EP',EP_ABI:[],NONCE_KEY:0n,SPA:'SP',ctx:{account:{address:first}}, pubA,pubB,
    runtime:{pubA,pubB,refreshPin:async()=>head,archives:[],preparePendingNonce:async()=>{pendingChecks++;}},
    frozen:{pmGas:{SP:{post:1n}}},waitForSlot,accumulateSlotWait,getAddress,
    existsSync:path=>pending.has(path),
    openSync:(path,mode)=>{assert.equal(mode,'wx');assert.ok(!pending.has(path));pending.set(path,null);return path;},
    writeSync:(path,value)=>pending.set(path,JSON.parse(value)),fsyncSync(){},closeSync(){},unlinkSync:path=>pending.delete(path),
    jsonable:value=>JSON.parse(stringify(value)),diffPaths:(a,b)=>a===b?[]:['value'],
    argVal:()=>null,writeLine:row=>rows.push(JSON.parse(stringify(row))),console:{log:msg=>messages.push(msg)},
    castSigner:async config=>({...config,type:'local'}),withPasswordSource:config=>config,
    selectSender:sender=>{context.sender=sender;},
    setup:async minimum=>assert.equal(minimum,1n),requirePostGas(){},revalidateAnchors:async()=>{
      if (options.reorg) throw Error('anchor changed');
    },
    passportAB:async()=>({block,invariant:{superPaymaster:{priceStalenessThreshold:options.threshold??100n},
      armEntryPoints:{SP:'0x'+'55'.repeat(20)},credit:{policy:0,pendingPolicyEta:0}},volatile:{cachedPriceUpdatedAt:99n}}),
    VERDICTS:{USEROP_SUCCESS:'USEROP_SUCCESS'}
  };
  context.EP=context.passportEP='0x'+'55'.repeat(20);
  const code = `(async()=>{ ${stop} ${readAB} ${helpers}
    let firstUseGate, activeRow, attemptIndex=0;
    const firstUse=true, window=null, formal=false, fixture=null;
    ${attempt}
    async function attemptInner(arm,idx,_tripletIndex,_passportStart,st) {
      const row=activeRow=st.row;
      await checkFirstUseGate(row);
      ${signGuard}
      if (withheld) {
        writeLine({...row,sent:false,verdict:'NOT_SENT'});
        st.written=true;
        return {verdict:'NOT_SENT'};
      }
      if (moveClock) advanceClock();
      await assertFirstUseFresh(signed);
      sends.push({arm,sender});
      sent.set(sender,(sent.get(sender)??0n)+1n);
      const txHash=row.tx.hash, bn=11n+BigInt(idx), blk={hash:receiptHash};
      const rcA={blockHash:blockMismatch?'other':receiptHash};
      Object.assign(row.tx,{blockNumber:bn,blockHash:rcA.blockHash});
      if (failReceipt) throw Error('receipt unavailable');
      ${receiptGuard}
      writeLine(row);
      st.written=true;
      return {verdict:VERDICTS.USEROP_SUCCESS,conservation:{ok:true}};
    }
    try {await runFirstUse(); return 0;}
    catch (e) {writeLine({kind:'first_use_end',exitCode:e.code??1}); return e.message;}
  })()`;
  const status = await runInNewContext(code,{
    ...context, get sender(){return context.sender;}, signed,sends,sent,moveClock:options.moveClock,
    advanceClock:()=>{head={...head,timestamp:options.moveClock};},
    withheld:options.withheld,
    receiptHash:block.hash,blockMismatch:options.blockMismatch,failReceipt:options.failReceipt
  });
  return {status,reads,sends,rows,messages,pending,pendingChecks};
}

test('first use scans every configured plan sender at one pin and exits cleanly when all are used', async()=>{
  const result=await run({none:true}); // every plan sender at key-0 nonce 3: done, nothing to do
  assert.equal(result.status,0);
  assert.deepEqual(result.messages,['nothing to do']);
  assert.equal(result.pendingChecks,0);
  assert.deepEqual(result.sends,[]);
  assert.deepEqual(result.reads,senderConfigs.flatMap(({sender})=>[['A',sender,10n],['B',sender,10n]]));
});

test('first use resumes a sender at an advanced nonce from the arm the nonce points to',async()=>{
  const result=await run({presend:{[first]:1n,[second]:3n}}); // first: 1 warm-up op included, no marker
  assert.equal(result.status,0);
  assert.deepEqual(JSON.parse(stringify(result.sends)),[{arm:'VPM',sender:first},{arm:'TPM',sender:first}]);
  assert.equal(result.pendingChecks,1);
  assert.equal(result.pending.size,0);
  const attempts=result.rows.filter(row=>row.kind==='first_use_attempt');
  assert.deepEqual(attempts.map(row=>row.arm),['VPM','TPM']);
  assert.deepEqual(attempts[0].nonceBefore,{A:'1',B:'1',blockNumber:'10'});
  assert.deepEqual(attempts[0].nonceAfter,{A:'2',B:'2',blockNumber:'11'});
  assert.deepEqual(attempts[1].nonceBefore,{A:'2',B:'2',blockNumber:'10'});
  assert.deepEqual(attempts[1].nonceAfter,{A:'3',B:'3',blockNumber:'12'});
});

test('first use refuses an unreconciled marker before reading any nonce, even at an advanced nonce',async()=>{
  const marker=resolve('/locks','10',`first-use-${first.toLowerCase()}.json`);
  const pending=new Map([[marker,{sender:first,hash:keccak256(signed)}]]);
  const result=await run({presend:{[first]:1n,[second]:3n},pending});
  assert.equal(result.status,'FIRST_USE_UNRECONCILED');
  assert.deepEqual(result.sends,[]);
  assert.deepEqual(result.reads,[]);
});

test('first use scans all senders before sending and refuses nonce disagreement',async()=>{
  const result=await run({disagree:true});
  assert.equal(result.status,'RPC_DISAGREEMENT');
  assert.deepEqual(result.sends,[]);
});

test('first use submits SP,VPM,TPM per sender in plan order and records their inclusion nonces',async t=>{
  const result=await run();
  assert.equal(result.status,0);
  assert.deepEqual(JSON.parse(stringify(result.sends)),[
    {arm:'SP',sender:first},{arm:'VPM',sender:first},{arm:'TPM',sender:first},
    {arm:'SP',sender:second},{arm:'VPM',sender:second},{arm:'TPM',sender:second}]);
  assert.equal(result.pending.size,0);
  assert.equal(result.pendingChecks,1);
  const attempts=result.rows.filter(row=>row.kind==='first_use_attempt');
  assert.equal(attempts.length,6);
  const nonces=[['0','1'],['1','2'],['2','3'],['0','1'],['1','2'],['2','3']];
  for (const [i,row] of attempts.entries()) {
    assert.equal(row.arm,['SP','VPM','TPM'][i%3]);
    assert.deepEqual(row.nonceBefore,{A:nonces[i][0],B:nonces[i][0],blockNumber:'10'});
    assert.deepEqual(row.nonceAfter,{A:nonces[i][1],B:nonces[i][1],blockNumber:String(11+i)});
    assert.deepEqual(row.tx,{hash:keccak256(signed),blockNumber:String(11+i),blockHash:block.hash});
    for (const field of ['block_slot','pair_id','allocation','tripletIndex','armOrder']) assert.ok(!(field in row));
  }
  const dir=mkdtempSync(join(process.cwd(),'.first-use-fixture-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const path=join(dir,'run.jsonl');
  writeFileSync(path,result.rows.map(stringify).join('\n')+'\n');
  const report=validateRun(path);
  assert.equal(report.accepted,false);
  assert.match(report.missing,/first-use journal cannot be used as window evidence/);
  const aggregate=aggregateWindows([dir],{registered:{windows:1}});
  assert.equal(aggregate.outcome,'INVALID-INTERRUPTED');
  assert.match(aggregate.errors.join('\n'),/first-use journal cannot be used as window evidence/);
});

for (const [name,options,error] of [
  ['the cached price is stale at the pin',{threshold:1n},'FIRST_USE_PRICE_STALE'],
  ['the earliest SP slot reaches price expiry',{lastTimestamp:100n,interval:10n,threshold:11n},'FIRST_USE_PRICE_STALE'],
  ['price expires just before broadcast',{moveClock:200n},'FIRST_USE_PRICE_STALE'],
  ['the independent deadline passes before broadcast',{moveClock:281n,threshold:500n},'FIRST_USE_DEADLINE'],
  ['the SP attempt is withheld',{withheld:true},'FIRST_USE_ATTEMPT_FAILED'],
  ['the earliest SP slot exceeds the independent deadline',{lastTimestamp:100n,interval:181n,threshold:500n},'sp_valid_after_exceeds_slot_deadline'],
  ['the nonce changes before signing',{changed:true},'FIRST_USE_NONCE_CHANGED'],
]) test(`first use refuses when ${name}`,async()=>{
  const result=await run(options);
  assert.equal(result.status,error);
  assert.deepEqual(result.sends,[]);
  if (options.withheld) assert.equal(result.rows.filter(row=>row.kind==='first_use_attempt').length,1);
});

test('first use refuses when a sender nonce moves mid-run',async()=>{
  const result=await run({changedAfter:8});
  assert.equal(result.status,'FIRST_USE_NONCE_CHANGED');
  assert.deepEqual(JSON.parse(stringify(result.sends)),[{arm:'SP',sender:first}]);
  const attempts=result.rows.filter(row=>row.kind==='first_use_attempt');
  assert.equal(attempts.length,2); // the SP op succeeded; the interrupted VPM op still writes its row
  assert.equal(attempts[1].stoppedBy.reason,'FIRST_USE_NONCE_CHANGED');
  assert.equal(attempts[1].arm,'VPM');
});

for (const [options,error] of [
  [{inclusionNonce:0n},'FIRST_USE_NONCE_NOT_ADVANCED'],
  [{inclusionNonce:2n},'FIRST_USE_NONCE_NOT_ADVANCED'],
  [{inclusionDisagreement:true},'RPC_DISAGREEMENT'],
  [{blockMismatch:true},'RECEIPT_BLOCK_MISMATCH'],
  [{failReceipt:true},'receipt unavailable'],
]) test(`first use stops after submission on ${error} and refuses a retry from a fresh journal`,async()=>{
  const failed=await run(options);
  assert.equal(failed.status,error);
  assert.equal(failed.sends.length,1);
  assert.equal([...failed.pending.values()][0].hash,keccak256(signed));
  assert.equal(failed.rows.find(row=>row.kind==='first_use_attempt').tx.hash,keccak256(signed));
  const retry=await run({pending:failed.pending});
  assert.equal(retry.status,'FIRST_USE_UNRECONCILED');
  assert.deepEqual(retry.sends,[]);
});

test('first-use CLI refuses window mode and requires all formal inputs',()=>{
  const invoke=flags=>spawnSync(process.execPath,[script,'--first-use',...flags],{encoding:'utf8'});
  const mixed=invoke(['--window-index']);
  assert.equal(mixed.status,2);
  assert.match(mixed.stderr,/--first-use cannot be combined with --window-index/);
  const missing=invoke([]);
  assert.equal(missing.status,2);
  assert.match(missing.stderr,/--first-use requires --frozen-plan/);
});

test('first use binds exactly the bundle senders in planIndex order',()=>{
  const bind=(plans,configs=senderConfigs,digest='pin')=>runInNewContext(`${helpers}\n[...firstUsePlans().keys()]`,{
    senderConfigs:configs,readFileSync:()=>({plans}),sha256:()=>digest,parse:x=>x,getAddress,
    argVal:()=> 'pin',die:message=>{throw Error(message);},createFrozenPlan:({account})=>({account})
  });
  const plans={[second]:{planIndex:2},[skipped]:{planIndex:1},[first]:{planIndex:0}};
  assert.deepEqual(Array.from(bind(plans)),[first,skipped,second]);
  assert.throws(()=>bind(plans,senderConfigs.slice(1)),/exactly the frozen plan senders/);
  assert.throws(()=>bind({...plans,[first]:{planIndex:1}}),/invalid frozen plan order/);
  assert.throws(()=>bind(plans,senderConfigs,'wrong'),/BUNDLE_DIGEST_MISMATCH/);
});


test('first-use retains all six transaction hashes if final anchor verification fails',async()=>{
  const result=await run({reorg:true});
  assert.equal(result.status,'anchor changed');
  assert.equal(result.sends.length,6);
  assert.equal(result.pending.size,2);
});

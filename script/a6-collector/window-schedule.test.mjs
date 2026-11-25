import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const w = await import('./window-schedule.mjs').catch(e => { if(e.code === 'ERR_MODULE_NOT_FOUND') return {}; throw e; });
const accounts=[200,201,202].map(n=>'0x'+n.toString(16).padStart(40,'0'));
const bytes=execFileSync('python3.11',['-B','script/a6-collector/frozen-fixture.py']);
const mutable=()=>JSON.parse(bytes,(_k,v,c)=>typeof v==='number'&&!Number.isSafeInteger(v)?JSON.rawJSON(c.source):v);
const sha=b=>createHash('sha256').update(b).digest('hex');
const opts={readBundle:()=>bytes,bundleSha256:sha(bytes),seed:'public',chainId:10,accounts};
const manifestFor=windowIndex=>w.createWindow({...opts,windowIndex}).manifest;
test('schedule port preserves sampler payload, digest, permutations and 20 allocations',()=>{
 const s=w.generateSchedule('public 🐈',accounts,10);
 const samplerAccounts=[2,3,4].map(n=>'0x'+n.toString(16).padStart(40,'0'));
 assert.equal(w.generateSchedule('synthetic-public-seed',samplerAccounts,10).sha256,'9f3396cd00c9b34972c1f008ee9fe833ba938b4a43c50d9345bfa060d98c0053');
 const canonical=value=>JSON.stringify(value,(_,v)=>v && !Array.isArray(v) && typeof v==='object'?Object.fromEntries(Object.keys(v).sort().map(k=>[k,v[k]])):v);
 assert.equal(s.sha256,sha(canonical(s.payload)));
 assert.deepEqual(s,w.generateSchedule('public 🐈',accounts,10));
 assert.notEqual(s.sha256,w.generateSchedule('other',accounts,10).sha256);
 for(let i=0;i<60;i+=6) assert.equal(new Set(s.payload.slots.slice(i,i+6).map(x=>x.order.join(','))).size,6);
 assert.equal(s.payload.slot_period_seconds,120);
 assert.equal(s.payload.max_elapsed_seconds,100);
 for(const account of accounts) for(const arm of ['SP','VerifyingPaymaster','TokenPaymaster']) assert.equal(s.payload.slots.filter(x=>x.senders[arm]===account).length,20);
 assert.throws(()=>w.generateSchedule('',accounts,10));
 assert.throws(()=>w.generateSchedule('s',[accounts[0],accounts[0],accounts[2]],10));
 assert.throws(()=>w.generateSchedule('s',accounts,1));
});
test('OP uses 120 s slots and a 100 s elapsed bound on both chains',()=>{
 const op=w.generateSchedule('public 🐈',accounts,10), ops=w.generateSchedule('public 🐈',accounts,11155420), sep=w.generateSchedule('public 🐈',accounts,11155111);
 assert.equal(ops.payload.slot_period_seconds,120);
 assert.equal(ops.payload.max_elapsed_seconds,100);
 assert.equal(sep.payload.slot_period_seconds,130);
 assert.equal(sep.payload.max_elapsed_seconds,120);
 for(const {payload:p} of [op,ops,sep]) {
  assert.ok(p.max_elapsed_seconds<p.slot_period_seconds);
  assert.ok(3*p.slot_period_seconds-p.max_elapsed_seconds>=60);
  for(const [i,slot] of p.slots.entries()) {
   assert.equal(slot.start_seconds,i*p.slot_period_seconds);
   assert.equal(slot.deadline_seconds,slot.start_seconds+p.max_elapsed_seconds);
  }
 }
 const q=chain=>JSON.parse(execFileSync('python3.11',['-I','-B','-c',`import json,sys;sys.path.insert(0,'script/a6-collector');import schedule;print(json.dumps(schedule.qualification('${chain}')))`]));
 const {chain:_a,...opq}=q('op-mainnet').payload, {chain:_b,...opsq}=q('op-sepolia').payload;
 assert.deepEqual(opsq,opq);
 assert.equal(q('op-sepolia').payload.chain,'op-sepolia');
 // The chain name is part of the frozen qualification, so the two OP chains never share a digest.
 assert.notEqual(q('op-sepolia').sha256,q('op-mainnet').sha256);
 assert.notEqual(ops.sha256,op.sha256);
 assert.throws(()=>w.generateSchedule('public 🐈',accounts,11155421));
});
test('window index is required and must be an integer in 1..3',()=>{
 for(const windowIndex of [undefined,null,0,4,1.5,'2',NaN]) {
  assert.throws(()=>w.createWindow({...opts,windowIndex,readBundle:()=>assert.fail('read bundle')}),/WINDOW_INDEX/);
 }
});
test('slice matching derives its size and index range from the registered protocol',()=>{
 const registered=w.REGISTERED_WINDOW;
 assert.deepEqual(registered,{targetTriplets:50,slotCap:60,windowSlots:20,windows:3,
  stoppingRule:w.STOPPING_RULE,warmupAttempts:0,warmup:false});
 const manifest=manifestFor(2);
 assert.ok(w.windowProtocolMatches(manifest,registered));
 for(const patch of [{windowIndex:'2'},{windowIndex:0},{windowIndex:4},{firstSlot:19},{lastSlot:40},{slots:19}]) {
  assert.equal(w.windowProtocolMatches({...manifest,slice:{...manifest.slice,...patch}},registered),false);
 }
 assert.ok(w.windowProtocolMatches({...manifest,slice:{windowIndex:2,firstSlot:30,lastSlot:59,slots:30}},
  {...registered,windows:2,windowSlots:30}));
});
test('window loads three exact plans, records digests, rejects plan.S mismatch',()=>{
 const window=w.createWindow({...opts,windowIndex:1});
 assert.equal(Object.keys(window.manifest.plan_sha256).length,3);
 assert.deepEqual([...window.adapters.values()].map(a=>a.plan.phaseC.attempts),[34,33,33]);
 assert.deepEqual(window.manifest.schedule,w.generateSchedule('public',accounts,10));
 for(const sender of accounts) assert.equal(window.manifest.plan_sha256[sender],window.adapters.get(sender).digest);
 const b=mutable();b.plans[accounts[1]].phaseC.addresses.S=accounts[0];const changed=Buffer.from(JSON.stringify(b));
 assert.throws(()=>w.createWindow({...opts,windowIndex:1,readBundle:()=>changed,bundleSha256:sha(changed)}),/PLAN_S_MISMATCH/);
 assert.throws(()=>w.createWindow({...opts,windowIndex:1,bundleSha256:'0'.repeat(64)}),/BUNDLE_DIGEST_MISMATCH/);
});
function fake({interval=17n,last=100n,times=[110n,115n,117n],disagree=false}={}) {
 let i=0;const reads=[];
 const block=()=>({number:BigInt(i+1),timestamp:times[Math.min(i,times.length-1)],hash:'0x'+String(i).padStart(64,'0')});
 const client={getBlock:async()=>block(),readContract:async args=>{reads.push(args);assert.equal(args.blockNumber,block().number);return args.functionName==='operators'?[0n,true,false,accounts[0],0n,interval]:[last,0n];}};
 return {runtime:{refreshPin:async()=>block(),pubA:client,pubB:disagree?{...client,readContract:async args=>args.functionName==='operators'?[0n,true,false,accounts[0],0n,999n]:[last,false]}:client},sleep:async()=>{i++;},reads};
}
test('SP wait uses both pinned chain values and reaches exact validAfter on fake chain',async()=>{
 const f=fake();const r=await w.waitForSlot({...f,arm:'SP',operator:accounts[0],sender:accounts[1],paymaster:accounts[2],start:110n,deadline:120n});
 assert.equal(r.allowed,true);assert.equal(r.wait.seconds,7n);assert.equal(r.wait.blocks,2n);
 assert.equal(r.wait.lastTimestamp,100n);assert.equal(r.wait.minTxInterval,17n);assert.equal(r.wait.validAfter,117n);
 assert.equal(r.wait.timestamp,117n);assert.ok(f.reads.some(r=>r.functionName==='userOpState'&&r.args[1]===accounts[1]));
});
test('deadline refusal is explicit and never sends or waits past known validAfter deadline',async()=>{
 const f=fake({interval:31n});let sleeps=0;
 const r=await w.waitForSlot({...f,sleep:async()=>{sleeps++;},arm:'SP',operator:accounts[0],sender:accounts[1],paymaster:accounts[2],start:110n,deadline:120n});
 assert.equal(r.allowed,false);assert.equal(r.reason,'sp_valid_after_exceeds_slot_deadline');assert.equal(sleeps,0);
 assert.equal(r.wait.validAfter,131n);
});
test('slot start and deadline apply to baseline arms too; endpoint disagreement stops SP',async()=>{
 const f=fake({times:[100n,110n]}); const r=await w.waitForSlot({...f,arm:'VPM',start:110n,deadline:120n});assert.equal(r.allowed,true);assert.equal(r.wait.seconds,10n);
 const late=await w.waitForSlot({...fake({times:[121n]}),arm:'TPM',start:110n,deadline:120n});assert.equal(late.reason,'slot_deadline_exceeded');
 await assert.rejects(w.waitForSlot({...fake({disagree:true}),arm:'SP',operator:accounts[0],sender:accounts[1],paymaster:accounts[2],start:110n,deadline:120n}),/SCHEDULE_RPC_DISAGREEMENT/);
});

test('window refuses insufficient per-arm budget without requiring a rewritten planner',()=>{
 const b=mutable();b.plans[accounts[1]].phaseC.attempts=19;
 const changed=Buffer.from(JSON.stringify(b));
 assert.throws(()=>w.createWindow({...opts,windowIndex:3,readBundle:()=>changed,bundleSha256:sha(changed)}),/PLAN_WINDOW_BUDGET/);
});
test('SP rechecks a later lastTimestamp and records a stalled chain without submission',async()=>{
 const f=fake({times:[110n,117n,122n]});
 for(const client of new Set([f.runtime.pubA,f.runtime.pubB])) {
 const read=client.readContract;
 client.readContract=async args=>args.functionName==='userOpState' && (await client.getBlock()).timestamp>=117n?[105n,false]:read(args);
 }
 const r=await w.waitForSlot({...f,arm:'SP',operator:accounts[0],sender:accounts[1],paymaster:accounts[2],start:110n,deadline:125n});
 assert.equal(r.wait.validAfter,122n);assert.equal(r.wait.timestamp,122n);assert.equal(r.wait.seconds,12n);
 await assert.rejects(w.waitForSlot({...fake(),arm:'SP',start:110n,deadline:120n,timeoutMs:0}),e=>e.message==='SCHEDULE_CLOCK_STALLED'&&e.wait.validAfter===117n);
});
test('scheduled incomplete slots persist evidence without legacy replacement exclusions',async()=>{
 const {evidenceIndex}=await import('./evidence.mjs');
 for(const reason of ['slot_deadline_exceeded','sp_valid_after_exceeds_slot_deadline','deposit_floor']) {
 const row={kind:'attempt',attemptIndex:0,tripletIndex:0,arm:'SP',sender:accounts[0],sent:false,tx:null,verdict:'NOT_SENT',failingCheck:reason};
 const context={schedule:true,windowId:'test',archives:[{records:[]},{records:[]}],passports:{},pins:{}};
 const index=evidenceIndex(row,context);
 assert.equal(index.notSentReason,reason);assert.equal(index.exclusionReason,null);assert.equal(index.sender,accounts[0]);
 assert.throws(()=>evidenceIndex(row,{...context,schedule:false}),/UNAPPROVED_ABANDONMENT/);
 }
});
test('fatal stop preserves completed and partial slot counts without retrying the failed arm',async()=>{
 const manifest=manifestFor(2),seen=[];
 await assert.rejects(w.runSlots(manifest,async(slot,arm)=>{
  const row={attemptIndex:seen.length,ok:true};seen.push([slot.block_slot,arm]);
  if(seen.length===5) throw Object.assign(Error('PIN_CHANGED'),{attemptRow:row});
  return row;
 },rows=>rows.every(r=>r.ok)),error=>{
  assert.equal(error.message,'PIN_CHANGED');
  assert.equal(error.windowProgress.complete,1);
  assert.equal(error.windowProgress.status,'STOPPED');
  assert.deepEqual(error.windowProgress.slots.map(s=>[s.block_slot,s.matched,s.attempts]),[[20,true,[0,1,2]],[21,false,[3,4]]]);
  const unusedSlots=Array.from({length:18},(_,i)=>22+i);
  assert.deepEqual(error.windowProgress.unusedSlots,unusedSlots);
  const rec=w.windowRecord(manifest,error.windowProgress);
  assert.deepEqual(rec.unusedSlots,unusedSlots);
  assert.equal(rec.usedSlots,2);
  assert.equal(rec.completeTriplets,1);
  return true;
 });
 assert.equal(seen.length,5);
});
test('all three slices exhaust in order even after 50 cumulative complete triplets',async()=>{
 const full=w.generateSchedule('public',accounts,10);
 const names={SP:'SP',VerifyingPaymaster:'VPM',TokenPaymaster:'TPM'};
 const counts=new Map();
 let aggregate=0;
 for(const windowIndex of [1,2,3]) {
  const {manifest,adapters}=w.createWindow({...opts,windowIndex});
  const firstSlot=(windowIndex-1)*20,lastSlot=firstSlot+19;
  assert.deepEqual(manifest.slice,{windowIndex,firstSlot,lastSlot,slots:20});
  assert.deepEqual(manifest.schedule,full);
  const expected=full.payload.slots.slice(firstSlot,lastSlot+1).flatMap(slot=>slot.order.map(name=>[slot.block_slot,names[name],slot.senders[name]]));
  const visited=[];
  const result=await w.runSlots(manifest,async(slot,arm,sender,index)=>{
   visited.push([slot.block_slot,arm,sender]);
   const key=sender+':'+arm, prior=counts.get(key)??0;
   assert.equal(index,prior);
   const {allocation}=adapters.get(sender).row(arm,index);
   assert.equal(allocation.tripletIndex,prior);
   assert.ok(index<allocation.attempts);
   counts.set(key,prior+1);
   return {attemptIndex:visited.length-1};
  },rows=>{assert.equal(rows.length,3);aggregate++;return true;});
  assert.deepEqual(visited,expected);
  assert.equal(result.complete,20);
  assert.equal(result.status,'EXHAUSTED');
  assert.deepEqual(result.unusedSlots,[]);
  assert.deepEqual(result.slots.map(s=>s.block_slot),Array.from({length:20},(_,i)=>firstSlot+i));
  const rec=w.windowRecord(manifest,result);
  assert.deepEqual(rec,{schedule_sha256:full.sha256,stoppingRule:w.STOPPING_RULE,status:'EXHAUSTED',
   targetTriplets:50,slotCap:60,windowIndex,firstSlot,lastSlot,scheduledSlots:20,usedSlots:20,completeTriplets:20,unusedSlots:[]});
 }
 assert.equal(aggregate,60);
 assert.equal(counts.size,9);
 assert.ok([...counts.values()].every(n=>n===20));
});
test('incomplete slots still exhaust the slice, and an extended schedule is refused',async()=>{
 const manifest=manifestFor(3);
 let attempted=0;
 const result=await w.runSlots(manifest,async()=>({attemptIndex:attempted++}),()=>false);
 assert.equal(result.status,'EXHAUSTED');
 assert.equal(result.complete,0);
 assert.equal(attempted,60);
 assert.equal(result.slots.at(-1).block_slot,59);
 assert.deepEqual(result.unusedSlots,[]);
 const {schedule}=manifest;
 const extended={...schedule,payload:{...schedule.payload,slots:[...schedule.payload.slots,{block_slot:60}]}};
 await assert.rejects(w.runSlots({...manifest,schedule:extended},()=>assert.fail('attempt'),()=>false),/SLOT_CAP/);
});

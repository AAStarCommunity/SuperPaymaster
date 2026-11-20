import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const w = await import('./window-schedule.mjs').catch(e => { if(e.code === 'ERR_MODULE_NOT_FOUND') return {}; throw e; });
const accounts=[200,201,202].map(n=>'0x'+n.toString(16).padStart(40,'0'));
const bytes=execFileSync('python3.11',['-B','script/a6-collector/frozen-fixture.py']);
const mutable=()=>JSON.parse(bytes,(_k,v,c)=>typeof v==='number'&&!Number.isSafeInteger(v)?JSON.rawJSON(c.source):v);
const sha=b=>createHash('sha256').update(b).digest('hex');
test('schedule port preserves sampler payload, digest, permutations and 20 allocations',()=>{
 const s=w.generateSchedule('public 🐈',accounts,10);
 const samplerAccounts=[2,3,4].map(n=>'0x'+n.toString(16).padStart(40,'0'));
 assert.equal(w.generateSchedule('synthetic-public-seed',samplerAccounts,10).sha256,'bf661687e2a487db7163393e5369a75fae592e0c26d3820eebf78dd966f2a4fd');
 const canonical=value=>JSON.stringify(value,(_,v)=>v && !Array.isArray(v) && typeof v==='object'?Object.fromEntries(Object.keys(v).sort().map(k=>[k,v[k]])):v);
 assert.equal(s.sha256,sha(canonical(s.payload)));
 assert.deepEqual(s,w.generateSchedule('public 🐈',accounts,10));
 assert.notEqual(s.sha256,w.generateSchedule('other',accounts,10).sha256);
 for(let i=0;i<60;i+=6) assert.equal(new Set(s.payload.slots.slice(i,i+6).map(x=>x.order.join(','))).size,6);
 assert.equal(s.payload.slot_period_seconds,30);
 assert.equal(s.payload.max_elapsed_seconds,20);
 for(const account of accounts) for(const arm of ['SP','VerifyingPaymaster','TokenPaymaster']) assert.equal(s.payload.slots.filter(x=>x.senders[arm]===account).length,20);
 assert.throws(()=>w.generateSchedule('',accounts,10));
 assert.throws(()=>w.generateSchedule('s',[accounts[0],accounts[0],accounts[2]],10));
 assert.throws(()=>w.generateSchedule('s',accounts,1));
});
test('fixed window all-success stops at 50 slots; all-failure runs 60 slots',async()=>{
 const s=w.generateSchedule('public',accounts,10), traces=[];
 for(const success of [true,false]) {
 const visited=[]; const result=await w.runSlots(s,async(slot,arm,sender,index)=>{visited.push([slot.block_slot,arm,sender,index]);return {ok:success};},rows=>rows.every(r=>r.ok));
 // Pre-registered stop: all-success reaches 50 complete at slot 49; all-failure runs the 60-slot cap.
 assert.equal(result.slots.length,success?50:60);assert.equal(result.complete,success?50:0); traces.push(visited);
 }
 assert.deepEqual(traces[0],traces[1].slice(0,150));assert.equal(traces[0].length,150);assert.equal(traces[1].length,180);
 assert.ok(traces[0].every(x=>x[3]>=0&&x[3]<20));
});
test('window loads three exact plans, records digests, rejects plan.S mismatch',()=>{
 const opts={readBundle:()=>bytes,bundleSha256:sha(bytes),seed:'public',chainId:10,accounts};
 const window=w.createWindow(opts);
 assert.equal(Object.keys(window.manifest.plan_sha256).length,3);
 assert.deepEqual([...window.adapters.values()].map(a=>a.plan.phaseC.attempts),[34,33,33]);
 assert.deepEqual(window.manifest.schedule,w.generateSchedule('public',accounts,10));
 for(const sender of accounts) assert.equal(window.manifest.plan_sha256[sender],window.adapters.get(sender).digest);
 const b=mutable();b.plans[accounts[1]].phaseC.addresses.S=accounts[0];const changed=Buffer.from(JSON.stringify(b));
 assert.throws(()=>w.createWindow({...opts,readBundle:()=>changed,bundleSha256:sha(changed)}),/PLAN_S_MISMATCH/);
 assert.throws(()=>w.createWindow({...opts,bundleSha256:'0'.repeat(64)}),/BUNDLE_DIGEST_MISMATCH/);
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
 assert.throws(()=>w.createWindow({readBundle:()=>changed,bundleSha256:sha(changed),seed:'public',chainId:10,accounts}),/PLAN_WINDOW_BUDGET/);
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
 const schedule=w.generateSchedule('public',accounts,10),seen=[];
 await assert.rejects(w.runSlots(schedule,async(slot,arm)=>{
  const row={attemptIndex:seen.length,ok:true};seen.push([slot.block_slot,arm]);
  if(seen.length===5) throw Object.assign(Error('PIN_CHANGED'),{attemptRow:row});
  return row;
 },rows=>rows.every(r=>r.ok)),error=>{
  assert.equal(error.message,'PIN_CHANGED');
  assert.equal(error.windowProgress.complete,1);
  assert.deepEqual(error.windowProgress.slots.map(s=>[s.block_slot,s.matched,s.attempts]),[[0,true,[0,1,2]],[1,false,[3,4]]]);
  return true;
 });
 assert.equal(seen.length,5);
});
// Pre-registered stopping rule: stop once 50 complete triplets exist; never extend past slot 60.
function stopHarness(isComplete) {
 const effects={signed:0,sent:0,rows:[]},visited=[];
 const attempt=async(slot,arm,sender,index)=>{
  visited.push(slot.block_slot);effects.signed++;effects.sent++;
  const row={attemptIndex:effects.rows.length,block_slot:slot.block_slot,ok:isComplete(slot.block_slot)};effects.rows.push(row);return row;
 };
 return {effects,visited,attempt,complete:rows=>rows.length===3&&rows.every(r=>r.ok)};
}
test('stop rule: 50th complete triplet in slot k<60 leaves slot k+1 unsent and records unused slots',async()=>{
 const s=w.generateSchedule('public',accounts,10);
 // Slots 0..4 incomplete, so the 50th complete triplet lands in slot 54.
 const h=stopHarness(b=>b>=5);
 const result=await w.runSlots(s,h.attempt,h.complete);
 assert.equal(result.complete,50);assert.equal(result.status,'COMPLETE');
 assert.equal(result.slots.length,55);assert.equal(result.slots.at(-1).block_slot,54);
 assert.ok(!h.visited.includes(55));assert.equal(Math.max(...h.visited),54);
 assert.equal(h.effects.signed,165);assert.equal(h.effects.sent,165);assert.equal(h.effects.rows.length,165);
 assert.ok(h.effects.rows.every(r=>r.block_slot<=54));
 assert.deepEqual(result.unusedSlots,[55,56,57,58,59]);
 const rec=w.windowRecord(s,result);
 assert.equal(rec.status,'COMPLETE');assert.deepEqual(rec.unusedSlots,[55,56,57,58,59]);
 assert.equal(rec.schedule_sha256,s.sha256);assert.equal(rec.scheduledSlots,60);assert.equal(rec.usedSlots,55);
 assert.equal(rec.completeTriplets,50);assert.equal(rec.targetTriplets,50);assert.equal(rec.slotCap,60);
 assert.equal(s.payload.slots.length,60,'the schedule still generates every slot');
 // Per-sender per-arm usage is at most 20.
 const used=new Map();for(const slot of s.payload.slots.slice(0,55)) for(const [arm,sender] of Object.entries(slot.senders)) used.set(sender+':'+arm,(used.get(sender+':'+arm)??0)+1);
 assert.equal(used.size,9);assert.ok([...used.values()].every(n=>n<=20));assert.ok([...used.values()].some(n=>n<20));
});
test('stop rule: 60 slots with fewer than 50 complete is INCOMPLETE and there is no 61st slot',async()=>{
 const s=w.generateSchedule('public',accounts,10);
 const h=stopHarness(b=>b>=11); // 49 complete
 const result=await w.runSlots(s,h.attempt,h.complete);
 assert.equal(result.complete,49);assert.equal(result.status,'INCOMPLETE');
 assert.equal(result.slots.length,60);assert.equal(h.effects.sent,180);assert.equal(Math.max(...h.visited),59);
 assert.deepEqual(result.unusedSlots,[]);
 const rec=w.windowRecord(s,result);assert.equal(rec.status,'INCOMPLETE');assert.deepEqual(rec.unusedSlots,[]);assert.equal(rec.usedSlots,60);
 // A schedule carrying a 61st slot is refused before anything is sent: never extend beyond 60.
 const extended={...s,payload:{...s.payload,slots:[...s.payload.slots,{...s.payload.slots[0],block_slot:60,pair_id:'block-60'}]}};
 const h2=stopHarness(()=>false);
 await assert.rejects(w.runSlots(extended,h2.attempt,h2.complete),/SLOT_CAP/);
 assert.equal(h2.effects.sent,0);
});
test('stop rule: incomplete slots (including partial ones) never trigger the stop',async()=>{
 const s=w.generateSchedule('public',accounts,10);
 // 49 complete, then nine incomplete slots (one of them partial: only two rows), then the 50th in slot 58.
 const effects={sent:0},visited=[];
 const result=await w.runSlots(s,async(slot,arm)=>{
  visited.push(slot.block_slot);effects.sent++;
  return {attemptIndex:effects.sent-1,ok:slot.block_slot<49||slot.block_slot===58,partial:slot.block_slot===52&&arm==='TPM'};
 },rows=>rows.length===3&&rows.every(r=>r.ok&&!r.partial));
 assert.equal(result.complete,50);assert.equal(result.status,'COMPLETE');
 assert.deepEqual(result.slots.slice(49,58).map(x=>x.matched),Array(9).fill(false));
 for(let b=49;b<=58;b++) assert.equal(visited.filter(x=>x===b).length,3);
 assert.deepEqual(result.unusedSlots,[59]);assert.ok(!visited.includes(59));
});

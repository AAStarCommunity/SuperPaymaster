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
test('fixed window visits every scheduled arm once regardless of success or failure',async()=>{
 const s=w.generateSchedule('public',accounts,10), traces=[];
 for(const success of [true,false]) {
 const visited=[]; const result=await w.runSlots(s,async(slot,arm,sender,index)=>{visited.push([slot.block_slot,arm,sender,index]);return {ok:success};},rows=>rows.every(r=>r.ok));
 assert.equal(result.slots.length,60);assert.equal(result.complete,success?60:0); traces.push(visited);
 }
 assert.deepEqual(traces[0],traces[1]);assert.equal(traces[0].length,180);
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

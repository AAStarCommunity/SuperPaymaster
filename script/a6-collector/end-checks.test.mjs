import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
const source=readFileSync(new URL('./collector.mjs',import.meta.url),'utf8');
// Execute the actual finalization and evidence writers with offline state and dependencies.
async function finish({code=10,drift=false,abort=false,anchorFailure=false,finalFault=null,waitForBlock=false}={}) {
 const calls=[],lines=[],trailers=[];
 class Stop extends Error { constructor(reason,code,detail){super(reason);Object.assign(this,{reason,code,detail});} }
 const start={chainId:1,block:{number:1,hash:'0x01'},invariant:{value:1}};
 const end={chainId:1,block:{number:2,hash:'0x02'},invariant:{value:drift?2:1},volatile:{operatorBalance:'0'}};
 const context={Stop,stop:{code,reason:abort?'CRASH':code?'INCOMPLETE':'EXHAUSTED'},passportStart:start,
  formal:true,window:{},windowOutcome:{status:abort?'STOPPED':code?'INCOMPLETE':'EXHAUSTED',
   windowIndex:2,firstSlot:20,lastSlot:39,scheduledSlots:20,usedSlots:code?0:20},
  senderConfigs:[{sender:'S1'},{sender:'S2'}],senderPassports:new Map([['S1',start],['S2',start]]),sender:'S1',
  selectSender(s){context.sender=s;},passportAB:async()=>{
   calls.push('passport:'+context.sender);
   const result=structuredClone(end);
   if(calls.filter(c=>c.startsWith('passport:')).length===3) {
    if(finalFault==='PASSPORT_DRIFT') result.invariant.value=2;
    if(finalFault==='END_BALANCE_MISMATCH') result.volatile.operatorBalance='1';
    if(finalFault==='PASSPORT_WINDOW_MISMATCH') result.block={number:1,hash:'0x01'};
   }
   return result;
  },
  savePassport:name=>name,diffPaths:(a,b)=>a.value===b.value?[]:['value'],
  runtime:{archives:[]},revalidateAnchors:async()=>{calls.push('anchors');if(anchorFailure)throw new Stop('ANCHOR_CHANGED',21);return {ok:true};},
  lastAttemptBlock:{blockNumber:1,blockHash:'0x01',operatorBalance:'0'},seenBlocks:new Set(),
  pubA:{getBlockNumber:async()=>{calls.push('block');return waitForBlock && calls.filter(c=>c==='block').length===1?1n:2n;}},
  setTimeout:resolve=>{calls.push('wait');resolve();},passportRefs:{},
  exitCode:null,writeLine:r=>lines.push(r),closeSync(){},fd:0,matched:0,count:50,tally:{},triplets:[],attemptIndex:0,
  rehearsal:false,evidenceRows:[],windowPath:'offline',runId:'offline',writeTrailer:(_p,r)=>trailers.push(r),replacements:[],armCounts:()=>({})};
 const block=source.slice(source.indexOf('let passportEnd = null;'),source.indexOf('console.log(`stop='));
 await vm.runInNewContext(`(async()=>{${block}})()`,context);
 return {calls,end:lines[0],trailer:trailers[0]};
}
for(const abort of [false,true]) test(`${abort?'aborted':'INCOMPLETE'} window records drift and still checks remaining passports and anchors`,async()=>{
 const r=await finish({code:abort?1:10,abort,drift:true});
 assert.ok(r.calls.includes('passport:S2'));
 assert.ok(r.calls.includes('anchors'));
 assert.ok(r.trailer.endChecks.some(c=>c.reason==='PASSPORT_DRIFT'));
 assert.deepEqual(r.end.endChecks,r.trailer.endChecks);
 assert.equal(r.end.stop.code,abort?1:10);
});
test('EXHAUSTED with failed end check is void and STOPPED in both evidence records',async()=>{
 const r=await finish({code:0,drift:true});
 assert.equal(r.trailer.void,true);
 assert.equal(r.trailer.window.status,'STOPPED');
 assert.equal(r.end.window.status,'STOPPED');
 assert.ok(r.calls.includes('anchors'));
});
test('anchor failure is recorded separately on an aborted window',async()=>{
 const r=await finish({abort:true,anchorFailure:true});
 assert.ok(r.trailer.endChecks.some(c=>c.reason==='ANCHOR_CHANGED'));
});
test('collectorHead records the schedule interpreter version',()=>{
 const block=source.slice(source.indexOf('function collectorHead()'),source.indexOf('// ── append-only JSONL'));
 const result=vm.runInNewContext(`${block};collectorHead()`,{
  window:{manifest:{pythonVersion:'3.test build information'}},adapter:null,formal:true,ROOT:'/offline',
  resolve:()=>'',readFileSync:()=>'',createHash:()=>({update:()=>({digest:()=>''})}),execSync:()=>({toString:()=>''})});
 assert.equal(result.pythonVersion,'3.test build information');
});

for(const code of [0,10,1]) for(const reason of ['PASSPORT_DRIFT','END_BALANCE_MISMATCH','PASSPORT_WINDOW_MISMATCH']) {
 test(`final passport records ${reason} on exit ${code}`,async()=>{
  const r=await finish({code,abort:code===1,finalFault:reason});
  for(const record of [r.end,r.trailer]) {
   const check=record.endChecks.find(c=>c.check==='finalPassport');
   assert.equal(check.status,'FAIL');
   assert.equal(check.reason,reason);
   assert.equal(check.code,21);
  }
  assert.equal(r.trailer.void,true);
  assert.equal(r.end.stop.code,code===0?21:code);
  assert.equal(r.trailer.window.status,code===10?'INCOMPLETE':'STOPPED');
  assert.ok(r.calls.includes('anchors'));
 });
}
test('clean window waits for a later block and records all end checks passing',async()=>{
 const r=await finish({code:0,waitForBlock:true});
 assert.deepEqual(r.calls,['block','wait','block','passport:S1','passport:S2','passport:S1','anchors']);
 assert.equal(r.end.endCheckScope,'on every in-process exit (not on SIGINT/SIGTERM/SIGKILL)');
 assert.equal(r.trailer.endCheckScope,r.end.endCheckScope);
 assert.equal(r.trailer.endPassport,'end');
 assert.equal(r.end.passport.block.number,2);
 assert.equal(r.trailer.void,false);
 assert.equal(r.end.stop.reason,'EXHAUSTED');
 assert.equal(r.end.exitCode,0);
 assert.equal(r.trailer.stopReason,'EXHAUSTED');
 assert.equal(r.trailer.window.status,'EXHAUSTED');
 assert.equal(r.end.scheduledSlots,20);
 assert.equal(r.end.attemptedSlots,20);
 assert.equal(r.end.window.windowIndex,2);
 assert.deepEqual(r.end.window,r.trailer.window);
 assert.deepEqual(JSON.parse(JSON.stringify(r.trailer.endChecks)),
  ['endBlock','senderPassport:S1','senderPassport:S2','finalPassport','anchors'].map(check=>({check,status:'PASS'})));
 assert.deepEqual(r.end.endChecks,r.trailer.endChecks);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { aggregateWindows } from './aggregate-windows.mjs';
import { sentWindowFixture } from './sent-window-fixture.mjs';
import { validateRun } from './validate.mjs';
import { REGISTERED_WINDOW } from './window-schedule.mjs';

async function fixture(t,options) {
  const dir=mkdtempSync(join(process.cwd(),'.aggregate-window-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  return {dir,...await sentWindowFixture(dir,options)};
}

function aggregateCli(dirs,frozenPlan,{seed,scheduleSha256},...extra) {
  const cli=spawnSync(process.execPath,['script/a6-collector/aggregate-windows.mjs',...dirs,
    '--frozen-plan',frozenPlan,'--registered-seed',seed,'--registered-schedule-sha256',scheduleSha256,...extra],{encoding:'utf8'});
  assert.ifError(cli.error);
  return {status:cli.status,...JSON.parse(cli.stdout)};
}

test('aggregate validates three independently archived slices and checks their boundaries',async t=>{
  const first=await fixture(t,{windowIndex:1});
  const priorSPTimestamps=new Map(first.rows.filter(row=>row.sent && row.arm==='SP').map(row=>[row.sender,BigInt(row.tx.blockTimestamp)]));
  const second=await fixture(t,{windowIndex:2,priceDelta:1n,priorSPTimestamps});
  const third=await fixture(t,{windowIndex:3,priceDelta:2n});
  const frozenPlan=join(first.dir,'bundle.json'), registered=first.registered;
  const options={frozenPlan,registered};
  const aggregate=(...windows)=>aggregateWindows(windows.map(w=>w.dir),options);
  const refused=(result,pattern)=>{
    assert.equal(result.outcome,'INVALID-INTERRUPTED',JSON.stringify(result));
    assert.match(result.errors.join('\n'),pattern);
  };

  const complete=aggregate(third,first,second);
  assert.deepEqual(complete,{
    outcome:'COMPLETE',completeTriplets:57,targetTriplets:50,errors:[]
  });
  const dirs=[first.dir,second.dir,third.dir];
  assert.deepEqual(aggregateCli(dirs,frozenPlan,registered),{status:0,...complete});

  await t.test('accepts the first sent SP gates in window 2 with window 1 timestamps',()=>{
    for(const [sender,lastTimestamp] of priorSPTimestamps) {
      const row=second.rows.find(row=>row.sent && row.arm==='SP' && row.sender===sender);
      const minTxInterval=BigInt(row.passport.invariant.superPaymaster.operator.minTxInterval);
      assert.ok(lastTimestamp>0n && minTxInterval>0n);
      assert.equal(row.slotChecks.length,2);
      for(const {allowed,wait} of row.slotChecks) {
        assert.equal(wait.lastTimestamp,String(lastTimestamp));
        assert.equal(wait.minTxInterval,String(minTxInterval));
        assert.equal(wait.validAfter,String(lastTimestamp+minTxInterval));
        assert.ok(BigInt(wait.timestamp)>=BigInt(wait.validAfter));
        assert.equal(allowed,true);
      }
    }
  });

  await t.test('CLI exits 1 for an invalid collection',()=>{
    const cli=aggregateCli(dirs.slice(0,2),frozenPlan,registered);
    assert.equal(cli.status,1);
    refused(cli,/requires 3 window directories/);
  });
  for(const [label,flag] of [['duplicate','--frozen-plan'],['unknown','--unexpected']]) {
    await t.test(`CLI refuses ${label} flags`,()=>{
      const cli=aggregateCli(dirs,frozenPlan,registered,flag,frozenPlan);
      assert.equal(cli.status,1);
      refused(cli,/usage: aggregate-windows\.mjs/);
    });
  }

  await t.test('refuses a missing slice or missing archive',()=>{
    refused(aggregate(first,third),/requires 3 window directories/);
    refused(aggregate(first,{dir:join(first.dir,'missing')},third),/cannot read/);
  });
  await t.test('refuses a second clean result for the same range with a distinct runId',async ()=>{
    const duplicate=await fixture(t,{windowIndex:2,runId:'second-range-again'});
    refused(aggregate(first,second,duplicate),/duplicate slice range/);
  });
  await t.test('refuses different ranges with the same runId',async ()=>{
    const duplicate=await fixture(t,{windowIndex:2,runId:first.trailer.windowId});
    refused(aggregate(first,duplicate,third),/runIds must be distinct/);
  });
  await t.test('refuses an interrupted or void slice',()=>{
    const path=join(second.dir,'trailer.json'), bytes=readFileSync(path);
    try {
      rmSync(path);
      refused(aggregate(first,second,third),/missing or invalid trailer/);
      writeFileSync(path,JSON.stringify({...second.trailer,void:true,stopReason:'STOPPED'}));
      refused(aggregate(first,second,third),/void window/);
    } finally {writeFileSync(path,bytes);}
  });
  await t.test('refuses passport brackets touching at the final passport block',async ()=>{
    const start=Number(first.end.passport.block.number);
    const overlapping=await fixture(t,{windowIndex:2,blockStart:start,priceDelta:1n});
    refused(aggregate(first,overlapping,third),/overlapping or reversed passport brackets/);
  });
  await t.test('refuses invariant drift outside the price exception',async ()=>{
    const drift=await fixture(t,{windowIndex:2,priceDelta:1n,version:'SuperPaymaster-different'});
    refused(aggregate(first,drift,third),/boundary passport drift/);
  });
  await t.test('keeps cached-price decimals invariant',async ()=>{
    const drift=await fixture(t,{windowIndex:2,priceDelta:1n,priceDecimals:9});
    refused(aggregate(first,drift,third),/boundary passport drift/);
  });
  await t.test('refuses a nonce gap across otherwise clean slices',async ()=>{
    const gap=await fixture(t,{windowIndex:2,priceDelta:1n,nonceOffset:1});
    refused(aggregate(first,gap,third),/nonce discontinuity/);
  });
  await t.test('refuses schedule, bundle, chain and account changes in one slice',()=>{
    const mutate=(path,change,pattern)=>{
      const file=join(second.dir,path), original=readFileSync(file,'utf8');
      const lines=original.trim().split('\n').map(JSON.parse);
      change(lines[0]);
      try {
        writeFileSync(file,lines.map(line=>JSON.stringify(line)).join('\n')+'\n');
        refused(aggregate(first,second,third),pattern);
      } finally { writeFileSync(file,original); }
    };
    mutate('manifest.json',m=>{m.schedule.sha256='f'.repeat(64);},/schedule SHA-256 differs/);
    mutate('manifest.json',m=>{m.bundleSha256='f'.repeat(64);},/frozen bundle SHA-256 mismatch/);
    mutate('run.jsonl',row=>{row.passport.chainId=11155111;},/schedule payload differs/);
    mutate('manifest.json',m=>{m.schedule.payload.accounts.reverse();},/schedule payload differs/);
  });
  await t.test('refuses reuse of a sender and arm allocation from an earlier slice',()=>{
    const file=second.runPath, original=readFileSync(file,'utf8');
    const lines=original.trim().split('\n').map(JSON.parse);
    const reused=first.rows.find(row=>row.sender===lines[1].sender && row.arm===lines[1].arm);
    lines[1].allocation=reused.allocation;
    try {
      writeFileSync(file,lines.map(line=>JSON.stringify(line)).join('\n')+'\n');
      refused(aggregate(first,second,third),/frozen allocation mismatch/);
    } finally { writeFileSync(file,original); }
  });
});

test('aggregate checks a nonce key that returns after a slice without it',async t=>{
  const keyedNonce=(key,sequence)=>(key<<64n)+sequence;
  const first=await fixture(t,{windowIndex:1,firstSenderKeyedNonce:keyedNonce(1n,10n)});
  const [sender]=first.accounts;
  const key=sender.toLowerCase()+':1', defaultKey=sender.toLowerCase()+':0';
  const options={frozenPlan:join(first.dir,'bundle.json'),registered:first.registered};
  const ranges=f=>{
    const report=validateRun(f.runPath,options);
    assert.equal(report.accepted,true,JSON.stringify(report));
    return report.window.nonceRanges;
  };
  const firstRanges=ranges(first);
  assert.equal(firstRanges[key].last,'10');
  const second=await fixture(t,{windowIndex:2,initialNonces:new Map([[sender,BigInt(firstRanges[defaultKey].last)+1n]])});
  const secondRanges=ranges(second);
  assert.equal(Object.hasOwn(secondRanges,key),false);
  const initialNonces=new Map([[sender,BigInt(secondRanges[defaultKey].last)+1n]]);
  const aggregate=third=>aggregateWindows([first.dir,second.dir,third.dir],options);
  const consecutive=await fixture(t,{windowIndex:3,initialNonces,firstSenderKeyedNonce:keyedNonce(1n,11n)});
  assert.equal(aggregate(consecutive).outcome,'COMPLETE');
  const gap=await fixture(t,{windowIndex:3,initialNonces,firstSenderKeyedNonce:keyedNonce(1n,12n)});
  assert.deepEqual(aggregate(gap),{outcome:'INVALID-INTERRUPTED',errors:[`windows 1 and 3: nonce discontinuity for ${key}`]});
});

test('aggregate CLI exits 3 for an incomplete collection of accepted slices',async t=>{
  const windows=await Promise.all([1,2,3].map(windowIndex=>fixture(t,{windowIndex,finalVpmSlots:3,finalVpmVerdict:'USEROP_REVERTED'})));
  const [first]=windows;
  assert.deepEqual(aggregateCli(windows.map(w=>w.dir),join(first.dir,'bundle.json'),first.registered),{
    status:3,outcome:'INCOMPLETE',completeTriplets:48,targetTriplets:50,errors:[]
  });
});

test('aggregate applies the registered collection target to accepted slices',async t=>{
  const protocol={...REGISTERED_WINDOW,targetTriplets:58};
  const windows=await Promise.all([1,2,3].map(windowIndex=>fixture(t,{windowIndex,protocol})));
  const result=aggregateWindows(windows.map(w=>w.dir),{frozenPlan:join(windows[0].dir,'bundle.json'),registered:windows[0].registered});
  assert.deepEqual(result,{outcome:'INCOMPLETE',completeTriplets:57,targetTriplets:58,errors:[]});
});

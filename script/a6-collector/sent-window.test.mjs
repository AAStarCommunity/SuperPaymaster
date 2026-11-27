import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { windowErrors } from './evidence-validate.mjs';
import { stringify } from './evidence.mjs';
import { localUserOpHash } from './gauge-lib.mjs';
import { sentWindowFixture } from './sent-window-fixture.mjs';
import { validateRun } from './validate.mjs';
import { accumulateSlotWait, REGISTERED_WINDOW } from './window-schedule.mjs';

function validate(f) {
  const report=validateRun(f.runPath,{frozenPlan:join(f.dir,'bundle.json'),registered:f.registered});
  return {status:report.validatorExit,...report};
}

function refuses(f,pattern) {
  const r=validate(f);
  assert.equal(r.status,1,JSON.stringify(r));
  assert.equal(r.accepted,false);
  assert.match(r.errors.join('\n'),pattern);
}

async function fixture(t,options) {
  const dir=mkdtempSync(join(process.cwd(),'.sent-window-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  return {dir,...await sentWindowFixture(dir,options)};
}

function withArtifact(f,path,mutate,check) {
  const file=join(f.dir,path), bytes=readFileSync(file);
  const value=JSON.parse(bytes);
  try {
    if(mutate) {mutate(value);writeFileSync(file,stringify(value)+'\n');}
    else rmSync(file);
    check();
  } finally {writeFileSync(file,bytes);}
}

function withRows(f,mutate,check) {
  const files=[f.runPath,join(f.dir,'index.ndjson')];
  const bytes=files.map(file=>readFileSync(file,'utf8'));
  const data=bytes.map(content=>content.trim().split('\n').map(JSON.parse));
  mutate(data[0].slice(1,-1),data[1]);
  try {
    files.forEach((file,i)=>writeFileSync(file,data[i].map(stringify).join('\n')+'\n'));
    check();
  } finally { files.forEach((file,i)=>writeFileSync(file,bytes[i])); }
}

test('frozen SENT window with rotating senders and A/B archives',async t=>{
  const f=await fixture(t);
  const result=validate(f);
  assert.equal(result.status,0,JSON.stringify(result));
  assert.equal(result.accepted,true);
  assert.equal(result.evidence,true);
  assert.equal(result.matchedTriplets,f.end.matchedTriplets);
  assert.deepEqual(result.recomputed,{NOT_SENT:3,USEROP_SUCCESS:f.end.matchedTriplets*3});
  assert.equal(result.attempts,60);
  assert.equal(result.stop,'EXHAUSTED');
  assert.equal(result.matchedTriplets,19);
  for(const arm of ['SP','VPM','TPM']) {
    const sent=f.rows.filter(r=>r.sent && r.arm===arm);
    assert.equal(new Set(sent.map(r=>r.sender)).size,3);
    if (arm==='TPM') {
      assert.ok(sent.every(r=>r.traces.length===1));
      assert.ok(f.index.filter(r=>r.trace).every(r=>r.trace.raw.A.length===2 && r.trace.raw.B.length===0));
    }
    if(arm==='VPM') assert.ok(sent.every(r=>r.pmGas.post==='0'));
  }
  assert.ok(f.rows.some(r=>!r.sent && r.slotChecks.length===1 && !r.packedOp));
  assert.ok(f.rows.some(r=>!r.sent && r.slotChecks.length===2 && r.packedOp));

  await t.test('the CLI requires the explicit registered schedule and accepts the matching registration',()=>{
    const r=spawnSync(process.execPath,['script/a6-collector/validate.mjs',f.runPath,'--frozen-plan',join(f.dir,'bundle.json')],{encoding:'utf8'});
    assert.ifError(r.error);
    assert.equal(r.status,2,r.stderr || r.stdout);
    assert.match(JSON.parse(r.stdout).missing,/requires --registered-seed/);
    const accepted=spawnSync(process.execPath,['script/a6-collector/validate.mjs',f.runPath,'--frozen-plan',join(f.dir,'bundle.json'),
      '--registered-seed',f.registered.seed,'--registered-schedule-sha256',f.registered.scheduleSha256],{encoding:'utf8'});
    assert.equal(accepted.status,0,accepted.stderr || accepted.stdout);
  });
  await t.test('the CLI and evidence validator refuse an undersized slice under the registered protocol',()=>{
    withArtifact(f,'manifest.json',manifest=>{manifest.slice.slots--;},()=>{
      const r=spawnSync(process.execPath,['script/a6-collector/validate.mjs',f.runPath,'--frozen-plan',join(f.dir,'bundle.json'),
        '--registered-seed',f.registered.seed,'--registered-schedule-sha256',f.registered.scheduleSha256],{encoding:'utf8'});
      assert.ifError(r.error);
      assert.equal(r.status,2,r.stderr || r.stdout);
      assert.match(JSON.parse(r.stdout).missing,/manifest differs from registered window protocol/);
      const lines=path=>readFileSync(path,'utf8').trim().split('\n').map(JSON.parse);
      const manifest=JSON.parse(readFileSync(join(f.dir,'manifest.json'),'utf8'));
      assert.deepEqual(windowErrors(lines(join(f.dir,'index.ndjson')),f.trailer,lines(f.runPath),manifest),
        ['manifest differs from registered window protocol']);
    });
  });
  await t.test('collector refuses occupied output before reading the bundle and allows an empty directory',()=>{
    const dir=join(f.dir,'fresh-window'), out=join(dir,'run.jsonl'), pins=join(f.dir,'pins.json');
    mkdirSync(dir);
    const start=JSON.parse(readFileSync(f.runPath,'utf8').split('\n',1)[0]);
    writeFileSync(pins,stringify(start.pins));
    const cli=()=>spawnSync(process.execPath,['script/a6-collector/collector.mjs',
      '--out',out,'--frozen-plan',join(dir,'intentionally-absent-bundle.json'),'--bundle-sha256','0'.repeat(64),
      '--count','50','--max-attempts','20','--b-max','1','--window-index','2','--seed','public',
      '--formal-config',join(f.dir,'formal.json'),'--rpc-a-file','unused','--rpc-b-file','unused',
      '--config','unused','--baselines','unused','--rpc-registry',join(f.dir,'rpc-identity.json'),'--pins',pins],{encoding:'utf8'});
    const fresh=cli();
    assert.ifError(fresh.error);
    assert.match(fresh.stderr,/ENOENT.*intentionally-absent-bundle/);
    for(const name of ['raw','index.ndjson','manifest.json','run.jsonl']) {
      const path=join(dir,name);
      if(name==='raw') mkdirSync(path);
      else writeFileSync(path,name==='run.jsonl'?'occupied':'');
      try {
        const refused=cli();
        assert.ifError(refused.error);
        assert.equal(refused.status,2,refused.stderr);
        assert.match(refused.stderr,name==='run.jsonl'?/refusing to touch non-empty/:/formal window already exists/);
      } finally { rmSync(path,{recursive:true}); }
    }
  });
  for(const [field,value] of [['targetTriplets',5],['slotCap',59],['stoppingRule','other'],['warmupAttempts',1],['warmup',true]]) {
    await t.test(`rejects manifest ${field} differing from the explicit protocol`,()=>{
      withArtifact(f,'manifest.json',manifest=>{manifest[field]=value;},()=>{
        assert.match(validate(f).missing,/manifest differs from registered window protocol/);
      });
    });
  }
  await t.test('requires the registered seed and schedule hash to regenerate the archive',()=>{
    const validateWith=registered=>validateRun(f.runPath,{frozenPlan:join(f.dir,'bundle.json'),registered});
    const wrongSeed=validateWith({...f.registered,seed:'another public seed'});
    assert.match(wrongSeed.missing,/schedule payload differs from regenerated registered schedule/);
    const wrongHash='0'.repeat(64);
    withArtifact(f,'manifest.json',m=>{m.schedule.sha256=wrongHash;},()=>{
      const result=validateWith({...f.registered,scheduleSha256:wrongHash});
      assert.match(result.missing,/schedule SHA-256 differs from registered schedule/);
    });
    withArtifact(f,'manifest.json',m=>{m.schedule.payload.slots[0].deadline_seconds++;},()=>{
      assert.match(validate(f).missing,/schedule payload differs from regenerated registered schedule/);
    });
  });
  await t.test('refuses a skipped or reordered slot and a partial non-final slot',()=>{
    const file=f.runPath, bytes=readFileSync(file,'utf8');
    for(const mutate of [
      rows=>rows.splice(3,3),
      rows=>rows.splice(0,6,...rows.slice(3,6),...rows.slice(0,3)),
      rows=>rows.splice(2,1),
    ]) {
      const [start,...rows]=bytes.trim().split('\n').map(JSON.parse), end=rows.pop();
      mutate(rows);
      rows.forEach((row,i)=>{row.attemptIndex=i;});
      try {
        writeFileSync(file,[start,...rows,end].map(stringify).join('\n')+'\n');
        refuses(f,/window slots must be traversed in schedule order/);
      } finally {writeFileSync(file,bytes);}
    }
  });
  await t.test('refuses a shared trailer and journal summary that disagrees with the attempts',()=>{
    const bytes=readFileSync(f.runPath,'utf8');
    const lines=bytes.trim().split('\n').map(JSON.parse);
    lines.at(-1).window.completeTriplets--;
    try {
      writeFileSync(f.runPath,lines.map(stringify).join('\n')+'\n');
      withArtifact(f,'trailer.json',t=>{t.window.completeTriplets--;},()=>{
        refuses(f,/window record differs from reconstructed slice/);
      });
    } finally {writeFileSync(f.runPath,bytes);}
  });
  await t.test('refuses a cached-price timestamp change inside a slice',()=>{
    const change=p=>{p.volatile.cachedPriceUpdatedAt=String(BigInt(p.volatile.cachedPriceUpdatedAt)+1n);};
    for(const path of ['passports/start-'+f.accounts[1]+'.json','passports/end-'+f.accounts[2]+'.json']) {
      withArtifact(f,path,change,()=>refuses(f,/cached price changed within window/));
    }
    withRows(f,rows=>change(rows[0].passport),()=>refuses(f,/run\.jsonl:2: cached price changed within window/));
  });
  await t.test('identifies the file and line of passports missing the cache timestamp',()=>{
    const remove=p=>{delete p.volatile.cachedPriceUpdatedAt;};
    withArtifact(f,'passports/start-'+f.accounts[1]+'.json',remove,()=>{
      assert.match(validate(f).missing,/passports\/start-.*\.json:1: missing volatile\.cachedPriceUpdatedAt/);
    });
    withArtifact(f,'passports/attempt-0.json',remove,()=>{
      refuses(f,/passports\/attempt-0\.json:1: missing volatile\.cachedPriceUpdatedAt/);
    });
    withRows(f,rows=>remove(rows[0].passport),()=>{
      refuses(f,/run\.jsonl:2: missing volatile\.cachedPriceUpdatedAt/);
    });
  });
  await t.test('the fixture accumulates SP wait and keeps separate gate pins',()=>{
    const row=f.rows.find(r=>r.sent && r.arm==='SP'), [early,submit]=row.slotChecks;
    assert.notDeepEqual(early.wait.pin,submit.wait.pin);
    assert.ok(BigInt(early.wait.seconds)>0n);
    assert.deepEqual(row.spWait,{...submit.wait,
      seconds:String(BigInt(early.wait.seconds)+BigInt(submit.wait.seconds)),
      blocks:String(BigInt(early.wait.blocks)+BigInt(submit.wait.blocks))});
    assert.equal(f.end.endCheckScope,'on every in-process exit (not on SIGINT/SIGTERM/SIGKILL)');
    assert.equal(f.trailer.endCheckScope,f.end.endCheckScope);
  });
  await t.test('rejects missing, denied or mistimed gates on sent rows',()=>{
    const mutations=[
      checks=>checks.pop(),
      checks=>{checks[0].allowed=false;},
      checks=>{checks[1].allowed=false;},
      checks=>{checks[0].wait.start=checks[0].wait.deadline;},
      checks=>{checks[1].wait.deadline=checks[1].wait.start;},
    ];
    const changed=[];
    withRows(f,(rows,index)=>{
      rows.filter(r=>r.sent).slice(0,mutations.length).forEach((row,i)=>{
        mutations[i](row.slotChecks);
        index[row.attemptIndex].slotChecks=row.slotChecks;
        changed.push(row.attemptIndex);
      });
    },()=>{
      const result=validate(f);
      assert.equal(result.status,1);
      for(const i of changed) assert.ok(result.errors.includes(`attempt ${i}: invalid slot gates`),result.errors.join('\n'));
    });
  });
  for(const [name,timestamp] of [
    ['rejects allowed sent gates after the slot deadline',wait=>BigInt(wait.deadline)+1000n],
    ['rejects allowed sent gates before the slot start',wait=>BigInt(wait.start)-1000n],
  ]) await t.test(name,()=>{
    const sent=f.rows.filter(row=>row.sent);
    withRows(f,(rows,index)=>{
      for(const {attemptIndex:i} of sent) {
        const row=rows[i];
        for(const gate of row.slotChecks) gate.wait.timestamp=String(timestamp(gate.wait));
        index[i].slotChecks=row.slotChecks;
        if(row.arm==='SP') {
          row.spWait.timestamp=row.slotChecks.at(-1).wait.timestamp;
          index[i].spWait=row.spWait;
        }
      }
    },()=>{
      const r=validate(f);
      assert.equal(r.status,1,JSON.stringify(r));
      for(const {attemptIndex:i} of sent) assert.ok(r.errors.includes(`attempt ${i}: invalid slot gates`),r.errors.join('\n'));
    });
  });
  await t.test('rejects an allowed SP gate before its recorded validAfter',()=>{
    const i=f.rows.find(r=>r.sent && r.arm==='SP').attemptIndex;
    withRows(f,(rows,index)=>{
      const gate=rows[i].slotChecks[0];
      gate.wait.lastTimestamp=String(BigInt(gate.wait.timestamp)+1n-BigInt(gate.wait.minTxInterval));
      gate.wait.validAfter=String(BigInt(gate.wait.timestamp)+1n);
      index[i].slotChecks=rows[i].slotChecks;
    },()=>refuses(f,new RegExp(`attempt ${i}: invalid slot gates`)));
  });
  await t.test('rejects a second gate after a valid first-gate denial',()=>{
    const i=f.rows.find(r=>!r.sent && r.slotChecks.length===2).attemptIndex;
    withRows(f,(rows,index)=>{
      const row=rows[i], [first,second]=row.slotChecks;
      Object.assign(first,{allowed:false,reason:second.reason});
      first.wait.timestamp=second.wait.timestamp;
      index[i].slotChecks=row.slotChecks;
      if(row.arm==='SP') index[i].spWait=row.spWait=accumulateSlotWait(first.wait,second.wait);
    },()=>refuses(f,new RegExp(`attempt ${i}: invalid schedule disposition`)));
  });
  await t.test('replays allowed gates and folds the SP wait even when the index agrees with the journal',()=>{
    const changed=[];
    withRows(f,(rows,index)=>{
      const [early,late]=rows.filter(r=>r.sent && r.arm!=='SP');
      early.slotChecks[0].wait.timestamp=String(BigInt(early.slotChecks[0].wait.start)-1n);
      late.slotChecks[1].wait.timestamp=String(BigInt(late.slotChecks[1].wait.deadline)+1n);
      const [premature,wrongSum,wrongWait]=rows.filter(r=>r.sent && r.arm==='SP');
      const wait=premature.slotChecks[0].wait;
      wait.lastTimestamp=wait.timestamp;
      wait.validAfter=String(BigInt(wait.lastTimestamp)+BigInt(wait.minTxInterval));
      wrongSum.slotChecks[0].wait.validAfter=String(BigInt(wrongSum.slotChecks[0].wait.validAfter)+1n);
      wrongWait.spWait.seconds=wrongWait.slotChecks[1].wait.seconds;
      for(const row of [early,late,premature,wrongSum,wrongWait]) {
        Object.assign(index[row.attemptIndex],{slotChecks:row.slotChecks,spWait:row.spWait});
        changed.push(row.attemptIndex);
      }
    },()=>{
      const result=validate(f);
      for(const i of changed) assert.ok(result.errors.includes(`attempt ${i}: invalid slot gates`),result.errors.join('\n'));
    });
  });
  await t.test('the elapsed slot deadline takes priority over SP validAfter',()=>{
    withRows(f,(rows,index)=>{
      const row=rows.find(r=>!r.sent && r.arm==='SP'), gate=row.slotChecks.at(-1);
      gate.wait.lastTimestamp=gate.wait.deadline;
      gate.wait.validAfter=String(BigInt(gate.wait.lastTimestamp)+BigInt(gate.wait.minTxInterval));
      const reason='sp_valid_after_exceeds_slot_deadline';
      row.failingCheck=row.scheduleDisposition=gate.reason=reason;
      row.spWait={...gate.wait,seconds:row.spWait.seconds,blocks:row.spWait.blocks};
      Object.assign(index[row.attemptIndex],{failureReason:reason,notSentReason:reason,scheduleDisposition:reason,
        slotChecks:row.slotChecks,spWait:row.spWait});
    },()=>refuses(f,/invalid schedule disposition/));
  });
  await t.test('rejects unsupported slot denial evidence',()=>{
    const changed=[];
    withRows(f,(rows,index)=>{
      const [packed,...early]=rows.filter(r=>!r.sent);
      const sp=[packed,...early].find(r=>r.arm==='SP');
      const other=early.find(r=>r!==sp);
      // The SP arm must be past validAfter's deadline and the time denial must be strictly late.
      for(const [row,reason,field] of [[sp,'sp_valid_after_exceeds_slot_deadline','validAfter'],
        [other,'slot_deadline_exceeded','timestamp']]) {
        const gate=row.slotChecks.at(-1), ix=index[row.attemptIndex];
        row.failingCheck=row.scheduleDisposition=gate.reason=reason;
        gate.wait[field]=gate.wait.deadline;
        if(row.arm==='SP') row.spWait={...row.spWait,...gate.wait};
        Object.assign(ix,{failureReason:reason,notSentReason:reason,scheduleDisposition:reason,slotChecks:row.slotChecks,spWait:row.spWait});
        changed.push(row.attemptIndex);
      }
      const nonSP=rows.find(r=>!r.sent && r.arm!=='SP' && r!==other);
      const gate=nonSP.slotChecks.at(-1), ix=index[nonSP.attemptIndex], reason='sp_valid_after_exceeds_slot_deadline';
      nonSP.failingCheck=nonSP.scheduleDisposition=gate.reason=reason;
      gate.wait.validAfter=gate.wait.timestamp;
      Object.assign(ix,{failureReason:reason,notSentReason:reason,scheduleDisposition:reason,slotChecks:nonSP.slotChecks});
      changed.push(nonSP.attemptIndex);
    },()=>{
      const result=validate(f);
      assert.equal(result.status,1);
      for(const i of changed) assert.ok(result.errors.includes(`attempt ${i}: invalid schedule disposition`),result.errors.join('\n'));
    });
  });
  await t.test('rejects an SP denial that ignores the expired slot deadline',()=>{
    const i=f.rows.find(r=>!r.sent && r.arm==='SP').attemptIndex;
    withRows(f,(rows,index)=>{
      const row=rows[i], gate=row.slotChecks.at(-1), reason='sp_valid_after_exceeds_slot_deadline';
      row.failingCheck=row.scheduleDisposition=gate.reason=reason;
      gate.wait.lastTimestamp=gate.wait.deadline;
      gate.wait.validAfter=String(BigInt(gate.wait.lastTimestamp)+BigInt(gate.wait.minTxInterval));
      row.spWait={...gate.wait,seconds:row.spWait.seconds,blocks:row.spWait.blocks};
      Object.assign(index[i],{failureReason:reason,notSentReason:reason,scheduleDisposition:reason,slotChecks:row.slotChecks,spWait:row.spWait});
    },()=>refuses(f,new RegExp(`attempt ${i}: invalid schedule disposition`)));
  });
  await t.test('rejects changed PVG columns with the original packed op and archives',()=>{
    const mutations={pvgSurplusReason:'cycle-max',pvgConsistency:'1',outerGasUsed:'1',outerEffectiveGasPrice:'1',
      l1DataFee:'0x1',calldataFloorGas:'1',calldataFloorBinding:null,bundlerNetGas:'1',opGasPrice:'1',unusedGasPenalty:'1',unusedGasPenaltyReason:'invented',bundlerNetGasExPenalty:'1'};
    const i=f.rows.find(r=>r.sent).attemptIndex;
    withRows(f,rows=>Object.assign(rows[i],mutations),()=>{
      const result=validate(f);
      assert.equal(result.status,1);
      for(const key of Object.keys(mutations)) assert.ok(result.errors.includes(`attempt ${i}: PVG measurement mismatch: ${key}`),result.errors.join('\n'));
    });
  });

  await t.test('rejects invented penalty fields before a transaction is sent',()=>{
    const early=f.rows.find(r=>!r.sent && !r.packedOp).attemptIndex;
    const packed=f.rows.find(r=>!r.sent && r.packedOp).attemptIndex;
    withRows(f,rows=>{
      rows[early].unusedGasPenalty='1';
      rows[packed].unusedGasPenaltyReason='invented';
    },()=>{
      const result=validate(f);
      assert.equal(result.status,1);
      assert.ok(result.errors.includes(`attempt ${early}: PVG measurement mismatch: unusedGasPenalty`));
      assert.ok(result.errors.includes(`attempt ${packed}: PVG measurement mismatch: unusedGasPenaltyReason`));
    });
  });

  const sender=f.accounts[1], endPath='passports/end-'+sender+'.json';
  await t.test('rejects sender 3 end passport invariant drift',()=>{
    withArtifact(f,'passports/end-'+f.accounts[2]+'.json',p=>p.invariant.xPNTs.maxSingleTxLimit='1',()=>{
      refuses(f,/end passport invariant drifted/);
    });
  });
  await t.test('rejects a different chainId in a sender end passport',()=>{
    withArtifact(f,endPath,p=>{p.chainId=11155111;},()=>refuses(f,/end passport metadata or block mismatch/));
  });
  await t.test('rejects missing sender end passport',()=>{
    withArtifact(f,endPath,null,()=>refuses(f,/missing or invalid end passport/));
  });
  await t.test('rejects attempts outside the sender passport bracket',()=>{
    const last=f.rows.findLast(r=>r.sent && r.sender===sender);
    withArtifact(f,endPath,p=>Object.assign(p,last.passport),()=>{
      refuses(f,/attempt outside sender passport bracket/);
    });
  });
  await t.test('rejects a row referencing another sender start passport',()=>{
    withRows(f,(rows,index)=>{
      const a=rows.find(r=>r.sent && r.sender!==f.accounts[0]);
      const b=rows.find(r=>r.sender===f.accounts[0]);
      index[a.attemptIndex].passports.start=index[b.attemptIndex].passports.start;
    },()=>refuses(f,/index start passport mismatch/));
  });
  for(const field of ['allowed','start','deadline']) {
    await t.test(`rejects a bad ${field} for both schedule dispositions`,()=>{
      const failures=[];
      withRows(f,(rows,index)=>{
        for(const [row,reason] of [
          [rows.find(r=>!r.sent && r.arm!=='SP'),'slot_deadline_exceeded'],
          [rows.find(r=>!r.sent && r.arm==='SP'),'sp_valid_after_exceeds_slot_deadline'],
        ]) {
          const gate=row.slotChecks.at(-1), ix=index[row.attemptIndex];
          row.failingCheck=row.scheduleDisposition=gate.reason=reason;
          if(reason==='sp_valid_after_exceeds_slot_deadline') {
            gate.wait.timestamp=gate.wait.deadline;
            gate.wait.lastTimestamp=gate.wait.deadline;
            gate.wait.validAfter=String(BigInt(gate.wait.lastTimestamp)+BigInt(gate.wait.minTxInterval));
          }
          if(field==='allowed') gate.allowed=true;
          else gate.wait[field]=String(BigInt(gate.wait[field])+1n);
          if(row.arm==='SP') row.spWait=gate.wait;
          Object.assign(ix,{failureReason:reason,notSentReason:reason,scheduleDisposition:reason,slotChecks:row.slotChecks,spWait:row.spWait});
          failures.push(row.attemptIndex);
        }
      },()=>{
        const r=validate(f);
        assert.equal(r.status,1);
        assert.equal(r.accepted,false);
        for(const i of failures) assert.ok(r.errors.includes(`attempt ${i}: invalid schedule disposition`),r.errors.join('\n'));
      });
    });
  }
  await t.test('rejects a submit-gate row stripped of packing evidence',()=>{
    withRows(f,(rows,index)=>{
      const row=rows.find(r=>!r.sent && r.slotChecks.length===2);
      const ix=index[row.attemptIndex];
      for(const field of ['chainId','entryPoint','bundler','nonce','paymaster','callDataHash','packedOp','expectedUserOpHash','gas']) {
        delete row[field];
        ix[field]=null;
        ix.missing['/'+field]='not collected before attempt ended';
      }
      for(const field of ['pmGas','bundledOps','epUserOpHash','localUserOpHash','bundledUserOpHashes','guard']) delete row[field];
      ix.bundle=null;
      ix.missing['/bundle']='not collected before attempt ended';
      const pvg=row.gasSources.preVerification;
      for(const field of ['bytes','overhead','value']) pvg[field]=null;
      for(const field of ['calldataGas','surplus','resolution','ruleValue','cycle']) delete pvg[field];
    },()=>refuses(f,/submit gate missing packing evidence/));
  });
  await t.test('rejects a packed row presented as an early gate',()=>{
    withRows(f,(rows,index)=>{
      const row=rows.find(r=>!r.sent && r.slotChecks.length===2);
      row.slotChecks.shift();
      index[row.attemptIndex].slotChecks=row.slotChecks;
    },()=>refuses(f,/early gate contains packing evidence/));
  });
  const packedNotSent=f.rows.find(r=>!r.sent && r.packedOp).attemptIndex;
  await t.test('reports a packed PVG length mismatch as an attempt error',()=>{
    withRows(f,(rows,index)=>{
      const row=rows[packedNotSent];
      row.packedOp.signature+='00';
      row.bundledOps[0].signature=row.packedOp.signature;
      Object.assign(index[packedNotSent],{packedOp:row.packedOp,bundle:row.bundledOps});
    },()=>refuses(f,new RegExp(`attempt ${packedNotSent}: PVG_LENGTHS`)));
  });
  await t.test('rejects tampered frozen preVerificationGas and pvgSurplus',()=>{
    withRows(f,(rows,index)=>{
      const row=rows[packedNotSent], pvg=BigInt(row.packedOp.preVerificationGas)+1000n;
      row.packedOp.preVerificationGas=row.bundledOps[0].preVerificationGas=row.gas.preVerificationGas=String(pvg);
      row.pvgSurplus=String(BigInt(row.pvgSurplus)+1000n);
      const hash=localUserOpHash({...row.packedOp,nonce:BigInt(row.nonce),preVerificationGas:pvg},row.entryPoint,row.chainId);
      row.expectedUserOpHash=row.epUserOpHash=row.localUserOpHash=hash;
      row.bundledUserOpHashes=[hash];
      const ix=index[packedNotSent];
      Object.assign(ix,{expectedUserOpHash:hash,packedOp:row.packedOp,bundle:row.bundledOps});
      ix.gas.preVerificationGas=String(pvg);
    },()=>refuses(f,new RegExp(`attempt ${packedNotSent}: frozen preVerificationGas mismatch`)));
  });
  await t.test('a row withheld after packing keeps only the gates it reached',()=>{
    withRows(f,(rows,index)=>{
      const row=rows.find(r=>!r.sent && r.slotChecks.length===2);
      row.slotChecks=[row.slotChecks[0]];
      index[row.attemptIndex].slotChecks=row.slotChecks;
      Object.assign(row,{failingCheck:'deposit_floor',exclusion:'NOT_SENT:DEPOSIT_FLOOR'});
      delete row.scheduleDisposition;
    },()=>assert.doesNotMatch(validate(f).errors.join('\n'),/invalid slot gates/));
  });
  await t.test('rejects a sent row with only its pre-send gate',()=>{
    withRows(f,(rows,index)=>{
      const row=rows.find(r=>r.sent);
      row.slotChecks=[row.slotChecks[0]];
      index[row.attemptIndex].slotChecks=row.slotChecks;
    },()=>refuses(f,/invalid slot gates/));
  });
  await t.test('rejects trailer/journal window record mismatch',()=>{
    withArtifact(f,'trailer.json',trailer=>trailer.window.usedSlots--,()=>{
      refuses(f,/trailer\/journal window record mismatch/);
    });
  });
});

test('frozen window rejects raw-bound balance discontinuity for a returning TPM sender',async t=>{
  refuses(await fixture(t,{senderBalanceGap:true}),/balance continuity failed: tpmTokenBalances/);
});

test('frozen window rejects raw-bound operator balance discontinuity across a sender change',async t=>{
  refuses(await fixture(t,{balanceGap:true}),/balance continuity failed: operatorBalance/);
});

test('frozen window rejects a raw-bound nonce sequence gap for one sender',async t=>{
  refuses(await fixture(t,{nonceGap:true}),/nonce sequence must advance exactly one for sender\/key/);
});

test('a later slice passes the real registered protocol with fewer than 50 triplets',async t=>{
  const f=await fixture(t,{windowIndex:2});
  const {seed,scheduleSha256}=f.registered;
  const result=validateRun(f.runPath,{frozenPlan:join(f.dir,'bundle.json'),registered:{seed,scheduleSha256}});
  assert.equal(result.accepted,true,JSON.stringify(result));
  assert.equal(result.window.windowIndex,2);
  assert.equal(result.window.slots.length,REGISTERED_WINDOW.windowSlots);
  assert.equal(result.matchedTriplets,19);
});

test('cached price must survive through the last gate deadline, including the deadline itself',async t=>{
  const f=await fixture(t,{windowIndex:2});
  const {slice,schedule}=JSON.parse(readFileSync(join(f.dir,'manifest.json'),'utf8'));
  const deadline=schedule.payload.slots[slice.lastSlot].deadline_seconds-schedule.payload.slots[slice.firstSlot].start_seconds;
  const exact=validate(await fixture(t,{windowIndex:2,priceStalenessThreshold:deadline}));
  assert.equal(exact.accepted,true,JSON.stringify(exact));
  refuses(await fixture(t,{windowIndex:2,priceStalenessThreshold:deadline-1}),/cached price expires before the last slice gate deadline/);
});

test('a slice accepts a fresh SP quote even when all end passports are after expiry',async t=>{
  const f=await fixture(t,{endPassportDelay:1000n});
  const spRows=f.rows.filter(row=>row.arm==='SP' && row.verdict==='USEROP_SUCCESS');
  const {invariant,volatile}=spRows[0].passport;
  const expires=BigInt(volatile.cachedPriceUpdatedAt)+BigInt(invariant.superPaymaster.priceStalenessThreshold);
  assert.ok(f.rows.every(row=>row.slotChecks.every(({wait})=>BigInt(wait.deadline)<=expires)));
  assert.ok(spRows.every(row=>BigInt(row.tx.blockTimestamp)<=expires));
  for(const name of ['end',...f.accounts.map(sender=>'end-'+sender)]) {
    const p=JSON.parse(readFileSync(join(f.dir,'passports',name+'.json'),'utf8'));
    assert.ok(BigInt(p.block.timestamp)>expires);
  }
  const result=validate(f);
  assert.equal(result.accepted,true,JSON.stringify(result));
});

test('a slice refuses a successful SP inclusion after quote expiry with fresh gates',async t=>{
  const f=await fixture(t,{windowIndex:3,lastSPInclusionDelay:1000n});
  const row=f.rows.at(-1);
  assert.equal(row.arm,'SP');
  assert.equal(row.verdict,'USEROP_SUCCESS');
  const {invariant,volatile}=row.passport;
  const expires=BigInt(volatile.cachedPriceUpdatedAt)+BigInt(invariant.superPaymaster.priceStalenessThreshold);
  assert.ok(BigInt(row.tx.blockTimestamp)>expires);
  assert.ok(f.rows.every(row=>row.slotChecks.every(({wait})=>BigInt(wait.deadline)<=expires)));
  refuses(f,new RegExp(`attempt ${row.attemptIndex}: cached price expires before SP inclusion`));
});

for(const [label,outerGasDelta] of [['below',-1n],['above',1n]]) {
  test(`frozen window rejects an archived outer gas limit ${label} the sender plan`,async t=>{
    refuses(await fixture(t,{outerGasDelta}),/outer transaction gas limit differs from frozen plan/);
  });
}

for(const finalVpmVerdict of ['TX_FAILED','USEROP_REVERTED','NO_EVENT']) {
  test(`frozen window recomputes all ten PVG columns for a sent ${finalVpmVerdict} row`,async t=>{
    const f=await fixture(t,{finalVpmVerdict});
    const result=validate(f);
    assert.equal(result.accepted,true,JSON.stringify(result));
    assert.equal(result.recomputed[finalVpmVerdict],1);
    const {attemptIndex:i}=f.rows.find(row=>row.verdict===finalVpmVerdict);
    const mutations={pvgSurplus:'1',pvgSurplusReason:'cycle-max',pvgConsistency:'1',outerGasUsed:'1',
      outerEffectiveGasPrice:'1',l1DataFee:'0x1',calldataFloorGas:'1',calldataFloorBinding:null,bundlerNetGas:'1',opGasPrice:'1'};
    withRows(f,rows=>Object.assign(rows[i],mutations),()=>{
      const report=validate(f);
      assert.equal(report.accepted,false,JSON.stringify(report));
      for(const key of Object.keys(mutations)) assert.ok(report.errors.includes(`attempt ${i}: PVG measurement mismatch: ${key}`),report.errors.join('\n'));
    });
  });
}

test('window TPM trace is bound to A and checked against the receipt', async t => {
  for (const [name, options, error] of [
    ['two provider traces', {tpmTraceEndpoints:[0,1]}, /TPM trace incomplete/],
    ['B-only trace', {tpmTraceEndpoints:[1]}, /TPM raw trace missing or inconsistent/],
    ['paymaster price log with false refresh', {tpmPriceLog:true}, /TPM receipt TokenPriceUpdated contradicts postOpRefreshed/],
    ['other emitter with false refresh', {tpmPriceLog:'other'}],
    ['true refresh with no price log', {tpmRefresh:true}],
    ['true refresh with a paymaster price log', {tpmRefresh:true,tpmPriceLog:true}],
  ]) await t.test(name, async st => {
    const f = await fixture(st,options);
    if (error) return refuses(f,error);
    const result = validate(f);
    assert.equal(result.accepted,true,JSON.stringify(result));
    assert.equal(result.matchedTriplets,options.tpmRefresh?18:19);
  });
});

test('window accepts a reverted TPM receipt without traces and requires the A trace on success',async t=>{
  const f=await fixture(t,{finalTpmRevert:true});
  const result=validate(f);
  assert.equal(result.accepted,true,JSON.stringify(result));
  assert.equal(result.recomputed.TX_FAILED,1);
  assert.equal(f.rows.find(row=>row.verdict==='TX_FAILED').traces.length,0);
  refuses(await fixture(t,{tpmTraceEndpoints:[]}),/TPM raw trace missing or inconsistent/);
});

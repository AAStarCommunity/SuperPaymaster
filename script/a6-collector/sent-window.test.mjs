import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { stringify } from './evidence.mjs';
import { sentWindowFixture } from './sent-window-fixture.mjs';

function validate(f) {
  const r=spawnSync(process.execPath,['script/a6-collector/validate.mjs',f.runPath,'--frozen-plan',join(f.dir,'bundle.json')],{encoding:'utf8'});
  assert.ifError(r.error);
  assert.equal(r.signal,null,r.stderr);
  return {status:r.status,...JSON.parse(r.stdout)};
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
  assert.equal(result.matchedTriplets,f.end.targetTriplets);
  assert.deepEqual(result.recomputed,{NOT_SENT:f.firstSent*3,USEROP_SUCCESS:f.end.targetTriplets*3});
  for(const arm of ['SP','VPM','TPM']) {
    const sent=f.rows.filter(r=>r.sent && r.arm===arm);
    assert.equal(new Set(sent.map(r=>r.sender)).size,3);
    if(arm==='VPM') assert.ok(sent.every(r=>r.pmGas.post==='0'));
  }
  assert.ok(f.rows.some(r=>!r.sent && r.slotChecks.length===1 && !r.packedOp));
  assert.ok(f.rows.some(r=>!r.sent && r.slotChecks.length===2 && r.packedOp));

  const sender=f.accounts[1], endPath='passports/end-'+sender+'.json';
  await t.test('rejects sender 3 end passport invariant drift',()=>{
    withArtifact(f,'passports/end-'+f.accounts[2]+'.json',p=>p.invariant.xPNTs.maxSingleTxLimit='1',()=>{
      refuses(f,/end passport invariant drifted/);
    });
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

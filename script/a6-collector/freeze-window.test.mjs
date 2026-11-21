import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createWindow } from './window-schedule.mjs';
import { sha256, writeArtifact, writeTrailer } from './evidence.mjs';
import { freeze } from './freeze.mjs';

const accounts=[200,201,202].map(n=>'0x'+n.toString(16).padStart(40,'0'));
const bytes=execFileSync('python3.11',['-B','script/a6-collector/frozen-fixture.py']);

// Lays out a scheduled window the way collector.mjs does: manifest.json at window start
// (collector.mjs, writeArtifact of {...window.manifest, windowId, startTimestamp}), then
// run.jsonl, index.ndjson, raw archives and the one-shot trailer.
function scheduledWindow(d) {
  const window=createWindow({readBundle:()=>bytes,bundleSha256:sha256(bytes),seed:'public',chainId:10,accounts});
  const w=join(d,'window');mkdirSync(w);
  writeArtifact(w,'manifest.json',{...window.manifest,windowId:'run-test',startTimestamp:1795413100});
  mkdirSync(join(w,'raw'));writeFileSync(join(w,'raw','A.ndjson'),'{"id":1}\n');
  writeFileSync(join(w,'run.jsonl'),'{"kind":"run_start"}\n{"kind":"run_end"}\n');
  writeFileSync(join(w,'index.ndjson'),'{"attempt":0}\n');
  writeTrailer(w,{schemaVersion:'a6-evidence-trailer/1',rehearsal:false,windowId:'run-test',void:true,window:{status:'INCOMPLETE'}});
  return w;
}

test('a scheduled window, which already holds the collector manifest.json, freezes once and keeps that file as an ordinary frozen entry',()=>{
  const d=realpathSync(mkdtempSync(join(tmpdir(),'a6-freeze-window-')));
  try {
    const w=scheduledWindow(d);
    const collectorManifest=readFileSync(join(w,'manifest.json'));
    const sample=join(d,'sampling.json');writeFileSync(sample,'{"seed":"s","samples":[]}\n');
    const m=freeze(w,sample);
    assert.equal(m.schemaVersion,'a6-freeze/1');
    assert.equal(m.rehearsal,false);
    for(const path of ['manifest.json','run.jsonl','index.ndjson','raw/A.ndjson','trailer.json','sampling-input.json'])
      assert.ok(m.files.some(f=>f.path===path),`frozen files include ${path}`);
    assert.equal(m.files.find(f=>f.path==='manifest.json').sha256,sha256(collectorManifest));
    assert.ok(!m.files.some(f=>f.path.startsWith('freeze-manifest')));
    // The collector's manifest is untouched; the freeze record and its digest are separate files.
    assert.deepEqual(readFileSync(join(w,'manifest.json')),collectorManifest);
    assert.equal(readFileSync(join(w,'freeze-manifest.sha256'),'utf8'),sha256(readFileSync(join(w,'freeze-manifest.json')))+'  freeze-manifest.json\n');
    assert.deepEqual(JSON.parse(readFileSync(join(w,'freeze-manifest.json'),'utf8')).files,m.files);
    assert.throws(()=>freeze(w,sample),/already frozen/);
  } finally {rmSync(d,{recursive:true,force:true});}
});

test('freeze CLI on a scheduled window exits 0 and writes the freeze record',()=>{
  const d=realpathSync(mkdtempSync(join(tmpdir(),'a6-freeze-window-cli-')));
  try {
    const w=scheduledWindow(d);
    const sample=join(d,'sampling.json');writeFileSync(sample,'{}\n');
    const r=spawnSync(process.execPath,['script/a6-collector/freeze.mjs',w,'--sampling',sample],{encoding:'utf8'});
    assert.equal(r.status,0,r.stderr);
    assert.ok(existsSync(join(w,'freeze-manifest.json')) && existsSync(join(w,'freeze-manifest.sha256')));
    const again=spawnSync(process.execPath,['script/a6-collector/freeze.mjs',w,'--sampling',sample],{encoding:'utf8'});
    assert.equal(again.status,2);assert.match(again.stderr,/already frozen/);
  } finally {rmSync(d,{recursive:true,force:true});}
});

// validate.mjs reads the rehearsal marker from trailer.json and the freeze record, not from the
// collector's window manifest (which has no rehearsal field).
function rehearsalRun(d) {
  const rows=readFileSync(new URL('../../docs/design/aoa-balance-mode/data/a6-gauge-local/positive.jsonl',import.meta.url),'utf8').trim().split('\n').map(JSON.parse);
  rows[0].rehearsal=true;rows.at(-1).rehearsal=true;
  writeFileSync(join(d,'run.jsonl'),rows.map(JSON.stringify).join('\n')+'\n');
  writeTrailer(d,{rehearsal:true});
  writeFileSync(join(d,'sample.json'),'{}');
}
const validate=d=>JSON.parse(spawnSync(process.execPath,['script/a6-collector/validate.mjs',join(d,'run.jsonl')],{encoding:'utf8'}).stdout);

test('a frozen rehearsal window carrying the collector manifest.json has no rehearsal marker mismatch',()=>{
  const d=realpathSync(mkdtempSync(join(tmpdir(),'a6-freeze-marker-')));
  try {
    rehearsalRun(d);
    const window=createWindow({readBundle:()=>bytes,bundleSha256:sha256(bytes),seed:'public',chainId:10,accounts});
    writeArtifact(d,'manifest.json',{...window.manifest,windowId:'run-test',startTimestamp:1});
    assert.equal(freeze(d,join(d,'sample.json')).rehearsal,true);
    const report=validate(d);
    assert.equal(report.rehearsal,true);
    assert.ok(!report.errors.includes('rehearsal marker mismatch'),JSON.stringify(report.errors));
  } finally {rmSync(d,{recursive:true,force:true});}
});

test('validate reads the freeze record as a rehearsal marker',()=>{
  const d=realpathSync(mkdtempSync(join(tmpdir(),'a6-freeze-marker2-')));
  try {
    rehearsalRun(d);freeze(d,join(d,'sample.json'));
    const p=join(d,'freeze-manifest.json');
    writeFileSync(p,JSON.stringify({...JSON.parse(readFileSync(p,'utf8')),rehearsal:false}));
    assert.ok(validate(d).errors.includes('rehearsal marker mismatch'));
  } finally {rmSync(d,{recursive:true,force:true});}
});

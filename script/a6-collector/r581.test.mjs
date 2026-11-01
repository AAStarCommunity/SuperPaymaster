import { tmpdir } from 'node:os';
import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, realpathSync, readFileSync, writeFileSync, chmodSync, mkdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { repairFixture } from './repair-fixture.mjs';
import { artifactErrors } from './artifact-validate.mjs';
import { publicAddress } from './formal.mjs';
import { exportRun } from './to-aoa-m3-receive.mjs';
const legacy=new URL('../../docs/design/aoa-balance-mode/data/a6-gauge-local/n50-mechanism.jsonl',import.meta.url);
function temp(fn) {const d=realpathSync(mkdtempSync(join(tmpdir(),'r581-')));try{return fn(d);}finally{rmSync(d,{recursive:true,force:true});}}
const archiveDir=realpathSync(mkdtempSync(join(tmpdir(),'r581-shared-')));
const base=repairFixture(archiveDir,3);
after(()=>rmSync(archiveDir,{recursive:true,force:true}));
function fixture() {
  const {start,attempts,rows,passport,finalBlockCheck}=structuredClone({start:base.start,attempts:base.attempts,rows:base.rows,passport:base.passport,finalBlockCheck:base.finalBlockCheck});
  const trailer={rehearsal:true,finalBlockCheck,endPassport:passport,triples:[{tripleIndex:0,included:true,attempts:[0,1,2]}]};
  return {start,attempts,rows,check:()=>artifactErrors(archiveDir,rows,trailer,[start,...attempts])};
}
function cli(d,rows,window) {
  const path=join(d,'run.jsonl');writeFileSync(path,rows.map(JSON.stringify).join('\n')+'\n');
  const result=spawnSync(process.execPath,['script/a6-collector/validate.mjs',path,...(window?['--window',window]:[])],{encoding:'utf8'});
  return {...result,report:JSON.parse(result.stdout),path};
}
function attack() {
  const rows=readFileSync(legacy,'utf8').trim().split('\n').map(JSON.parse),start=rows[0];
  for(const r of rows) r.schema='a6-gauge/2';
  Object.assign(start,{rpcA:'https://a.example',rpcB:'https://b.example',allowSameEndpointLocal:false,protocolConformant:true});
  for(const r of [start,rows.at(-1)]) {
    r.passport.allowSameEndpointLocal=false;
    for(const s of Object.values(r.passport.invariant.stakes))Object.assign(s,{staked:true,stake:'1000000000000000000',unstakeDelaySec:'86400'});
    r.passport.invariant.credit={policy:0,hasPendingPolicy:false,pendingPolicy:0,pendingPolicyEta:0,policyEpoch:0};
  }
  return rows;
}
test('M-1 legacy N50 remains exit 3 and reports formal false',()=>temp(d=>{
  const r=cli(d,readFileSync(legacy,'utf8').trim().split('\n').map(JSON.parse));
  assert.equal(r.status,3);assert.equal(r.report.formal,false);
}));
for(const flag of [undefined,false]) test(`M-1 forged N50 formal=${flag} cannot be accepted or exported as formal`,()=>temp(d=>{
  const rows=attack();rows[0].formal=flag;const r=cli(d,rows);
  assert.notEqual(r.status,0);assert.equal(r.report.accepted,false);assert.equal(r.report.protocolConformant,false);assert.equal(r.report.formal,false);
  try {assert.notEqual(exportRun(r.path,join(d,'export')).runType,'formal-candidate');}catch(e){assert.match(e.message,/run not shown consistent/);}
  assert.notEqual(exportRun(r.path,join(d,'unchecked'),{validate:false}).runType,'formal-candidate');
}));
test('M-2 formal window cannot strip rehearsal on chain 31337',()=>temp(d=>{
  const f=fixture(d);assert.deepEqual(f.check(),[]);delete f.start.rehearsal;
  assert.match(f.check().join(';'),/chainId policy/);
}));
test('M-2 rehearsal requires chain 31337',()=>temp(d=>{
  const f=fixture(d);f.start.passport.chainId=1;
  assert.match(f.check().join(';'),/chainId policy/);
}));
test('M-2 non-rehearsal chain must match frozen target',()=>temp(d=>{
  const f=fixture(d);delete f.start.rehearsal;f.start.passport.chainId=11155111;
  assert.match(f.check().join(';'),/target chainId/);
}));
for(const key of ['gasUsed','effectiveGasPrice']) test(`L-1 receipt binds tx.${key}`,()=>temp(d=>{
  const f=fixture(d);assert.deepEqual(f.check(),[]);f.attempts[0].tx[key]=String(BigInt(f.attempts[0].tx[key])+1n);
  assert.match(f.check().join(';'),new RegExp('raw receipt '+key));
}));
// Every field emitted by viem's transaction formatter in this fixture is covered,
// including null fields; whole-object equality also rejects added or deleted keys.
const rawFields=temp(d=>Object.keys(fixture(d).attempts[0].tx.raw));
for(const key of rawFields) test(`L-1 raw transaction binds tx.raw.${key}`,()=>temp(d=>{
  const f=fixture(d);assert.deepEqual(f.check(),[]);f.attempts[0].tx.raw[key]='mutated';
  assert.match(f.check().join(';'),/raw transaction summary/);
}));
for(const key of ['observedUserOpEvent']) test(`L-2 deleting ${key} fails formal archive validation`,()=>temp(d=>{
  const f=fixture(d);assert.deepEqual(f.check(),[]);delete f.attempts[0][key];
  assert.ok(f.check().length,`${key} was accepted`);
}));
for(const ip of ['2001:db8::1','2001:0db8:0:0:0:0:0:1','2002:0808:0808::1','2001::1','2001:0000:1234::1']) test(`L-4 rejects reserved IPv6 ${ip}`,()=>assert.equal(publicAddress(ip),false));
test('L-4 keeps public IPv6 usable',()=>assert.equal(publicAddress('2606:4700:4700::1111'),true));
test('L-4 rehearsal reports missing nightly directory before executing any command',()=>temp(d=>{
  // Run only the configuration prefix, never the Anvil/deployment body.
  const source=readFileSync(new URL('./rehearsal-window.sh',import.meta.url),'utf8');
  const prefix=source.slice(0,source.indexOf('export FOUNDRY_DISABLE_NIGHTLY_WARNING'));
  const env={...process.env};delete env.A6_FOUNDRY_NIGHTLY_DIR;
  const missing=spawnSync('bash',['-c',prefix],{env,encoding:'utf8'});
  assert.notEqual(missing.status,0);assert.match(missing.stderr,/Set A6_FOUNDRY_NIGHTLY_DIR/);
  const configured=spawnSync('bash',['-c',prefix+'\nprintf "%s" "$PATH"'],{env:{...env,A6_FOUNDRY_NIGHTLY_DIR:d},encoding:'utf8'});
  assert.equal(configured.status,0);assert.ok(configured.stdout.startsWith(d+':'));
}));

// Isolate the exporter trust boundary with a controlled validator report. The
// real validator attack is exercised above; this is not an archive-acceptance fixture.
for(const [name,startFormal,reportFormal] of [['missing start formal',undefined,true],['false start formal',false,true],['missing report formal',true,undefined]]) test(`M-1 exporter rejects ${name} even with accepted report`,()=>temp(d=>{
  const rows=attack();rows[0].formal=true;
  const path=join(d,'run.jsonl'),bin=join(d,'bin');mkdirSync(bin);
  const stub=join(bin,'node');
  const report={consistent:true,accepted:true,formal:true};
  const writeStub=()=>{writeFileSync(stub,'#!'+process.execPath+'\nif(process.argv[process.argv.indexOf("--window")+1]!=='+JSON.stringify(d)+')process.exit(9);const fs=require("node:fs");fs.writeFileSync(process.argv[process.argv.indexOf("--json")+1],'+JSON.stringify(JSON.stringify(report))+');');chmodSync(stub,0o700);};
  writeStub();writeFileSync(path,rows.map(JSON.stringify).join('\n')+'\n');
  const previous=process.env.PATH;process.env.PATH=bin+':'+previous;
  try {
    assert.equal(exportRun(path,join(d,'positive')).runType,'formal-candidate');
    rows[0].formal=startFormal;report.formal=reportFormal;writeStub();
    writeFileSync(path,rows.map(JSON.stringify).join('\n')+'\n');
    assert.notEqual(exportRun(path,join(d,'negative')).runType,'formal-candidate');
  } finally {process.env.PATH=previous;}
}));

test('L-2 deleting userOpEvent.logIndex fails',()=>temp(d=>{
  const f=fixture(d);delete f.attempts[0].userOpEvent.logIndex;assert.ok(f.check().length);
}));

test('M-1 forged legacy formal true without archives fails at the CLI and cannot export',()=>temp(d=>{
  const rows=attack();rows[0].formal=true;
  const r=cli(d,rows);
  assert.notEqual(r.status,0);assert.notEqual(r.report.accepted,true);
  assert.match(JSON.stringify(r.report),/missing or invalid index/);
  assert.throws(()=>exportRun(r.path,join(d,'checked')),/run not shown consistent/);
  assert.equal(exportRun(r.path,join(d,'unchecked'),{validate:false}).runType,'rehearsal');
}));
test('M-2 stripped rehearsal chain 31337 is rejected by CLI chain policy',()=>temp(d=>{
  const f=repairFixture(d,3);
  delete f.start.rehearsal;
  const trailer={schemaVersion:'a6-evidence-trailer/1',windowId:'w',void:false,stopReason:'COMPLETE',stopAttempt:2,finalBlockCheck:f.finalBlockCheck,endPassport:f.passport,triples:[{tripleIndex:0,included:true,attempts:[0,1,2]}],replacements:[],counts:{}};
  writeFileSync(join(d,'index.ndjson'),f.rows.map(JSON.stringify).join('\n'));
  writeFileSync(join(d,'trailer.json'),JSON.stringify(trailer));
  writeFileSync(join(d,'manifest.json'),'{}');
  const r=cli(d,[{...f.start,bMax:1},...f.attempts,{kind:'run_end',passport:f.start.passport,stop:{reason:'COMPLETE',code:0},triplets:[]}]);
  assert.notEqual(r.status,0);assert.notEqual(r.report.accepted,true);
  assert.match(JSON.stringify(r.report),/formal\/rehearsal chainId policy mismatch/);
  assert.doesNotMatch(JSON.stringify(r.report),/rehearsal marker mismatch/);
  temp(snapshot=>{
    const captured=cli(snapshot,[{...f.start,bMax:1},...f.attempts,{kind:'run_end',passport:f.start.passport,stop:{reason:'COMPLETE',code:0},triplets:[]}],d);
    assert.match(JSON.stringify(captured.report),/formal\/rehearsal chainId policy mismatch/);
    assert.doesNotMatch(JSON.stringify(captured.report),/missing or invalid index/);
  });
}));
test('M-2 missing frozen target chain is rejected',()=>{
  const f=fixture();delete f.start.rehearsal;f.start.passport.chainId=1;delete f.start.frozenConfig.chainId;
  assert.match(f.check().join(';'),/target chainId required|Passport identity\/config mismatch/);
});
for(const ip of ['::ffff:127.0.0.1','::ffff:7f00:1','0:0:0:0:0:ffff:7f00:1','::127.0.0.1','::7f00:1','64:ff9b::127.0.0.1','64:ff9b::7f00:1','0064:ff9b:0:0:0:0:7f00:1','64:ff9b:1::a00:1']) test(`L-4 rejects IPv4 embedding ${ip}`,()=>assert.equal(publicAddress(ip),false));

for (const ip of ['2001:2::1','2001:0002:0000:ffff::1','2001:10::1','2001:1f:ffff::1','2001:20::1','2001:2f:ffff::1']) test(`reserved prefix rejects ${ip}`,()=>assert.equal(publicAddress(ip),false));
for (const ip of ['2001:2:1::1','2001:30::1','2001:4860:4860::8888']) test(`public prefix permits ${ip}`,()=>assert.equal(publicAddress(ip),true));

import { formalWindowFixture } from './formal-window-fixture.mjs';
test('complete formal CLI window loses acceptance and export classification without formal',()=>temp(d=>{
  const rows=formalWindowFixture(d);
  const positive=cli(d,rows);
  assert.equal(positive.status,0,JSON.stringify(positive.report));
  assert.equal(positive.report.accepted,true);
  assert.equal(exportRun(positive.path,join(d,'positive')).runType,'formal-candidate');
  delete rows[0].formal;
  const negative=cli(d,rows);
  assert.notEqual(negative.status,0);assert.notEqual(negative.report.accepted,true);assert.equal(negative.report.formal,false);
  assert.notEqual(exportRun(negative.path,join(d,'unchecked'),{validate:false}).runType,'formal-candidate');
  assert.throws(()=>exportRun(negative.path,join(d,'checked')),/run not shown consistent/);
}));

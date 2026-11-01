import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, realpathSync, rmSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { repairFixture } from './repair-fixture.mjs';
import { artifactErrors } from './artifact-validate.mjs';
import { windowErrors } from './evidence-validate.mjs';
import { exclusionReason, EXCLUSION_REASONS } from './evidence.mjs';
const H='0x'+'ab'.repeat(32);
function temp(fn) {const d=realpathSync(mkdtempSync('/tmp/a6-review-'));try{return fn(d);}finally{rmSync(d,{recursive:true,force:true});}}
function editRaw(d,path,fn) {
  const records=readFileSync(join(d,path),'utf8').trim().split('\n').map(JSON.parse);fn(records);
  writeFileSync(join(d,path),records.map(JSON.stringify).join('\n')+'\n');
}
function request(raw) {const q=JSON.parse(Buffer.from(raw.request,'base64'));Object.assign(q,{method:raw.method,params:raw.params});raw.request=raw.requestBase64=Buffer.from(JSON.stringify(q)).toString('base64');}
function fixture(d) {
  const f=repairFixture(d,3),trailer={finalBlockCheck:f.finalBlockCheck,endPassport:f.passport,triples:[{tripleIndex:0,included:false,attempts:[0,1,2]}]};
  return {...f,trailer,check:()=>artifactErrors(d,f.rows,trailer,[f.start,...f.attempts])};
}
test('H continuity rejects TPM token/cache changes and limits rehearsal timestamp exemption',()=>temp(d=>{
  const rows=readFileSync(new URL('../../docs/design/aoa-balance-mode/data/a6-gauge-local/n50-mechanism.jsonl',import.meta.url),'utf8').trim().split('\n').map(JSON.parse);
  const tpm=rows.filter(r=>r.kind==='attempt' && r.arm==='TPM');assert.ok(tpm.length>1);
  for(const r of tpm) for(const side of ['before','after']) for(const e of ['A','B']) Object.assign(r.readbacks[side][e],{tpmCachedPriceTimestamp:'10',tpmTokenBalances:{sender:'5',paymaster:'7'}});
  const run=()=>{const p=join(d,'run.jsonl');writeFileSync(p,rows.map(JSON.stringify).join('\n')+'\n');const out=spawnSync(process.execPath,['script/a6-collector/validate.mjs',p],{encoding:'utf8'});return JSON.parse(out.stdout);};
  assert.equal(run().consistent,true);
  for(const [field,value] of [['tpmCachedPriceTimestamp','11'],['tpmTokenBalances',{sender:'6',paymaster:'7'}],['tpmTokenBalances',{sender:'5',paymaster:'8'}]]) {
    const r=tpm[1],old=r.readbacks.before.A[field];
    for(const e of ['A','B'])r.readbacks.before[e][field]=value;
    assert.match(run().errors.join(';'),new RegExp('balance continuity failed: '+field));
    for(const e of ['A','B'])r.readbacks.before[e][field]=old;
  }
  const vpm=rows.filter(r=>r.kind==='attempt' && r.arm==='VPM')[1];
  for(const field of ['epDeposit','operatorBalance']) {
    const old=vpm.readbacks.before.A[field];
    for(const e of ['A','B'])vpm.readbacks.before[e][field]=String(BigInt(old)+1n);
    assert.match(run().errors.join(';'),new RegExp('balance continuity failed: '+field));
    for(const e of ['A','B'])vpm.readbacks.before[e][field]=old;
  }
  rows[0].rehearsal=true;rows.at(-1).rehearsal=true;
  tpm[1].rehearsalControl={kind:'tpmCacheAged',cachedPriceTimestamp:{to:'11'}};
  assert.match(run().errors.join(';'),/rehearsal cache timestamp mismatch/);
  // The collector reads the uint48 back as a JSON number; the control records a decimal string (real rehearsal shape).
  for(const e of ['A','B'])tpm[1].readbacks.before[e].tpmCachedPriceTimestamp=11;
  assert.doesNotMatch(run().errors.join(';'),/rehearsal cache timestamp mismatch|balance continuity failed: tpmCachedPriceTimestamp/);
  for(const e of ['A','B'])tpm[1].readbacks.before[e].tpmTokenBalances.sender='99';
  assert.match(run().errors.join(';'),/balance continuity failed: tpmTokenBalances/);
}));
test('H archive allowlist rejects mutation and scopes rehearsal writes to controlled attempt blocks',()=>temp(d=>{
  const f=fixture(d);assert.deepEqual(f.check(),[]);
  const path=f.archives[0].records[0].path,saved=readFileSync(join(d,path));
  const extraPath=f.archives[0].records.at(-1).path,extraSaved=readFileSync(join(d,extraPath));
  const insert=method=>editRaw(d,extraPath,rs=>{
    const raw=structuredClone(rs.at(-1));Object.assign(raw,{id:raw.id+1,method,params:[],blockAnchor:null,anchor:null});request(raw);rs.push(raw);
  });
  for(const method of ['anvil_setStorageAt','evm_mine','hardhat_setBalance','debug_setHead','eth_sendTransaction','personal_unlockAccount','unknown_method']) {
    insert(method);assert.match(f.check().join(';'),/archived RPC method forbidden/);writeFileSync(join(d,extraPath),extraSaved);
  }
  f.start.rehearsal=f.trailer.rehearsal=true;
  const a=f.attempts[2];a.rehearsalControl={kind:'tpmCacheAged',atBlock:'103',cachedPriceTimestamp:{to:'10'}};
  // Replace an existing nonessential send record, preserving strict archive ID order.
  for(const method of ['anvil_setStorageAt','evm_mine']) for(const number of ['102','103','104']) {
    editRaw(d,path,rs=>{const raw=rs.find(r=>r.method==='eth_sendRawTransaction' && r.id>a.evidenceStart[0]);Object.assign(raw,{method,params:[],blockAnchor:{number,hash:H},anchor:null});request(raw);});
    if(number==='103') assert.doesNotMatch(f.check().join(';'),/archived RPC method forbidden/);
    else assert.match(f.check().join(';'),/archived RPC method forbidden/);
    writeFileSync(join(d,path),saved);
  }
  delete a.rehearsalControl;insert('evm_mine');assert.match(f.check().join(';'),/archived RPC method forbidden/);
}));
test('M1 exact archived tracer options reject extra nested and top-level options',()=>temp(d=>{
  const f=fixture(d);assert.deepEqual(f.check(),[]);
  for(const endpoint of ['A','B']) for(const tracer of ['callTracer','prestateTracer']) for(const [key,value,nested] of [['disableStorage',true,true],['disableCode',true,true],['onlyTopCall',true,true],['timeout','1s',false]]) {
    const path=f.rows[2].trace.raw[endpoint][0].path,saved=readFileSync(join(d,path));
    editRaw(d,path,rs=>{for(const raw of rs)if(raw.method==='debug_traceTransaction' && raw.params[1].tracer===tracer){(nested?raw.params[1].tracerConfig:raw.params[1])[key]=value;request(raw);}});
    assert.match(f.check().join(';'),/exact tracer config required/);writeFileSync(join(d,path),saved);
  }
}));
test('M2 labels cannot manufacture exclusion evidence or override decoded reasons',()=>{
  for(const reason of EXCLUSION_REASONS) assert.throws(()=>exclusionReason({reason,verdict:'NOT_SENT'}),/UNAPPROVED_ABANDONMENT/,reason);
  assert.throws(()=>exclusionReason({reason:'AA32',preflight:{revertReason:'price stale'}}),/UNAPPROVED_ABANDONMENT/);
  assert.throws(()=>exclusionReason({reason:'not_included',sent:true,verdict:'NO_EVENT',logs:[],tx:{hash:H,blockHash:H,blockNumber:'1',status:'success'}}),/UNAPPROVED_ABANDONMENT/);
  assert.equal(exclusionReason({reason:'bundler_error',submissionException:{message:'submission threw'}}),'bundler_error');
  assert.equal(exclusionReason({sent:true,tx:{hash:H},logs:[],verdict:'NO_EVENT'}),'not_included');
});
test('M2 artifact validation recomputes indexed exclusion labels',()=>temp(d=>{
  const f=fixture(d);assert.deepEqual(f.check(),[]);
  f.rows[0].exclusionReason='AA32';assert.match(f.check().join(';'),/exclusionReason mismatch/);
}));
test('M2 row and replacement validators reject unsupported exclusion labels',()=>temp(d=>{
  const f=fixture(d),a=f.attempts[0];a.reason='AA32';a.verdict='NOT_SENT';f.rows[0].verdict='NOT_SENT';f.rows[0].exclusionReason='AA32';
  const trailer={...f.trailer,schemaVersion:'a6-evidence-trailer/1',windowId:'w',stopAttempt:2,replacements:[{abandoned:{windowId:'w',tripleIndex:0},replacement:{windowId:'w',tripleIndex:1},reason:'AA32'}]};
  const errors=windowErrors(f.rows,trailer,[f.start,...f.attempts,{kind:'run_end',stop:{code:0}}]);
  assert.match(errors.join(';'),/UNAPPROVED_ABANDONMENT/);assert.match(errors.join(';'),/unsupported replacement exclusion reason/);
}));

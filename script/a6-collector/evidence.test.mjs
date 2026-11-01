import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, rmSync, mkdirSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { rawArchive, evidenceIndex, loadRegistry, loadPins, sha256 } from './evidence.mjs';
import { freeze } from './freeze.mjs';
import { dispositionErrors, feePauseErrors } from './disposition.mjs';
import { feePause, formalConfig, armOrder } from './formal.mjs';
import { localUserOpHash } from './gauge-lib.mjs';
import { concat, pad, toHex } from 'viem';
const H = '0x'+'ab'.repeat(32), address = n => '0x'+String(n).padStart(40,'0');
function temp(fn) { const d=mkdtempSync(join(tmpdir(),'a6-slice2-')); try { return fn(d); } finally { rmSync(d,{recursive:true,force:true}); } }
const categories = ['collector','validator','dependencies','contractSources','abi','config'];
const pins = Object.fromEntries(categories.map(k => [k,[{path:'/offline/fixture',sha256:'a'.repeat(64)}]]));
const schema = JSON.parse(readFileSync(new URL('./evidence-index.schema.json',import.meta.url)));
// Check the schema vocabulary used by this interface without downloading a validator.
function conforms(v,s) {
  if(s.allOf && !s.allOf.every(x=>conforms(v,x))) return false;
  if(s.if && conforms(v,s.if) && s.then && !conforms(v,s.then)) return false;
  if(s.not && conforms(v,s.not)) return false;
  if(!s.type && s.properties && !Object.entries(s.properties).every(([k,x])=>!(k in v)||conforms(v[k],x))) return false;
  if(s.$ref) return conforms(v,schema.$defs[s.$ref.split('/').at(-1)]);
  if(s.anyOf) return s.anyOf.some(x=>conforms(v,x));
  if(s.const !== undefined && v!==s.const) return false;
  if(s.enum && !s.enum.includes(v)) return false;
  if(s.type==='null') return v===null;
  if(s.type==='object') return v!==null && typeof v==='object' && !Array.isArray(v) && (s.required??[]).every(k=>k in v) && Object.entries(v).every(([k,x])=>s.properties?.[k] ? conforms(x,s.properties[k]) : s.additionalProperties===false ? false : typeof s.additionalProperties==='object' ? conforms(x,s.additionalProperties):true);
  if(s.type==='array') return Array.isArray(v) && v.length >= (s.minItems??0) && v.length <= (s.maxItems??Infinity) && (!s.uniqueItems || new Set(v.map(x=>JSON.stringify(x))).size===v.length) && v.every(x=>conforms(x,s.items));
  if(s.type==='integer') return Number.isSafeInteger(v) && v >= (s.minimum??-Infinity);
  if(s.type==='boolean') return typeof v==='boolean';
  if(s.type==='string') return typeof v==='string' && v.length >= (s.minLength??0) && (!s.pattern || new RegExp(s.pattern).test(v));
  return true;
}
test('raw archive exact bytes, UTC rollover and independent monotonically increasing endpoint IDs',()=>temp(d=>{
  const A=rawArchive(d,'A'), B=rawArchive(d,'B');
  const request=Buffer.from('{ "jsonrpc": "2.0" }\n'), response=Buffer.from([0,255,10]);
  for(const [a,ts] of [[A,'2026-10-31T23:59:59.000Z'],[B,'2026-11-01T00:00:00.000Z'],[A,'2026-11-01T00:00:01.000Z']]) a.append({requestedAtUtc:ts,method:'eth_call',params:[{},'0x2a'],anchor:{number:'0x2a',hash:H},requestBase64:request.toString('base64'),responseBase64:response.toString('base64')});
  assert.throws(()=>rawArchive(d,'A'),/EEXIST/);
  assert.deepEqual(A.ids,[1,2]); assert.deepEqual(B.ids,[1]);
  for(const a of [A,B]) for(const r of a.records) {
    const saved=JSON.parse(readFileSync(join(d,r.path),'utf8'));
    assert.deepEqual(Buffer.from(saved.request,'base64'),request); assert.deepEqual(Buffer.from(saved.response,'base64'),response);
    assert.equal(saved.blockAnchor.number,'42'); assert.equal(saved.id,r.id);
  }
}));
test('index records unsent absence, all state fields and rejects malformed structural identities',()=>{
  const row={attemptIndex:0,tripletIndex:0,arm:'SP',verdict:'NOT_SENT',failingCheck:'basefee_above_cap',chainId:1};
  const x=evidenceIndex(row,{windowId:'w',archives:[{records:[]},{records:[]}],pins,rpcIdentity:{path:'rpc-identity.json',sha256:'b'.repeat(64)},passports:{},included:false,stopReason:'BASEFEE_PAUSED'});
  assert.ok(conforms(x,schema)); assert.equal(x.tx,null); assert.equal(x.notSentReason,'basefee_above_cap');
  assert.equal(Object.keys(x.state.before).length,14); assert.ok(x.missing['/tx']);
  assert.equal(conforms({...x,attempt:-1},schema),false); assert.equal(conforms({...x,armOrder:['SP','SP','TPM']},schema),false);
  const bad=structuredClone(x); delete bad.state.after.debts; assert.equal(conforms(bad,schema),false);
});
test('index references observed UOE position, raw transaction bytes and both fixed state anchors',()=>temp(d=>{
  const row=JSON.parse(readFileSync(new URL('../../docs/design/aoa-balance-mode/data/a6-gauge-local/positive.jsonl',import.meta.url),'utf8').split('\n')[1]);
  const archives=['A','B'].map(e=>rawArchive(d,e));
  const uoe=row.logs.find(l=>l.topics[1]===row.expectedUserOpHash); row.userOpEvent.logIndex=uoe.logIndex;
  row.tx.input='0x1234'; row.tx.handleOpsIndex=0; row.tx.maxFeePerGas='20000000000'; row.tx.maxPriorityFeePerGas='2000000000';
  const rawTx={hash:row.tx.hash,input:row.tx.input};
  for(const a of archives) for(const side of ['before','after']) {
    const s=row.readbacks[side].A;
    for(const method of ['eth_call','eth_getTransactionReceipt','eth_getTransactionByHash']) a.append({requestedAtUtc:'2026-11-01T00:00:00.000Z',method,params:method==='eth_call'?[{},'0x'+BigInt(s.blockNumber).toString(16)]:[row.tx.hash],anchor:{number:'0x'+BigInt(s.blockNumber).toString(16),hash:s.blockHash},requestBase64:'e30=',responseBase64:Buffer.from(JSON.stringify({result:rawTx})).toString('base64')});
  }
  const p={path:'passports/start.json',raw:{A:[],B:[]}};
  const x=evidenceIndex(row,{windowId:'w',archives,pins,rpcIdentity:{path:'rpc-identity.json',sha256:'b'.repeat(64)},passports:{start:p,attempt:p,end:p},included:true,stopReason:'COMPLETE'});
  assert.ok(conforms(x,schema)); assert.equal(x.observedUserOpHash,row.expectedUserOpHash); assert.equal(x.uoe.logIndex,uoe.logIndex); assert.deepEqual(x.tx.raw,rawTx);
  for(const side of ['before','after']) for(const e of ['A','B']) for(const ref of x.state[side].debts.raw[e]) {
    const record=readFileSync(join(d,ref.path),'utf8').trim().split('\n').map(JSON.parse).find(r=>r.id===ref.id);
    assert.equal(record.blockAnchor.hash,x.state[side].debts.anchor.hash);
  }
}));
test('registry requires evidence, independent operators/backends/upstreams and credential-free labels; pins verify bytes',()=>temp(d=>{
  const evidence=join(d,'proof');writeFileSync(evidence,'offline evidence');const pin={path:evidence,sha256:sha256(readFileSync(evidence))};
  const registry={schemaVersion:'a6-rpc-identity/1',...Object.fromEntries(['A','B'].map(e=>[e,{operatorName:e,backendIdentity:e,upstream:e,endpointLabel:e,registeredAt:'2026-11-01T00:00:00.000Z',evidence:[pin]}]))};
  const path=join(d,'registry.json'); const save=x=>writeFileSync(path,JSON.stringify(x));save(registry);assert.ok(loadRegistry(path));
  for(const field of ['operatorName','backendIdentity','upstream']) { const bad=structuredClone(registry);bad.B[field]=bad.A[field];save(bad);assert.throws(()=>loadRegistry(path),/share/); }
  const bad=structuredClone(registry);bad.A.endpointLabel='https://key@rpc.invalid';save(bad);assert.throws(()=>loadRegistry(path),/credential/);
  const pp=join(d,'pins.json');writeFileSync(pp,JSON.stringify(Object.fromEntries(categories.map(k=>[k,[pin]]))));assert.ok(loadPins(pp));
  writeFileSync(evidence,'tampered');save(registry);assert.throws(()=>loadRegistry(path),/SHA-256/);assert.throws(()=>loadPins(pp),/SHA-256/);
}));
test('freeze includes nested and hidden files plus exact sampling artifact, hashes itself separately and refuses twice',()=>temp(d=>{
  const w=join(d,'window');mkdirSync(w);mkdirSync(join(w,'raw'));writeFileSync(join(w,'raw','x'),'raw bytes');writeFileSync(join(w,'.hidden'),'hidden');
  const sample=join(d,'sampling');writeFileSync(sample,'seed/list/command\n');const m=freeze(w,sample);
  assert.ok(m.files.some(f=>f.path==='.hidden'));assert.ok(m.files.some(f=>f.path==='raw/x'));assert.ok(!m.files.some(f=>f.path==='manifest.json'));
  for(const f of m.files) assert.equal(f.sha256,sha256(readFileSync(join(w,f.path))));
  assert.equal(readFileSync(join(w,'manifest.sha256'),'utf8').split(' ')[0],sha256(readFileSync(join(w,'manifest.json'))));
  assert.equal(m.sampling.sha256,sha256(readFileSync(sample)));assert.throws(()=>freeze(w,sample),/already frozen/);
}));
test('freeze refuses symlink and preserves exclusive refusal after interrupted freeze',()=>temp(d=>{
  const w=join(d,'w');mkdirSync(w);const sample=join(d,'sample');writeFileSync(sample,'x');symlinkSync(sample,join(w,'link'));
  assert.throws(()=>freeze(w,sample),/symlink/);assert.throws(()=>freeze(w,sample),/EEXIST/);
}));
test('exclusions and fee pauses reject missing or contradictory reasons and false fee claims',()=>{
  assert.ok(dispositionErrors({included:false}).length);
  assert.ok(dispositionErrors({verdict:'NOT_SENT',exclusion:'NOT_SENT'}).length);
  assert.ok(dispositionErrors({verdict:'NOT_SENT',failingCheck:'deposit_floor',exclusion:'NOT_SENT:basefee_above_cap'}).length);
  const row={...feePause({number:42n,hash:H,baseFeePerGas:5000000001n},5000000000n),gas:{maxFeePerGas:'5000000000'}};
  assert.deepEqual(dispositionErrors(row),[]);assert.deepEqual(feePauseErrors(row),[]);
  assert.ok(feePauseErrors({...row,baseFeePerGas:'5000000000'}).length);
});
test('validate CLI accepts frozen per-arm formal shapes and a fee-paused partial triple, rejects missing/contradictory exclusion',()=>temp(d=>{
  const source=readFileSync(new URL('../../docs/design/aoa-balance-mode/data/a6-gauge-local/positive.jsonl',import.meta.url),'utf8').trim().split('\n').map(JSON.parse);
  const start=source[0], row=source[1], end=source.at(-1);
  const config={frozen:true,chainId:start.passport.chainId,operator:address(9),factory:address(8),sender:address(7),salt:'0',bundlerGasLimit:'3000000',accounts:Object.fromEntries(['owner','bundler','verifyingSigner'].map((r,i)=>[r,{name:r,address:address(i+1)}])),fees:{maxFeePerGas:'5000000000',maxPriorityFeePerGas:'1000000000'},task:{token:address(4),recipient:address(5)},gas:Object.fromEntries(armOrder(0).map((arm,i)=>[arm,{callGasLimit:String(100000+i),verificationGasLimit:'300000',preVerificationGas:'60000',paymasterVerificationGasLimit:'450000',paymasterPostOpGasLimit:'480000'}]))};
  const frozen=JSON.parse(JSON.stringify(formalConfig(config,1),(_,v)=>typeof v==='bigint'?String(v):v));
  start.formal=true;start.frozenConfig=config;start.bMax='1';start.passport.invariant.gas=frozen.gas;start.passport.invariant.pmGas=frozen.pmGas;
  end.passport.invariant=structuredClone(start.passport.invariant);end.passport.volatile.operatorBalance=start.passport.volatile.operatorBalance;
  row.armOrder=armOrder(0);row.gas=frozen.gas.SP;row.pmGas=frozen.pmGas.SP;
  row.packedOp.gasFees=concat([pad(toHex(1000000000n),{size:16}),pad(toHex(5000000000n),{size:16})]);
  row.packedOp.paymasterAndData=concat([row.paymaster,pad(toHex(450000n),{size:16}),pad(toHex(480000n),{size:16}),'0x'+row.packedOp.paymasterAndData.slice(106)]);
  const hash=localUserOpHash(row.packedOp,row.entryPoint,row.chainId);
  row.expectedUserOpHash=hash;row.localUserOpHash=hash;row.epUserOpHash=hash;row.bundledOps=[row.packedOp];row.bundledUserOpHashes=[hash];
  Object.assign(row,JSON.parse(JSON.stringify(feePause({number:42n,hash:H,baseFeePerGas:5000000001n},5000000000n),(_,v)=>typeof v==='bigint'?String(v):v)));
  for(const k of ['readbacks','conservation','userOpEvent','gasDecomposition','gasTrace','charge','spMode']) delete row[k];
  end.stop={reason:'BASEFEE_PAUSED',code:10};end.exitCode=10;end.matchedTriplets=0;end.triplets=[{tripletIndex:0,armOrder:armOrder(0),matched:false,attempts:[0]}];end.tally={SP:{attempts:1,verdicts:{NOT_SENT:1}},VPM:{attempts:0,verdicts:{}},TPM:{attempts:0,verdicts:{}}};
  const path=join(d,'run.jsonl');
  const run=()=>{writeFileSync(path,[start,row,end].map(x=>JSON.stringify(x)).join('\n')+'\n');return spawnSync(process.execPath,['script/a6-collector/validate.mjs',path],{encoding:'utf8'});};
  let result=run();assert.equal(result.status,3,result.stdout+result.stderr);assert.equal(JSON.parse(result.stdout).consistent,true);
  delete row.exclusion;result=run();assert.equal(result.status,1,result.stdout);assert.match(result.stdout,/exclusion reason required/);
  row.exclusion='NOT_SENT:deposit_floor';result=run();assert.equal(result.status,1);assert.match(result.stdout,/contradicts failure/);
  row.exclusion='NOT_SENT:basefee_above_cap';row.gas.callGasLimit='1';result=run();assert.equal(result.status,1);assert.match(result.stdout,/gas mismatch/);
}));

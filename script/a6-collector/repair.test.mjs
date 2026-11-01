import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, realpathSync, rmSync, readFileSync, writeFileSync, mkdirSync, symlinkSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { repairFixture } from './repair-fixture.mjs';
import { artifactErrors, transactionErrors } from './artifact-validate.mjs';
import { windowErrors } from './evidence-validate.mjs';
import { archivedRpc, resolveEndpoints, revalidateAnchors, requireDecodedPreflight } from './formal.mjs';
import { rawArchive } from './evidence.mjs';
import { freeze } from './freeze.mjs';
import { postOpRefreshed, traceTPM } from './trace-policy.mjs';
import { toFunctionSelector } from 'viem';
const H='0x'+'ab'.repeat(32);
async function temp(fn) {const d=realpathSync(mkdtempSync('/tmp/a6-repair-'));try{return await fn(d);}finally{rmSync(d,{recursive:true,force:true});}}
function fixture(d) {
  const f=repairFixture(d,1),trailer={finalBlockCheck:f.finalBlockCheck,endPassport:f.passport,triples:[{tripleIndex:0,included:true,attempts:[0]}]};
  const check=()=>artifactErrors(d,f.rows,trailer,[f.start,...f.attempts]);return {...f,trailer,check};
}
test('positive artifact fixture resolves real archives, pins, state values and transaction bundle',()=>temp(d=>assert.deepEqual(fixture(d).check(),[])));
for(const [name,mutate,pattern] of [
  ['missing archive',(f,d)=>rmSync(join(d,f.rows[0].endpoints.A.receipt[0].path)),/artifact verification/],
  ['missing pin',(f)=>{f.rows[0].pins.abi[0].path='/nonexistent/a6-pin';},/artifact verification/],
  ['null included evidence with erased missing map',(f)=>{for(const k of ['packedOp','bundle','tx','uoe'])f.rows[0][k]=null;f.rows[0].missing={};},/mismatch/],
  ['journal state substitution',(f)=>{f.rows[0].state.after.entryPointDeposit.value='0';},/state mismatch/],
  ['index arm order',(f)=>{f.rows[0].armOrder=['TPM','SP','VPM'];},/armOrder mismatch/],
  ['chronological arm order',(f)=>{f.attempts[0].arm='TPM';},/chronological arm order/],
  ['timestamp absent',(f)=>{delete f.attempts[0].collectedAtUtc;},/chronology/],
  ['registry tampering',(f,d)=>writeFileSync(join(d,'rpc-identity.json'),'{}'),/hash mismatch/],
  ['duplicate raw id',(f,d)=>{const p=join(d,f.rows[0].endpoints.A.receipt[0].path);writeFileSync(p,readFileSync(p,'utf8')+readFileSync(p,'utf8').split('\n')[0]+'\n');},/resolve uniquely/],
  ['raw request method substitution',(f,d)=>{const p=join(d,f.rows[0].endpoints.A.receipt[0].path);const rs=readFileSync(p,'utf8').trim().split('\n').map(JSON.parse);rs[0].method='eth_call';writeFileSync(p,rs.map(JSON.stringify).join('\n'));},/metadata mismatch/],
  ['raw state return substitution',(f,d)=>{const p=join(d,f.rows[0].endpoints.A.receipt[0].path);const rs=readFileSync(p,'utf8').trim().split('\n').map(JSON.parse);for(const r of rs)if(r.method==='eth_call'){const response=JSON.parse(Buffer.from(r.response,'base64'));response.result='0x'+'0'.repeat(64);r.response=r.responseBase64=Buffer.from(JSON.stringify(response)).toString('base64');}writeFileSync(p,rs.map(JSON.stringify).join('\n'));},/state mismatch|state call/],
])test(`offline gate rejects ${name}`,()=>temp(d=>{const f=fixture(d);mutate(f,d);assert.match(f.check().join(';'),pattern);}));
test('frozen recipient/token, tx input, bundle index, gas and fees independently bound',()=>temp(d=>{
  const f=fixture(d),a=f.attempts[0];
  for(const field of ['recipient','token']) {const c=structuredClone(f.config);c.task[field]='0x'+'12'.repeat(20);assert.match(transactionErrors(a,c).join(';'),/calldata/);}
  for(const [key,value] of [['input','0x1234'],['handleOpsIndex',1],['gasLimit','3000001'],['maxFeePerGas','5000000001'],['maxPriorityFeePerGas','1000000001']]) {const b=structuredClone(a);b.tx[key]=value;assert.ok(transactionErrors(b,f.config).length);}
}));
test('transport, unavailable fixed blocks and reorgs latch before a subsequent send; only decoded preflight survives',async()=>{
  for(const mode of ['transport','missing','reorg']) {
    const records=[],calls=[];let n=0;
    const rpc=archivedRpc({url:'https://provider.invalid',endpoint:'A',append:r=>records.push(r),fetchImpl:async(_,{body})=>{const q=JSON.parse(body);calls.push(q.method);if(mode==='transport')throw Error('network');return new Response(JSON.stringify({jsonrpc:'2.0',id:q.id,result:q.method==='eth_getBlockByNumber'?(mode==='missing'?null:{number:'0x1',hash:++n===1?H:'0x'+'cd'.repeat(32)}):'0x'}));}});
    let error;try{await rpc.request({method:'eth_call',params:[{},'0x1']});}catch(e){error=e;}
    assert.ok(error);assert.throws(()=>requireDecodedPreflight(error,null));const before=calls.length;
    await assert.rejects(rpc.request({method:'eth_sendRawTransaction',params:['0x1234']}));assert.equal(calls.length,before);
  }
  assert.doesNotThrow(()=>requireDecodedPreflight(Error('contract'),{errorName:'FailedOp',reason:'AA32'}));
});
test('finalization re-reads every inclusion/fixed anchor on both endpoints and detects last-block reorg',async()=>{
  const calls=[];const archives=['A','B'].map(e=>({records:[{blockAnchor:{number:'1',hash:H}},{blockAnchor:{number:'2',hash:H}}],request:async q=>{calls.push([e,q.params[0]]);return {number:q.params[0],hash:H};}}));
  await revalidateAnchors(archives);assert.equal(calls.length,4);
  archives[1].request=async q=>({number:q.params[0],hash:q.params[0]==='0x2'?'changed':H});await assert.rejects(revalidateAnchors(archives),/historical block/);
});
test('DNS refuses local/private/unspecified destinations and aliases sharing addresses',async()=>{
  for(const address of ['127.0.0.1','10.0.0.1','172.16.0.1','192.168.0.1','169.254.1.1','0.0.0.0','::','::1','fe80::1','fc00::1','::ffff:127.0.0.1'])await assert.rejects(resolveEndpoints('https://a.invalid','https://b.invalid',async()=>[{address}]),/forbidden/);
  await assert.rejects(resolveEndpoints('http://[::]:8545','https://b.invalid'),/remote/);
  await assert.rejects(resolveEndpoints('https://a.invalid','https://b.invalid',async()=>[{address:'8.8.8.8'}]),/share/);
});
test('credential response bytes are exact, flagged, stop transport and cannot freeze',()=>temp(async d=>{
  const archive=rawArchive(d,'A'), secret='fixture-secret-value';
  const rpc=archivedRpc({url:`https://provider.invalid/${secret}`,endpoint:'A',append:archive.append,fetchImpl:async(_,{body})=>new Response(JSON.stringify({jsonrpc:'2.0',id:JSON.parse(body).id,error:{code:-1,message:secret}}))});
  await assert.rejects(rpc.request({method:'eth_chainId'}),/credential exposure/);
  assert.equal(archive.records[0].credentialFlag,true);assert.ok(Buffer.from(archive.records[0].response,'base64').toString().includes(secret));
  const sampling=join(d,'sample');writeFileSync(sampling,'x');assert.throws(()=>freeze(d,sampling),/credential flagged/);
}));
test('freeze rejects window and sampling symlink ancestors before creating lock',()=>temp(d=>{
  const real=join(d,'real');mkdirSync(real);mkdirSync(join(real,'window'));writeFileSync(join(real,'sample'),'x');symlinkSync(real,join(d,'alias'));
  for(const [w,s] of [[join(d,'alias/window'),join(real,'sample')],[join(real,'window'),join(d,'alias/sample')]])assert.throws(()=>freeze(w,s),/symlink ancestors/);
  assert.equal(existsSync(join(real,'window/.freeze-lock')),false);
}));
test('TPM requires dual traces, excludes oracle calls/storage writes, refuses failed traces',async()=>{
  const pm='0x'+'12'.repeat(20),call={type:'CALL',to:pm,input:toFunctionSelector('postOp(uint8,bytes,uint256,uint256)'),calls:[]},state={pre:{},post:{}};
  assert.equal(postOpRefreshed(call,state,pm),false);
  assert.equal(postOpRefreshed({...call,calls:[{type:'STATICCALL',input:toFunctionSelector('latestRoundData()')}]},state,pm),true);
  assert.equal(postOpRefreshed(call,{pre:{[pm]:{storage:{'0x1':'0x2'}}},post:{}},pm),true);
  await assert.rejects(traceTPM([{request:async()=>{throw Error('trace unavailable');}}],H,pm),/trace unavailable/);
  assert.throws(()=>postOpRefreshed(null,state,pm),/unavailable/);
});
test('config pin binds the frozen object even if journal and index agree',()=>temp(d=>{
  const f=fixture(d);f.start.frozenConfig.task.recipient='0x'+'34'.repeat(20);
  assert.match(f.check().join(';'),/frozen config differs/);
}));
test('formal archive preserves malformed response bytes and then blocks further requests',async()=>{
  const rows=[];let calls=0;
  const rpc=archivedRpc({url:'https://provider.invalid',endpoint:'A',append:r=>rows.push(r),fetchImpl:async()=>{calls++;return new Response('{broken');}});
  await assert.rejects(rpc.request({method:'eth_chainId'}),/invalid response/);
  assert.equal(Buffer.from(rows[0].responseBase64,'base64').toString(),'{broken');
  await assert.rejects(rpc.request({method:'eth_chainId'}));assert.equal(calls,1);
});
test('credential scanning covers query values, userinfo and configured patterns without printing matches',async()=>{
  for(const [url,secret,secretPatterns] of [['https://userpart:passwordpart@provider.invalid','passwordpart',[]],['https://provider.invalid?key=querysecret','querysecret',[]],['https://provider.invalid','custom-secret-123',['custom-secret-\\d+']]]) {
    const records=[];const rpc=archivedRpc({url,endpoint:'A',secretPatterns,append:r=>records.push(r),fetchImpl:async(_,{body})=>new Response(JSON.stringify({jsonrpc:'2.0',id:JSON.parse(body).id,result:secret}))});
    await assert.rejects(rpc.request({method:'eth_chainId'}),e=>!e.message.includes(secret)&&/credential/.test(e.message));assert.equal(records[0].credentialFlag,true);
  }
});
test('finalization evidence missing one endpoint is rejected offline',()=>temp(d=>{
  const f=fixture(d);f.trailer.finalBlockCheck.raw.B=[];assert.match(f.check().join(';'),/final historical anchor/);
}));
test('actual send sequence cannot be relabeled through journal armOrder',()=>temp(d=>{
  const f=fixture(d),path=join(d,f.rows[0].endpoints.A.transaction[0].path),records=readFileSync(path,'utf8').trim().split('\n').map(JSON.parse);
  const send=records.find(r=>r.method==='eth_sendRawTransaction');send.requestedAtUtc='2027-01-01T00:00:00.000Z';writeFileSync(path,records.map(JSON.stringify).join('\n'));
  assert.match(f.check().join(';'),/send sequence/);
}));
test('included TPM requires archived dual traces and cannot hide refresh classification',()=>temp(d=>{
  const f=repairFixture(d,3),trailer={finalBlockCheck:f.finalBlockCheck,endPassport:f.passport,triples:[{tripleIndex:0,included:true,attempts:[0,1,2]}]};
  const check=()=>artifactErrors(d,f.rows,trailer,[f.start,...f.attempts]);
  assert.deepEqual(check(),[]);
  f.attempts[2].postOpRefreshed=true;assert.match(check().join(';'),/trace mismatch|included TPM/);
}));

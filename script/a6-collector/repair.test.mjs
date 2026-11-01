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
  ['raw state return substitution',(f,d)=>{const p=join(d,f.rows[0].endpoints.A.receipt[0].path);const rs=readFileSync(p,'utf8').trim().split('\n').map(JSON.parse);for(const r of rs)if(r.method==='eth_call'){const response=JSON.parse(Buffer.from(r.response,'base64'));response.result='0x'+'0'.repeat(64);r.response=r.responseBase64=Buffer.from(JSON.stringify(response)).toString('base64');}writeFileSync(p,rs.map(JSON.stringify).join('\n'));},/state mismatch|state call|Passport raw value/],
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
  const pm='0x'+'12'.repeat(20),call={type:'CALL',to:'0x'+'34'.repeat(20),calls:[{type:'CALL',to:pm,input:toFunctionSelector('postOp(uint8,bytes,uint256,uint256)'),calls:[]}]},state={pre:{[call.to]:{balance:'0x1'}},post:{[call.to]:{balance:'0x2'}}};
  assert.equal(postOpRefreshed(call,state,pm),false);
  assert.equal(postOpRefreshed({...call,calls:[{...call.calls[0],calls:[{type:'STATICCALL',input:toFunctionSelector('latestRoundData()')}]}]},state,pm),true);
  assert.equal(postOpRefreshed(call,{pre:{...state.pre,[pm]:{storage:{'0x3':'0x2'}}},post:state.post},pm),true);
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
  f.attempts[2].postOpRefreshed=true;assert.match(check().join(';'),/trace mismatch|TPM trace disagreement|included TPM/);
}));

test('strict send gate requires both archived later heads after prior receipt',()=>temp(d=>{
  const f=repairFixture(d,3), trailer={finalBlockCheck:f.finalBlockCheck,endPassport:f.passport,triples:[{tripleIndex:0,included:true,attempts:[0,1,2]}]};
  const check=()=>artifactErrors(d,f.rows,trailer,[f.start,...f.attempts]);
  assert.deepEqual(check(),[]);
  const path=join(d,f.rows[0].endpoints.B.receipt[0].path);
  const records=readFileSync(path,'utf8').trim().split('\n').map(JSON.parse);
  for(const r of records) if(r.method==='eth_blockNumber') {const response=JSON.parse(Buffer.from(r.response,'base64'));response.result='0x0';r.response=r.responseBase64=Buffer.from(JSON.stringify(response)).toString('base64');}
  writeFileSync(path,records.map(JSON.stringify).join('\n'));
  assert.match(check().join(';'),/both heads must advance/);
}));
test('each field carries all anchored eth_call records and consumers select target and params',()=>temp(d=>{
  const f=fixture(d), states=f.rows[0].state.before;
  assert.deepEqual(states.operatorBalance.raw,states.entryPointDeposit.raw);
  assert.ok(states.operatorBalance.raw.A.length>1);
  assert.deepEqual(f.check(),[]);
}));
test('archived block cannot contain two window handleOps even if journal heights differ',()=>temp(d=>{
  const f=repairFixture(d,3),trailer={finalBlockCheck:f.finalBlockCheck,endPassport:f.passport,triples:[{tripleIndex:0,included:true,attempts:[0,1,2]}]};
  const path=join(d,f.rows[0].endpoints.A.receipt[0].path),records=readFileSync(path,'utf8').trim().split('\n').map(JSON.parse);
  for(const r of records) if(r.method==='eth_getBlockByNumber') {
    const response=JSON.parse(Buffer.from(r.response,'base64'));
    if(response.result.transactions?.includes(f.attempts[0].tx.hash)) {response.result.transactions.push(f.attempts[1].tx.hash);r.response=r.responseBase64=Buffer.from(JSON.stringify(response)).toString('base64');}
  }
  writeFileSync(path,records.map(JSON.stringify).join('\n'));
  assert.match(artifactErrors(d,f.rows,trailer,[f.start,...f.attempts]).join(';'),/more than one handleOps/);
}));

function editRaw(d,path,edit) {const records=readFileSync(join(d,path),'utf8').trim().split('\n').map(JSON.parse);edit(records);writeFileSync(join(d,path),records.map(JSON.stringify).join('\n')+'\n');}
test('H2 Passport gate values must be rederived even when file and journal agree',()=>temp(d=>{
  const f=fixture(d),p=f.start.passport, saved=readFileSync(join(d,f.passport.path),'utf8');
  assert.deepEqual(f.check(),[]);
  const cases=[];
  for(const arm of ['SP','VPM','TPM']) for(const field of ['deposit','staked','stake','unstakeDelaySec','withdrawTime']) cases.push([p.volatile.depositInfo[arm],field]);
  for(const arm of ['SP','VPM','TPM']) for(const field of ['staked','stake','unstakeDelaySec','withdrawTime']) cases.push([p.invariant.stakes[arm],field]);
  for(const code of Object.values(p.invariant.code)) if(code) for(const field of ['codehash','size','address']) cases.push([code,field]);
  cases.push([p.invariant.superPaymaster,'version'],[p.invariant.superPaymaster,'paused'],[p.invariant.credit,'policy'],[p.invariant.superPaymaster.cachedPrice,'price'],[p.volatile,'cachedPriceUpdatedAt']);
  for(const [object,key] of cases) {
    const old=object[key];object[key]=typeof old==='boolean'?!old:key==='address'?'0x'+'99'.repeat(20):key==='codehash'?H:key==='version'?old.toUpperCase():String(BigInt(old)+1n);
    writeFileSync(join(d,f.passport.path),JSON.stringify(p));
    assert.match(f.check().join(';'),/Passport (raw value|identity\/config) mismatch/,key);
    object[key]=old;
  }
  writeFileSync(join(d,f.passport.path),saved);assert.deepEqual(f.check(),[]);
  f.passport.raw.A=f.passport.raw.A.filter(ref=>!f.archives[0].records.some(r=>r.id===ref.id && r.method==='eth_getCode'));
  assert.match(f.check().join(';'),/Passport raw value mismatch/);
}));
test('H3 complete ordered receipts bind status and every log on both endpoints',()=>temp(d=>{
  const f=fixture(d);assert.deepEqual(f.check(),[]);
  for(const endpoint of ['A','B']) for(const mutation of ['status','extra','missing','order','address','topics','data','logIndex']) {
    const path=f.rows[0].endpoints[endpoint].receipt[0].path, saved=readFileSync(join(d,path));
    editRaw(d,path,records=>{for(const raw of records) if(raw.method==='eth_getTransactionReceipt') {
      const response=JSON.parse(Buffer.from(raw.response,'base64')),r=response.result;
      if(mutation==='status')r.status='0x0';else if(mutation==='extra')r.logs.push({...r.logs[0],logIndex:'0xffff'});else if(mutation==='missing')r.logs.pop();else if(mutation==='order')r.logs.reverse();else r.logs[0][mutation]=mutation==='topics'?[H]:mutation==='address'?'0x'+'99'.repeat(20):mutation==='logIndex'?'0xffff':'0x1234';
      raw.response=raw.responseBase64=Buffer.from(JSON.stringify(response)).toString('base64');
    }});
    assert.match(f.check().join(';'),/raw complete receipt mismatch/,endpoint+mutation);writeFileSync(join(d,path),saved);
  }
}));
test('M1 archived trace requests require withLog and diffMode even on abandoned attempts',()=>temp(d=>{
  const f=repairFixture(d,3),trailer={finalBlockCheck:f.finalBlockCheck,endPassport:f.passport,triples:[{tripleIndex:0,included:false,attempts:[0,1,2]}]};
  const check=()=>artifactErrors(d,f.rows,trailer,[f.start,...f.attempts]);assert.deepEqual(check(),[]);
  for(const endpoint of ['A','B']) for(const tracer of ['callTracer','prestateTracer']) {
    const path=f.rows[2].trace.raw[endpoint][0].path,saved=readFileSync(join(d,path));
    editRaw(d,path,records=>{for(const raw of records) if(raw.method==='debug_traceTransaction' && raw.params[1].tracer===tracer) {delete raw.params[1].tracerConfig;const q=JSON.parse(Buffer.from(raw.request,'base64'));q.params=raw.params;raw.request=raw.requestBase64=Buffer.from(JSON.stringify(q)).toString('base64');}});
    assert.match(check().join(';'),/TPM raw trace missing or inconsistent/);writeFileSync(join(d,path),saved);
  }
}));
test('M1 empty diff and bare postOp cannot prove no refresh',()=>{
  const pm='0x'+'12'.repeat(20),ep='0x'+'34'.repeat(20),frame={type:'CALL',to:pm,input:toFunctionSelector('postOp(uint8,bytes,uint256,uint256)')},call={type:'CALL',to:ep,calls:[frame]};
  for(const root of [frame,call]) assert.throws(()=>postOpRefreshed(root,{pre:{},post:{}},pm),/TPM trace incomplete/);
  assert.throws(()=>postOpRefreshed(call,{pre:{[pm]:{balance:'0x1'}},post:{[pm]:{balance:'0x2'}}},pm),/TPM trace incomplete/);
});
test('L2 endpoint archive ids cannot restart across date files',()=>temp(d=>{
  const f=fixture(d),refs=f.finalBlockCheck.raw.A,path=refs[0].path;
  assert.deepEqual(f.check(),[]);
  const ids=new Map();editRaw(d,path,rs=>rs.forEach((r,i)=>{ids.set(r.id,i+1);r.id=i+1;}));
  for(const ref of refs) ref.id=ids.get(ref.id);
  assert.match(f.check().join(';'),/globally strictly increasing/);
}));

test('H1 archived refresh abandonment and its clean replacement validate together',()=>temp(d=>{
  const f=repairFixture(d,6),a=f.attempts[2],trailer={finalBlockCheck:f.finalBlockCheck,endPassport:f.passport,triples:[{tripleIndex:0,included:false,attempts:[0,1,2]},{tripleIndex:1,included:true,attempts:[3,4,5]}]};
  a.postOpRefreshed=true;f.rows[2].trace.postOpRefreshed=true;
  for(const t of a.traces) {t.postOpRefreshed=true;t.call.calls[0].calls.push({type:'STATICCALL',to:a.tpmOracle,input:toFunctionSelector('latestRoundData()')});}
  for(const endpoint of ['A','B']) editRaw(d,f.rows[2].trace.raw[endpoint][0].path,records=>{for(const raw of records) if(raw.method==='debug_traceTransaction' && raw.params[0]===a.tx.hash && raw.params[1].tracer==='callTracer') {const r=JSON.parse(Buffer.from(raw.response,'base64'));r.result=a.traces[endpoint==='A'?0:1].call;raw.response=raw.responseBase64=Buffer.from(JSON.stringify(r)).toString('base64');}});
  const check=()=>artifactErrors(d,f.rows,trailer,[f.start,...f.attempts]);
  assert.deepEqual(check(),[]);
  trailer.triples[0].included=true;assert.match(check().join(';'),/included TPM refresh/);
  trailer.triples[0].included=false;
  a.postOpRefreshed=false;f.rows[2].trace.postOpRefreshed=false;assert.match(check().join(';'),/TPM trace disagreement/);
}));

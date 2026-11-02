import { tmpdir } from 'node:os';
import test from 'node:test';
import assert from 'node:assert/strict';
import { waitAfterInclusion, inclusionErrors, formalRuntime } from './formal.mjs';
import { postOpRefreshed } from './trace-policy.mjs';
import { toFunctionSelector } from 'viem';
test('next attempt waits for receipt and independently later A and B heads',async()=>{
  const receipt={blockNumber:10n,blockHash:'hash'};let a=0,b=0;
  const clients=[{getBlockNumber:async()=>[10n,11n,12n][a++]},{getBlockNumber:async()=>[10n,10n,11n][b++]}];
  assert.deepEqual(await waitAfterInclusion(clients,receipt,{pollMs:0}),[12n,11n]);assert.equal(a,3);assert.equal(b,3);
  await assert.rejects(waitAfterInclusion(clients,null),/receipt/);
  await assert.rejects(waitAfterInclusion([{getBlockNumber:async()=>11n},{getBlockNumber:async()=>10n}],receipt,{timeoutMs:0}),/both heads/);
});
test('all sent attempts including abandoned candidates require strictly increasing distinct inclusion blocks',()=>{
  const row=n=>({sent:true,tx:{blockNumber:String(n)},included:false});
  assert.deepEqual(inclusionErrors([row(10),{sent:false},row(12)]),[]);
  assert.match(inclusionErrors([row(10),row(10)]).join(';'),/more than one handleOps/);
  assert.match(inclusionErrors([row(12),row(10)]).join(';'),/strictly increasing/);
});
test('TPM cache slots 3 and 4 refresh; unrelated storage does not',()=>{
  const pm='0x'+'12'.repeat(20),call={type:'CALL',to:'0x'+'34'.repeat(20),calls:[{type:'CALL',to:pm,input:toFunctionSelector('postOp(uint8,bytes,uint256,uint256)')}]};
  for(const slot of [0,1,2,3,4,5,10]) for(const side of ['pre','post']) {
    const state={pre:{[call.to]:{balance:'0x1'}},post:{[call.to]:{balance:'0x2'}}};state[side][pm]={storage:{['0x'+slot.toString(16).padStart(64,'0')]:'0x01'}};
    assert.equal(postOpRefreshed(call,state,pm),[3,4].includes(slot));
  }
});

import { mkdtempSync, writeFileSync, readFileSync, rmSync, realpathSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { freeze } from './freeze.mjs';
test('rehearsal runtime rejects remote URLs and nonlocal chains before signing or RPC',async()=>{
  const d=mkdtempSync(join(tmpdir(),'a6-mode-'));
  try {
    const a=join(d,'a'),b=join(d,'b');writeFileSync(a,'https://example.com');writeFileSync(b,'http://127.0.0.1:8546');
    const args={rehearsal:true,config:{chainId:31337},rpcAFile:a,rpcBFile:b,outPath:join(d,'run')};
    await assert.rejects(formalRuntime(args),/literal loopback/);
    writeFileSync(a,'http://127.0.0.1:8545');
    await assert.rejects(formalRuntime({...args,config:{chainId:1}}),/chain 31337/);
  } finally {rmSync(d,{recursive:true,force:true});}
});
test('rehearsal marker survives freeze and validator always refuses evidence acceptance',()=>{
  const d=realpathSync(mkdtempSync(join(tmpdir(),'a6-marker-')));
  try {
    const rows=readFileSync(new URL('../../docs/design/aoa-balance-mode/data/a6-gauge-local/positive.jsonl',import.meta.url),'utf8').trim().split('\n').map(JSON.parse);
    rows[0].rehearsal=true;rows.at(-1).rehearsal=true;
    writeFileSync(join(d,'run.jsonl'),rows.map(JSON.stringify).join('\n')+'\n');
    writeFileSync(join(d,'trailer.json'),JSON.stringify({rehearsal:true}));
    writeFileSync(join(d,'sample.json'),'{}');
    assert.equal(freeze(d,join(d,'sample.json')).rehearsal,true);
    const r=spawnSync(process.execPath,['script/a6-collector/validate.mjs',join(d,'run.jsonl')],{encoding:'utf8'});
    const report=JSON.parse(r.stdout);
    assert.equal(report.consistent,true);assert.equal(report.rehearsal,true);assert.equal(report.protocolConformant,false);assert.equal(report.accepted,false);assert.equal(r.status,3);
  } finally {rmSync(d,{recursive:true,force:true});}
});

import { rehearsalTpmRefresh } from './rehearsal-refresh.mjs';
test('M2 refresh control ages only chosen rehearsal TPM cache within validation lifetime',async()=>{
  const writes=[],ttl=864000n,now=2000000n,pm='0x'+'12'.repeat(20);
  const client={getChainId:async()=>31337,getBlock:async()=>({number:10n,timestamp:now}),getStorageAt:async()=> '0x'+ttl.toString(16),readContract:async({functionName})=>functionName==='tokenPaymasterConfig'?[0n,0n,0n,ttl*2n]:100n,request:async q=>writes.push(q)};
  const options={rehearsal:true,config:{chainId:31337,rehearsalForceTpmRefresh:true},arm:'TPM',attemptIndex:4,client,paymaster:pm,abi:[]};
  for(const change of [{rehearsal:false},{arm:'SP'},{attemptIndex:2},{attemptIndex:7},{config:{chainId:31337}}]) assert.equal(await rehearsalTpmRefresh({...options,...change}),null);
  assert.equal(writes.length,0);
  const control=await rehearsalTpmRefresh(options);assert.equal(control.kind,'tpmCacheAged');assert.deepEqual(control.slots,[3,4]);assert.equal(control.cachedPrice.to,'50');assert.equal(control.cachedPriceTimestamp.to,String(now-ttl-1n));
  assert.deepEqual(writes.map(q=>q.method),['anvil_setStorageAt','anvil_setStorageAt','evm_mine']);
  const timestamp=BigInt(writes[0].params[2]);assert.equal(now-timestamp,ttl+1n);assert.ok(now<timestamp+ttl*2n);assert.equal(BigInt(writes[1].params[2]),50n);
  await assert.rejects(rehearsalTpmRefresh({...options,config:{...options.config,chainId:1}}),/chain 31337/);
  await assert.rejects(rehearsalTpmRefresh({...options,client:{...client,getChainId:async()=>1}}),/chain 31337/);
  await assert.rejects(rehearsalTpmRefresh({...options,client:{...client,readContract:async()=>[0n,0n,0n,ttl]}}),/valid inclusion interval/);
});
test('H1 validator excludes refreshed TPM from matching using traces not row flag',()=>{
  const d=realpathSync(mkdtempSync(join(tmpdir(),'a6-refresh-match-')));
  try {
    const rows=readFileSync(new URL('../../docs/design/aoa-balance-mode/data/a6-gauge-local/positive.jsonl',import.meta.url),'utf8').trim().split('\n').map(JSON.parse),tpm=rows.find(r=>r.arm==='TPM'),end=rows.at(-1);
    tpm.traces=[0,1].map(()=>({call:{type:'CALL',to:tpm.entryPoint,calls:[{type:'CALL',to:tpm.paymaster,input:toFunctionSelector('postOp(uint8,bytes,uint256,uint256)'),calls:[{type:'STATICCALL',input:toFunctionSelector('latestRoundData()')}]}]},state:{pre:{[tpm.entryPoint.toLowerCase()]:{balance:'0x1'}},post:{[tpm.entryPoint.toLowerCase()]:{balance:'0x2'}}}}));tpm.postOpRefreshed=true;
    const run=()=>{writeFileSync(join(d,'run.jsonl'),rows.map(JSON.stringify).join('\n')+'\n');return JSON.parse(spawnSync(process.execPath,['script/a6-collector/validate.mjs',join(d,'run.jsonl')],{encoding:'utf8'}).stdout);};
    let report=run();assert.equal(report.matchedTriplets,0);assert.equal(report.consistent,false);
    end.matchedTriplets=0;end.triplets[0].matched=false;end.stop={reason:'ATTEMPT_BUDGET_EXHAUSTED',code:10};end.exitCode=10;
    report=run();assert.equal(report.consistent,true,JSON.stringify(report));
    tpm.postOpRefreshed=false;report=run();assert.match(report.crash,/TPM trace disagreement/);
  } finally {rmSync(d,{recursive:true,force:true});}
});

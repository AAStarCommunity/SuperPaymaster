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
  const pm='0x'+'12'.repeat(20),call={type:'CALL',to:pm,input:toFunctionSelector('postOp(uint8,bytes,uint256,uint256)')};
  for(const slot of [0,1,2,3,4,5,10]) for(const side of ['pre','post']) {
    const state={pre:{},post:{}};state[side][pm]={storage:{['0x'+slot.toString(16).padStart(64,'0')]:'0x01'}};
    assert.equal(postOpRefreshed(call,state,pm),[3,4].includes(slot));
  }
});

import { mkdtempSync, writeFileSync, readFileSync, rmSync, realpathSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { freeze } from './freeze.mjs';
test('rehearsal runtime rejects remote URLs and nonlocal chains before signing or RPC',async()=>{
  const d=mkdtempSync('/private/tmp/a6-mode-');
  try {
    const a=join(d,'a'),b=join(d,'b');writeFileSync(a,'https://example.com');writeFileSync(b,'http://127.0.0.1:8546');
    const args={rehearsal:true,config:{chainId:31337},rpcAFile:a,rpcBFile:b,outPath:join(d,'run')};
    await assert.rejects(formalRuntime(args),/literal loopback/);
    writeFileSync(a,'http://127.0.0.1:8545');
    await assert.rejects(formalRuntime({...args,config:{chainId:1}}),/chain 31337/);
  } finally {rmSync(d,{recursive:true,force:true});}
});
test('rehearsal marker survives freeze and validator always refuses evidence acceptance',()=>{
  const d=realpathSync(mkdtempSync('/private/tmp/a6-marker-'));
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

import test from 'node:test';
import assert from 'node:assert/strict';
import { settlementBranch } from './branch.mjs';
const token='0x'+'11'.repeat(20), user='0x'+'22'.repeat(20), hash='0x'+'33'.repeat(32);
const topics={balance:'lock',credit:'credit'};
const log=branch=>({address:token,topics:[topics[branch],'0x'+user.slice(2).padStart(64,'0'),hash],data:'0x'+'00'.repeat(branch==='balance'?64:32)});
test('records balance and credit settlement for the exact operation',()=>{
 for(const branch of ['balance','credit']) assert.equal(settlementBranch([log(branch)],{token,user,hash,topics,planned:branch}).observed,branch);
});
test('rejects wrong branch, missing, ambiguous and unrelated settlements',()=>{
 for(const logs of [[log('credit')],[],[log('balance'),log('credit')],[{...log('balance'),address:user}],[{...log('balance'),topics:['lock',log('balance').topics[1],'wrong']}],[{...log('balance'),data:'0x'}]])
 assert.throws(()=>settlementBranch(logs,{token,user,hash,topics,planned:'balance'}));
});

import { readFileSync } from 'node:fs';
test('collector checks branch once, after receipt classification',()=>{
 const source=readFileSync(new URL('../a6-collector/collector.mjs',import.meta.url),'utf8');
 assert.equal(source.split('row.spBranch = settlementBranch(').length-1,1);
 assert.ok(source.indexOf('row.spBranch = settlementBranch(')>source.indexOf('const cls = classifyAttempt('));
});

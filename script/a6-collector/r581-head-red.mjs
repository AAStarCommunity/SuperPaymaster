// Opt-in mutation runner. Restores the exact working-tree source after every run.
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const path=new URL('./artifact-validate.mjs',import.meta.url), original=readFileSync(path,'utf8');
const member="if (!heads.some(h=>h===BigInt(a.tx.headBefore))) throw Error('raw headBefore mismatch');";
const max="if (BigInt(a.tx.blockNumber)<=heads.reduce((m,h)=>h>m?h:m)) throw Error('raw inclusion block not newer than every head read before send');";
const results=[];
try {
  for(const [finding,from,to,pattern] of [
    ['headBefore old last-head rule',member,"if (heads.at(-1)!==BigInt(a.tx.headBefore)) throw Error('raw headBefore mismatch');",'headBefore accepts'],
    ['headBefore membership guard removed',member,'','headBefore rejects a claimed'],
    ['headBefore maximum inclusion guard removed',max,'','headBefore rejects inclusion'],
  ]) {
    if(!original.includes(from)) throw Error('mutation target missing: '+finding);
    writeFileSync(path,original.replace(from,to));
    let run;
    try {run=spawnSync(process.execPath,['--test','--test-reporter=tap','--test-name-pattern='+pattern,'script/a6-collector/repair.test.mjs'],{encoding:'utf8'});}
    finally {writeFileSync(path,original);}
    const failedTests=[...run.stdout.matchAll(/^not ok \d+ - (.+)$/gm)].map(m=>m[1]);
    if(run.status!==1 || !failedTests.length) throw Error('mutation did not go red: '+finding+'\n'+run.stdout+run.stderr);
    results.push({finding,exit:run.status,failedTests});
  }
} finally {writeFileSync(path,original);}
const output=new URL('./r581-red-results.json',import.meta.url);
const previous=JSON.parse(readFileSync(output,'utf8')).filter(r=>!r.finding.startsWith('headBefore '));
writeFileSync(output,JSON.stringify([...previous,...results],null,2)+'\n');
console.log(JSON.stringify(results,null,2));

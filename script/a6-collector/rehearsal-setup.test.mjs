import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

test('rehearsal rejects invalid gasFactor before clients or configuration reads',()=>{
 const dir=mkdtempSync(join(tmpdir(),'rq3-gas-factor-'));
 try {
  const path=join(dir,'policy.json');
  for(const gasFactor of [undefined,{numerator:0,denominator:1},{numerator:-1,denominator:1},
   {numerator:1,denominator:2},{numerator:1,denominator:0},{numerator:1,denominator:-1},
   {numerator:1.5,denominator:1},{numerator:2,denominator:1.5},
   {numerator:'2',denominator:1},{numerator:2,denominator:true},
   {numerator:2**53,denominator:1}]) {
   writeFileSync(path,JSON.stringify({gasFactor}));
   const result=spawnSync(process.execPath,['script/a6-collector/rehearsal-setup.mjs',
    'http://127.0.0.1:1',dir,join(dir,'absent-config'),join(dir,'absent-baseline'),path],{encoding:'utf8'});
   assert.equal(result.status,1);
   assert.match(result.stderr,/Error: invalid gasFactor/);
  }
 } finally { rmSync(dir,{recursive:true,force:true}); }
});

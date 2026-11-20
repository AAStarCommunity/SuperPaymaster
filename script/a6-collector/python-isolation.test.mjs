import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync,writeFileSync,rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { createWindow } from './window-schedule.mjs';
test('schedule isolates Python imports and records sys.version in manifest',()=>{
 const dir=mkdtempSync(join(tmpdir(),'schedule-isolation-'));
 const previous=process.env.PYTHONPATH;
 try {
  writeFileSync(join(dir,'json.py'),'raise RuntimeError("PYTHONPATH injection")\n');
  const bytes=execFileSync('python3.11',['-I','-B','script/a6-collector/frozen-fixture.py']);
  process.env.PYTHONPATH=dir;
  const w=createWindow({readBundle:()=>bytes,bundleSha256:createHash('sha256').update(bytes).digest('hex'),seed:'20261010',chainId:10,accounts:[200,201,202].map(n=>'0x'+n.toString(16).padStart(40,'0'))});
  assert.equal(w.manifest.pythonVersion,execFileSync('python3',['-I','-B','-c','import sys; print(sys.version)'],{encoding:'utf8'}).trim());
 } finally {if(previous===undefined)delete process.env.PYTHONPATH;else process.env.PYTHONPATH=previous;rmSync(dir,{recursive:true,force:true});}
});

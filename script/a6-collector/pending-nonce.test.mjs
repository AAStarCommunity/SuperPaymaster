import test from 'node:test';
import assert from 'node:assert/strict';
import * as formal from './formal.mjs';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
const address='0x'+'12'.repeat(20);
const clients=(a,b)=>[a,b].map(n=>({getTransactionCount:async args=>{assert.deepEqual(args,{address,blockTag:'pending'});return n;}}));
for (const [name,values,label] of [['endpoint disagreement',[4,5],'PENDING_NONCE_DISAGREEMENT'],['unexpected jump',[6,6],'PENDING_NONCE_CHANGED']]) test(name,async()=>{
 const guard=await formal.pendingSequence(clients(4,4),address);
 await assert.rejects(guard.send(clients(...values),async()=>assert.fail('sent')),{message:label});
});
test('pending progression is submitted exactly',async()=>{
 const guard=await formal.pendingSequence(clients(4,4),address);
 for(const n of [4,5]) assert.equal(await guard.send(clients(n,n),async nonce=>nonce),n);
});
for(const stale of [false,true]) test(stale?'stale lock is refused':'lock held by another process',()=>{
 const dir=mkdtempSync(resolve('cache/3arm/r2/lock-'));
 try {
  if(stale){mkdirSync(resolve(dir,'10'),{recursive:true});writeFileSync(resolve(dir,'10',address+'.lock'),'{"pid":99999999}');}
  const release=stale?null:formal.acquireBundlerLock(dir,10,address);
  const child=spawnSync(process.execPath,['--input-type=module','-e',`import {acquireBundlerLock} from './script/a6-collector/formal.mjs'; acquireBundlerLock(${JSON.stringify(dir)},10,${JSON.stringify(address)});`],{encoding:'utf8'});
  assert.notEqual(child.status,0);assert.match(child.stderr,/active or stale lock requires operator review/);
  release?.();
 } finally {rmSync(dir,{recursive:true,force:true});}
});

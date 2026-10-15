import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {decodeLogsFrom,SP_EVENTS_ABI,TOKEN_EVENTS_ABI,spConservation} from '../gauge-lib.mjs';
const lines=readFileSync('script/a6-collector/offline-review/fixtures/postop-a0-from-inflight.jsonl','utf8').trim().split('\n').map(JSON.parse);
const inv=lines[0].passport.invariant,r=lines[1];
const tokenEvents=decodeLogsFrom(r.logs,inv.xPNTs.address,TOKEN_EVENTS_ABI);
const lc=tokenEvents.find(e=>e.event==='LockCreated').args;
const before=r.readbacks.before.A, after=structuredClone(r.readbacks.after.A);
after.inflightA0=lc.aReserved;
after.operatorBalance=String(BigInt(before.operatorBalance)-BigInt(lc.aReserved));
after.userXPNTs=before.userXPNTs;after.totalSupply=before.totalSupply;after.totalTxSponsored=before.totalTxSponsored;
after.totalSpent=String(BigInt(before.totalSpent)+BigInt(lc.aReserved));
after.lockedOf=String(BigInt(before.lockedOf)+BigInt(lc.xLocked));after.lockXLocked=lc.xLocked;
const args={before,after,spEvents:decodeLogsFrom(r.logs,inv.code.superPaymasterProxy.address,SP_EVENTS_ABI),tokenEvents,expectedHash:r.expectedUserOpHash,sender:r.sender,paymaster:inv.code.superPaymasterProxy.address,operator:inv.superPaymaster.operator.address,cls:{verdict:'USEROP_REVERTED',revertKind:'postOpReverted'}};
assert.equal(spConservation(args).ok,true);
const missing=spConservation({...args,tokenEvents:[]});
assert.equal(missing.evaluated,false);assert.equal(missing.ok,null);
assert.ok(missing.notEvaluable.includes('LockCreated'));
assert.equal(spConservation({...args,after:{...after,inflightA0:'7'}}).ok,false);
assert.equal(spConservation({...args,after:{...after,lockedOf:before.lockedOf}}).ok,false);
const pin=execFileSync('git',['show','1ac0e1c5:contracts/src/tokens/v2/xPNTsTokenV2.sol'],{encoding:'utf8'}).split('\n');
for(const [n,text] of [[240,'lockedOf[user] = locked + x;'],[263,'lockedOf[user] -= r.xLocked;'],[305,'creditReservedOf[user] += aPNTs;'],[322,'creditReservedOf[user] -= r.amount;']]) assert.equal(pin[n-1].trim(),text);
// Historical comparator is immutable; HEAD advances as fixes land.
assert.equal(createHash('sha256').update(readFileSync('script/a6-collector/offline-review/validate-old.mjs')).digest('hex'),'b260ae9c8ac06ba02044de4e99a045d0a186a64156b48bed4c5ff7c403820d00');
console.log('PASS: postOp positive, missing-event null, independent a0, R2, four pinned citations, immutable historical validator snapshot');

assert.equal(createHash('sha256').update(readFileSync('script/a6-collector/offline-review/validate-round2-old.mjs')).digest('hex'),'8bab958d2675c3b37696fd775fd19f4d973b90d168eb8208e5ea4b5fd5a0e1fa');
for (const f of ['totalSpent','userXPNTs','totalSupply','totalTxSponsored']) {
  assert.equal(spConservation({...args,after:{...after,[f]:String(BigInt(after[f])+1n)}}).ok,false,f);
}
for (const field of ['user','locker']) {
  const bad=structuredClone(tokenEvents);bad.find(e=>e.event==='LockCreated').args[field]='0x'+'12'.repeat(20);
  assert.equal(spConservation({...args,tokenEvents:bad}).ok,false,field);
}
const positive=readFileSync('docs/design/aoa-balance-mode/data/a6-gauge-local/positive.jsonl','utf8').trim().split('\n').map(JSON.parse)[1];
const success={...args,before:positive.readbacks.before.A,after:positive.readbacks.after.A,
  tokenEvents:decodeLogsFrom(positive.logs,inv.xPNTs.address,TOKEN_EVENTS_ABI),
  spEvents:decodeLogsFrom(positive.logs,inv.code.superPaymasterProxy.address,SP_EVENTS_ABI),cls:{verdict:'USEROP_SUCCESS'}};
assert.equal(spConservation(success).ok,true);
for (const field of ['user','locker']) {
  const bad=structuredClone(success.tokenEvents);bad.find(e=>e.event==='LockCreated').args[field]='0x'+'12'.repeat(20);
  assert.equal(spConservation({...success,tokenEvents:bad}).ok,false,field);
}
console.log('PASS: round-2 pin, validation writes, unchanged xPNTs/supply, success and postOp lock identities');

import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { getAddress, keccak256 } from 'viem';
import { createWindow } from './window-schedule.mjs';
import { sha256, stringify, writeArtifact } from './evidence.mjs';
import { localUserOpHash } from './gauge-lib.mjs';
import { finalizePVG, recordPVG } from './pvg.mjs';

const accounts=[200,201,202].map(n=>getAddress('0x'+n.toString(16).padStart(40,'0')));
const bytes=execFileSync('python3.11',['-B','script/a6-collector/frozen-fixture.py']);
const bundleSha256=sha256(bytes);
const {adapters,manifest}=createWindow({readBundle:()=>bytes,bundleSha256,seed:'public',chainId:10,accounts});
const [legacyStart]=readFileSync(new URL('../../docs/design/aoa-balance-mode/data/a6-gauge-local/positive.jsonl',import.meta.url),'utf8').split('\n',1).map(JSON.parse);
const names={SP:'SP',VerifyingPaymaster:'VPM',TokenPaymaster:'TPM'};
const deadline='slot_deadline_exceeded';
const NO_TRAILER='missing or invalid trailer: interrupted window';

function fixture(t) {
  const dir=mkdtempSync(join(process.cwd(),'.validate-window-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const passports=new Map(accounts.map(sender=>{
    const p=structuredClone(legacyStart.passport), {frozen}=adapters.get(sender);
    Object.assign(p,{chainId:10,allowSameEndpointLocal:false});
    Object.assign(p.invariant,{sender,gas:frozen.gas,pmGas:frozen.pmGas,callDataHash:keccak256(frozen.callData),
      credit:{policy:0,hasPendingPolicy:false,pendingPolicy:0,pendingPolicyEta:0,policyEpoch:0}});
    p.invariant.code.account.address=sender;
    for(const stake of Object.values(p.invariant.stakes)) Object.assign(stake,{staked:true,stake:'1000000000000000000',unstakeDelaySec:86400});
    return [sender,p];
  }));
  const m=structuredClone(manifest), {schedule,targetTriplets,slotCap}=m;
  m.startTimestamp=legacyStart.passport.block.timestamp;
  const head={schema:'a6-gauge/2',runId:'frozen-test'}, arms=Object.values(names);
  const start={...head,kind:'run_start',formal:true,protocolConformant:true,fixture:null,rpcA:'https://a.invalid',rpcB:'https://b.invalid',
    allowSameEndpointLocal:false,count:targetTriplets,maxAttempts:slotCap,arms,passport:structuredClone(passports.get(accounts[0]))};
  const last=structuredClone(start.passport);
  last.block={...last.block,number:String(BigInt(last.block.number)+1n),hash:'0x'+'ad'.repeat(32)};
  const rows=schedule.payload.slots.flatMap(slot=>slot.order.map((name,j)=>{
    const arm=names[name],sender=slot.senders[name];
    return {...adapters.get(sender).row(arm,Math.floor(slot.block_slot/accounts.length)),...head,kind:'attempt',
      attemptIndex:slot.block_slot*arms.length+j,tripletIndex:slot.block_slot,arm,sender,armOrder:slot.order.map(a=>names[a]),
      block_slot:slot.block_slot,pair_id:slot.pair_id,seed:schedule.payload.seed,schedule_sha256:schedule.sha256,
      fixture:null,collectedAtUtc:'2026-11-25T00:00:00Z',sent:false,tx:null,verdict:'NOT_SENT',
      failingCheck:deadline,scheduleDisposition:deadline,slotChecks:[{allowed:false,reason:deadline,wait:{
        start:BigInt(m.startTimestamp)+BigInt(slot.start_seconds),
        deadline:BigInt(m.startTimestamp)+BigInt(slot.deadline_seconds),
        timestamp:BigInt(m.startTimestamp)+BigInt(slot.deadline_seconds)+1n
      }}]};
  }));
  const end={...head,kind:'run_end',passport:last,targetTriplets,matchedTriplets:0,stop:{reason:'INCOMPLETE',code:10},exitCode:10,
    tally:Object.fromEntries(arms.map(a=>[a,{attempts:slotCap,verdicts:{NOT_SENT:slotCap}}])),
    triplets:schedule.payload.slots.map(({block_slot,pair_id})=>({block_slot,pair_id,matched:false,
      attempts:arms.map((_,j)=>block_slot*arms.length+j),tripletIndex:block_slot}))};
  const index=rows.map(r=>({attempt:r.attemptIndex,passports:{start:{path:`passports/start-${r.sender}.json`}}}));
  return {m,start,rows,end,index,passports,run({withPlan=true,withManifest=true,bundle=bytes,truncated=false}={}) {
    if(withManifest) writeArtifact(dir,'manifest.json',m);
    for(const [sender,p] of passports) writeArtifact(dir,`passports/start-${sender}.json`,p);
    writeFileSync(join(dir,'bundle.json'),bundle);
    writeFileSync(join(dir,'run.jsonl'),[start,...rows,...(truncated?[]:[end])].map(stringify).join('\n')+'\n');
    writeFileSync(join(dir,'index.ndjson'),index.map(stringify).join('\n')+'\n');
    const r=spawnSync(process.execPath,['script/a6-collector/validate.mjs',join(dir,'run.jsonl'),
      ...(withPlan?['--frozen-plan',join(dir,'bundle.json')]:[])],{encoding:'utf8'});
    assert.ifError(r.error);
    return {status:r.status,...JSON.parse(r.stdout)};
  }};
}

function refused(report,message) {
  assert.ok([1,2].includes(report.status),JSON.stringify(report));
  assert.match([...report.errors,report.missing].join('\n'),message);
}

test('window requires --frozen-plan from manifest provenance alone',t=>{
  const f=fixture(t);
  for(const row of f.rows) { delete row.bundleSha256; delete row.planDigest; }
  const result=f.run({withPlan:false});
  assert.equal(result.status,2);
  refused(result,/requires --frozen-plan/);
});
for(const source of ['start','attempt']) test(`window requires --frozen-plan from ${source} provenance without a manifest`,t=>{
  const f=fixture(t);
  if(source==='start') {
    for(const row of f.rows) { delete row.bundleSha256; delete row.planDigest; }
    f.start.planDigest=manifest.plan_sha256[accounts[0]];
  }
  const result=f.run({withPlan:false,withManifest:false});
  assert.equal(result.status,2);
  refused(result,/requires --frozen-plan/);
});
test('window rejects a bundle with mismatched bytes',t=>{
  refused(fixture(t).run({bundle:Buffer.concat([bytes,Buffer.from('\n')])}),/bundle SHA-256 mismatch/);
});
test('window rejects mismatched row bundleSha256 and planDigest',t=>{
  const f=fixture(t), row=f.rows.find(r=>r.sender===accounts[1]);
  row.bundleSha256='0'.repeat(64);
  row.planDigest=f.m.plan_sha256[accounts[0]];
  const r=f.run();
  refused(r,/bundleSha256 mismatch/);
  refused(r,/planDigest mismatch/);
});
test('window rejects a mismatched manifest plan digest',t=>{
  const f=fixture(t);
  f.m.plan_sha256[accounts[1]]=f.m.plan_sha256[accounts[0]];
  refused(f.run(),/manifest planDigest mismatch/);
});
test('window accepts all three start passports and scheduled NOT_SENT rows',t=>{
  const f=fixture(t), sp=f.rows.find(r=>r.arm==='SP');
  sp.failingCheck=sp.scheduleDisposition=sp.slotChecks[0].reason='sp_valid_after_exceeds_slot_deadline';
  sp.slotChecks[0].wait.timestamp=sp.slotChecks[0].wait.deadline;
  sp.slotChecks[0].wait.validAfter=sp.slotChecks[0].wait.deadline+1n;
  assert.equal(f.passports.get(accounts[1]).invariant.pmGas.VPM.post,0n);
  const r=f.run();
  // The fixture has no archive or trailer (PR 2b): that is the only error the window may report.
  assert.deepEqual(r.errors,[NO_TRAILER],JSON.stringify(r));
  assert.equal(r.accepted,false);
  assert.deepEqual(r.recomputed,{NOT_SENT:f.rows.length});
});
test('a packed NOT_SENT operation uses the passport of its sender',async t=>{
  const f=fixture(t), row=f.rows.find(r=>r.arm==='VPM' && r.sender===accounts[1]);
  const {frozen,plan:{phaseC}}=adapters.get(row.sender), {invariant:inv}=f.passports.get(row.sender);
  const gas={...frozen.gas.VPM}, pmGas=frozen.pmGas.VPM, paymaster=inv.code.verifyingPaymaster.address;
  const hex=n=>n.toString(16).padStart(32,'0');
  const lengths=phaseC.pvgLengths.VPM;
  const {packed,pvg}=await finalizePVG(async preVerificationGas=>({packed:{
    sender:row.sender,nonce:0n,initCode:'0x',callData:frozen.callData,
    accountGasLimits:'0x'+hex(gas.verificationGasLimit)+hex(gas.callGasLimit),preVerificationGas,
    gasFees:'0x'+hex(gas.maxPriorityFeePerGas)+hex(gas.maxFeePerGas),
    paymasterAndData:paymaster+hex(pmGas.ver)+hex(pmGas.post)+'00'.repeat(lengths.paymasterAndData-52),
    signature:'0x'+'11'.repeat(lengths.signature)
  }}),inv.beneficiary,{lengths,reserve:phaseC.pvgReserve.VPM});
  const entryPoint=inv.entryPoint.address, hash=localUserOpHash(packed,entryPoint,10);
  gas.preVerificationGas=pvg.value;
  Object.assign(row,{chainId:10,entryPoint,paymaster,nonce:packed.nonce,bundler:inv.bundler,callDataHash:inv.callDataHash,gas,pmGas,
    expectedUserOpHash:hash,epUserOpHash:hash,localUserOpHash:hash,bundledUserOpHashes:[hash],packedOp:packed,bundledOps:[packed],guard:{allowed:true}});
  row.slotChecks.unshift({allowed:true,wait:{...row.slotChecks[0].wait}});
  recordPVG(row,pvg);
  const r=f.run();
  assert.deepEqual(r.errors,[NO_TRAILER],JSON.stringify(r));
});
for(const key of ['gas','pmGas']) test(`window rejects sender 2's mismatched frozen ${key}`,t=>{
  const f=fixture(t), inv=f.passports.get(accounts[1]).invariant;
  if(key==='gas') inv.gas.VPM.callGasLimit++;
  else inv.pmGas.VPM.post++;
  refused(f.run(),new RegExp(`sender ${accounts[1]}: frozen ${key}/passport mismatch`));
});
for(const [field,mutate,message] of [
  ['arm',r=>{r.arm=r.armOrder[1];},/schedule armOrder mismatch/],
  ['armOrder',r=>{r.armOrder.reverse();},/schedule armOrder mismatch/],
  ['sender',r=>{r.sender=accounts.find(a=>a!==r.sender);},/schedule sender mismatch/],
  ['pair_id',r=>{r.pair_id='other';},/schedule pair_id/],
  ['seed',r=>{r.seed='other';},/schedule hash or seed mismatch/],
  ['schedule_sha256',r=>{r.schedule_sha256='0'.repeat(64);},/schedule hash or seed mismatch/],
  ['scheduleDisposition',r=>{r.scheduleDisposition='other';},/invalid schedule disposition/],
  ['slotChecks',r=>{r.slotChecks=[];},/invalid schedule disposition/],
  ['failingCheck',r=>{r.failingCheck='unknown';r.logs=[];},/NOT_SENT contradicts row evidence or failingCheck/]
]) test(`window rejects a mismatched ${field}`,t=>{
  const f=fixture(t);
  mutate(f.rows[0]);
  refused(f.run(),message);
});
test('window binds the index start passport to its row sender',t=>{
  const f=fixture(t);
  f.index[0].passports.start.path=f.index[1].passports.start.path;
  refused(f.run(),/index start passport mismatch/);
});
test('a truncated window (no run_end, no trailer) reports the interrupted archive and refuses',t=>{
  const r=fixture(t).run({truncated:true});
  assert.equal(r.status,2,JSON.stringify(r));
  assert.deepEqual(r.errors,[NO_TRAILER]);
  assert.match(r.missing,/last line is not run_end/);
});

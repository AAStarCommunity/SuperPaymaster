import { syntheticSummary } from './synthetic-summary.mjs';
// PR #477 reviewer regressions. All inputs are synthetic; no RPC or archive writes.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { spawnSync, execFileSync } from 'node:child_process';
import { keccak256, toBytes } from 'viem';
import { localUserOpHash, conservationStop, spConservation, decodeLogsFrom, SP_EVENTS_ABI, TOKEN_EVENTS_ABI } from '../gauge-lib.mjs';
const out = 'script/a6-collector/offline-review';
const dir = mkdtempSync(`${out}/.review-`);
const root = process.env.A6_REVIEW_ARCHIVE ?? 'docs/design/aoa-balance-mode/data/a6-gauge-local';
const load = name => readFileSync(`${root}/${name}.jsonl`, 'utf8').trim().split('\n').map(JSON.parse);
const old = `${dir}/old.mjs`;
writeFileSync(old, execFileSync('git', ['show', '6b0a4261:script/a6-collector/validate.mjs']));
const sig = s => keccak256(toBytes(s));
const UOE = sig('UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)');
const LOCK = sig('LockCreated(address,bytes32,address,uint256,uint256)');
const SETTLE = sig('LockSettled(address,bytes32,uint256,uint256)');
const SPONSORED = sig('TransactionSponsored(address,address,uint256,uint256)');
const CREDIT = sig('CreditReserved(address,bytes32,address,uint256)');
const POST = sig('PostOpRevertReason(bytes32,address,uint256,bytes)');
const word = n => BigInt(n).toString(16).padStart(64, '0');
const results = [];
function run(a, validator) {
  const file = `${dir}/input.jsonl`;
  writeFileSync(file, a.map(JSON.stringify).join('\n') + '\n');
  const r = spawnSync(process.execPath, [validator, file], { encoding: 'utf8' });
  assert.ifError(r.error);
  return { exit: r.status, report: JSON.parse(r.stdout) };
}
function check(name, a, oldExit, newExit, proof) {
  a = syntheticSummary(structuredClone(a));
  const before = run(a, old), after = run(a, 'script/a6-collector/validate.mjs');
  assert.equal(before.exit, oldExit, `${name} old: ${JSON.stringify(before.report)}`);
  assert.equal(after.exit, newExit, `${name} new: ${JSON.stringify(after.report)}`);
  if (proof) assert.match(after.report.errors.join(';'), proof);
  if (newExit === 3) { assert.equal(after.report.consistent, true); assert.equal(after.report.accepted, false); }
  results.push([name, oldExit, newExit, after.report.errors.join('; ') || 'consistent']);
}
function budget(a) { Object.assign(a.at(-1), { matchedTriplets: 0, exitCode: 10, stop: { reason: 'MAX_ATTEMPTS', code: 10 } }); }
function unsent(r) { Object.assign(r, { sent: false, tx: null, logs: [], verdict: 'NOT_SENT', failingCheck: 'preflight_revert', exclusion: 'NOT_SENT:PREFLIGHT' }); delete r.readbacks; delete r.conservation; }
function nothing() {
  const a = load('positive'); a.slice(1,-1).forEach(unsent); budget(a);
  a.at(-1).passport.volatile.operatorBalance = a[0].passport.volatile.operatorBalance;
  return a;
}
try {
  for (const count of [1, 2]) {
    const a = load('positive'); a.slice(-1-count,-1).forEach(unsent); budget(a);
    check(`F1-${count}-unsent`, a, 1, 3);
    const bad = structuredClone(a); bad[1].tx.from = '0x'+'22'.repeat(20);
    check(`F1-${count}-unsent-bundler-tamper`, bad, 1, 1, /bundler/);
  }
  const deposit=load('positive');unsent(deposit[3]);deposit[3].failingCheck='deposit_floor';deposit[3].exclusion='NOT_SENT:DEPOSIT_FLOOR';budget(deposit);check('F1-deposit-floor-unsent',deposit,1,3);
  const trailing = load('positive');
  const tail = structuredClone(trailing.slice(1,-1)); tail.forEach((r,i)=>{unsent(r);r.attemptIndex=3+i;r.tripletIndex=1;});
  trailing.splice(-1,0,...tail); budget(trailing); trailing.at(-1).matchedTriplets=1;
  check('F1-trailing-all-unsent-triplet',trailing,1,3);
  const a = nothing(); check('F1-F4-all-unsent', a, 1, 3);
  // Isolate F4 from F1 with zero attempts, rather than hiding the old missing-field verdict.
  const zero = nothing(); zero.splice(1,3); check('F4-zero-attempts', zero, 2, 3);
  for (const [name, source] of [['nothing',a], ['zero',zero]]) {
    const bad = structuredClone(source); bad.at(-1).passport.volatile.operatorBalance = '1';
    check(`F4-${name}-balance-tamper`, bad, 1, 1, /end passport balance/);
  }
  const dup = load('positive'); dup[3].tx.hash = dup[2].tx.hash;
  check('F1-duplicate-sent-tx', dup, 1, 1, /reused transaction|must be distinct/);
  const floor = nothing();
  for (const p of [floor[0].passport, floor.at(-1).passport]) p.invariant.superPaymaster.minPostOpGas = '200001';
  check('F7-unsent-floor', floor, 1, 3);
  function tailRate(a) {
    const r=a[1], pd=r.packedOp.paymasterAndData; r.packedOp.paymasterAndData=pd.slice(0,146)+word(0)+pd.slice(210);
    const prev=r.expectedUserOpHash,h=localUserOpHash(r.packedOp,r.entryPoint,r.chainId);
    r.expectedUserOpHash=r.localUserOpHash=r.epUserOpHash=h;r.bundledOps=[structuredClone(r.packedOp)];r.bundledUserOpHashes=[h];
    for(const l of r.logs)l.topics=l.topics.map(t=>t.toLowerCase()===prev.toLowerCase()?h:t);
  }
  const withheldTail=nothing();tailRate(withheldTail);check('F7-unsent-low-maxRate',withheldTail,1,3);
  const executedTail=load('positive');tailRate(executedTail);check('F7-executed-low-maxRate-tamper',executedTail,1,1,/maxRate/);
  const executed = load('positive');
  for (const p of [executed[0].passport, executed.at(-1).passport]) p.invariant.superPaymaster.minPostOpGas = '200001';
  check('F7-executed-floor-tamper', executed, 1, 1, /below contract floor/);
  // First tx reverted: preserve its block evidence but roll back every state leaf.
  const failed = load('positive'), r = failed[1], delta = BigInt(r.readbacks.before.A.operatorBalance)-BigInt(r.readbacks.after.A.operatorBalance);
  r.tx.status = 'reverted'; r.logs = []; r.verdict = 'TX_FAILED'; r.conservation = { evaluated:false, ok:null, checks:[] };
  for (const rpc of ['A','B']) r.readbacks.after[rpc] = { ...r.readbacks.before[rpc], blockNumber:r.tx.blockNumber, blockHash:r.tx.blockHash };
  for (const row of failed.slice(2,-1)) for (const side of ['before','after']) for (const rpc of ['A','B']) row.readbacks[side][rpc].operatorBalance = String(BigInt(row.readbacks[side][rpc].operatorBalance)+delta);
  failed.at(-1).passport.volatile.operatorBalance = r.readbacks.after.A.operatorBalance; budget(failed);
  for (const p of [failed[0].passport,failed.at(-1).passport]) p.invariant.superPaymaster.minPostOpGas = '200001';
  check('F7-tx-failed-floor', failed, 1, 3);
  const badFailed = structuredClone(failed); badFailed[1].readbacks.after.A.debts = '1'; badFailed[1].readbacks.after.B.debts = '1';
  check('F7-tx-failed-state-tamper', badFailed, 1, 1, /no_execution.debts/);
  function credit(name) {
    const a = load(name), r=a[1], inv=a[0].passport.invariant;
    const lock=r.logs.find(l=>l.topics[0]===LOCK), a0=BigInt('0x'+lock.data.slice(66,130));
    lock.topics[0]=CREDIT; lock.data='0x'+word(a0);
    r.logs=r.logs.filter(l=>![SETTLE,SPONSORED].includes(l.topics[0]));
    const u=r.logs.find(l=>l.topics[0]===UOE); u.data=u.data.slice(0,66)+word(0)+u.data.slice(130);
    r.logs.push({address:r.entryPoint,topics:[POST,u.topics[1],u.topics[2]],data:'0x'});
    r.verdict=name==='positive'?'USEROP_REVERTED':r.verdict;
    r.conservation={evaluated:name==='positive',ok:name==='positive'?true:null,checks:[]};
    for(const rpc of ['A','B']) {
      const b=r.readbacks.before[rpc], z=r.readbacks.after[rpc];
      Object.assign(z,{operatorBalance:String(BigInt(b.operatorBalance)-a0),totalSpent:String(BigInt(b.totalSpent)+a0),
        protocolRevenue:b.protocolRevenue,totalTxSponsored:b.totalTxSponsored,userXPNTs:b.userXPNTs,totalSupply:b.totalSupply,
        lockedOf:b.lockedOf,lockXLocked:'0',debts:b.debts,creditReservedOf:String(BigInt(b.creditReservedOf)+a0),
        inflightOperator:inv.superPaymaster.operator.address,inflightA0:String(a0)});
      // Foreign op's inflight mapping is not the expected op's mapping.
      if(name!=='positive') { z.inflightOperator=b.inflightOperator; z.inflightA0=b.inflightA0; }
    }
    for(const row of a.slice(2,-1)) for(const side of ['before','after']) for(const rpc of ['A','B']) row.readbacks[side][rpc].operatorBalance=r.readbacks.after.A.operatorBalance;
    a.at(-1).passport.volatile.operatorBalance=r.readbacks.after.A.operatorBalance; budget(a); return a;
  }
  for(const name of ['positive','b-drop-op','c-wrong-hash']) {
    const a=credit(name); check(`F3-credit-postop-${name}`,a,1,3);
    for(const f of ['creditReservedOf','debts']) {const bad=structuredClone(a); for(const rpc of ['A','B']) bad[1].readbacks.after[rpc][f]='1';check(`F3-${name}-${f}-tamper`,bad,1,1,/R.credit_unchanged|receipt.unexplained/);}
    for(const topic of [1,3]) {const bad=structuredClone(a); bad[1].logs.find(l=>l.topics[0]===CREDIT).topics[topic]='0x'+'22'.repeat(32);check(`F3-${name}-identity-${topic}`,bad,1,1,/R.lock_identity/);}
  }
  const cr=credit('positive'), rcr=cr[1], inv=cr[0].passport.invariant;
  const args={before:rcr.readbacks.before.A,after:rcr.readbacks.after.A,tokenEvents:decodeLogsFrom(rcr.logs,inv.xPNTs.address,TOKEN_EVENTS_ABI),spEvents:decodeLogsFrom(rcr.logs,inv.code.superPaymasterProxy.address,SP_EVENTS_ABI),expectedHash:rcr.expectedUserOpHash,sender:rcr.sender,paymaster:rcr.paymaster,operator:inv.superPaymaster.operator.address,cls:{verdict:'USEROP_REVERTED',revertKind:'postOpReverted'}};
  assert.equal(spConservation(args).ok,true); assert.equal(spConservation(args).mode,'CREDIT');
  for(const field of ['creditReservedOf','debts','inflightA0']) assert.equal(spConservation({...args,after:{...args.after,[field]:'1'}}).ok,false);
  for(const field of ['user','locker']) {const bad=structuredClone(args);bad.tokenEvents.find(e=>e.event==='CreditReserved').args[field]='0x'+'22'.repeat(20);assert.equal(spConservation(bad).ok,false);}
  assert.equal(conservationStop([{id:'continuity.block',ok:true}]),null);
  for(const id of ['continuity.block','unique.tx']) { const stop=conservationStop([{id,ok:false}]); assert.equal(stop.reason,'EVIDENCE_CONTINUITY_MISMATCH'); assert.equal(stop.code,28); }
  assert.equal(conservationStop([{id:'D1',ok:false}]).code,22);
  check('F6-priced-positive',load('positive'),0,0);
  // Keep fee/accounting coherent: zero aGas/charge used to pass all identities.
  { const free=load('positive'), r=free[1], b=r.readbacks.before.A;
  r.logs.find(l=>l.topics[0]===SPONSORED).data='0x'+word(0)+word(0);
  r.logs.find(l=>l.topics[0]===SETTLE).data='0x'+word(0)+word(0);
  for(const rpc of ['A','B']) for(const f of ['operatorBalance','protocolRevenue','userXPNTs','totalSupply']) r.readbacks.after[rpc][f]=r.readbacks.before[rpc][f];
  for(const row of free.slice(2,-1)) for(const side of ['before','after']) for(const rpc of ['A','B']) row.readbacks[side][rpc].operatorBalance=b.operatorBalance;
  free.at(-1).passport.volatile.operatorBalance=b.operatorBalance;
  check('F6-zero-self-consistent-charge',free,0,1,/C9.aGas_actualGasCost_price/);
  }
  const archiveNames=['positive','a-exec-revert','b-drop-op','c-wrong-hash','d-tamper-b','e-conservation-injected','e-missing-field','n50-mechanism'], archiveExits=[0,3,3,3,2,1,2,3], archiveRows=[];
  for(const [i,name] of archiveNames.entries()) {
    const result=run(load(name),'script/a6-collector/validate.mjs');assert.equal(result.exit,archiveExits[i],name);
    const report=result.report;archiveRows.push([name,result.exit,report.matchedTriplets??'',report.missing??(report.errors.join('; ')||'consistent')]);
  }
  writeFileSync(`${out}/round4-archives.tsv`,'archive\texit\tmatched\tproof\n'+archiveRows.map(r=>r.join('\t')).join('\n')+'\n');
  const table=spawnSync(process.execPath,['script/a6-collector/negative-controls/table.mjs',root],{encoding:'utf8'});assert.equal(table.status,0,table.stderr);assert.match(table.stdout,/exit \*\*2\*\* \(fails closed, not accepted\)/);
  const lines=readFileSync(`${root}/results.tsv`,'utf8').replace(/(a-exec-revert\t10\t)3/,'$1'+'0');
  writeFileSync(`${dir}/results.tsv`,lines);
  const badTable=spawnSync(process.execPath,['script/a6-collector/negative-controls/table.mjs',dir],{encoding:'utf8'});assert.notEqual(badTable.status,0);assert.match(badTable.stderr,/a-exec-revert: expected collector/);
  const pin=p=>execFileSync('git',['show',`1ac0e1c5:${p}`],{encoding:'utf8'}).split('\n');
  const sp=pin('contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol'), ep=pin('singleton-paymaster/lib/account-abstraction-v7/contracts/core/EntryPoint.sol'), st=pin('contracts/src/paymasters/superpaymaster/v3/SuperPaymasterStorage.sol');
  for(const [lines,n,text] of [[sp,424,'uint32(snap >> 96)'],[sp,425,'actualUserOpFeePerGas'],[sp,427,'actualGasCost + bufWei'],[ep,672,'userOp.preVerificationGas'],[ep,703,'actualGas * gasPrice'],[ep,716,'preGas - gasleft()'],[ep,730,'actualGas * gasPrice'],[st,201,'175_000'],[st,200,'2_000_000'],[st,202,'5_000'],[st,203,'50_000']])assert.ok(lines[n-1].includes(text),`pin:${n}: ${text}`);
  writeFileSync(`${out}/review-results.tsv`,'control\told_exit\tnew_exit\tproof\n'+results.map(r=>r.join('\t')).join('\n')+'\n');
  console.log(`PASS: ${results.length} PR reviewer controls, plus collector CREDIT-postOp accounting and identity controls`);
} finally { rmSync(dir,{recursive:true,force:true}); }

// Final #477 Low findings: compare the reviewed head with this worktree, offline.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync, readdirSync, symlinkSync } from 'node:fs';
import { spawnSync, execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
import { keccak256, toBytes } from 'viem';
import { localUserOpHash } from '../gauge-lib.mjs';
import { syntheticSummary } from './synthetic-summary.mjs';
const out = 'script/a6-collector/offline-review';
const root = process.env.A6_REVIEW_ARCHIVE ?? 'docs/design/aoa-balance-mode/data/a6-gauge-local';
const dir = mkdtempSync(`${out}/.followups-`);
const baseline = p => execFileSync('git', ['show', `58a8eb44:${p}`], { encoding: 'utf8' });
const reviewed = `${dir}/reviewed.mjs`;
writeFileSync(reviewed, execFileSync('git', ['show', '64246042:script/a6-collector/validate.mjs'], { encoding: 'utf8' }));
const old = `${dir}/old.mjs`, validator = 'script/a6-collector/validate.mjs';
writeFileSync(old, baseline(validator));
const load = () => readFileSync(`${root}/positive.jsonl`, 'utf8').trim().split('\n').map(JSON.parse);
const results = [];
const sig = s => keccak256(toBytes(s));
const UOE = sig('UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)');
const LOCK = sig('LockCreated(address,bytes32,address,uint256,uint256)');
const word = n => BigInt(n).toString(16).padStart(64, '0');
function run(a, script) {
  const file = `${dir}/input.jsonl`;
  writeFileSync(file, a.map(JSON.stringify).join('\n') + '\n');
  const r = spawnSync(process.execPath, [script, file], { encoding: 'utf8' });
  assert.ifError(r.error);
  return { exit: r.status, report: JSON.parse(r.stdout) };
}
function check(name, a, oldExit, newExit, proof, comparator = old) {
  const before = run(a, comparator), after = run(a, validator);
  assert.equal(before.exit, oldExit, `${name} old: ${JSON.stringify(before.report)}`);
  assert.equal(after.exit, newExit, `${name} new: ${JSON.stringify(after.report)}`);
  if (proof) assert.match(after.report.errors.join('; '), proof, name);
  if (newExit === 3) { assert.equal(after.report.consistent, true); assert.equal(after.report.accepted, false); }
  results.push([name, oldExit, newExit, after.report.errors.join('; ') || 'consistent']);
}
function unsent(r) {
  Object.assign(r, { sent: false, tx: null, logs: [], verdict: 'NOT_SENT', failingCheck: 'preflight_revert' });
  delete r.readbacks; delete r.conservation;
}
function budget(a) { Object.assign(a.at(-1), { matchedTriplets: 0, exitCode: 10, stop: { reason: 'MAX_ATTEMPTS', code: 10 } }); }
try {
  const honest = load(); unsent(honest[3]); budget(honest); syntheticSummary(honest);
  check('N1-honest-NOT_SENT', honest, 3, 3);
  for (const reason of ['deposit_floor', 'preflight_revert']) {
    const a = structuredClone(honest); a[3].failingCheck = reason;
    check(`N1-honest-${reason}`, a, 3, 3);
  }
  const hidden = load(); Object.assign(hidden[3], { sent: false, verdict: 'NOT_SENT' });
  hidden[3].tx.from = '0x' + '22'.repeat(20); budget(hidden); syntheticSummary(hidden);
  check('N1-hidden-receipt', hidden, 3, 1, /NOT_SENT contradicts/);
  for (const field of ['tx', 'logs', 'readbacks', 'failingCheck']) {
    const a = structuredClone(honest);
    if (field === 'tx') a[3].tx = load()[3].tx;
    if (field === 'logs') a[3].logs = load()[3].logs;
    if (field === 'readbacks') a[3].readbacks = load()[3].readbacks;
    if (field === 'failingCheck') a[3].failingCheck = 'invented';
    check(`N1-unsent-${field}-tamper`, a, 3, 1, /NOT_SENT contradicts/);
  }
  for (const receipt of [false, true]) {
    const a = load(), r = structuredClone(a[3]);
    if (!receipt) unsent(r); else Object.assign(r, { sent: false, verdict: 'NOT_SENT' });
    r.attemptIndex = 3; r.tripletIndex = 1; r.arm = 'SP';
    // Use an honest SP-shaped withheld row; receipt variant stays TPM to reproduce the review probe.
    if (!receipt) { const sp = structuredClone(a[1]); unsent(sp); Object.assign(sp, {attemptIndex:3, tripletIndex:1}); a.splice(-1,0,sp); }
    else { r.arm = 'TPM'; a.splice(-1,0,r); }
    syntheticSummary(a);
    check(`N1-after-target-${receipt ? 'receipt' : 'withheld'}`, a, 0, 1, /attempt after COMPLETE target/);
  }
  for (const field of ['tally', 'triplets', 'targetTriplets']) {
    const a = load();
    if (field === 'tally') a.at(-1).tally.TPM.attempts++;
    if (field === 'triplets') a.at(-1).triplets[0].attempts.pop();
    if (field === 'targetTriplets') a.at(-1).targetTriplets++;
    check(`N1-${field}-tamper`, a, 0, 1, new RegExp(`run_end.${field}`));
  }
  check('N1-honest-COMPLETE', load(), 0, 0);
  const badBundler = load(); badBundler[3].tx.from = '0x'+'22'.repeat(20);
  check('N1-sent-bundler-tamper', badBundler, 1, 1, /bundler/);

  // Execute the actual shell publication tail, with archive files and no chain setup.
  const campaign = `${dir}/campaign`;
  execFileSync('mkdir', [campaign]);
  for (const name of readdirSync(root)) if (name !== 'results.tsv' && name !== 'NEGATIVE-CONTROLS.md') symlinkSync(resolve(root, name), `${campaign}/${name}`);
  const runner = 'script/a6-collector/negative-controls/run.sh';
  const publication = source => source.slice(source.lastIndexOf('\nrun n50-mechanism')).split('\n').slice(2).join('\n');
  for (const tamper of [false, true]) {
    const lines = readFileSync(`${root}/results.tsv`, 'utf8');
    writeFileSync(`${campaign}/results.tsv`, tamper ? lines.replace(/(a-exec-revert\t10\t)3/, '$1'+'0') : lines);
    const exits = [];
    for (const source of [baseline(runner), readFileSync(runner, 'utf8')]) {
      writeFileSync(`${campaign}/NEGATIVE-CONTROLS.md`, 'previous valid report\n');
      const r = spawnSync('bash', ['-u', '-c', publication(source)], { encoding: 'utf8', env: { ...process.env, OUT: resolve(campaign), GAUGE: resolve('script/a6-collector') } });
      assert.ifError(r.error); exits.push(r.status);
      if (tamper && source === readFileSync(runner, 'utf8')) {
        assert.match(r.stderr, /a-exec-revert: expected collector/);
        assert.equal(readFileSync(`${campaign}/NEGATIVE-CONTROLS.md`, 'utf8'), 'previous valid report\n');
        assert.doesNotMatch(r.stdout, /wrote/);
      }
      if (!tamper) assert.equal(readFileSync(`${campaign}/NEGATIVE-CONTROLS.md`, 'utf8'), readFileSync(`${root}/NEGATIVE-CONTROLS.md`, 'utf8'));
    }
    assert.deepEqual(exits, tamper ? [0,1] : [0,0]);
    results.push([`N2-${tamper ? 'wrong-verdict' : 'honest-table'}`, ...exits, tamper ? 'run.sh fails; previous report preserved; no success message' : 'archive table identical']);
  }

  // Prose controls check the actual tracked files, and reject restored stale claims.
  const docs = ['README.md','ROUND5.md','REVIEW-FIXES.md','FOLLOWUPS.md'];
  const proseOK = texts => texts.every(t => /58a8eb44/.test(t) && /0988a589/.test(t))
    && !texts.some(t => /regenerated (?:at `d8c8a9f4`|in `6b0a4261`)|The existing archive remains unchanged|No chain regeneration was authorized here|No commits, pushes|no chain operations, contract source\s+edits, commits or pushes|No remote PR body was edited|direct N1 probes never normalize summaries/i.test(t));
  const prior = docs.map(n => n === 'FOLLOWUPS.md' ? execFileSync('git', ['show', `64246042:${out}/${n}`], { encoding: 'utf8' }) : baseline(`${out}/${n}`)), current = docs.map(n => readFileSync(`${out}/${n}`, 'utf8'));
  assert.equal(proseOK(prior), false); assert.equal(proseOK(current), true);
  results.push(['N3-current-provenance', 'stale', 'current', '58a8eb44 archive / 0988a589 collector; historical scope distinguished']);
  for (const claim of ['No commits, pushes', 'no commits, pushes', 'NO COMMITS, PUSHES']) {
    assert.equal(proseOK([...current, claim]), false);
    results.push([`N3-case-${claim}`, 'stale', 'reject', 'case-insensitive provenance assertion']);
  }
  for (const [i, text] of prior.entries()) {
    const tampered = [...current]; tampered[i] = text; assert.equal(proseOK(tampered), false);
    results.push([`N3-restored-stale-${docs[i]}`, 'reject', 'reject', 'provenance assertion rejects historical prose']);
  }

  check('N4-honest-single-UOE', load(), 0, 0);
  for (const name of ['CreditReserved(address,bytes32,address,uint256)', 'LockCreated(address,bytes32,address,uint256,uint256)', 'LockSettled(address,bytes32,uint256,uint256)', 'CreditSettled(address,bytes32,uint256)']) {
    const a = load(), event = structuredClone(a[1].logs.find(l => l.topics[0] === LOCK));
    event.topics[0] = sig(name); event.topics[2] = '0x'+'22'.repeat(32); a[1].logs.push(event);
    check(`N4-orphan-${name.split('(')[0]}`, a, 0, 1, /receipt.orphan_token_event/);
  }
  for (const [index, arm] of [[2,'VPM'],[3,'TPM']]) {
    const a = load(), event = structuredClone(a[1].logs.find(l => l.topics[0] === LOCK));
    event.topics[0] = sig('CreditReserved(address,bytes32,address,uint256)');
    event.topics[2] = '0x'+'22'.repeat(32); a[index].logs.push(event);
    check(`Nit2-${arm}-orphan-CreditReserved`, a, 0, 1, /receipt.orphan_token_event/);
  }
  const badLock = load(); badLock[1].logs.find(l => l.topics[0] === LOCK).topics[3] = '0x'+'22'.repeat(32);
  check('N4-bound-event-identity-tamper', badLock, 1, 1, /lock_identity/);

  function gap(stopped, advance) {
    const a = load(), r = a[3];
    if (advance) {
      const prev = r.expectedUserOpHash, n = BigInt(r.nonce)+2n;
      r.nonce = r.packedOp.nonce = String(n);
      const h = localUserOpHash(r.packedOp, r.entryPoint, r.chainId);
      r.expectedUserOpHash = r.localUserOpHash = r.epUserOpHash = h;
      r.bundledOps = [structuredClone(r.packedOp)]; r.bundledUserOpHashes = [h];
      for (const l of r.logs) l.topics = l.topics.map(t => t.toLowerCase() === prev.toLowerCase() ? h : t);
      const u = r.logs.find(l => l.topics[0] === UOE); u.data = '0x'+word(n)+u.data.slice(66);
    }
    if (stopped) {
      r.tx.blockNumber = String(BigInt(r.tx.blockNumber)+1n); r.tx.headBefore = String(BigInt(r.tx.headBefore)+1n);
      for (const rpc of ['A','B']) {
        r.readbacks.before[rpc].blockNumber = r.tx.headBefore; r.readbacks.before[rpc].blockHash = '0x'+'33'.repeat(32);
        r.readbacks.after[rpc].blockNumber = r.tx.blockNumber;
      }
      r.conservation.checks.find(c => c.id === 'continuity.block').ok = false;
      r.stoppedBy = { reason:'EVIDENCE_CONTINUITY_MISMATCH', detail:{attemptIndex:2,failed:[{id:'continuity.block',ok:false}]} };
      a.at(-1).stop = { reason:'EVIDENCE_CONTINUITY_MISMATCH',code:28 }; a.at(-1).exitCode=28; a.at(-1).matchedTriplets=0;
      a.at(-1).passport.block.number = String(BigInt(r.tx.blockNumber)+1n);
    }
    return syntheticSummary(a);
  }
  check('N5-honest-block-gap', gap(true,false), 3, 3);
  check('N5-honest-external-same-key-advance', gap(true,true), 1, 3);
  check('N5-unstopped-nonce-gap-tamper', gap(false,true), 1, 1, /nonce sequence/);
  const fakeStop = gap(false,true); fakeStop[3].stoppedBy = { reason:'EVIDENCE_CONTINUITY_MISMATCH' };
  Object.assign(fakeStop.at(-1), { matchedTriplets:0, exitCode:28, stop:{reason:'EVIDENCE_CONTINUITY_MISMATCH',code:28} }); syntheticSummary(fakeStop);
  check('N5-stop-label-without-block-gap-tamper', fakeStop, 1, 1, /nonce sequence/);
  const wrongEnd = gap(true,true);
  Object.assign(wrongEnd.at(-1), { exitCode:10, stop:{reason:'MAX_ATTEMPTS',code:10} });
  check('Nit1-stopped-gap-wrong-run-end-tamper', wrongEnd, 1, 1, /nonce sequence/);
  const badNonce = gap(true,true); badNonce[3].logs.find(l => l.topics[0] === UOE).data = '0x'+word(999)+badNonce[3].logs.find(l => l.topics[0] === UOE).data.slice(66);
  check('N5-stopped-event-nonce-tamper', badNonce, 1, 1, /EVENT_FIELD_MISMATCH/);
  const badBlock = gap(true,true); badBlock[3].readbacks.after.A.blockHash = '0x'+'44'.repeat(32);
  check('N5-stopped-block-tamper', badBlock, 1, 1, /readback_after_blockhash/);
  // finish() wrote the final row, but passport@bn threw before attempt() returned.
  // Replay collector:606-617 on the returned prefix only, independent of syntheticSummary.
  function crashAfterWrite(archive, length, code, returnedLast = false) {
    const source = readFileSync(`${root}/${archive}.jsonl`, 'utf8').trim().split('\n').map(JSON.parse);
    const rows = source.slice(1, 1 + length), end = structuredClone(source.at(-1));
    end.stop = { reason: code === 1 ? 'CRASH' : 'PASSPORT_DRIFT', code };
    end.exitCode = code;
    end.passport.volatile.operatorBalance = rows.at(-1).readbacks.after.A.operatorBalance;
    end.tally = Object.fromEntries(source[0].arms.map(arm => [arm, { attempts:0, verdicts:{} }]));
    end.triplets = []; end.matchedTriplets = 0;
    const returned = returnedLast ? rows : rows.slice(0, -1);
    let group = [];
    for (const row of returned) {
      assert.equal(row.verdict, 'USEROP_SUCCESS');
      assert.equal(row.conservation.ok, true);
      const tally = end.tally[row.arm];
      tally.attempts++; tally.verdicts.USEROP_SUCCESS = tally.attempts;
      group.push(row);
      if (group.length === source[0].arms.length) {
        end.triplets.push({tripletIndex:row.tripletIndex,matched:true,attempts:group.map(r => r.attemptIndex)});
        end.matchedTriplets++; group = [];
      }
    }
    return [source[0], ...rows, end];
  }
  for (const archive of ['positive', 'n50-mechanism']) for (const [offset, arm] of ['SP','VPM','TPM'].entries()) {
    const length = (archive === 'positive' ? 0 : 60) + offset + 1;
    for (const code of [1,21]) {
      const a = crashAfterWrite(archive, length, code);
      check(`M1-${archive}-${arm}-stop-${code}-after-write`, a, 1, 3, undefined, reviewed);
      check(`M1-${archive}-${arm}-stop-${code}-tallied`, crashAfterWrite(archive,length,code,true), 3, 3, undefined, reviewed);
      const forged = structuredClone(a), r = forged.at(-2);
      Object.assign(r, {sent:false,verdict:'NOT_SENT',failingCheck:'preflight_revert'});
      check(`M1-${archive}-${arm}-stop-${code}-NOT_SENT-tamper`, forged, 1, 1, /NOT_SENT contradicts/, reviewed);
    }
  }
  for (const code of [0,10]) {
    const a = crashAfterWrite('positive',3,1);
    Object.assign(a.at(-1), {exitCode:code,stop:{reason:code === 0 ? 'COMPLETE' : 'MAX_ATTEMPTS',code}});
    check(`M1-no-exception-stop-${code}`, a, 1, 1, /run_end.tally/, reviewed);
  }
  const mixed = crashAfterWrite('positive', 3, 1);
  mixed.at(-1).matchedTriplets = 1;
  check('M1-mixed-summary-tamper', mixed, 1, 1, /run_end\.(tally|triplets)/, reviewed);
  const missingPassport = crashAfterWrite('positive',1,1);
  missingPassport.at(-1).stop = {reason:'RPC_DISAGREEMENT',code:20};
  missingPassport.at(-1).exitCode = 20; missingPassport.at(-1).passport = null;
  const missingResult = run(missingPassport, validator);
  assert.equal(missingResult.exit, 2); assert.match(missingResult.report.missing, /missing field/);
  assert.equal(missingResult.report.crash, undefined);
  results.push(['R4-null-end-passport', 2, 2, 'missing field; no TypeError']);
  writeFileSync(`${out}/followup-results.tsv`, 'control\told_exit\tnew_exit\tproof\n'+results.map(r => r.join('\t')).join('\n')+'\n');
  console.log(`PASS: ${results.length} follow-up controls (N1–N5: 58a8eb44; M1: 64246042 vs worktree)`);
} finally { rmSync(dir, {recursive:true,force:true}); }

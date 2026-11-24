import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { runSession, parseArgs, PINNED_MODULES, OPERATOR_PAUSE_MS, GENESIS } from './setup-session.mjs';

const ROOT = '/deploy', COMMIT = 'a'.repeat(40);
const sha256 = b => createHash('sha256').update(b).digest('hex');
const gitBlob = b => createHash('sha1').update(Buffer.concat([Buffer.from(`blob ${b.length}\0`), b])).digest('hex');
const IDS = ['0/C2.approve', '0/C2.deposit', '0/C3.deploy'];
const BUNDLE = Buffer.from(JSON.stringify({ plans: { x: { pin: { block: '0x315298b' } } }, steps: IDS.map(id => ({ id })) }));
// Literal on purpose: the production list must not silently shrink.
const EXPECTED_PINNED = ['script/rq3op/setup.mjs', 'script/rq3op/completion.mjs', 'script/rq3op/gate_worker.py',
  'script/rq3op/setup_state.py', 'script/rq3op/plan_three_arm.py', 'script/upgrade/manifest_exec.py',
  'script/rehearsal/deploylive_postdeploy_check.py', 'script/rq3op/checker_runner.py', 'script/a6-collector/formal.mjs',
  'script/a6-collector/frozen-plan.mjs'];
const opts = (o = {}) => ({ 'deploy-root': ROOT, 'expect-commit': COMMIT, bundle: 'cache/plan.json', digest: sha256(BUNDLE),
  signers: 's.json', 'rpc-a': 'cache/a', 'rpc-b': 'cache/b', audit: 'cache/audit.ndjson', config: 'cfg.json', inputs: 'in.json',
  start: 0, end: 2, 'expect-head': GENESIS, 'heads-file': '/outside/heads.jsonl', 'empty-history-acknowledged': true, ...o });

function fixture({ regenerated = BUNDLE, confirms = ['confirm'], failAt = null, clock = [], afterStep = () => {}, foreignAt = null } = {}) {
  const files = { [resolve(ROOT, 'cache/plan.json')]: BUNDLE, [resolve(ROOT, 'cfg.json')]: Buffer.from('cfg'), [resolve(ROOT, 'in.json')]: Buffer.from('in') };
  for (const p of EXPECTED_PINNED) files[resolve(ROOT, p)] = Buffer.from('module ' + p);
  const committed = Object.fromEntries(EXPECTED_PINNED.map(p => [p, gitBlob(files[resolve(ROOT, p)])]));
  const ev = { main: [], planner: [], heads: [], logs: [], prompts: 0, chdir: [], imports: [] };
  const state = { head: GENESIS, own: {}, status: '', commit: COMMIT };
  let t = 0;
  const io = {
    realpath: p => p, read: p => { if (!(p in files)) throw Error('missing ' + p); return files[p]; },
    now: () => (clock.length ? clock.shift() : t += 1000), log: s => ev.logs.push(s), chdir: d => ev.chdir.push(d),
    git: (root, args) => {
      if (args[0] === 'status') return state.status;
      if (args[1] === 'HEAD') return state.commit;
      if (args[1] === 'HEAD^{tree}') return 'b'.repeat(40);
      if (args[1].startsWith('HEAD:')) return committed[args[1].slice(5)];
      throw Error('unexpected git ' + args.join(' '));
    },
    planner: async (root, args) => { ev.planner.push({ root, args }); return regenerated; },
    readLine: async () => { ev.prompts++; return confirms.shift(); },
    appendHead: (f, s) => ev.heads.push([f, s]),
    importModule: async p => {
      ev.imports.push(p);
      if (p.endsWith('frozen-plan.mjs')) return { parse: b => JSON.parse(String(b)) };
      if (p.endsWith('completion.mjs')) return { chainHead: () => state.head, completionEntry: (_, __, id) => state.own[id] ?? null };
      if (p.endsWith('setup.mjs')) return { main: async (args, deps) => {
        const index = Number(args[2]);
        ev.main.push({ args, deps });
        if (index === failAt) throw Error('setup gate: {"gate":"rq3_send_price_fresh"} https://secret.example/key');
        state.head = sha256(state.head + args[2]);
        state.own[IDS[index]] = { recordDigest: state.head };
        if (index === foreignAt) state.head = sha256('foreign');
        afterStep(index, { files, state });
      } };
      throw Error('unexpected import ' + p);
    },
  };
  return { io, ev, files, state };
}

test('the pinned module list is the reviewed literal list', () => assert.deepEqual(PINNED_MODULES, EXPECTED_PINNED));

test('regenerates once, confirms, runs each step with only deps.regenerate and chains CHAIN_HEAD', async () => {
  const { io, ev } = fixture();
  const s = await runSession(opts(), io);
  assert.equal(s.status, 'complete'); assert.equal(s.stepsDone, 3); assert.equal(s.hashesEqual, true);
  assert.equal(ev.planner.length, 1);
  assert.deepEqual(ev.planner[0].args.slice(-2), ['--block', '0x315298b']); assert.equal(ev.planner[0].root, ROOT);
  assert.equal(ev.main.length, 3); assert.deepEqual(ev.chdir, [ROOT]);
  assert.ok(ev.logs.some(l => l.includes('no global first-run scan is performed')));
  let expected = GENESIS;
  for (const [i, call] of ev.main.entries()) {
    assert.deepEqual(Object.keys(call.deps), ['regenerate']);
    assert.ok((await call.deps.regenerate()).equals(BUNDLE));
    assert.deepEqual(call.args, ['cache/plan.json', sha256(BUNDLE), String(i), 's.json', 'cache/a', 'cache/b', 'cache/audit.ndjson', 'cfg.json', 'in.json', '--expect-head', expected]);
    expected = sha256(expected + String(i));
    const line = JSON.parse(ev.heads[i][1]);
    assert.equal(line.chainHead, expected); assert.equal(line.id, IDS[i]); assert.equal(ev.heads[i][0], '/outside/heads.jsonl');
  }
  assert.equal(s.lastChainHead, expected);
});

for (const [name, change, message] of [
  ['wrong commit', f => { f.state.commit = 'c'.repeat(40); }, /expected commit/],
  ['dirty worktree', f => { f.state.status = ' M x'; }, /not clean/],
  ['pinned module differs from HEAD', f => { f.files[resolve(ROOT, 'script/rq3op/gate_worker.py')] = Buffer.from('edited'); }, /pinned module differs/],
  ['bundle digest', f => { f.files[resolve(ROOT, 'cache/plan.json')] = Buffer.from('other'); }, /digest mismatch/],
]) test('refuses before regeneration: ' + name, async () => {
  const f = fixture(); change(f);
  await assert.rejects(runSession(opts(), f.io), message);
  assert.equal(f.ev.planner.length, 0); assert.equal(f.ev.main.length, 0);
});

test('regenerated bytes must equal the frozen bundle', async () => {
  const f = fixture({ regenerated: Buffer.from(String(BUNDLE) + ' ') });
  await assert.rejects(runSession(opts(), f.io), /bytes mismatch/); assert.equal(f.ev.main.length, 0);
});

test('--expect-head is checked against the completion log before the planner runs', async () => {
  const f = fixture();
  const s = await runSession(opts({ 'expect-head': '1'.repeat(64), 'empty-history-acknowledged': false, start: 1 }), f.io);
  assert.equal(s.status, 'stopped'); assert.equal(f.ev.planner.length, 0); assert.equal(f.ev.main.length, 0);
});

test('genesis head requires --empty-history-acknowledged and --start 0', async () => {
  for (const o of [{ 'empty-history-acknowledged': false }, { start: 1 }]) {
    const f = fixture();
    await assert.rejects(runSession(opts(o), f.io), /empty-history-acknowledged/);
    assert.equal(f.ev.planner.length, 0); assert.equal(f.ev.main.length, 0);
  }
});

test('--end beyond the bundle is refused before the planner and any step', async () => {
  const f = fixture();
  await assert.rejects(runSession(opts({ end: 3 }), f.io), /--end must be below 3/);
  assert.equal(f.ev.planner.length, 0); assert.equal(f.ev.main.length, 0);
});

test('no operator confirmation: nothing runs', async () => {
  const f = fixture({ confirms: ['yes'] });
  const s = await runSession(opts(), f.io);
  assert.equal(s.status, 'stopped'); assert.equal(f.ev.main.length, 0);
});

test('first failing step stops the session: no retry, no later step, URL redacted', async () => {
  const f = fixture({ failAt: 1 });
  const s = await runSession(opts(), f.io);
  assert.equal(s.status, 'stopped'); assert.equal(s.failedIndex, 1); assert.equal(f.ev.main.length, 2);
  assert.equal(s.stepsDone, 1); assert.equal(f.ev.heads.length, 1);
  assert.doesNotMatch(f.ev.logs.join('\n'), /secret\.example/);
});

test('a completion head that is not this step\'s own entry stops the session', async () => {
  const f = fixture({ foreignAt: 0 });
  const s = await runSession(opts(), f.io);
  assert.equal(s.status, 'stopped'); assert.equal(s.failedIndex, 0); assert.equal(f.ev.main.length, 1); assert.equal(f.ev.heads.length, 0);
});

for (const [name, change] of [
  ['dirty tree', ({ state }) => { state.status = '?? x'; }],
  ['moved HEAD', ({ state }) => { state.commit = 'd'.repeat(40); }],
  ['edited pinned module', ({ files }) => { files[resolve(ROOT, 'script/rq3op/setup_state.py')] = Buffer.from('edited'); }],
]) test('pre-step re-check stops before the next step: ' + name, async () => {
  const f = fixture({ afterStep: (i, ctx) => { if (i === 0) change(ctx); } });
  const s = await runSession(opts(), f.io);
  assert.equal(s.status, 'stopped'); assert.equal(s.nextIndex, 1); assert.equal(f.ev.main.length, 1);
});

for (const p of ['cfg.json', 'in.json', 'cache/plan.json']) test('a session input changed after regeneration stops before the first step: ' + p, async () => {
  const f = fixture();
  const log = f.io.log;
  f.io.log = s => { log(s); if (s.startsWith('SESSION_REGENERATED')) f.files[resolve(ROOT, p)] = Buffer.from('changed'); };
  const s = await runSession(opts(), f.io);
  assert.equal(s.status, 'stopped'); assert.equal(s.nextIndex, 0); assert.match(s.reason, /session file changed/); assert.equal(f.ev.main.length, 0);
});

for (const p of ['script/a6-collector/frozen-plan.mjs', 'script/rq3op/completion.mjs']) test('a pinned module changed between the start snapshot and its import stops before the planner: ' + p, async () => {
  const f = fixture();
  const log = f.io.log;
  f.io.log = s => { log(s); if (s.startsWith('SESSION_START')) f.files[resolve(ROOT, p)] = Buffer.from('edited'); };
  await assert.rejects(runSession(opts(), f.io), /pinned module differs/);
  assert.equal(f.ev.planner.length, 0); assert.equal(f.ev.main.length, 0);
  assert.equal(f.ev.imports.some(i => i.endsWith(p)), false);
});

test('operator pause: more than 50 minutes after confirmation stops between steps until reconfirmed', async () => {
  const clock = [0, 1, 0, 1000, 1000, OPERATOR_PAUSE_MS + 2000];
  const f = fixture({ clock, confirms: ['confirm', 'no'] });
  const s = await runSession(opts(), f.io);
  assert.equal(s.status, 'stopped'); assert.equal(s.nextIndex, 1); assert.equal(f.ev.main.length, 1); assert.equal(f.ev.prompts, 2);
});

test('operator pause reconfirmed: continues', async () => {
  const clock = [0, 1, 0, 1000, 1000, OPERATOR_PAUSE_MS + 2000, OPERATOR_PAUSE_MS + 2000, OPERATOR_PAUSE_MS + 3000, OPERATOR_PAUSE_MS + 3000, OPERATOR_PAUSE_MS + 4000, OPERATOR_PAUSE_MS + 4000];
  const f = fixture({ clock, confirms: ['confirm', 'confirm'] });
  const s = await runSession(opts(), f.io);
  assert.equal(s.status, 'complete'); assert.equal(f.ev.main.length, 3); assert.equal(f.ev.prompts, 2);
});

test('heads file inside the deploy worktree is refused', async () => {
  const f = fixture();
  await assert.rejects(runSession(opts({ 'heads-file': '/deploy/cache/heads' }), f.io), /outside the deploy worktree/);
});

test('a changed session input after the last step never ends as complete', async () => {
  const f = fixture({ afterStep: (i, { files }) => { if (i === 2) files[resolve(ROOT, 'in.json')] = Buffer.from('changed'); } });
  const s = await runSession(opts(), f.io);
  assert.equal(s.status, 'stopped-hash-mismatch'); assert.equal(s.hashesEqual, false); assert.equal(s.stepsDone, 3);
});

test('argument parsing is strict', () => {
  assert.throws(() => parseArgs(['--bundle', 'x']), /missing/);
  const ok = ['--deploy-root','/d','--expect-commit',COMMIT,'--bundle','b','--digest','f'.repeat(64),'--signers','s','--rpc-a','a','--rpc-b','b','--audit','u','--config','c','--inputs','i','--start','0','--end','51','--expect-head',GENESIS,'--heads-file','/h'];
  assert.equal(parseArgs(ok).end, 51); assert.equal(parseArgs(ok)['empty-history-acknowledged'], false);
  assert.equal(parseArgs([...ok, '--empty-history-acknowledged'])['empty-history-acknowledged'], true);
  assert.throws(() => parseArgs([...ok, '--start', '1']), /usage/);
  assert.throws(() => parseArgs(ok.map(v => v === '51' ? '-1' : v)), /invalid/);
});

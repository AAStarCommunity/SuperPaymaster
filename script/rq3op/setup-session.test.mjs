import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { runSession, parseArgs, PINNED_MODULES, OPERATOR_PAUSE_MS, GENESIS, sortKeys, canonicalRuntime, probeSigner, exitCodeFor, stepDirName, stableReceipts, RECEIPT_CONFIRMATIONS, RECEIPT_DELAY_BLOCKS, RECEIPT_TIMEOUT_MS } from './setup-session.mjs';
import { archivedRpc } from '../a6-collector/formal.mjs';
import { createPublicClient, custom } from 'viem';
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, realpathSync, rmSync, readFileSync, lstatSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

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
  signers: 's.json', 'rpc-a': 'cache/a', 'rpc-b': 'cache/b', 'audit-dir': 'cache/steps', config: 'cfg.json', inputs: 'in.json',
  start: 0, end: 2, 'expect-head': GENESIS, 'heads-file': '/outside/heads.jsonl', 'empty-history-acknowledged': true, ...o });

const FORMAL = { formalRuntime: async () => FORMAL.next ?? ({}) };
function fixture({ regenerated = BUNDLE, confirms = ['confirm'], failAt = null, clock = [], afterStep = () => {}, foreignAt = null, mainError = null, mainImpl = null, root = ROOT } = {}) {
  const files = { [resolve(root, 'cache/plan.json')]: BUNDLE, [resolve(root, 'cfg.json')]: Buffer.from('cfg'), [resolve(root, 'in.json')]: Buffer.from('in'),
    [resolve(root, 'cache/b')]: Buffer.from('steps-b'), [resolve(root, 'cache/regenb')]: Buffer.from('regen-b') };
  for (const p of EXPECTED_PINNED) files[resolve(root, p)] = Buffer.from('module ' + p);
  const committed = Object.fromEntries(EXPECTED_PINNED.map(p => [p, gitBlob(files[resolve(root, p)])]));
  const ev = { main: [], planner: [], heads: [], logs: [], prompts: 0, chdir: [], imports: [], dirs: [], links: [] };
  const state = { head: GENESIS, own: {}, status: '', commit: COMMIT };
  let t = 0;
  const io = {
    mkdir: (p, o = {}) => { if (ev.dirs.includes(p)) { if (o.recursive) return; throw Object.assign(Error('EEXIST: ' + p), { code: 'EEXIST' }); } ev.dirs.push(p); },
    lstat: p => { if (ev.links.includes(p)) return { isSymbolicLink: () => true, isDirectory: () => false };
      if (p === resolve(root, 'cache') || ev.dirs.includes(p)) return { isSymbolicLink: () => false, isDirectory: () => true };
      throw Object.assign(Error('ENOENT: ' + p), { code: 'ENOENT' }); },
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
      if (p.endsWith('formal.mjs')) return FORMAL;
      if (p.endsWith('setup.mjs')) return { main: async (args, deps) => {
        const index = Number(args[args[0] === 'record' ? 3 : 2]);
        ev.main.push({ args, deps });
        if (mainImpl) return mainImpl(args, deps, { files, state });
        if (mainError) throw mainError;
        if (index === failAt) throw Error('setup gate: {"gate":"rq3_send_price_fresh"} https://secret.example/key');
        state.head = sha256(state.head + String(index));
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

test('regenerates once, confirms, runs each step with deps.regenerate + deps.runtime only (no deps.send) and chains CHAIN_HEAD', async () => {
  const { io, ev } = fixture();
  const s = await runSession(opts(), io);
  assert.equal(s.status, 'complete'); assert.equal(s.stepsDone, 3); assert.equal(s.hashesEqual, true);
  assert.equal(ev.planner.length, 1);
  assert.deepEqual(ev.planner[0].args.slice(-2), ['--block', '0x315298b']); assert.equal(ev.planner[0].root, ROOT);
  assert.equal(ev.main.length, 3); assert.deepEqual(ev.chdir, [ROOT]);
  assert.ok(ev.logs.some(l => l.includes('no global first-run scan is performed')));
  let expected = GENESIS;
  for (const [i, call] of ev.main.entries()) {
    assert.deepEqual(Object.keys(call.deps), ['regenerate', 'runtime']);
    assert.ok((await call.deps.regenerate()).equals(BUNDLE));
    assert.deepEqual(call.args, ['cache/plan.json', sha256(BUNDLE), String(i), 's.json', 'cache/a', 'cache/b', resolve(ROOT, 'cache/steps', String(i).padStart(3, '0'), 'setup.audit.ndjson'), 'cfg.json', 'in.json', '--expect-head', expected]);
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
  const ok = ['--deploy-root','/d','--expect-commit',COMMIT,'--bundle','b','--digest','f'.repeat(64),'--signers','s','--rpc-a','a','--rpc-b','b','--audit-dir','u','--config','c','--inputs','i','--start','0','--end','51','--expect-head',GENESIS,'--heads-file','/h'];
  assert.equal(parseArgs(ok).end, 51); assert.equal(parseArgs(ok)['empty-history-acknowledged'], false);
  assert.equal(parseArgs([...ok, '--empty-history-acknowledged'])['empty-history-acknowledged'], true);
  assert.throws(() => parseArgs([...ok, '--start', '1']), /usage/);
  assert.throws(() => parseArgs(ok.map(v => v === '51' ? '-1' : v)), /invalid/);
});

// ── canonical pair compare (DSR ruling C) ──────────────────────────────────────────────────────────────
const stringify = v => JSON.stringify(v);
test('sortKeys: the same values in a different key order compare equal, at any depth', () => {
  const a = { hash: '0x1', number: '0x2', nested: { b: 1, a: [{ y: 2, x: 1 }] } };
  const b = { nested: { a: [{ x: 1, y: 2 }], b: 1 }, number: '0x2', hash: '0x1' };
  assert.notEqual(stringify(a), stringify(b));
  assert.equal(stringify(sortKeys(a)), stringify(sortKeys(b)));
});
test('sortKeys: a differing value, a missing key or an extra key at any depth still disagrees', () => {
  const base = { hash: '0x1', inner: { logs: [{ data: '0xaa', topics: ['0x1'] }] } };
  const variants = [
    { hash: '0x2', inner: base.inner },                                              // value, top level
    { hash: '0x1', inner: { logs: [{ data: '0xab', topics: ['0x1'] }] } },           // value, depth 3
    { hash: '0x1', inner: { logs: [{ data: '0xaa' }] } },                            // missing key, depth 3
    { hash: '0x1', inner: { logs: [{ data: '0xaa', topics: ['0x1'], extra: null }] } }, // extra key, depth 3
    { hash: '0x1' },                                                                 // missing key, top level
    { ...base, blockTimestamp: '0x5' },                                              // extra key, top level
    { hash: '0x1', inner: { logs: [{ data: '0xaa', topics: ['0x1'] }, {}] } },       // extra array element
    { hash: '0x1', inner: { logs: [{ data: '0xaa', topics: '0x1' }] } },             // array vs string
  ];
  for (const v of variants) assert.notEqual(stringify(sortKeys(base)), stringify(sortKeys(v)), stringify(v));
});
test('sortKeys: array order is kept, so a reordered array disagrees', () => {
  assert.notEqual(stringify(sortKeys({ t: ['0x1', '0x2'] })), stringify(sortKeys({ t: ['0x2', '0x1'] })));
  assert.deepEqual(sortKeys([{ b: 1, a: 2 }, 3]), [{ a: 2, b: 1 }, 3]);
});
test('sortKeys: strings, numbers, booleans and null are returned unchanged; values are not coerced', () => {
  for (const v of ['0x00', '', 0, 1.5, true, false, null]) assert.equal(sortKeys(v), v);
  assert.deepEqual(sortKeys({ n: 1, s: '1', z: null }), { n: 1, s: '1', z: null });
  assert.equal(typeof sortKeys({ v: '0x1' }).v, 'string');
});

function rawRuntime(results) {
  const calls = [];
  const archive = name => ({ name, append: () => name, request: async args => { calls.push([name, args]); const r = results(name, args); if (r instanceof Error) throw r; return r; } });
  const runtime = { archives: [archive('A'), archive('B')], accounts: { bundler: { address: '0x01' } }, pubA: {}, pubB: {}, refreshPin: async () => 1 };
  return { runtime, calls, formalRuntime: async options => { runtime.options = options; return runtime; } };
}
test('canonicalRuntime: requests reach the raw archive identical (same object, same count) with and without the wrapper', async () => {
  const results = (name, args) => args.method === 'eth_getBlockByNumber' ? (name === 'A' ? { hash: '0x1', number: '0x2' } : { number: '0x2', hash: '0x1' }) : '0xaa37dc';
  const sequence = [{ method: 'eth_chainId', params: [] }, { method: 'eth_getBlockByNumber', params: ['0x2', false] }, { method: 'eth_sendRawTransaction', params: ['0xf8'] }];
  const plain = rawRuntime(results), wrapped = rawRuntime(results);
  const rt = await canonicalRuntime(wrapped.formalRuntime)({ readOnly: false });
  for (const args of sequence) for (const i of [0, 1]) { await plain.runtime.archives[i].request(args); await rt.archives[i].request(args); }
  assert.deepEqual(wrapped.calls, plain.calls);
  for (const [k, [, args]] of wrapped.calls.entries()) assert.equal(args, sequence[Math.floor(k / 2)]);
  const [ha, hb] = await Promise.all(rt.archives.map(a => a.request({ method: 'eth_getBlockByNumber', params: ['0x2', false] })));
  assert.equal(stringify(ha), stringify(hb));
  assert.equal(await rt.archives[0].request({ method: 'eth_sendRawTransaction', params: ['0xf8'] }), '0xaa37dc');
});
test('canonicalRuntime: everything except archives[i].request is the raw runtime; options pass unchanged in normal mode', async () => {
  const raw = rawRuntime(() => null);
  const options = { readOnly: false, pendingNonce: true, config: {}, rpcAFile: 'a', rpcBFile: 'b', outPath: 'o' };
  const rt = await canonicalRuntime(raw.formalRuntime)(options);
  assert.equal(raw.runtime.options, options);
  for (const k of ['accounts', 'refreshPin']) assert.equal(rt[k], raw.runtime[k]);
  for (const i of [0, 1]) { assert.equal(rt.archives[i].append, raw.runtime.archives[i].append); assert.equal(rt.archives[i].name, raw.runtime.archives[i].name); }
  assert.equal(raw.runtime.archives[0].request === rt.archives[0].request, false);
});
test('canonicalRuntime: provider errors are rethrown unchanged', async () => {
  const boom = Error('RPC A transport failed (redacted)');
  const rt = await canonicalRuntime(rawRuntime(() => boom).formalRuntime)({});
  await assert.rejects(rt.archives[0].request({ method: 'eth_chainId', params: [] }), e => e === boom);
});
test('probe mode: formalRuntime gets the refusing probe signer; normal mode never passes createSigner', async () => {
  const normal = rawRuntime(() => null), probe = rawRuntime(() => null);
  await canonicalRuntime(normal.formalRuntime)({ readOnly: false });
  await canonicalRuntime(probe.formalRuntime, { probe: true })({ readOnly: false });
  assert.equal('createSigner' in normal.runtime.options, false);
  assert.equal(probe.runtime.options.createSigner, probeSigner);
  const signer = await probeSigner({ name: 'rq3-experiment', address: '0x8bf53dB6864c0ebe1fbE2fd33D00BACD1248d4Fc' });
  assert.equal(signer.type, 'local'); assert.equal(signer.address, '0x8bf53dB6864c0ebe1fbE2fd33D00BACD1248d4Fc');
  for (const f of ['signMessage', 'signTransaction', 'signTypedData']) assert.throws(() => signer[f]({}), /probe: signing refused/);
});
test('--probe-reads requires --start 0 --end 0 and is the only mode that sets deps.send', async () => {
  const argv = o => Object.entries(opts(o)).flatMap(([k, v]) => v === true ? ['--' + k] : v === false ? [] : ['--' + k, String(v)]);
  assert.throws(() => parseArgs(argv({ 'probe-reads': true, start: 0, end: 1 })), /--probe-reads requires/);
  assert.equal(parseArgs(argv({ 'probe-reads': true, start: 0, end: 0 }))['probe-reads'], true);
  assert.equal(parseArgs(argv({}))['probe-reads'], false);
  let sent = 0;
  const f = fixture({ mainImpl: async (args, deps) => { sent++; await deps.send({}); } });
  const s = await runSession(opts({ 'probe-reads': true, end: 0 }), f.io);
  assert.equal(s.status, 'probe-reached-send'); assert.equal(s.index, 0); assert.equal(f.ev.main.length, 1); assert.equal(sent, 1);
  assert.deepEqual(Object.keys(f.ev.main[0].deps), ['regenerate', 'runtime', 'send']);
  assert.equal(f.ev.heads.length, 0);
});
test('probe mode: any other setup error is a stop, not a probe success', async () => {
  const f = fixture({ mainError: Error('setup read disagreement') });
  const s = await runSession(opts({ 'probe-reads': true, end: 0 }), f.io);
  assert.equal(s.status, 'stopped'); assert.equal(s.error, 'setup read disagreement');
});
test('formal.mjs changed after the start snapshot stops before any step', async () => {
  const f = fixture();
  const log = f.io.log;
  f.io.log = s => { log(s); if (s.startsWith('SESSION_REGENERATED')) f.files[resolve(ROOT, 'script/a6-collector/formal.mjs')] = Buffer.from('edited'); };
  await assert.rejects(runSession(opts(), f.io), /pinned module differs/);
  assert.equal(f.ev.main.length, 0);
});
test('formal.mjs changed while it is being imported stops before any step (re-verify after import)', async () => {
  const f = fixture();
  const importModule = f.io.importModule;
  f.io.importModule = async p => { const m = await importModule(p); if (p.endsWith('formal.mjs')) f.files[resolve(ROOT, p.slice(ROOT.length + 1))] = Buffer.from('edited'); return m; };
  await assert.rejects(runSession(opts(), f.io), /pinned module differs from HEAD: script\/a6-collector\/formal.mjs/);
  assert.equal(f.ev.main.length, 0);
});

// ── Daybreak #681 H1 / L1 / L2 ─────────────────────────────────────────────────────────────────────────
const probeRun = mainImpl => { const f = fixture({ mainImpl }); return runSession(opts({ 'probe-reads': true, end: 0 }), f.io).then(s => ({ s, f })); };
test('probe: setup.main returning normally (e.g. already-satisfied) is a stop, appends no head', async () => {
  const { s, f } = await probeRun(async () => {});
  assert.equal(s.status, 'stopped'); assert.match(s.reason, /returned without reaching send/); assert.equal(f.ev.heads.length, 0);
});
test('probe: the refusal text thrown without deps.send being called is a stop (identity, not message)', async () => {
  const { s } = await probeRun(async () => { throw Error('probe: send refused'); });
  assert.equal(s.status, 'stopped'); assert.equal(s.error, 'probe: send refused');
});
test('probe: deps.send called twice is a stop', async () => {
  const { s } = await probeRun(async (a, deps) => { try { await deps.send({}); } catch {} await deps.send({}); });
  assert.equal(s.status, 'stopped');
});
test('probe: a new completion entry or a moved chain head before the refusal is a stop', async () => {
  for (const mutate of [st => { st.own[IDS[0]] = { recordDigest: 'x' }; }, st => { st.head = sha256('moved'); }]) {
    const { s, f } = await probeRun(async (a, deps, { state }) => { mutate(state); await deps.send({}); });
    assert.equal(s.status, 'stopped'); assert.match(s.reason, /completion log changed/); assert.equal(f.ev.heads.length, 0);
  }
});
test('probe: a session file or HEAD changed before the refusal ends stopped-hash-mismatch, exit nonzero', async () => {
  const fileChange = await probeRun(async (a, deps, { files }) => { files[resolve(ROOT, 'cfg.json')] = Buffer.from('changed'); await deps.send({}); });
  assert.equal(fileChange.s.status, 'stopped-hash-mismatch'); assert.equal(fileChange.s.hashesEqual, false);
  const headChange = await probeRun(async (a, deps, { state }) => { state.commit = 'c'.repeat(40); await deps.send({}); });
  assert.equal(headChange.s.status, 'stopped-hash-mismatch');
});
test('sortKeys: values outside the JSON domain throw instead of collapsing', () => {
  const accessor = Object.defineProperty({}, 'x', { get: () => 1, enumerable: true });
  const hidden = Object.defineProperty({}, 'x', { value: 1, enumerable: false });
  const cyclic = { a: 1 }; cyclic.self = cyclic;
  const cyclicArray = []; cyclicArray.push(cyclicArray);
  const extraArray = [1]; extraArray.tag = 'x';
  class Box { constructor() { this.x = 1; } }
  for (const v of [new Date(0), 1n, undefined, new Uint8Array([1]), accessor, hidden, cyclic, cyclicArray, extraArray, new Box(),
    { toJSON: () => 'x' }, { [Symbol('s')]: 1 }, NaN, Infinity, () => 1, Symbol('s'), [undefined], { a: undefined }, new Map()])
    assert.throws(() => sortKeys(v), /sortKeys:/, String(v));
});
test('sortKeys: null-prototype objects and shared (non-cyclic) references are accepted', () => {
  const o = Object.create(null); o.b = 1; o.a = 2;
  assert.equal(stringify(sortKeys(o)), '{"a":2,"b":1}');
  const shared = { x: 1 };
  assert.equal(stringify(sortKeys({ p: shared, q: [shared, shared] })), '{"p":{"x":1},"q":[{"x":1},{"x":1}]}');
  assert.equal(stringify(sortKeys(JSON.parse('{"__proto__":{"z":1},"a":0}'))), '{"__proto__":{"z":1},"a":0}');
});

// ── --regen-rpc-b (DSR ruling: regeneration on Alchemy+Tenderly, steps on Alchemy+QuickNode) ──────────
const PLANNER_ARGV = b => ['-B', resolve(ROOT, 'script/rq3op/plan_three_arm.py'), resolve(ROOT, 'cfg.json'), resolve(ROOT, 'in.json'), '-',
  '--rpc-a-file', resolve(ROOT, 'cache/a'), '--rpc-b-file', resolve(ROOT, b), '--block', '0x315298b'];
test('--regen-rpc-b: regeneration gets the regen B file, every setup.main step still gets --rpc-b', async () => {
  const f = fixture();
  const s = await runSession(opts({ 'regen-rpc-b': 'cache/regenb' }), f.io);
  assert.equal(s.status, 'complete');
  assert.equal(f.ev.planner.length, 1); assert.deepEqual(f.ev.planner[0].args, PLANNER_ARGV('cache/regenb'));
  for (const call of f.ev.main) { assert.equal(call.args[5], 'cache/b'); assert.equal(call.args.includes('cache/regenb'), false); }
  const providers = JSON.parse(f.ev.logs.find(l => l.startsWith('SESSION_PROVIDERS ')).slice(18));
  assert.deepEqual(providers, { regenerationB: { file: resolve(ROOT, 'cache/regenb'), sha256: sha256(Buffer.from('regen-b')) }, stepsB: { file: 'cache/b', sha256: sha256(Buffer.from('steps-b')) } });
  assert.equal(JSON.parse(f.ev.logs.find(l => l.startsWith('SESSION_START ')).slice(14)).files[resolve(ROOT, 'cache/regenb')], sha256(Buffer.from('regen-b')));
});
test('--regen-rpc-b absent: planner argv is exactly as before (rpc-b) and the snapshot has no extra file', async () => {
  const f = fixture();
  await runSession(opts(), f.io);
  assert.deepEqual(f.ev.planner[0].args, PLANNER_ARGV('cache/b'));
  const start = JSON.parse(f.ev.logs.find(l => l.startsWith('SESSION_START ')).slice(14));
  assert.equal(Object.keys(start.files).some(k => k.endsWith('regenb')), false);
  assert.equal(JSON.parse(f.ev.logs.find(l => l.startsWith('SESSION_PROVIDERS ')).slice(18)).regenerationB.file, 'cache/b');
});
test('--regen-rpc-b is in the start snapshot: changed between steps stops before the next step', async () => {
  const f = fixture({ afterStep: (i, { files }) => { if (i === 0) files[resolve(ROOT, 'cache/regenb')] = Buffer.from('swapped'); } });
  const s = await runSession(opts({ 'regen-rpc-b': 'cache/regenb' }), f.io);
  assert.equal(s.status, 'stopped'); assert.equal(s.nextIndex, 1); assert.match(s.reason, /session file changed since start: \/deploy\/cache\/regenb/);
});
test('--regen-rpc-b outside the deploy worktree is refused; parseArgs accepts it once', async () => {
  await assert.rejects(runSession(opts({ 'regen-rpc-b': '../elsewhere/b' }), fixture().io), /--regen-rpc-b must be inside/);
  const argv = o => Object.entries(opts(o)).flatMap(([k, v]) => v === true ? ['--' + k] : v === false ? [] : ['--' + k, String(v)]);
  assert.equal(parseArgs(argv({ 'regen-rpc-b': 'cache/regenb' }))['regen-rpc-b'], 'cache/regenb');
  assert.equal('regen-rpc-b' in parseArgs(argv({})), false);
  assert.throws(() => parseArgs([...argv({ 'regen-rpc-b': 'x' }), '--regen-rpc-b', 'y']), /usage/);
});

// ── Daybreak increment: --regen-rpc-b canonical containment, probe + regen, CLI exit code ────────────
function realTree() {
  const base = realpathSync(mkdtempSync(resolve(tmpdir(), 'regen-')));
  const root = resolve(base, 'deploy');
  mkdirSync(resolve(root, 'cache/sub'), { recursive: true }); mkdirSync(resolve(base, 'outside'));
  writeFileSync(resolve(root, 'cache/regenb'), 'regen-b'); writeFileSync(resolve(base, 'outside/b'), 'outside');
  symlinkSync(resolve(base, 'outside/b'), resolve(root, 'cache/link'));
  symlinkSync(resolve(root, 'cache/regenb'), resolve(root, 'cache/inlink'));
  return { base, root, cleanup: () => rmSync(base, { recursive: true, force: true }) };
}
function realFixture(root) {
  const f = fixture({ root });
  const read = f.io.read, reads = [];
  f.io.realpath = realpathSync; f.io.mkdir = (p, o) => mkdirSync(p, o); f.io.lstat = p => lstatSync(p);
  f.io.read = p => { reads.push(p); return p in f.files ? read(p) : readFileSync(p); };
  return { f, reads };
}
test('--regen-rpc-b: an in-tree symlink to an outside file is refused before the target is read (real filesystem)', async () => {
  const t = realTree();
  try {
    const { f, reads } = realFixture(t.root);
    await assert.rejects(runSession(opts({ 'deploy-root': t.root, 'regen-rpc-b': 'cache/link' }), f.io), /--regen-rpc-b must be inside/);
    assert.equal(reads.length, 0); assert.equal(f.ev.planner.length, 0);
  } finally { t.cleanup(); }
});
test('--regen-rpc-b: an absolute in-tree path, a normalized `..` path and an in-tree symlink all resolve to the canonical file', async () => {
  const t = realTree();
  try {
    for (const [n, given] of [resolve(t.root, 'cache/regenb'), 'cache/sub/../regenb', 'cache/inlink'].entries()) {
      const { f } = realFixture(t.root);
      f.files[resolve(t.root, 'cache/b')] = Buffer.from('steps-b');
      const s = await runSession(opts({ 'deploy-root': t.root, 'regen-rpc-b': given, 'audit-dir': 'cache/steps' + n }), f.io);
      assert.equal(s.status, 'complete', given);
      assert.equal(f.ev.planner[0].args[f.ev.planner[0].args.indexOf('--rpc-b-file') + 1], resolve(t.root, 'cache/regenb'), given);
      const start = JSON.parse(f.ev.logs.find(l => l.startsWith('SESSION_START ')).slice(14));
      assert.equal(start.files[resolve(t.root, 'cache/regenb')], sha256(Buffer.from('regen-b')), given);
    }
  } finally { t.cleanup(); }
});
test('--probe-reads with --regen-rpc-b: regeneration uses the regen file, the probe step gets --rpc-b, success needs the send refusal', async () => {
  const f = fixture({ mainImpl: async (args, deps) => { assert.equal(args[5], 'cache/b'); await deps.send({}); } });
  const s = await runSession(opts({ 'probe-reads': true, end: 0, 'regen-rpc-b': 'cache/regenb' }), f.io);
  assert.equal(s.status, 'probe-reached-send'); assert.equal(s.hashesEqual, true);
  assert.equal(f.ev.planner[0].args[f.ev.planner[0].args.indexOf('--rpc-b-file') + 1], resolve(ROOT, 'cache/regenb'));
  assert.equal(f.ev.heads.length, 0);
});
test('CLI exit code: only complete and probe-reached-send exit 0', () => {
  assert.equal(exitCodeFor('complete'), 0); assert.equal(exitCodeFor('probe-reached-send'), 0);
  for (const s of ['stopped', 'stopped-hash-mismatch', undefined]) assert.equal(exitCodeFor(s), 1);
});
test('CLI process: a refused probe invocation exits 1 with a redacted message', () => {
  const file = fileURLToPath(new URL('./setup-session.mjs', import.meta.url));
  const argv = Object.entries(opts({ 'probe-reads': true, start: 0, end: 1 })).flatMap(([k, v]) => v === true ? ['--' + k] : v === false ? [] : ['--' + k, String(v)]);
  const r = spawnSync(process.execPath, [file, ...argv], { input: '', encoding: 'utf8' });
  assert.equal(r.status, 1); assert.match(r.stderr, /setup session stopped: --probe-reads requires --start 0 --end 0/);
});

// ── per-step audit window (DSR ruling (a): evidence.mjs:39 raw/<A|B> is a non-recursive mkdir) ──────────
const stepAudit = (root, i) => resolve(root, 'cache/steps', String(i).padStart(3, '0'), 'setup.audit.ndjson');
test('per-step audit: each step gets its own new directory; heads entries and SESSION_SUMMARY record the audit paths', async () => {
  const f = fixture();
  const s = await runSession(opts(), f.io);
  assert.equal(s.status, 'complete');
  assert.deepEqual(s.audits, [0, 1, 2].map(i => stepAudit(ROOT, i)));
  assert.deepEqual(f.ev.heads.map(([, l]) => JSON.parse(l).audit), [0, 1, 2].map(i => stepAudit(ROOT, i)));
  assert.deepEqual(f.ev.dirs, [resolve(ROOT, 'cache/steps'), ...[0, 1, 2].map(i => resolve(ROOT, 'cache/steps', String(i).padStart(3, '0')))]);
});
test('per-step audit: an existing step directory stops before setup.main for that step', async () => {
  const f = fixture();
  f.ev.dirs.push(resolve(ROOT, 'cache/steps/001'));
  const s = await runSession(opts(), f.io);
  assert.equal(s.status, 'stopped'); assert.equal(s.nextIndex, 1); assert.match(s.reason, /step audit directory exists/);
  assert.equal(f.ev.main.length, 1); assert.deepEqual(s.audits, [stepAudit(ROOT, 0)]);
});
test('per-step audit: --audit (the single-file form that dies at step 1) is no longer accepted', () => {
  const argv = Object.entries(opts()).flatMap(([k, v]) => v === true ? ['--' + k] : v === false ? [] : ['--' + k, String(v)]);
  assert.throws(() => parseArgs([...argv.filter((a, i, all) => a !== '--audit-dir' && all[i - 1] !== '--audit-dir'), '--audit', 'cache/audit.ndjson']), /usage/);
  assert.throws(() => parseArgs(argv.filter((a, i, all) => a !== '--audit-dir' && all[i - 1] !== '--audit-dir')), /missing --audit-dir/);
});
test('per-step audit: --audit-dir outside the root, or an in-tree symlink to outside, is refused (real filesystem)', async () => {
  const outside = fixture();
  await assert.rejects(runSession(opts({ 'audit-dir': '../elsewhere' }), outside.io), /--audit-dir must be under cache\//);
  assert.deepEqual(outside.ev.dirs, [], 'nothing is created outside the root before the refusal');
  const t = realTree();
  try {
    symlinkSync(resolve(t.base, 'outside'), resolve(t.root, 'cache/outdir'));
    const { f } = realFixture(t.root);
    await assert.rejects(runSession(opts({ 'deploy-root': t.root, 'audit-dir': 'cache/outdir' }), f.io), /--audit-dir component is not a real directory/);
    assert.equal(f.ev.planner.length, 0);
  } finally { t.cleanup(); }
});
test('probe mode uses the per-step layout too', async () => {
  const f = fixture({ mainImpl: async (args, deps) => { assert.equal(args[6], stepAudit(ROOT, 0)); await deps.send({}); } });
  const s = await runSession(opts({ 'probe-reads': true, end: 0 }), f.io);
  assert.equal(s.status, 'probe-reached-send'); assert.deepEqual(s.audits, [stepAudit(ROOT, 0)]);
});
test('real evidence.mjs rawArchive (pinned at 99a38d8d): per-step windows both create their archives; one shared window fails at step 2', async () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const pinned = spawnSync('git', ['show', '99a38d8d:script/a6-collector/evidence.mjs'], { cwd: here });
  assert.equal(pinned.status, 0);
  assert.ok(readFileSync(resolve(here, '../a6-collector/evidence.mjs')).equals(pinned.stdout), 'evidence.mjs differs from 99a38d8d');
  const { rawArchive } = await import('../a6-collector/evidence.mjs');
  const base = realpathSync(mkdtempSync(resolve(tmpdir(), 'raw-')));
  try {
    for (const i of [0, 1]) {
      const dir = resolve(base, 'steps', String(i).padStart(3, '0'));
      mkdirSync(resolve(base, 'steps'), { recursive: true }); mkdirSync(dir);
      // formal.mjs:300 calls rawArchive(dirname(outPath), endpoint) for A and B.
      for (const e of ['A', 'B']) rawArchive(dirname(resolve(dir, 'setup.audit.ndjson')), e);
    }
    const shared = resolve(base, 'shared');
    mkdirSync(shared);
    for (const e of ['A', 'B']) rawArchive(shared, e);
    assert.throws(() => rawArchive(shared, 'A'), /EEXIST/);
  } finally { rmSync(base, { recursive: true, force: true }); }
});

// ── Daybreak increment 2: step outcome, audit-dir creation, heads append failure, index format ─────────
test('outcome: a normal return with the head unchanged and no own entry stops as unrecorded, no head appended', async () => {
  const f = fixture({ mainImpl: async () => {} });
  const s = await runSession(opts(), f.io);
  assert.equal(s.status, 'stopped'); assert.equal(s.outcome, 'unrecorded'); assert.equal(s.failedIndex, 0); assert.match(s.reason, /^unrecorded:/);
  assert.equal(f.ev.heads.length, 0); assert.deepEqual(s.outcomes, { recorded: 0, 'already-satisfied-recorded': 0 });
});
test('outcome: a pre-existing own entry with the head unchanged is already-satisfied-recorded (counted, in the heads entry)', async () => {
  const f = fixture({ mainImpl: async () => {} });
  f.state.own[IDS[0]] = { recordDigest: GENESIS };
  const s = await runSession(opts({ end: 0 }), f.io);
  assert.equal(s.status, 'complete'); assert.deepEqual(s.outcomes, { recorded: 0, 'already-satisfied-recorded': 1 });
  assert.equal(JSON.parse(f.ev.heads[0][1]).outcome, 'already-satisfied-recorded');
});
test('outcome: an entry that appears in this step but the head did not move is not accepted', async () => {
  const f = fixture({ mainImpl: async (a, d, { state }) => { state.own[IDS[0]] = { recordDigest: 'x'.repeat(64) }; } });
  const s = await runSession(opts({ end: 0 }), f.io);
  assert.equal(s.status, 'stopped'); assert.equal(f.ev.heads.length, 0);
});
test('outcome: a normal run records every step as recorded with counts', async () => {
  const f = fixture();
  const s = await runSession(opts(), f.io);
  assert.deepEqual(s.outcomes, { recorded: 3, 'already-satisfied-recorded': 0 });
  assert.deepEqual(f.ev.heads.map(([, l]) => JSON.parse(l).outcome), ['recorded', 'recorded', 'recorded']);
});
test('restart after a send whose completion was never written: the gate STOP propagates as a stop, nothing appended', async () => {
  // setup_state.py:45: no completion record + target matching + initial not matching raises setup_state_STOP.
  const f = fixture({ mainImpl: async () => { throw Error('setup gate: {"gate":"setup_state_STOP"}'); } });
  const prior = sha256('step 0 recorded earlier'); f.state.head = prior;
  const s = await runSession(opts({ start: 1, 'expect-head': prior, 'empty-history-acknowledged': false }), f.io);
  assert.equal(s.status, 'stopped'); assert.equal(s.failedIndex, 1); assert.match(s.error, /setup_state_STOP/); assert.equal(f.ev.heads.length, 0);
});
test('heads file append failure after a recorded step: stopped, reason names it, chain head and outcome reported', async () => {
  const f = fixture();
  f.io.appendHead = () => { throw Error('EACCES: heads'); };
  const s = await runSession(opts(), f.io);
  assert.equal(s.status, 'stopped'); assert.match(s.reason, /heads file append failed after the step/);
  assert.equal(s.failedIndex, 0); assert.equal(s.outcome, 'recorded'); assert.equal(s.chainHeadAfterStep, f.state.own[IDS[0]].recordDigest);
  assert.equal(f.ev.main.length, 1);
});
test('step directory names: 3-digit padded, wider indices stay unique', () => {
  assert.equal(stepDirName(0), '000'); assert.equal(stepDirName(51), '051'); assert.equal(stepDirName(999), '999'); assert.equal(stepDirName(1000), '1000');
});
test('--audit-dir must be under cache/', async () => {
  await assert.rejects(runSession(opts({ 'audit-dir': 'steps' }), fixture().io), /must be under cache\//);
  await assert.rejects(runSession(opts({ 'audit-dir': 'cache' }), fixture().io), /must be under cache\//);
});
test('--audit-dir: nothing is created before the operator confirmation', async () => {
  const f = fixture({ confirms: ['no'] });
  const s = await runSession(opts(), f.io);
  assert.equal(s.status, 'stopped'); assert.deepEqual(f.ev.dirs, []);
});
test('--audit-dir (real filesystem): a missing child under a symlinked parent is refused and nothing is created outside', async () => {
  const t = realTree();
  try {
    symlinkSync(resolve(t.base, 'outside'), resolve(t.root, 'cache/outdir'));
    const { f } = realFixture(t.root);
    await assert.rejects(runSession(opts({ 'deploy-root': t.root, 'audit-dir': 'cache/outdir/new/steps' }), f.io), /component is not a real directory/);
    assert.equal(existsSync(resolve(t.base, 'outside/new')), false);
  } finally { t.cleanup(); }
});
test('--audit-dir (real filesystem): missing components are created one by one; an existing step directory stops before setup.main', async () => {
  const t = realTree();
  try {
    const { f } = realFixture(t.root);
    f.files[resolve(t.root, 'cache/b')] = Buffer.from('steps-b');
    const s = await runSession(opts({ 'deploy-root': t.root, 'audit-dir': 'cache/x/y/steps', end: 0 }), f.io);
    assert.equal(s.status, 'complete', JSON.stringify(s)); assert.ok(lstatSync(resolve(t.root, 'cache/x/y/steps/000')).isDirectory());
    mkdirSync(resolve(t.root, 'cache/pre/000'), { recursive: true });
    const g = realFixture(t.root).f; g.files[resolve(t.root, 'cache/b')] = Buffer.from('steps-b');
    const s2 = await runSession(opts({ 'deploy-root': t.root, 'audit-dir': 'cache/pre', end: 0 }), g.io);
    assert.equal(s2.status, 'stopped'); assert.match(s2.reason, /step audit directory exists/); assert.equal(g.ev.main.length, 0);
  } finally { t.cleanup(); }
});
test('--audit-dir: a component that is not a real directory right after its mkdir is refused before the step', async () => {
  const f = fixture();
  const mkdir = f.io.mkdir;
  // Simulates a swap between creating a component and using it: the created base turns out to be a symlink.
  f.io.mkdir = (p, o) => { mkdir(p, o); if (p === resolve(ROOT, 'cache/steps')) f.ev.links.push(p); };
  const s = await runSession(opts(), f.io);
  assert.equal(s.status, 'stopped'); assert.match(s.error, /component is not a real directory/); assert.equal(f.ev.main.length, 0);
});

// ── stable post-send receipts (run 1 step 0: one provider answered from a sibling unsafe block) ─────────
const CANON = '0x' + 'c'.repeat(64), SIBLING = '0x' + 'b'.repeat(64), TX = '0x' + 'ab'.repeat(32);
const clock = () => { let t = 0; return { now: () => t, sleep: async ms => { t += ms; } }; };
const notFoundError = () => Object.assign(Error('not found'), { name: 'TransactionReceiptNotFoundError' });
function fakePub({ receipts, heads, blocks = [CANON] }) {
  const calls = [], take = (l, i) => l[Math.min(i, l.length - 1)];
  let r = 0, h = 0, b = 0;
  return { calls,
    getTransactionReceipt: async a => { calls.push(['getTransactionReceipt', a]); const v = take(receipts, r++); if (v === null) throw notFoundError(); if (v instanceof Error) throw v; return v; },
    getBlockNumber: async a => { calls.push(['getBlockNumber', a]); return take(heads, h++); },
    getBlock: async a => { calls.push(['getBlock', a]); return { hash: take(blocks, b++) }; },
    waitForTransactionReceipt: async a => { calls.push(['waitForTransactionReceipt', a]); return { fallback: true }; },
    readContract: async a => { calls.push(['readContract', a]); return 'rc'; } };
}
const receipt = (hash, n = 101n, status = 'success') => ({ transactionHash: TX, blockHash: hash, blockNumber: n, status });
assert.equal(RECEIPT_CONFIRMATIONS, 3); assert.equal(RECEIPT_DELAY_BLOCKS, 3); assert.equal(RECEIPT_TIMEOUT_MS, 120000);

// A fake OP Sepolia endpoint behind the REAL pinned archivedRpc and a real viem client (no mocks between them).
// Chain: head = 100 + floor(t / 2000); the tx is in block `inclusion`; before `siblingUntil` the provider answers the
// receipt and that block from a sibling (SIBLING hash), afterwards from the canonical block (CANON).
function realArchive({ c, inclusion = 101, includedAt = 2000, siblingUntil = 3000, fail = () => null }) {
  const wire = [];
  const headAt = t => 100 + Math.floor(t / 2000);
  const hashAt = t => t < siblingUntil ? SIBLING : CANON;
  const hex = n => '0x' + n.toString(16);
  const rcpt = t => ({ transactionHash: TX, transactionIndex: '0x1', blockHash: hashAt(t), blockNumber: hex(inclusion), from: '0x08822612177e93a5b8da59b45171638eb53d495a',
    to: '0x41d1aa70fd501e23d36a29b2b16be88afea4279e', cumulativeGasUsed: '0xb3ee', gasUsed: '0xb3ee', effectiveGasPrice: '0xf4434', contractAddress: null, logs: [],
    logsBloom: '0x' + '0'.repeat(512), status: '0x1', type: '0x2' });
  const block = (n, t) => ({ number: hex(n), hash: n === inclusion ? hashAt(t) : '0x' + n.toString(16).padStart(64, '0'), parentHash: '0x' + '0'.repeat(64), timestamp: hex(1795540000 + n * 2),
    transactions: [], gasLimit: '0x1c9c380', gasUsed: '0x0', baseFeePerGas: '0xfa', miner: '0x' + '0'.repeat(40), extraData: '0x', size: '0x1', difficulty: '0x0', nonce: '0x0000000000000000',
    logsBloom: '0x' + '0'.repeat(512), sha3Uncles: '0x' + '0'.repeat(64), stateRoot: '0x' + '0'.repeat(64), receiptsRoot: '0x' + '0'.repeat(64), transactionsRoot: '0x' + '0'.repeat(64), uncles: [] });
  const fetchImpl = async (url, opts) => {
    const { id, method, params } = JSON.parse(opts.body), t = c.now();
    wire.push({ t, method, params, head: headAt(t) });
    const f = fail(method, t); if (f instanceof Error) throw f;
    let body;
    if (f) body = { jsonrpc: '2.0', id, error: f };
    else if (method === 'eth_blockNumber') body = { jsonrpc: '2.0', id, result: hex(headAt(t)) };
    else if (method === 'eth_getTransactionReceipt') body = { jsonrpc: '2.0', id, result: t < includedAt ? null : rcpt(t) };
    else if (method === 'eth_getBlockByNumber') body = { jsonrpc: '2.0', id, result: block(Number(BigInt(params[0])), t) };
    else if (method === 'eth_getTransactionByHash') body = { jsonrpc: '2.0', id, result: { hash: TX, blockHash: hashAt(t), blockNumber: hex(inclusion), from: rcpt(t).from, to: rcpt(t).to,
      input: '0x095ea7b3', value: '0x0', nonce: '0x0', gas: '0x10dd3', maxFeePerGas: '0xf4434', maxPriorityFeePerGas: '0xf4240', chainId: '0xaa37dc', type: '0x2', transactionIndex: '0x1',
      v: '0x0', r: '0x1', s: '0x1', yParity: '0x0', accessList: [] } };
    else throw Error('unexpected ' + method);
    return { ok: true, status: 200, arrayBuffer: async () => Buffer.from(JSON.stringify(body)) };
  };
  const rpc = archivedRpc({ url: 'http://fake.invalid', endpoint: 'B', append: () => {}, fetchImpl });
  return { rpc, wire, pub: createPublicClient({ transport: custom(rpc, { retryCount: 0 }) }) };
}
const causeChain = e => { const out = []; for (let x = e; x; x = x.cause) out.push(String(x.message ?? x)); return out.join(' <- '); };
const blockReads = ['eth_getTransactionReceipt', 'eth_getTransactionByHash', 'eth_getBlockByNumber'];

test('real archive: sibling answers in the first ~1 s only → canonical receipt; no receipt/tx/block read before head ≥ H0+3; pinned recordCompletion reads then pass', async () => {
  const c = clock(), stats = {};
  const { rpc, wire, pub } = realArchive({ c });
  const got = await stableReceipts(pub, stats, c).waitForTransactionReceipt({ hash: TX });
  assert.equal(got.blockHash, CANON); assert.equal(got.status, 'success');
  const h0 = wire[0].head;
  assert.equal(wire[0].method, 'eth_blockNumber');
  for (const w of wire.filter(w => blockReads.includes(w.method))) assert.ok(w.head >= h0 + 3, JSON.stringify(w));
  assert.deepEqual({ startBlock: stats.startBlock, firstReadHead: stats.firstReadHead, block: stats.block, confirmations: stats.confirmations },
    { startBlock: '100', firstReadHead: '103', block: '101', confirmations: '3' });
  // The reads pinned recordCompletion makes next on the same archive (verifyReceipt: receipt, block at height, tx) see
  // the same hash, so the anchor map does not trip.
  const r = await rpc.request({ method: 'eth_getTransactionReceipt', params: [TX] });
  const b = await rpc.request({ method: 'eth_getBlockByNumber', params: ['0x65', false] });
  const t = await rpc.request({ method: 'eth_getTransactionByHash', params: [TX] });
  assert.equal(r.blockHash, CANON); assert.equal(b.hash, CANON); assert.equal(t.blockHash, CANON);
});
test('real archive: a sibling seen at the first receipt read rejects fast with "recorded block hash changed" in the cause chain; no fallback', async () => {
  const c = clock(), stats = {};
  // Inclusion in 102: the receipt read at t=6000 (head 103) sees the sibling; depth 3 only at t=8000, when the block is canonical.
  const { pub } = realArchive({ c, inclusion: 102, includedAt: 4000, siblingUntil: 7000 });
  const err = await stableReceipts(pub, stats, c).waitForTransactionReceipt({ hash: TX }).then(() => null, e => e);
  assert.ok(err, 'must reject'); assert.match(causeChain(err), /recorded block hash changed|not canonical/);
  assert.ok(c.now() < 20000, 'fast: ' + c.now());
});
test('real archive: a transport error rejects at once with its own cause (archive goes sticky by design)', async () => {
  const c = clock(), stats = {};
  const { pub } = realArchive({ c, fail: (m, t) => m === 'eth_blockNumber' && t === 2000 ? Error('ECONNRESET') : null });
  const err = await stableReceipts(pub, stats, c).waitForTransactionReceipt({ hash: TX }).then(() => null, e => e);
  assert.match(causeChain(err), /transport failed/); assert.equal(c.now(), 2000);
});
test('real archive: a -32005 RPC error rejects at once with its own cause', async () => {
  const c = clock(), stats = {};
  const { pub } = realArchive({ c, fail: m => m === 'eth_getTransactionReceipt' ? { code: -32005, message: 'limit exceeded' } : null });
  const err = await stableReceipts(pub, stats, c).waitForTransactionReceipt({ hash: TX }).then(() => null, e => e);
  assert.match(causeChain(err), /-32005/); assert.equal(c.now(), 6000);
});
test('real archive: receipt not found at first, included later (block 104) → canonical receipt at depth 3', async () => {
  const c = clock(), stats = {};
  const { pub, wire } = realArchive({ c, inclusion: 104, includedAt: 8000, siblingUntil: 0 });
  const got = await stableReceipts(pub, stats, c).waitForTransactionReceipt({ hash: TX });
  assert.equal(got.blockHash, CANON); assert.equal(stats.block, '104'); assert.equal(stats.confirmations, '3');
  assert.equal(wire.filter(w => w.method === 'eth_getBlockByNumber').length, 1);
});
test('stable receipts: receipt never found within the timeout → explicit error naming hash, H0 and last head; no fallback wait', async () => {
  const c = clock(), stats = {};
  const pub = fakePub({ receipts: [null], heads: Array.from({ length: 400 }, (_, i) => BigInt(100 + i)) });
  const err = await stableReceipts(pub, stats, c).waitForTransactionReceipt({ hash: TX }).then(() => null, e => e);
  assert.match(err.message, new RegExp('no receipt within 120 s for ' + TX + ' \\(H0 100, last head \\d+\\)'));
  assert.equal(pub.calls.some(([m]) => m === 'waitForTransactionReceipt'), false);
});
test('stable receipts: no confirmations within the timeout → rejects (never returns a shallow receipt)', async () => {
  const c = clock(), stats = {};
  const pub = fakePub({ receipts: [receipt(CANON, 103n)], heads: [100n, 103n, 103n] });
  await assert.rejects(stableReceipts(pub, stats, c).waitForTransactionReceipt({ hash: TX }), /no receipt within 120 s/);
});
test('stable receipts: a receipt for another transaction rejects; hash case differences are accepted and the receipt keeps its own case', async () => {
  const c = clock();
  const other = { ...receipt(CANON), transactionHash: '0x' + 'cd'.repeat(32) };
  await assert.rejects(stableReceipts(fakePub({ receipts: [other], heads: [100n, 103n] }), {}, c).waitForTransactionReceipt({ hash: TX }), /another transaction/);
  const upper = '0x' + 'C'.repeat(64);
  const got = await stableReceipts(fakePub({ receipts: [{ ...receipt(upper), transactionHash: TX.toUpperCase().replace('0X', '0x') }], heads: [100n, 103n, 103n] }), {}, clock()).waitForTransactionReceipt({ hash: TX });
  assert.equal(got.blockHash, upper); assert.notEqual(TX.toUpperCase().replace('0X', '0x'), TX);
});
test('stable receipts: a reverted receipt is returned unchanged; a number-valued blockNumber is an error, not swallowed', async () => {
  const got = await stableReceipts(fakePub({ receipts: [receipt(CANON, 101n, 'reverted')], heads: [100n, 103n, 103n] }), {}, clock()).waitForTransactionReceipt({ hash: TX });
  assert.equal(got.status, 'reverted');
  await assert.rejects(stableReceipts(fakePub({ receipts: [{ ...receipt(CANON), blockNumber: 101 }], heads: [100n, 103n] }), {}, clock()).waitForTransactionReceipt({ hash: TX }), TypeError);
});
test('stable receipts: block read at the receipt height and head reads with cacheTime 0', async () => {
  const pub = fakePub({ receipts: [receipt(CANON, 101n)], heads: [100n, 103n, 103n] });
  await stableReceipts(pub, {}, clock()).waitForTransactionReceipt({ hash: TX });
  assert.deepEqual(pub.calls.filter(([m]) => m === 'getBlock'), [['getBlock', { blockNumber: 101n }]]);
  for (const [, a] of pub.calls.filter(([m]) => m === 'getBlockNumber')) assert.deepEqual(a, { cacheTime: 0 });
});
test('stable receipts: every other method reaches the raw pinned client untouched, with identical arguments', async () => {
  const pub = fakePub({ receipts: [receipt(CANON)], heads: [1n] });
  const w = stableReceipts(pub, {}, clock());
  for (const k of ['getBlock', 'getBlockNumber', 'getTransactionReceipt', 'readContract']) assert.equal(w[k], pub[k], k);
  const a = { blockNumber: 7n }, b = { cacheTime: 0 }, r = { address: '0x01', functionName: 'x' };
  await w.getBlock(a); await w.getBlockNumber(b); await w.readContract(r);
  assert.equal(pub.calls[0][1], a); assert.equal(pub.calls[1][1], b); assert.equal(pub.calls[2][1], r);
});
test('canonicalRuntime: pubA/pubB are the stable-receipt proxies; with A sibling-first over the real archive the setup.mjs:35 compare passes', async () => {
  const c = clock();
  const A = realArchive({ c }), B = realArchive({ c, siblingUntil: 0 });
  const raw = rawRuntime(() => null);
  raw.runtime.pubA = A.pub; raw.runtime.pubB = B.pub;
  let seen;
  const rt = await canonicalRuntime(raw.formalRuntime, { receipts: c, onReceipts: s => { seen = s; } })({});
  assert.notEqual(rt.pubA, raw.runtime.pubA); assert.equal(rt.pubA.getBlock, raw.runtime.pubA.getBlock);
  const [ra, rb] = await Promise.all([rt.pubA.waitForTransactionReceipt({ hash: TX }), rt.pubB.waitForTransactionReceipt({ hash: TX })]);
  assert.equal(ra.status, 'success'); assert.equal(rb.status, ra.status); assert.equal(ra.blockHash, rb.blockHash); assert.equal(ra.blockNumber, rb.blockNumber);
  assert.equal(seen.A.hash, TX); assert.equal(seen.B.block, '101');
});

// ── record path ─────────────────────────────────────────────────────────────────────────────────────────
const RTX = '0x3469c1c0005d9fee6eff5c8b29c00b51a57f5287f8c7e7c5b5fa1b2a6cf83759';
const argvOf = o => Object.entries(opts(o)).flatMap(([k, v]) => v === true ? ['--' + k] : v === false ? [] : ['--' + k, String(v)]);
test('record flags: only together, single index equal to --start/--end, hash format, not with --probe-reads', () => {
  assert.throws(() => parseArgs(argvOf({ 'record-step': 0, end: 0 })), /go together/);
  assert.throws(() => parseArgs(argvOf({ 'record-tx': RTX, end: 0 })), /go together/);
  assert.throws(() => parseArgs(argvOf({ 'record-step': 0, 'record-tx': RTX, end: 1 })), /equal to it/);
  assert.throws(() => parseArgs(argvOf({ 'record-step': 1, 'record-tx': RTX, start: 0, end: 0 })), /equal to it/);
  assert.throws(() => parseArgs(argvOf({ 'record-step': 0, 'record-tx': RTX.toUpperCase().replace('0X', '0x'), end: 0 })), /record-tx must be/);
  assert.throws(() => parseArgs(argvOf({ 'record-step': 0, 'record-tx': RTX.slice(0, 64), end: 0 })), /record-tx must be/);
  assert.throws(() => parseArgs(argvOf({ 'record-step': 0, 'record-tx': RTX, end: 0, 'probe-reads': true })), /cannot be combined/);
  const ok = parseArgs(argvOf({ 'record-step': 0, 'record-tx': RTX, end: 0 }));
  assert.equal(ok['record-step'], 0); assert.equal(ok['record-tx'], RTX);
});
test('record: pinned setup.main gets record mode argv with the tx hash; outcome recorded; no deps.send', async () => {
  const f = fixture();
  const s = await runSession(opts({ 'record-step': 0, 'record-tx': RTX, end: 0 }), f.io);
  assert.equal(s.status, 'complete', JSON.stringify(s)); assert.deepEqual(s.outcomes, { recorded: 1, 'already-satisfied-recorded': 0 });
  const call = f.ev.main[0];
  assert.deepEqual(call.args, ['record', 'cache/plan.json', sha256(BUNDLE), '0', 's.json', 'cache/a', 'cache/b', resolve(ROOT, 'cache/steps/000/setup.audit.ndjson'), 'cfg.json', 'in.json', RTX, '--expect-head', GENESIS]);
  assert.deepEqual(Object.keys(call.deps), ['regenerate', 'runtime']);
  assert.equal(JSON.parse(f.ev.heads[0][1]).outcome, 'recorded');
});
test('record: refused before setup.main when the step already has its own completion entry; nothing appended', async () => {
  const f = fixture();
  f.state.own[IDS[0]] = { recordDigest: sha256('earlier') };
  const s = await runSession(opts({ 'record-step': 0, 'record-tx': RTX, end: 0 }), f.io);
  assert.equal(s.status, 'stopped'); assert.match(s.reason, /record refused/); assert.equal(f.ev.main.length, 0); assert.equal(f.ev.heads.length, 0);
});
test('record: a pinned-code rejection (tx not matching the frozen step) stops, nothing appended', async () => {
  const f = fixture({ mainImpl: async () => { throw Error('completion transaction field mismatch'); } });
  const s = await runSession(opts({ 'record-step': 0, 'record-tx': RTX, end: 0 }), f.io);
  assert.equal(s.status, 'stopped'); assert.match(s.error, /field mismatch/); assert.equal(f.ev.heads.length, 0);
});
test('record: setup returning without a new own entry is a stop', async () => {
  const f = fixture({ mainImpl: async () => {} });
  const s = await runSession(opts({ 'record-step': 0, 'record-tx': RTX, end: 0 }), f.io);
  assert.equal(s.status, 'stopped'); assert.equal(f.ev.heads.length, 0);
});
test('pinned verifyReceipt (completion.mjs == 99a38d8d) rejects a tx that does not match the frozen step', async () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const pinned = spawnSync('git', ['show', '99a38d8d:script/rq3op/completion.mjs'], { cwd: here });
  assert.equal(pinned.status, 0); assert.ok(readFileSync(resolve(here, 'completion.mjs')).equals(pinned.stdout));
  const { verifyReceipt } = await import('./completion.mjs');
  const step = { from: '0x08822612177e93a5b8da59b45171638eb53d495a', tx: { from: '0x08822612177e93a5b8da59b45171638eb53d495a', to: '0x41d1aa70fd501e23d36a29b2b16be88afea4279e',
    data: '0x095ea7b3', value: '0x0', nonce: '0x0', gas: '0x10dd3', maxFeePerGas: '0xf4434', maxPriorityFeePerGas: '0xf4240', chainId: '0xaa37dc' } };
  const tx = { ...step.tx, input: step.tx.data, blockHash: CANON };
  const read = over => async (m) => m === 'eth_getTransactionReceipt' ? { status: '0x1', transactionHash: RTX, blockHash: CANON, blockNumber: '0x31775a2' }
    : m === 'eth_getBlockByNumber' ? { hash: CANON, timestamp: '0x1' } : { ...tx, ...over };
  assert.equal((await verifyReceipt(read({}), step, RTX)).receiptStatus, 'success');
  await assert.rejects(verifyReceipt(read({ input: '0x095ea7b4' }), step, RTX), /calldata mismatch/);
  await assert.rejects(verifyReceipt(read({ nonce: '0x1' }), step, RTX), /field mismatch/);
  await assert.rejects(verifyReceipt(read({ to: '0x' + '9'.repeat(40) }), step, RTX), /identity mismatch/);
});


test('SESSION_RECEIPTS: one line per step with H0, head at first read, inclusion block, depth, polls and fallback per provider', async () => {
  FORMAL.next = { archives: [], pubA: fakePub({ receipts: [receipt(CANON)], heads: [100n, 103n, 103n] }), pubB: fakePub({ receipts: [receipt(CANON)], heads: [100n, 103n, 104n] }) };
  try {
    const f = fixture({ mainImpl: async (args, deps, { state }) => {
      const rt = await deps.runtime({});
      await Promise.all([rt.pubA.waitForTransactionReceipt({ hash: TX }), rt.pubB.waitForTransactionReceipt({ hash: TX })]);
      state.head = sha256('r0'); state.own[IDS[0]] = { recordDigest: state.head };
    } });
    const s = await runSession(opts({ end: 0 }), f.io);
    assert.equal(s.status, 'complete');
    const line = JSON.parse(f.ev.logs.find(l => l.startsWith('SESSION_RECEIPTS ')).slice(17));
    assert.deepEqual(line, { index: 0, A: { hash: TX, polls: 3, startBlock: '100', firstReadHead: '103', lastHead: '103', block: '101', confirmations: '3' },
      B: { hash: TX, polls: 3, startBlock: '100', firstReadHead: '103', lastHead: '104', block: '101', confirmations: '4' } });
  } finally { delete FORMAL.next; }
});
test('record: a refused record creates no step directory', async () => {
  const f = fixture();
  f.state.own[IDS[0]] = { recordDigest: sha256('earlier') };
  await runSession(opts({ 'record-step': 0, 'record-tx': RTX, end: 0 }), f.io);
  assert.equal(f.ev.dirs.some(d => d.endsWith('/000')), false);
});

test('real archive: a provider that consistently answers the sibling is not caught by the wrapper; setup.mjs:35 still sees the A/B difference', async () => {
  const c = clock();
  const A = realArchive({ c, siblingUntil: 0 }), B = realArchive({ c, siblingUntil: 1e9 });
  const [ra, rb] = await Promise.all([stableReceipts(A.pub, {}, c).waitForTransactionReceipt({ hash: TX }), stableReceipts(B.pub, {}, c).waitForTransactionReceipt({ hash: TX })]);
  assert.equal(ra.blockHash, CANON); assert.equal(rb.blockHash, SIBLING);
  assert.equal(rb.blockHash !== ra.blockHash, true); // the pinned compare fails exactly as in run 1
});
test('stable receipts: without the archive layer, a block hash differing from the receipt is still rejected', async () => {
  const pub = fakePub({ receipts: [receipt(CANON)], heads: [100n, 103n, 103n], blocks: [SIBLING] });
  await assert.rejects(stableReceipts(pub, {}, clock()).waitForTransactionReceipt({ hash: TX }), /not canonical/);
});

// ── Daybreak #682 increment 2: no fallback, deadline around every call, shared cancellation ──────────────
test('real archive: inclusion exactly when the deadline expires → stop, no receipt accepted', async () => {
  const c = clock(), stats = {};
  const { pub, wire } = realArchive({ c, inclusion: 160, includedAt: 120000, siblingUntil: 0 });
  const err = await stableReceipts(pub, stats, c).waitForTransactionReceipt({ hash: TX }).then(() => null, e => e);
  assert.match(String(err?.message), /no receipt within 120 s/);
  assert.equal(wire.some(w => w.method === 'eth_getTransactionReceipt' && w.t >= 120000), false);
  assert.equal(wire.some(w => w.method === 'eth_getBlockByNumber'), false);
});
test('real archive: late inclusion whose first non-null receipt is provisional → stops fast with the cause', async () => {
  const c = clock(), stats = {};
  // Included in 105 at t=10000 (head 105); provisional until t=11000; first receipt read at t=10000; depth 3 at t=14000.
  const { pub } = realArchive({ c, inclusion: 105, includedAt: 10000, siblingUntil: 11000 });
  const err = await stableReceipts(pub, stats, c).waitForTransactionReceipt({ hash: TX }).then(() => null, e => e);
  assert.ok(err); assert.match(causeChain(err), /recorded block hash changed|not canonical/); assert.equal(stats.block, '105');
});
test('real archive: a transport error after several not-found polls rejects at once with its cause', async () => {
  const c = clock();
  const { pub } = realArchive({ c, inclusion: 110, includedAt: 30000, fail: (m, t) => m === 'eth_getTransactionReceipt' && t === 9000 ? Error('ECONNRESET') : null });
  const err = await stableReceipts(pub, {}, c).waitForTransactionReceipt({ hash: TX }).then(() => null, e => e);
  assert.match(causeChain(err), /transport failed/); assert.equal(c.now(), 9000);
});
test('real archive: a transport error during the final block read rejects with its cause', async () => {
  const c = clock();
  const { pub } = realArchive({ c, siblingUntil: 0, fail: m => m === 'eth_getBlockByNumber' ? Error('ECONNRESET') : null });
  const err = await stableReceipts(pub, {}, c).waitForTransactionReceipt({ hash: TX }).then(() => null, e => e);
  assert.match(causeChain(err), /transport failed/);
});
test('stable receipts: a result that arrives after the deadline is rejected even though the call succeeded', async () => {
  const c = clock();
  const pub = fakePub({ receipts: [receipt(CANON)], heads: [100n, 103n, 103n] });
  const getBlock = pub.getBlock;
  pub.getBlock = async a => { await c.sleep(200000); return getBlock(a); }; // the call outlives the 120 s bound
  await assert.rejects(stableReceipts(pub, {}, c).waitForTransactionReceipt({ hash: TX }), /no receipt within 120 s/);
});
test('shared cancellation: once one provider waiter rejects, the other stops at its next call', async () => {
  const c = clock();
  const A = fakePub({ receipts: [Error('RPC A transport failed (redacted)')], heads: [100n, 103n] });
  const B = fakePub({ receipts: [null], heads: Array.from({ length: 400 }, (_, i) => BigInt(100 + i)) });
  const raw = rawRuntime(() => null); raw.runtime.pubA = A; raw.runtime.pubB = B;
  const rt = await canonicalRuntime(raw.formalRuntime, { receipts: c })({});
  const [ea, eb] = await Promise.all([rt.pubA.waitForTransactionReceipt({ hash: TX }).then(() => null, e => e), rt.pubB.waitForTransactionReceipt({ hash: TX }).then(() => null, e => e)]);
  assert.match(ea.message, /RPC A transport failed/);
  assert.match(eb.message, /receipt wait stopped: the other provider failed \(RPC A transport failed/);
  assert.ok(B.calls.length < 20, 'B stopped early: ' + B.calls.length);
});
test('shared cancellation is per step: a new runtime starts with a clear flag', async () => {
  const c = clock();
  const raw = rawRuntime(() => null);
  raw.runtime.pubA = fakePub({ receipts: [Error('boom')], heads: [100n, 103n] }); raw.runtime.pubB = fakePub({ receipts: [null], heads: [100n, 103n] });
  const make = canonicalRuntime(raw.formalRuntime, { receipts: c });
  const first = await make({});
  await first.pubA.waitForTransactionReceipt({ hash: TX }).catch(() => {});
  raw.runtime.pubA = fakePub({ receipts: [receipt(CANON)], heads: [100n, 103n, 103n] });
  const second = await make({});
  assert.equal((await second.pubA.waitForTransactionReceipt({ hash: TX })).blockHash, CANON);
});
test('shared cancellation: a waiter whose peer has already failed makes no provider call at all', async () => {
  const pub = fakePub({ receipts: [receipt(CANON)], heads: [100n, 103n, 103n] });
  await assert.rejects(stableReceipts(pub, {}, { ...clock(), cancel: { reason: 'peer failed' } }).waitForTransactionReceipt({ hash: TX }), /other provider failed \(peer failed\)/);
  assert.equal(pub.calls.length, 0);
});

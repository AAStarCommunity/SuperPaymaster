import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { runSession, parseArgs, PINNED_MODULES, OPERATOR_PAUSE_MS, GENESIS, sortKeys, canonicalRuntime, probeSigner } from './setup-session.mjs';

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

const FORMAL = { formalRuntime: async () => ({}) };
function fixture({ regenerated = BUNDLE, confirms = ['confirm'], failAt = null, clock = [], afterStep = () => {}, foreignAt = null, mainError = null, mainImpl = null } = {}) {
  const files = { [resolve(ROOT, 'cache/plan.json')]: BUNDLE, [resolve(ROOT, 'cfg.json')]: Buffer.from('cfg'), [resolve(ROOT, 'in.json')]: Buffer.from('in'),
    [resolve(ROOT, 'cache/b')]: Buffer.from('steps-b'), [resolve(ROOT, 'cache/regenb')]: Buffer.from('regen-b') };
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
      if (p.endsWith('formal.mjs')) return FORMAL;
      if (p.endsWith('setup.mjs')) return { main: async (args, deps) => {
        const index = Number(args[2]);
        ev.main.push({ args, deps });
        if (mainImpl) return mainImpl(args, deps, { files, state });
        if (mainError) throw mainError;
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
  for (const k of ['accounts', 'pubA', 'pubB', 'refreshPin']) assert.equal(rt[k], raw.runtime[k]);
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
  assert.deepEqual(providers, { regenerationB: { file: 'cache/regenb', sha256: sha256(Buffer.from('regen-b')) }, stepsB: { file: 'cache/b', sha256: sha256(Buffer.from('steps-b')) } });
  assert.equal(JSON.parse(f.ev.logs.find(l => l.startsWith('SESSION_START ')).slice(14)).files['cache/regenb'], sha256(Buffer.from('regen-b')));
});
test('--regen-rpc-b absent: planner argv is exactly as before (rpc-b) and the snapshot has no extra file', async () => {
  const f = fixture();
  await runSession(opts(), f.io);
  assert.deepEqual(f.ev.planner[0].args, PLANNER_ARGV('cache/b'));
  const start = JSON.parse(f.ev.logs.find(l => l.startsWith('SESSION_START ')).slice(14));
  assert.equal('cache/regenb' in start.files, false);
  assert.equal(JSON.parse(f.ev.logs.find(l => l.startsWith('SESSION_PROVIDERS ')).slice(18)).regenerationB.file, 'cache/b');
});
test('--regen-rpc-b is in the start snapshot: changed between steps stops before the next step', async () => {
  const f = fixture({ afterStep: (i, { files }) => { if (i === 0) files[resolve(ROOT, 'cache/regenb')] = Buffer.from('swapped'); } });
  const s = await runSession(opts({ 'regen-rpc-b': 'cache/regenb' }), f.io);
  assert.equal(s.status, 'stopped'); assert.equal(s.nextIndex, 1); assert.match(s.reason, /session file changed since start: cache\/regenb/);
});
test('--regen-rpc-b outside the deploy worktree is refused; parseArgs accepts it once', async () => {
  await assert.rejects(runSession(opts({ 'regen-rpc-b': '../elsewhere/b' }), fixture().io), /--regen-rpc-b must be inside/);
  const argv = o => Object.entries(opts(o)).flatMap(([k, v]) => v === true ? ['--' + k] : v === false ? [] : ['--' + k, String(v)]);
  assert.equal(parseArgs(argv({ 'regen-rpc-b': 'cache/regenb' }))['regen-rpc-b'], 'cache/regenb');
  assert.equal('regen-rpc-b' in parseArgs(argv({})), false);
  assert.throws(() => parseArgs([...argv({ 'regen-rpc-b': 'x' }), '--regen-rpc-b', 'y']), /usage/);
});

// RQ3 setup session driver. Regenerates the frozen plan ONCE per session, then runs setup.mjs main() per step
// with deps.regenerate returning those verified bytes. Every other setup.mjs gate runs unchanged.
// setup.mjs is imported from the deploy worktree given by path. The tree and module checks below DETECT a change
// between checks (start, before each step, end); they are not an immutable snapshot, and transitive modules,
// node_modules and PATH executables are not pinned. This file never sends, signs or writes the completion log itself.
import { readFileSync, appendFileSync, realpathSync, mkdirSync, lstatSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';

// Operator pause: after this long since the last confirmation the driver stops between steps for a new one.
// It refreshes nothing; the on-chain price-freshness gate in plan_three_arm.pre_send is the control.
export const OPERATOR_PAUSE_MS = 50 * 60 * 1000;
export const GENESIS = '0'.repeat(64);
// Paths relative to the deploy root; blobs must equal HEAD at start and before each step, sha256 re-checked at end.
export const PINNED_MODULES = ['script/rq3op/setup.mjs', 'script/rq3op/completion.mjs', 'script/rq3op/gate_worker.py',
  'script/rq3op/setup_state.py', 'script/rq3op/plan_three_arm.py', 'script/upgrade/manifest_exec.py',
  'script/rehearsal/deploylive_postdeploy_check.py', 'script/rq3op/checker_runner.py', 'script/a6-collector/formal.mjs',
  'script/a6-collector/frozen-plan.mjs'];
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const gitBlob = bytes => createHash('sha1').update(Buffer.concat([Buffer.from(`blob ${bytes.length}\0`), bytes])).digest('hex');
const redact = s => String(s?.message ?? s).replace(/https?:\/\/\S+/g, '<url>');
const VALUE_KEYS = ['deploy-root','expect-commit','bundle','digest','signers','rpc-a','rpc-b','audit-dir','config','inputs','start','end','expect-head','heads-file'];
const FLAG_KEYS = ['empty-history-acknowledged', 'probe-reads'];
// Optional: B endpoint file for the driver's own regeneration only (planner + post-deploy checker); steps use --rpc-b.
const OPTIONAL_VALUE_KEYS = ['regen-rpc-b'];

// setup.mjs:159-163 compares the two providers' parsed results with plain JSON.stringify, so equal objects whose
// keys come back in a different order disagree (OP Sepolia headers: Alchemy vs QuickNode). The session hands setup a
// runtime whose archive requests return the same result with object keys sorted recursively. Arrays keep their order;
// strings, numbers, booleans and null pass unchanged; method, params and errors pass through untouched. formal.mjs
// archives each provider's raw response bytes before this runs (archivedRpc), so the archive is unaffected.
// Only the JSON value domain is accepted (what formal.mjs's JSON.parse yields); anything else throws, so a value whose
// meaning is not in its own enumerable data keys (Date, typed array, accessor, toJSON) cannot be collapsed.
export function sortKeys(value, seen = new Set()) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value !== 'object') throw Error('sortKeys: not a JSON value');
  if (seen.has(value)) throw Error('sortKeys: cycle');
  seen.add(value);
  try {
    if (Array.isArray(value)) {
      if (Object.getPrototypeOf(value) !== Array.prototype || Reflect.ownKeys(value).length !== value.length + 1) throw Error('sortKeys: not a JSON array');
      return Array.from(value, item => sortKeys(item, seen));
    }
    const proto = Object.getPrototypeOf(value);
    if (proto !== Object.prototype && proto !== null) throw Error('sortKeys: not a plain object');
    const keys = Reflect.ownKeys(value);
    for (const k of keys) {
      const d = Object.getOwnPropertyDescriptor(value, k);
      if (typeof k !== 'string' || !d.enumerable || !('value' in d)) throw Error('sortKeys: not a JSON data property');
    }
    return Object.fromEntries(keys.sort().map(k => [k, sortKeys(value[k], seen)]));
  } finally { seen.delete(value); }
}
const refuseSigning = () => { throw Error('probe: signing refused'); };
// Probe signer: the configured address, and every signing call throws. Used only with --probe-reads; no keystore.
export const probeSigner = async account => ({ type: 'local', source: 'probe', address: account.address,
  signMessage: refuseSigning, signTransaction: refuseSigning, signTypedData: refuseSigning });
export function canonicalRuntime(formalRuntime, { probe = false } = {}) {
  return async options => {
    const runtime = await formalRuntime(probe ? { ...options, createSigner: probeSigner } : options);
    return { ...runtime, archives: runtime.archives.map(archive => ({ ...archive, request: async args => sortKeys(await archive.request(args)) })) };
  };
}

export function parseArgs(argv) {
  const named = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i]?.replace(/^--/, '');
    if (FLAG_KEYS.includes(k) && !(k in named)) { named[k] = true; continue; }
    if (![...VALUE_KEYS, ...OPTIONAL_VALUE_KEYS].includes(k) || argv[i+1] === undefined || k in named) throw Error('usage: ' + VALUE_KEYS.map(k => '--' + k + ' <v>').join(' ') + ' [--regen-rpc-b <v>] [--empty-history-acknowledged] [--probe-reads]');
    named[k] = argv[++i];
  }
  for (const k of VALUE_KEYS) if (!(k in named)) throw Error('missing --' + k);
  if (!/^[0-9a-f]{40}$/.test(named['expect-commit'])) throw Error('--expect-commit must be 40 hex');
  if (!/^[0-9a-f]{64}$/.test(named.digest)) throw Error('--digest must be 64 hex');
  if (!/^[0-9a-f]{64}$/.test(named['expect-head'])) throw Error('--expect-head must be 64 hex');
  const start = Number(named.start), end = Number(named.end);
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start) throw Error('--start/--end invalid');
  if (named['probe-reads'] && (start !== 0 || end !== 0)) throw Error('--probe-reads requires --start 0 --end 0');
  return { ...named, start, end, 'empty-history-acknowledged': named['empty-history-acknowledged'] === true, 'probe-reads': named['probe-reads'] === true };
}

export function snapshot(io, root, opts) {
  const files = {};
  for (const p of [...PINNED_MODULES, opts.bundle, opts.config, opts.inputs, ...(opts['regen-rpc-b'] ? [opts['regen-rpc-b']] : [])]) files[p] = sha256(io.read(resolve(root, p)));
  return { head: io.git(root, ['rev-parse', 'HEAD']), tree: io.git(root, ['rev-parse', 'HEAD^{tree}']),
    status: io.git(root, ['status', '--porcelain']), files };
}

// Expected commit, clean worktree, every pinned module equal to its HEAD blob. Returns an error string or null.
export function treeProblem(io, root, commit, paths = PINNED_MODULES) {
  if (io.git(root, ['rev-parse', 'HEAD']) !== commit) return 'deploy worktree HEAD is not the expected commit';
  if (io.git(root, ['status', '--porcelain']) !== '') return 'deploy worktree is not clean';
  for (const p of paths) if (gitBlob(io.read(resolve(root, p))) !== io.git(root, ['rev-parse', `HEAD:${p}`])) return 'pinned module differs from HEAD: ' + p;
  return null;
}

export const stepDirName = index => String(index).padStart(3, '0');
// --audit-dir must lie under <root>/cache (gitignored). At start only existing components are inspected (each must be a
// real directory, never a symlink); nothing is created until ensure() runs right before the first step, after the gates
// and the operator confirmation. ensure() creates missing components one at a time, non-recursively, re-checking each.
// Known gap: a component swapped concurrently between a check and the next mkdir is not detected (single-operator host).
export function auditDirPlan(io, root, given) {
  const cache = resolve(root, 'cache'), path = resolve(root, given);
  if (!path.startsWith(cache + '/')) throw Error('--audit-dir must be under cache/ in the deploy worktree');
  const isDir = p => { let st; try { st = io.lstat(p); } catch (error) { if (error.code === 'ENOENT') return false; throw error; }
    if (st.isSymbolicLink() || !st.isDirectory() || io.realpath(p) !== p) throw Error('--audit-dir component is not a real directory: ' + p); return true; };
  if (!isDir(cache)) throw Error('--audit-dir: cache/ missing in the deploy worktree');
  const parts = path.slice(cache.length + 1).split('/');
  let cursor = cache; const missing = [];
  for (const part of parts) { cursor = resolve(cursor, part); if (missing.length || !isDir(cursor)) missing.push(cursor); }
  let done = missing.length === 0;
  return { path, ensure() { if (done) return; for (const dir of missing) { io.mkdir(dir); isDir(dir); } done = true; } };
}
export async function runSession(opts, io) {
  const root = io.realpath(opts['deploy-root']);
  // --regen-rpc-b is resolved to its real path before anything reads it; the canonical path must be inside the root and
  // is what the snapshot hashes and the planner receives (a symlink in the tree pointing outside is refused unread).
  if (opts['regen-rpc-b'] !== undefined) {
    const canonical = io.realpath(resolve(root, opts['regen-rpc-b']));
    if (!canonical.startsWith(root + '/')) throw Error('--regen-rpc-b must be inside the deploy worktree');
    opts = { ...opts, 'regen-rpc-b': canonical };
  }
  // Per-step audit window: setup.mjs:155 hands formal.mjs outPath = --audit, and evidence.mjs:39 creates
  // <dirname>/raw/<A|B> with a non-recursive mkdir, so one shared audit path fails at the second step (EEXIST).
  // Each step gets <audit-dir>/<3-digit index>/setup.audit.ndjson in a directory created exclusively just before it.
  const auditBase = auditDirPlan(io, root, opts['audit-dir']);
  const log = io.log, record = { steps: [], heads: [], audits: [], outcomes: { recorded: 0, 'already-satisfied-recorded': 0 } };
  const headsFile = resolve(opts['heads-file']);
  if (headsFile === root || headsFile.startsWith(root + '/')) throw Error('--heads-file must be outside the deploy worktree');
  const regenB = opts['regen-rpc-b'] ?? opts['rpc-b'];
  const finish = (status, extra = {}) => {
    let after;
    try { after = snapshot(io, root, opts); } catch (error) { after = { error: redact(error) }; }
    const equal = JSON.stringify(after) === JSON.stringify(record.before);
    // A changed tree or file never ends as a success (complete or probe-reached-send).
    const final = !equal && (status === 'complete' || status === 'probe-reached-send') ? 'stopped-hash-mismatch' : status;
    const summary = { status: final, stepsDone: record.steps.length, lastIndex: record.steps.at(-1)?.index ?? null,
      lastChainHead: record.heads.at(-1) ?? opts['expect-head'], hashesEqual: equal, audits: record.audits, outcomes: record.outcomes, ...extra };
    log('SESSION_SUMMARY ' + JSON.stringify(summary));
    return summary;
  };
  const verify = paths => { const problem = treeProblem(io, root, opts['expect-commit'], paths); if (problem) throw Error(problem); };
  const importPinned = async p => { verify([p]); return io.importModule(resolve(root, p)); };
  // 1. Deploy worktree, recorded hashes.
  verify();
  record.before = snapshot(io, root, opts);
  log('SESSION_START ' + JSON.stringify({ commit: record.before.head, tree: record.before.tree, files: record.before.files }));
  log('SESSION_PROVIDERS ' + JSON.stringify({ regenerationB: { file: regenB, sha256: sha256(io.read(resolve(root, regenB))) },
    stepsB: { file: opts['rpc-b'], sha256: sha256(io.read(resolve(root, opts['rpc-b']))) } }));
  const raw = io.read(resolve(root, opts.bundle));
  if (sha256(raw) !== opts.digest) throw Error('reviewed bundle digest mismatch');
  const { parse } = await importPinned('script/a6-collector/frozen-plan.mjs');
  const bundle = parse(raw);
  if (opts.end >= bundle.steps.length) throw Error(`--end must be below ${bundle.steps.length}`);
  // 2. The starting head must match the completion log before the planner runs.
  const { chainHead, completionEntry } = await importPinned('script/rq3op/completion.mjs');
  const completionPath = resolve(root, opts.bundle) + '.completions.jsonl';
  if (chainHead(completionPath, opts.digest) !== opts['expect-head']) return finish('stopped', { reason: 'completion log head differs from --expect-head' });
  if (opts['expect-head'] === GENESIS) {
    if (!opts['empty-history-acknowledged'] || opts.start !== 0) throw Error('genesis head requires --empty-history-acknowledged and --start 0');
    log('SESSION_NOTE empty history acknowledged: anchored on the genesis head; no global first-run scan is performed');
  }
  // 3. Regenerate once, exactly as setup.mjs:133-145 (cwd = root, same argv), and require the frozen bytes.
  const block = Object.values(bundle.plans)[0].pin.block;
  const regenStart = io.now();
  const regenerated = Buffer.from(await io.planner(root, ['-B', resolve(root, 'script/rq3op/plan_three_arm.py'), resolve(root, opts.config),
    resolve(root, opts.inputs), '-', '--rpc-a-file', resolve(root, opts['rpc-a']), '--rpc-b-file', resolve(root, regenB), '--block', block]));
  const regenEnd = io.now();
  if (!raw.equals(regenerated)) throw Error('regenerated bundle bytes mismatch');
  if (sha256(regenerated) !== opts.digest) throw Error('regenerated bundle digest mismatch');
  log('SESSION_REGENERATED ' + JSON.stringify({ sha256: opts.digest, block, startMs: regenStart, endMs: regenEnd }));
  const setup = await importPinned('script/rq3op/setup.mjs');
  const formal = await importPinned('script/a6-collector/formal.mjs');
  verify(['script/rq3op/setup.mjs', 'script/a6-collector/formal.mjs']);
  const probe = opts['probe-reads'];
  if (probe) log('SESSION_NOTE probe-reads: signer refuses to sign and deps.send refuses; the step stops at its send');
  // deps.send is set only in probe mode; otherwise setup builds its own send from the canonical archives[0] (setup.mjs:157).
  // Probe success is recognised by this session's own Error instance, thrown only by deps.send.
  const refused = Error('probe: send refused');
  let sendCalls = 0;
  const deps = { regenerate: async () => Buffer.from(regenerated), runtime: canonicalRuntime(formal.formalRuntime, { probe }),
    ...(probe ? { send: async () => { sendCalls++; throw refused; } } : {}) };
  // 4. Operator confirmation (the price is refreshed between regeneration and this line).
  const confirm = async why => { log('SESSION_WAIT ' + why + ' — type "confirm" to continue, anything else stops'); return (await io.readLine())?.trim() === 'confirm'; };
  if (!await confirm('before first step')) return finish('stopped', { reason: 'operator did not confirm' });
  let confirmedAt = io.now(), head = opts['expect-head'];
  io.chdir(root);
  for (let index = opts.start; index <= opts.end; index++) {
    if (io.now() - confirmedAt > OPERATOR_PAUSE_MS) {
      if (!await confirm(`operator pause before step ${index}`)) return finish('stopped', { reason: 'operator did not reconfirm', nextIndex: index });
      confirmedAt = io.now();
    }
    const problem = treeProblem(io, root, opts['expect-commit'])
      ?? Object.entries(record.before.files).map(([p, h]) => sha256(io.read(resolve(root, p))) !== h ? 'session file changed since start: ' + p : null).find(Boolean);
    if (problem) return finish('stopped', { reason: problem, nextIndex: index });
    const stepDir = resolve(auditBase.path, stepDirName(index));
    try { auditBase.ensure(); io.mkdir(stepDir); } catch (error) { return finish('stopped', { reason: 'step audit directory exists or cannot be created', nextIndex: index, error: redact(error) }); }
    const audit = resolve(stepDir, 'setup.audit.ndjson');
    record.audits.push(audit);
    const args = [opts.bundle, opts.digest, String(index), opts.signers, opts['rpc-a'], opts['rpc-b'], audit, opts.config, opts.inputs, '--expect-head', head];
    const ownBefore = completionEntry(completionPath, opts.digest, bundle.steps[index].id);
    try {
      await setup.main(args, deps);
    } catch (error) {
      if (probe && error === refused && sendCalls === 1) {
        const after = chainHead(completionPath, opts.digest);
        if (after !== head || completionEntry(completionPath, opts.digest, bundle.steps[index].id))
          return finish('stopped', { reason: 'probe: completion log changed', failedIndex: index, chainHeadAfterFailure: after });
        return finish('probe-reached-send', { index });
      }
      let after = 'unavailable'; try { after = chainHead(completionPath, opts.digest); } catch {}
      return finish('stopped', { reason: 'setup step failed', failedIndex: index, chainHeadAfterFailure: after, error: redact(error) });
    }
    if (probe) return finish('stopped', { reason: 'probe: setup returned without reaching send', failedIndex: index });
    const next = chainHead(completionPath, opts.digest);
    const own = completionEntry(completionPath, opts.digest, bundle.steps[index].id);
    if (next !== head && next !== own?.recordDigest) return finish('stopped', { reason: 'completion log head is not this step\'s own entry', failedIndex: index, chainHeadAfterStep: next });
    // A normal return counts only with the step's own completion entry: new in this step (recorded), or pre-existing
    // with the head unchanged (already-satisfied-recorded; setup_state.py:41-42 needs a record for already-satisfied).
    const outcome = !ownBefore && own && next !== head && next === own.recordDigest ? 'recorded'
      : ownBefore && own && next === head && own.recordDigest === ownBefore.recordDigest ? 'already-satisfied-recorded' : 'unrecorded';
    if (outcome === 'unrecorded') return finish('stopped', { reason: 'unrecorded: setup returned without this step\'s own completion entry', outcome, failedIndex: index, chainHeadAfterStep: next });
    head = next;
    record.steps.push({ index, outcome }); record.heads.push(head); record.outcomes[outcome]++;
    try { io.appendHead(headsFile, JSON.stringify({ index, id: bundle.steps[index].id, chainHead: head, outcome, audit, atMs: io.now() }) + '\n'); }
    catch (error) { return finish('stopped', { reason: 'heads file append failed after the step', failedIndex: index, chainHeadAfterStep: head, outcome, error: redact(error) }); }
  }
  return finish('complete');
}

const realIO = () => {
  const rl = createInterface({ input: process.stdin }), lines = rl[Symbol.asyncIterator]();
  return {
    realpath: realpathSync, read: p => readFileSync(p), mkdir: (p, o) => mkdirSync(p, o), lstat: p => lstatSync(p), now: () => Date.now(), log: s => process.stdout.write(s + '\n'),
    git: (root, args) => execFileSync('git', ['-C', root, ...args], { encoding: 'utf8' }).trim(),
    importModule: p => import(pathToFileURL(p).href),
    planner: async (root, args) => (await promisify(execFile)('python3', args, { cwd: root, encoding: 'buffer', maxBuffer: 64 * 1024 * 1024 })).stdout,
    readLine: async () => (await lines.next()).value, chdir: d => process.chdir(d), appendHead: (f, s) => appendFileSync(f, s, { mode: 0o600 }),
    close: () => rl.close(),
  };
};
export const exitCodeFor = status => status === 'complete' || status === 'probe-reached-send' ? 0 : 1;
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const io = realIO();
  Promise.resolve().then(() => runSession(parseArgs(process.argv.slice(2)), io))
    .then(s => { process.exitCode = exitCodeFor(s.status); })
    .catch(e => { process.stderr.write('setup session stopped: ' + redact(e) + '\n'); process.exitCode = 1; })
    .finally(() => io.close());
}

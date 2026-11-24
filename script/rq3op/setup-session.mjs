// RQ3 setup session driver. Regenerates the frozen plan ONCE per session, then runs setup.mjs main() per step
// with deps.regenerate returning those verified bytes. Every other setup.mjs gate runs unchanged.
// setup.mjs is imported from the clean deploy worktree given by path (its git blob is checked against HEAD);
// this file never sends, signs or writes the completion log itself.
import { readFileSync, appendFileSync, realpathSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';

export const PRICE_WINDOW_MS = 50 * 60 * 1000;
export const GENESIS = '0'.repeat(64);
// Files whose bytes the session pins at start and re-checks at end (paths relative to the deploy root).
export const PINNED_MODULES = ['script/rq3op/setup.mjs', 'script/rq3op/completion.mjs', 'script/rq3op/gate_worker.py',
  'script/rq3op/setup_state.py', 'script/rq3op/plan_three_arm.py', 'script/upgrade/manifest_exec.py',
  'script/rehearsal/deploylive_postdeploy_check.py', 'script/rq3op/checker_runner.py', 'script/a6-collector/formal.mjs',
  'script/a6-collector/frozen-plan.mjs'];
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const gitBlob = bytes => createHash('sha1').update(Buffer.concat([Buffer.from(`blob ${bytes.length}\0`), bytes])).digest('hex');

export function parseArgs(argv) {
  const named = {}, keys = ['deploy-root','expect-commit','bundle','digest','signers','rpc-a','rpc-b','audit','config','inputs','start','end','expect-head','heads-file'];
  for (let i = 0; i < argv.length; i += 2) {
    const k = argv[i]?.replace(/^--/, '');
    if (!keys.includes(k) || argv[i+1] === undefined || k in named) throw Error('usage: ' + keys.map(k => '--' + k + ' <v>').join(' '));
    named[k] = argv[i+1];
  }
  for (const k of keys) if (!(k in named)) throw Error('missing --' + k);
  if (!/^[0-9a-f]{40}$/.test(named['expect-commit'])) throw Error('--expect-commit must be 40 hex');
  if (!/^[0-9a-f]{64}$/.test(named.digest)) throw Error('--digest must be 64 hex');
  if (!/^[0-9a-f]{64}$/.test(named['expect-head'])) throw Error('--expect-head must be 64 hex');
  const start = Number(named.start), end = Number(named.end);
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start) throw Error('--start/--end invalid');
  return { ...named, start, end };
}

// Hashes of the pinned modules, the session inputs and the deploy tree; equality at start and end is reported.
export function snapshot(io, root, opts) {
  const files = {};
  for (const p of [...PINNED_MODULES, opts.bundle, opts.config, opts.inputs]) files[p] = sha256(io.read(resolve(root, p)));
  return { head: io.git(root, ['rev-parse', 'HEAD']), tree: io.git(root, ['rev-parse', 'HEAD^{tree}']),
    status: io.git(root, ['status', '--porcelain']), files };
}

export async function runSession(opts, io) {
  const root = io.realpath(opts['deploy-root']);
  const log = io.log, record = { steps: [], heads: [] };
  const headsFile = resolve(opts['heads-file']);
  if (headsFile === root || headsFile.startsWith(root + '/')) throw Error('--heads-file must be outside the deploy worktree');
  const finish = (status, extra = {}) => {
    let after = null;
    try { after = snapshot(io, root, opts); } catch (error) { after = { error: error.message }; }
    const equal = JSON.stringify(after) === JSON.stringify(record.before);
    const summary = { status, stepsDone: record.steps.length, lastIndex: record.steps.at(-1)?.index ?? null,
      lastChainHead: record.heads.at(-1) ?? opts['expect-head'], hashesEqual: equal, ...extra };
    log('SESSION_SUMMARY ' + JSON.stringify(summary));
    return summary;
  };
  // 1. Deploy worktree: expected commit, clean, setup.mjs is the committed blob.
  if (io.git(root, ['rev-parse', 'HEAD']) !== opts['expect-commit']) throw Error('deploy worktree HEAD is not the expected commit');
  if (io.git(root, ['status', '--porcelain']) !== '') throw Error('deploy worktree is not clean');
  for (const p of PINNED_MODULES)
    if (gitBlob(io.read(resolve(root, p))) !== io.git(root, ['rev-parse', `HEAD:${p}`])) throw Error('pinned module differs from HEAD: ' + p);
  record.before = snapshot(io, root, opts);
  log('SESSION_START ' + JSON.stringify({ commit: record.before.head, tree: record.before.tree, files: record.before.files }));
  // 2. Regenerate once, exactly as setup.mjs:133-145 (cwd = root, same argv), and require the frozen bytes.
  const raw = io.read(resolve(root, opts.bundle));
  if (sha256(raw) !== opts.digest) throw Error('reviewed bundle digest mismatch');
  const { parse } = await io.importModule(resolve(root, 'script/a6-collector/frozen-plan.mjs'));
  const block = Object.values(parse(raw).plans)[0].pin.block;
  const regenStart = io.now();
  const regenerated = Buffer.from(await io.planner(root, ['-B', resolve(root, 'script/rq3op/plan_three_arm.py'), resolve(root, opts.config),
    resolve(root, opts.inputs), '-', '--rpc-a-file', resolve(root, opts['rpc-a']), '--rpc-b-file', resolve(root, opts['rpc-b']), '--block', block]));
  const regenEnd = io.now();
  if (!raw.equals(regenerated)) throw Error('regenerated bundle bytes mismatch');
  if (sha256(regenerated) !== opts.digest) throw Error('regenerated bundle digest mismatch');
  log('SESSION_REGENERATED ' + JSON.stringify({ sha256: opts.digest, block, startMs: regenStart, endMs: regenEnd }));
  const setup = await io.importModule(resolve(root, 'script/rq3op/setup.mjs'));
  const { chainHead } = await io.importModule(resolve(root, 'script/rq3op/completion.mjs'));
  if (gitBlob(io.read(resolve(root, 'script/rq3op/setup.mjs'))) !== io.git(root, ['rev-parse', 'HEAD:script/rq3op/setup.mjs'])) throw Error('setup.mjs changed during import');
  const completionPath = resolve(root, opts.bundle) + '.completions.jsonl';
  if (chainHead(completionPath, opts.digest) !== opts['expect-head']) return finish('stopped', { reason: 'completion log head differs from --expect-head' });
  // 3. Operator confirmation (the price is refreshed between regeneration and this line).
  const confirm = async why => { log('SESSION_WAIT ' + why + ' — type "confirm" to continue, anything else stops'); return (await io.readLine())?.trim() === 'confirm'; };
  if (!await confirm('before first step')) return finish('stopped', { reason: 'operator did not confirm' });
  let confirmedAt = io.now(), head = opts['expect-head'];
  io.chdir(root);
  for (let index = opts.start; index <= opts.end; index++) {
    if (io.now() - confirmedAt > PRICE_WINDOW_MS) {
      if (!await confirm(`price window passed before step ${index}`)) return finish('stopped', { reason: 'operator did not reconfirm', nextIndex: index });
      confirmedAt = io.now();
    }
    const args = [opts.bundle, opts.digest, String(index), opts.signers, opts['rpc-a'], opts['rpc-b'], opts.audit, opts.config, opts.inputs, '--expect-head', head];
    try {
      await setup.main(args, { regenerate: async () => Buffer.from(regenerated) });
    } catch (error) {
      let after = 'unavailable'; try { after = chainHead(completionPath, opts.digest); } catch {}
      return finish('stopped', { reason: 'setup step failed', failedIndex: index, chainHeadAfterFailure: after, error: String(error?.message ?? error).replace(/https?:\/\/\S+/g, '<url>') });
    }
    head = chainHead(completionPath, opts.digest);
    record.steps.push({ index }); record.heads.push(head);
    io.appendHead(headsFile,JSON.stringify({ index, chainHead: head, atMs: io.now() }) + '\n');
  }
  return finish('complete');
}

const realIO = () => {
  const lines = createInterface({ input: process.stdin })[Symbol.asyncIterator]();
  return {
    realpath: realpathSync, read: p => readFileSync(p), now: () => Date.now(), log: s => process.stdout.write(s + '\n'),
    git: (root, args) => execFileSync('git', ['-C', root, ...args], { encoding: 'utf8' }).trim(),
    importModule: p => import(pathToFileURL(p).href),
    planner: async (root, args) => (await promisify(execFile)('python3', args, { cwd: root, encoding: 'buffer', maxBuffer: 64 * 1024 * 1024 })).stdout,
    readLine: async () => (await lines.next()).value, chdir: d => process.chdir(d), appendHead: (f, s) => appendFileSync(f, s, { mode: 0o600 }),
  };
};
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runSession(parseArgs(process.argv.slice(2)), realIO())
    .then(s => { process.exitCode = s.status === 'complete' ? 0 : 1; process.exit(); })
    .catch(e => { process.stderr.write('setup session stopped: ' + String(e?.message ?? e).replace(/https?:\/\/\S+/g, '<url>') + '\n'); process.exit(1); });
}

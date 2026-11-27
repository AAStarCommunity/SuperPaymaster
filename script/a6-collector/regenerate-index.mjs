// Offline regeneration of a frozen window's derived evidence index (index.ndjson) from the
// unchanged run.jsonl + raw/ archive. Each line is rebuilt exactly as collector.mjs writeLine()
// builds it at write time: evidenceIndex(row, context) with the same context (archives truncated
// to records with id <= row.evidenceEnd[i], windowId = run_start.runId, schedule true for a frozen
// window, pins/rpcIdentity from run_start, passports {start, attempt} refs as the collector recorded
// them, stopReason, replaces null), then the window scheduling fields Object.assign()ed onto the
// index row, serialized with evidence.mjs stringify + '\n' (the appendIndex format).
//
// The original index.ndjson is only READ (passports refs + byte-identity self-check); run.jsonl,
// raw/, passports/, manifest.json and trailer.json are never modified. The only file written is
// the --out path, which must not exist and must not be <window-dir>/index.ndjson.
//
// Usage: node script/a6-collector/regenerate-index.mjs <window-dir> --out <new-index-path>
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { evidenceIndex, sha256, stringify } from './evidence.mjs';

const WINDOW_SCHEMA = 'rq3-window-v1';

/** Sorted relative paths of every file under dir (prefix prepended). */
export function walkFiles(dir, prefix = '') {
  const out = [];
  for (const name of readdirSync(dir).sort()) {
    const p = join(dir, name), rel = prefix ? `${prefix}/${name}` : name;
    if (statSync(p).isDirectory()) out.push(...walkFiles(p, rel));
    else out.push(rel);
  }
  return out;
}

/** sha256 of run.jsonl and every file under raw/ and passports/, keyed by relative path. */
export function inputHashes(windowDir) {
  const rels = ['run.jsonl', ...walkFiles(join(windowDir, 'raw'), 'raw'), ...walkFiles(join(windowDir, 'passports'), 'passports')];
  return Object.fromEntries(rels.map(rel => [rel, sha256(readFileSync(join(windowDir, rel)))]));
}

// Raw archive reader, mirroring artifact-validate.mjs (readdirSync().sort() over raw/{A,B},
// /^\d{8}\.ndjson$/ file names, trim/split/parse per line, path re-attached to each record,
// ids unique and strictly increasing per endpoint as the append-only writer guarantees).
export function loadArchives(windowDir) {
  const archives = [{ endpoint: 'A', records: [] }, { endpoint: 'B', records: [] }];
  for (const [i, endpoint] of ['A', 'B'].entries()) {
    for (const name of readdirSync(join(windowDir, 'raw', endpoint)).sort()) {
      if (!/^\d{8}\.ndjson$/.test(name)) throw new Error(`invalid raw date file: raw/${endpoint}/${name}`);
      const path = `raw/${endpoint}/${name}`;
      let previous = 0;
      for (const line of readFileSync(join(windowDir, path)).toString().trim().split('\n').filter(Boolean)) {
        const r = JSON.parse(line);
        if (r.endpoint !== endpoint) throw new Error(`raw record endpoint mismatch: ${path}`);
        if (!Number.isSafeInteger(r.id) || r.id <= previous) throw new Error(`raw ids must be strictly increasing per endpoint: ${path}`);
        previous = r.id;
        archives[i].records.push({ ...r, path });
      }
    }
  }
  return archives;
}

// For rows whose original tx.raw was null, only tx.raw (and its missing-evidence entry) may change.
const ALLOWED_DIFF = [/^tx\.raw(\.|$)/, /^missing\.\/tx\/raw$/];

/** Leaf paths whose serialized values differ between two parsed values. */
function diffPaths(a, b, prefix = '') {
  if (stringify(a) === stringify(b)) return [];
  if (a == null || b == null || typeof a !== 'object' || typeof b !== 'object' || Array.isArray(a) !== Array.isArray(b)) return [prefix || '(root)'];
  const out = [];
  for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) out.push(...diffPaths(a[k], b[k], prefix ? `${prefix}.${k}` : k));
  return out;
}

export function regenerateIndex(windowDir, outPath, log = console.log) {
  windowDir = resolve(windowDir);
  outPath = resolve(outPath);
  for (const rel of ['run.jsonl', 'index.ndjson', 'manifest.json'])
    if (!existsSync(join(windowDir, rel))) throw new Error(`not a frozen window (missing ${rel}): ${windowDir}`);
  const originalIndexPath = join(windowDir, 'index.ndjson');
  if (outPath === originalIndexPath) throw new Error(`--out must not be the window's own index.ndjson: ${outPath}`);
  if (existsSync(outPath)) throw new Error(`--out already exists: ${outPath}`);
  const manifest = JSON.parse(readFileSync(join(windowDir, 'manifest.json'), 'utf8'));
  if (manifest?.schema !== WINDOW_SCHEMA) throw new Error(`not a frozen window manifest (schema ${manifest?.schema ?? 'missing'}): ${windowDir}`);
  const schedule = true; // frozen window: collector passes schedule:Boolean(window) === true

  const pre = inputHashes(windowDir);
  log(`window: ${windowDir} (${WINDOW_SCHEMA}, schedule=${schedule})`);
  log(`pre-write input hashes (${Object.keys(pre).length} files: run.jsonl + raw/ + passports/):`);
  for (const [rel, h] of Object.entries(pre)) log(`  ${h}  ${rel}`);

  const runRows = readFileSync(join(windowDir, 'run.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
  const runStart = runRows.find(r => r.kind === 'run_start');
  if (!runStart) throw new Error('run.jsonl has no run_start row');
  const attempts = runRows.filter(r => r.kind === 'attempt');
  const originalLines = readFileSync(originalIndexPath, 'utf8').trim().split('\n').filter(Boolean);
  if (attempts.length !== originalLines.length)
    throw new Error(`run.jsonl has ${attempts.length} attempt rows but index.ndjson has ${originalLines.length} lines`);
  log(`attempts in run.jsonl: ${attempts.length}; lines in original index.ndjson: ${originalLines.length}`);
  const archives = loadArchives(windowDir);

  const lines = [];
  const rawRows = { identical: 0, differing: 0, violations: [] };
  const otherRows = { identical: 0, differing: 0, paths: new Map(), violations: [] };
  for (const [i, a] of attempts.entries()) {
    const origLine = originalLines[i], orig = JSON.parse(origLine);
    // Context exactly as collector.mjs writeLine() (~line 212) passes it, with the archive
    // truncation artifact-validate.mjs (~line 272) applies when rebuilding rows offline.
    const context = {
      schedule,
      windowId: runStart.runId,
      archives: archives.map((arc, ei) => ({ records: arc.records.filter(r => r.id <= a.evidenceEnd?.[ei]) })),
      pins: runStart.pins,
      rpcIdentity: runStart.rpcIdentity,
      passports: { start: orig.passports?.start ?? null, attempt: orig.passports?.attempt ?? null },
      stopReason: a.stoppedBy?.reason ?? null,
      replaces: null,
    };
    const index = evidenceIndex(a, context);
    // The window scheduling fields the collector Object.assign()s onto the index row.
    Object.assign(index, { block_slot: a.block_slot, pair_id: a.pair_id, seed: a.seed, schedule_sha256: a.schedule_sha256, warmup: false, spWait: a.spWait, slotChecks: a.slotChecks, scheduleDisposition: a.scheduleDisposition });
    const line = stringify(index);
    lines.push(line);
    if (orig.tx?.raw != null) {
      if (line === origLine) rawRows.identical++;
      else { rawRows.differing++; rawRows.violations.push(i); for (const p of diffPaths(JSON.parse(line), orig)) otherRows.paths.set(p, (otherRows.paths.get(p) ?? 0) + 1); }
    } else if (line === origLine) otherRows.identical++;
    else {
      otherRows.differing++;
      for (const p of diffPaths(JSON.parse(line), orig)) {
        otherRows.paths.set(p, (otherRows.paths.get(p) ?? 0) + 1);
        if (!ALLOWED_DIFF.some(re => re.test(p))) otherRows.violations.push(`${i}:${p}`);
      }
    }
  }

  log('self-check against original index.ndjson:');
  log(`  rows with non-null original tx.raw: ${rawRows.identical} byte-identical, ${rawRows.differing} differing`);
  if (rawRows.violations.length) log(`  ERROR: not byte-identical despite non-null original tx.raw (row indices): ${rawRows.violations.join(',')}`);
  log(`  other rows: ${otherRows.identical} identical, ${otherRows.differing} differing`);
  if (otherRows.paths.size)
    log(`  differing field paths (path: rows): ${[...otherRows.paths.entries()].map(([p, n]) => `${p}: ${n}`).join(', ')}`);

  log(`  allowed differing paths for rows with null original tx.raw: ${ALLOWED_DIFF.map(re => re.source).join(', ')}`);
  if (rawRows.violations.length) throw new Error(`self-check failed: ${rawRows.violations.length} rows with non-null original tx.raw are not byte-identical; nothing written`);
  if (otherRows.violations.length) throw new Error(`self-check failed: paths outside the allowed set differ (row:path): ${otherRows.violations.join(', ')}; nothing written`);
  writeFileSync(outPath, lines.join('\n') + '\n', { flag: 'wx', mode: 0o600 });
  log(`wrote ${lines.length} rows to ${outPath}`);

  const post = inputHashes(windowDir);
  log(`post-write input hashes (${Object.keys(post).length} files):`);
  for (const [rel, h] of Object.entries(post)) log(`  ${h}  ${rel}`);
  const unchanged = Object.keys(pre).length === Object.keys(post).length && Object.entries(pre).every(([rel, h]) => post[rel] === h);
  if (!unchanged) throw new Error('input files changed during regeneration (run.jsonl/raw/passports must be untouched)');
  log(`inputs unchanged: OK (${Object.keys(post).length}/${Object.keys(post).length} files match pre-write hashes)`);
  const indexSha = sha256(readFileSync(outPath));
  log(`new index sha256: ${indexSha}`);
  return { outPath, rows: lines.length, indexSha, rawRows, otherRows, pre, post };
}

function usage() {
  console.error('usage: node script/a6-collector/regenerate-index.mjs <window-dir> --out <new-index-path>');
  process.exit(2);
}

function main() {
  const args = process.argv.slice(2);
  if (!args.length || args[0].startsWith('--')) usage();
  const windowDir = args[0];
  const outFlag = args.findIndex(a => a === '--out' || a.startsWith('--out='));
  if (outFlag < 0) usage();
  const outPath = args[outFlag].startsWith('--out=') ? args[outFlag].slice('--out='.length) : args[outFlag + 1];
  if (!outPath) usage();
  try {
    regenerateIndex(windowDir, outPath);
  } catch (e) {
    console.error(`regenerate-index: ${e.message}`);
    process.exit(1);
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) main();

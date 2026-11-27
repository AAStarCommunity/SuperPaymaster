import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { sha256 } from './evidence.mjs';
import { sentWindowFixture } from './sent-window-fixture.mjs';

const script = fileURLToPath(new URL('./regenerate-index.mjs', import.meta.url));

function snapshot(dir) {
  const out = {};
  const walk = d => {
    for (const name of readdirSync(d).sort()) {
      const p = join(d, name), rel = d === dir ? name : `${d.slice(dir.length + 1)}/${name}`;
      if (statSync(p).isDirectory()) walk(p);
      else out[rel] = sha256(readFileSync(p));
    }
  };
  walk(dir);
  return out;
}

function runCli(dir, out) {
  return spawnSync(process.execPath, [script, dir, '--out', out], { encoding: 'utf8' });
}

test('regenerate-index reproduces the collector index byte-for-byte and leaves every input untouched', async t => {
  const dir = mkdtempSync(join(process.cwd(), '.regen-index-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  // Default fixture: eth_getTransactionByHash is archived only once per sent tx (the included
  // response), so there is no null-poll row and the whole index must regenerate identically.
  await sentWindowFixture(dir);
  const before = snapshot(dir);
  for (const rel of ['run.jsonl', 'index.ndjson', 'manifest.json', 'trailer.json'])
    assert.ok(before[rel], `fixture missing ${rel}`);
  assert.ok(Object.keys(before).some(rel => rel.startsWith('raw/')), 'fixture missing raw/');
  assert.ok(Object.keys(before).some(rel => rel.startsWith('passports/')), 'fixture missing passports/');

  const out = join(dir, 'index.regenerated.ndjson');
  const r = runCli(dir, out);
  assert.equal(r.status, 0, `stdout:\n${r.stdout}\nstderr:\n${r.stderr}`);

  // (a) inputs untouched: every pre-existing file still present with the same sha256, and no
  // protected file was modified (run.jsonl, raw/, passports/, manifest.json, trailer.json, index.ndjson).
  const after = snapshot(dir);
  const added = Object.keys(after).filter(rel => !(rel in before));
  assert.deepEqual(added, ['index.regenerated.ndjson'], `unexpected new files: ${added.join(',')}`);
  for (const [rel, h] of Object.entries(before)) assert.equal(after[rel], h, `input modified: ${rel}`);

  // (b) the regenerated output equals the collector's own index for this null-poll-free fixture.
  assert.equal(readFileSync(out, 'utf8'), readFileSync(join(dir, 'index.ndjson'), 'utf8'));

  // CLI reporting: hashes printed pre and post, inputs asserted unchanged, index sha256 printed.
  assert.match(r.stdout, /pre-write input hashes \(\d+ files: run\.jsonl \+ raw\/ \+ passports\/\):/);
  assert.match(r.stdout, /post-write input hashes \(\d+ files\):/);
  assert.match(r.stdout, /inputs unchanged: OK \(\d+\/\d+ files match pre-write hashes\)/);
  assert.match(r.stdout, /rows with non-null original tx\.raw: \d+ byte-identical, 0 differing/);
  assert.match(r.stdout, new RegExp(`new index sha256: ${sha256(readFileSync(out))}`));
  const indexLines = readFileSync(join(dir, 'index.ndjson'), 'utf8').trim().split('\n').length;
  assert.match(r.stdout, new RegExp(`wrote ${indexLines} rows to`));
});

test('regenerate-index refuses an existing --out and the window\'s own index.ndjson, changing nothing', async t => {
  const dir = mkdtempSync(join(process.cwd(), '.regen-index-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  await sentWindowFixture(dir);
  const before = snapshot(dir);

  const existing = join(dir, 'already-there.ndjson');
  writeFileSync(existing, 'x\n');
  const snapshotWithExtra = { ...before, 'already-there.ndjson': sha256(readFileSync(existing)) };
  let r = runCli(dir, existing);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /--out already exists/);
  assert.equal(readFileSync(existing, 'utf8'), 'x\n');

  r = runCli(dir, join(dir, 'index.ndjson'));
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /must not be the window's own index\.ndjson/);

  r = spawnSync(process.execPath, [script, dir], { encoding: 'utf8' });
  assert.equal(r.status, 2);
  assert.match(r.stderr, /usage:/);

  assert.deepEqual(snapshot(dir), snapshotWithExtra, 'refused runs must not modify the window');
  assert.ok(existsSync(join(dir, 'index.ndjson')));
});

test('regenerate-index refuses a non-window journal, changing nothing', async t => {
  const dir = mkdtempSync(join(process.cwd(), '.regen-index-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  await sentWindowFixture(dir);
  const manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8'));
  writeFileSync(join(dir, 'manifest.json'), JSON.stringify({ ...manifest, schema: 'not-a-window' }));
  const before = snapshot(dir);
  const r = runCli(dir, join(dir, 'index.regenerated.ndjson'));
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /not a frozen window/);
  assert.deepEqual(snapshot(dir), before);
});

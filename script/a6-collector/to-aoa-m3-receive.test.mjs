// node --test script/a6-collector/to-aoa-m3-receive.test.mjs
// Offline controls for the aoa-m3-receive-v1 exporter, on the archived local-anvil runs (not A6 data).
// validate.mjs needs node_modules (viem); the adapter-only controls run with validate disabled.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, rmSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { exportRun, decodeUoe, ExportError, UOE_TOPIC } from './to-aoa-m3-receive.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const DATA = join(HERE, '../../docs/design/aoa-balance-mode/data/a6-gauge-local');
const rowsOf = (name) => readFileSync(join(DATA, name), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
let hasViem = true;
try { await import('viem'); } catch { hasViem = false; }

function withRun(rows, fn) {
  const d = mkdtempSync(join(tmpdir(), 'aoa-m3-test-'));
  try {
    const src = join(d, 'run.jsonl');
    writeFileSync(src, rows.map((r) => JSON.stringify(r)).join('\n') + '\n');
    const out = join(d, 'out');
    execFileSync('mkdir', ['-p', out]);
    return fn(src, out);
  } finally {
    rmSync(d, { recursive: true, force: true });
  }
}
const exportRows = (rows, opts = { validate: false }) => withRun(rows, (src, out) => exportRun(src, out, opts));
const refused = (rows, re, opts) => assert.throws(() => exportRows(rows, opts), (e) => e instanceof ExportError && re.test(e.message));
const spRow = (rows) => rows.find((r) => r.kind === 'attempt' && r.arm === 'SP');

test('UOE topic constant is keccak256 of the v0.7 event signature', { skip: !hasViem }, async () => {
  const { keccak256, toHex } = await import('viem');
  assert.equal(keccak256(toHex('UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)')), UOE_TOPIC);
});

test('positive run: every attempt included, fields from the decoded receipt log', () => {
  const rows = rowsOf('positive.jsonl');
  const pkg = exportRows(rows);
  assert.equal(pkg.schema, 'aoa-m3-receive-v1');
  assert.equal(pkg.runType, 'rehearsal');
  assert.equal(pkg.attempts.length, 3);
  assert.ok(pkg.attempts.every((a) => a.included));
  const sp = pkg.attempts.find((a) => a.paymasterKind === 'SP');
  const r = spRow(rows);
  assert.equal(sp.actualGasCostWei, String(r.userOpEvent.actualGasCost));
  assert.equal(sp.userOpHash, r.expectedUserOpHash.toLowerCase());
  assert.equal(sp.target, '0x000000000000000000000000000000000000dead');
  assert.equal(new Set(pkg.attempts.map((a) => a.pairId)).size, 1);
});

test('export is deterministic', () => {
  const rows = rowsOf('positive.jsonl');
  const a = withRun(rows, (src, out) => { exportRun(src, out, { validate: false }); return readFileSync(join(out, 'receive.json'), 'utf8'); });
  const b = withRun(rows, (src, out) => { exportRun(src, out, { validate: false }); return readFileSync(join(out, 'receive.json'), 'utf8'); });
  assert.equal(a, b);
});

test('deleting the UserOperationEvent of a success row refuses the export', () => {
  const rows = rowsOf('positive.jsonl');
  const r = spRow(rows);
  r.logs = r.logs.filter((l) => l.topics[0].toLowerCase() !== UOE_TOPIC);
  refused(rows, /0 matching UserOperationEvent/);
});

test('a collector record that disagrees with its own log refuses the export', () => {
  for (const [field, value] of [['actualGasCost', '1'], ['actualGasUsed', '1'], ['success', false]]) {
    const rows = rowsOf('positive.jsonl');
    spRow(rows).userOpEvent[field] = value;
    refused(rows, /disagrees with the collector/);
  }
});

test('validate.mjs does not read the userOpEvent summary; the export cross-check does', { skip: !hasViem }, () => {
  // Found 2026-10-27: validate.mjs decodes the receipt logs itself and never compares the collector's
  // userOpEvent summary, so a tampered summary is still "consistent" there. The exporter refuses it.
  const rows = rowsOf('positive.jsonl');
  spRow(rows).userOpEvent.actualGasCost = '1';
  withRun(rows, (src) => {
    let status = 0;
    try { execFileSync('node', [join(HERE, 'validate.mjs'), src], { stdio: 'ignore' }); } catch (e) { status = e.status; }
    assert.ok(status === 0 || status === 3, `validate.mjs exit ${status}`);
  });
  refused(rows, /disagrees with the collector/, { validate: true });
  const ok = exportRows(rowsOf('positive.jsonl'), { validate: true });
  assert.equal(ok.attempts.filter((a) => a.included).length, 3);
});

test('an archive validate.mjs finds inconsistent is refused', { skip: !hasViem }, () => {
  const rows = rowsOf('positive.jsonl');
  delete spRow(rows).logs;  // validate.mjs: missing field logs (exit 2)
  refused(rows, /validate\.mjs exit 2/, { validate: true });
});

test('passport drift or a missing passport refuses the export', () => {
  const drift = rowsOf('positive.jsonl');
  drift.at(-1).passport.invariant.bundler = '0x' + '11'.repeat(20);
  refused(drift, /drifted/);
  const none = rowsOf('positive.jsonl');
  none.at(-1).passport = null;
  refused(none, /no start\/end passport/);
});

test('failed and fixture attempts are kept, excluded, with reasons', () => {
  for (const name of ['a-exec-revert.jsonl', 'b-drop-op.jsonl', 'c-wrong-hash.jsonl']) {
    const rows = rowsOf(name);
    const pkg = exportRows(rows);
    assert.equal(pkg.attempts.length, rows.filter((r) => r.kind === 'attempt').length, name);
    assert.ok(pkg.attempts.every((a) => !a.included && /VERDICT:/.test(a.exclusionReason)), name);
  }
});

test('an unmatched triplet excludes its successful arms', () => {
  const rows = rowsOf('positive.jsonl');
  rows.at(-1).triplets[0].matched = false;
  const pkg = exportRows(rows);
  assert.ok(pkg.attempts.every((a) => !a.included && a.exclusionReason === 'TRIPLET_INCOMPLETE'));
});

test('runType is formal-candidate only for a protocolConformant run', () => {
  const rows = rowsOf('positive.jsonl');
  rows[0].protocolConformant = true;
  assert.equal(exportRows(rows).runType, 'formal-candidate');
});

test('decodeUoe matches only the EntryPoint, the topic and the expected hash', () => {
  const r = spRow(rowsOf('positive.jsonl'));
  assert.equal(decodeUoe(r.logs, r.entryPoint, r.expectedUserOpHash).count, 1);
  assert.equal(decodeUoe(r.logs, '0x' + '22'.repeat(20), r.expectedUserOpHash).count, 0);
  assert.equal(decodeUoe(r.logs, r.entryPoint, '0x' + '33'.repeat(32)).count, 0);
  const twice = [...r.logs, r.logs.find((l) => l.topics[0].toLowerCase() === UOE_TOPIC)];
  assert.equal(decodeUoe(twice, r.entryPoint, r.expectedUserOpHash).count, 2);
});

test('CLI refuses a non-empty output directory', () => {
  const d = mkdtempSync(join(tmpdir(), 'aoa-m3-cli-'));
  try {
    writeFileSync(join(d, 'x'), 'x');
    assert.throws(() => execFileSync('node', [join(HERE, 'to-aoa-m3-receive.mjs'), join(DATA, 'positive.jsonl'), d], { stdio: 'pipe' }),
      (e) => e.status === 1 && /not empty/.test(e.stderr.toString()));
    assert.deepEqual(readdirSync(d), ['x']);
  } finally {
    rmSync(d, { recursive: true, force: true });
  }
});

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
  for (const [field, value] of [['actualGasCost', '1'], ['actualGasUsed', '1'], ['success', false], ['nonce', '9'],
    ['sender', '0x' + '44'.repeat(20)], ['paymaster', '0x' + '55'.repeat(20)]]) {
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

test('runType is formal-candidate only for a protocolConformant a6-gauge/2 run', () => {
  const rows = rowsOf('positive.jsonl');
  assert.equal(exportRows(rows).runType, 'rehearsal');
  rows[0].protocolConformant = true;
  assert.equal(exportRows(rows).runType, 'rehearsal', 'a /1 run never recorded credit OFF');
  for (const r of rows) r.schema = 'a6-gauge/2';
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

const uoeLog = (r) => r.logs.find((l) => l.topics[0].toLowerCase() === UOE_TOPIC);
const setWord = (data, i, hex64) => data.slice(0, 2 + 64 * i) + hex64 + data.slice(2 + 64 * (i + 1));

test('gas evidence must be consistent on every arm', () => {
  for (const arm of ['SP', 'VPM', 'TPM']) {
    const rows = rowsOf('positive.jsonl');
    const r = rows.find((x) => x.kind === 'attempt' && x.arm === arm);
    const l = uoeLog(r);
    l.data = setWord(l.data, 3, '0'.repeat(64));  // actualGasUsed = 0 in the log ...
    r.userOpEvent.actualGasUsed = '0';             // ... and in the summary, so the two still agree
    refused(rows, /inconsistent with the op's fee caps/);
  }
  const rows = rowsOf('positive.jsonl');
  const r = rows.find((x) => x.kind === 'attempt' && x.arm === 'TPM');
  const l = uoeLog(r);
  const doubled = (BigInt('0x' + l.data.slice(2 + 128, 2 + 192)) * 2n).toString(16).padStart(64, '0');
  l.data = setWord(l.data, 2, doubled);  // cost no longer equals used x a price within the caps
  r.userOpEvent.actualGasCost = BigInt('0x' + doubled).toString();
  refused(rows, /inconsistent with the op's fee caps/);
});

test('a price capped at maxFeePerGas must be reachable', () => {
  const rows = rowsOf('positive.jsonl');
  const r = rows.find((x) => x.kind === 'attempt' && x.arm === 'VPM');
  const l = uoeLog(r);
  const used = BigInt('0x' + l.data.slice(2 + 192, 2 + 256));
  const cost = used * BigInt(r.gas.maxFeePerGas);  // 20 gwei: needs basefee >= 18 gwei, but the tx paid ~1 gwei
  l.data = setWord(l.data, 2, cost.toString(16).padStart(64, '0'));
  r.userOpEvent.actualGasCost = cost.toString();
  refused(rows, /inconsistent with the op's fee caps/);
  // Reachable cap: same cost with a bundle price high enough for that basefee.
  const ok = rowsOf('positive.jsonl');
  const v = ok.find((x) => x.kind === 'attempt' && x.arm === 'VPM');
  const lv = uoeLog(v);
  lv.data = setWord(lv.data, 2, cost.toString(16).padStart(64, '0'));
  v.userOpEvent.actualGasCost = cost.toString();
  v.tx.effectiveGasPrice = (BigInt(v.gas.maxFeePerGas) - BigInt(v.gas.maxPriorityFeePerGas)).toString();
  assert.equal(exportRows(ok).attempts.filter((a) => a.included).length, 3);
});

test('a per-gas price above maxFeePerGas is refused', async () => {
  const { gasConsistent } = await import('./to-aoa-m3-receive.mjs');
  const gas = { maxFeePerGas: '10', maxPriorityFeePerGas: '1' };
  assert.equal(gasConsistent({ actualGasCost: '12000', actualGasUsed: '1000' }, gas, 20n), false);  // price 12 > 10
  assert.equal(gasConsistent({ actualGasCost: '5000', actualGasUsed: '1000' }, gas, 20n), true);    // price 5, basefee 4
});

test('tx.gasUsed above tx.gasLimit refuses the export', () => {
  const rows = rowsOf('positive.jsonl');
  const vpm = rows.find((x) => x.kind === 'attempt' && x.arm === 'VPM');
  vpm.tx.gasUsed = '999999999999999';
  refused(rows, /at most tx\.gasLimit/);
});

test('tx.gasUsed equal to tx.gasLimit is accepted', () => {
  const rows = rowsOf('positive.jsonl');
  const vpm = rows.find((x) => x.kind === 'attempt' && x.arm === 'VPM');
  vpm.tx.gasUsed = vpm.tx.gasLimit;
  assert.equal(exportRows(rows).attempts.filter((a) => a.included).length, 3);
});

test('a successful UOE whose cost does not divide by gas used is refused', () => {
  const rows = rowsOf('positive.jsonl');
  const r = rows.find((x) => x.kind === 'attempt' && x.arm === 'VPM');
  const l = uoeLog(r);
  const cost = BigInt('0x' + l.data.slice(2 + 128, 2 + 192)) + 1n;
  l.data = setWord(l.data, 2, cost.toString(16).padStart(64, '0'));
  r.userOpEvent.actualGasCost = cost.toString();
  refused(rows, /inconsistent with the op's fee caps/);
});

test('the gas check follows the decoded UOE, not the collector verdict', () => {
  // An excluded row (verdict not success) whose log still says success is checked like any successful UOE.
  const rows = rowsOf('positive.jsonl');
  const r = rows.find((x) => x.kind === 'attempt' && x.arm === 'VPM');
  r.verdict = 'USEROP_REVERTED';
  const l = uoeLog(r);
  l.data = setWord(l.data, 2, (BigInt('0x' + l.data.slice(2 + 128, 2 + 192)) + 1n).toString(16).padStart(64, '0'));
  refused(rows, /inconsistent with the op's fee caps/);
});

test('a failed UOE with a non-dividing prefund cost is excluded, not a refused run', () => {
  const rows = rowsOf('positive.jsonl');
  const r = rows.find((x) => x.kind === 'attempt' && x.arm === 'TPM');
  const l = uoeLog(r);
  l.data = setWord(l.data, 1, '0'.repeat(64));                      // success = false
  const used = BigInt('0x' + l.data.slice(2 + 192, 2 + 256));
  l.data = setWord(l.data, 2, (used * 3n + 1n).toString(16).padStart(64, '0'));  // prefund, not a multiple
  r.verdict = 'USEROP_REVERTED';
  const pkg = exportRows(rows);
  const tpm = pkg.attempts.find((a) => a.paymasterKind === 'TokenPaymaster');
  assert.equal(tpm.included, false);
  assert.match(tpm.exclusionReason, /UOE_FAILED/);
});

test('receipt numbers must be decimal strings', () => {
  for (const [field, value] of [['gasUsed', false], ['effectiveGasPrice', false], ['gasUsed', '0x10'], ['gasUsed', '0']]) {
    const rows = rowsOf('positive.jsonl');
    spRow(rows).tx[field] = value;
    refused(rows, field === 'gasUsed' && value === '0' ? /must be positive/ : /not a decimal string/);
  }
});

test('address topics must be canonically padded', () => {
  const rows = rowsOf('positive.jsonl');
  const l = uoeLog(spRow(rows));
  l.topics[2] = '0x' + 'ff'.repeat(12) + l.topics[2].slice(26);
  refused(rows, /non-canonical address topic 2/);
});

test('per-arm controls are derived per arm, so a differing arm is visible to the checker', () => {
  const rows = rowsOf('positive.jsonl');
  const vpm = rows.find((x) => x.kind === 'attempt' && x.arm === 'VPM');
  vpm.gas = { ...vpm.gas, callGasLimit: String(Number(vpm.gas.callGasLimit) + 1) };
  const pkg = exportRows(rows);
  assert.equal(new Set(pkg.attempts.map((a) => a.bundlerConfigHash)).size, 2);
  // A different account, consistent across the row, its summary and its log, still differs from the passport.
  const other = rowsOf('positive.jsonl');
  const tpm = other.find((x) => x.kind === 'attempt' && x.arm === 'TPM');
  const acct = '0x' + '66'.repeat(20);
  tpm.sender = acct;
  tpm.userOpEvent.sender = acct;
  uoeLog(tpm).topics[2] = '0x' + '0'.repeat(24) + acct.slice(2);
  refused(other, /sender is not the passport account/);
});

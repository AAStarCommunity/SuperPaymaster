// Offline tests for the opt-in Keychain/pty keystore password source of castSigner.
// Fake `security` is injected through a test driver; fake `cast` uses PATH. The real keychain
// and real keystores are never touched.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { privateKeyToAccount } from 'viem/accounts';
import * as formal from './formal.mjs';
import { hashMessage } from 'viem';
const { castSigner, formalRuntime } = formal;

const PASSWORD = 'Pw-node-4b1d9e-SENTINEL-do-not-leak';
const raw = `0x${'cd'.repeat(32)}`, hash = hashMessage({ raw });
const fakes = fileURLToPath(new URL('./pty-fakes/', import.meta.url));
const account = privateKeyToAccount(`0x${'6'.repeat(64)}`);

function fakeEnv(keychain) {
  const dir = mkdtempSync(join(tmpdir(), 'a6-keychain-'));
  mkdirSync(join(dir, 'records'));
  for (const name of ['cast', 'security']) {
    writeFileSync(join(dir, name), readFileSync(join(fakes, `fake_${name}.py`)));
    chmodSync(join(dir, name), 0o755);
  }
  writeFileSync(join(dir, 'keychain.json'), JSON.stringify(keychain));
  const records = prefix => readdirSync(join(dir, 'records')).filter(f => f.startsWith(`${prefix}-`)).map(f => JSON.parse(readFileSync(join(dir, 'records', f), 'utf8')));
  const runs = [];
  const run = mode => (cmd, args, opts) => {
    const env = { ...process.env, PATH: `${dir}:${process.env.PATH}`, FAKE_DIR: dir, FAKE_CAST_MODE: mode, FAKE_CAST_SIG: sig };
    runs.push({ cmd, args, opts, env });
    // stderr is captured here (not inherited) so the test can scan it.
    return execFileSync('/usr/bin/python3', ['-I', '-B', join(fakes, 'run_helper.py'), join(dir, 'security'), ...args.slice(3)], { ...opts, stdio: [opts.stdio[0], 'pipe', 'pipe'], env });
  };
  return { dir, records, run, runs, close: () => rmSync(dir, { recursive: true, force: true }) };
}
let sig;
test.before(async () => { sig = await account.signMessage({ message: { raw } }); });

const noPassword = (...blobs) => { for (const b of blobs) assert.ok(!JSON.stringify(b ?? null).includes(PASSWORD), 'password leaked'); };

test('default source keeps the exact cast argv and /dev/tty stdio', async () => {
  const calls = [];
  const signer = castSigner({ name: 'rq3-bundler', address: account.address }, 'bundler', (cmd, args, opts) => { calls.push({ cmd, args, opts }); return `${sig}\n`; });
  assert.equal(await signer.signMessage({ message: { raw } }), sig);
  assert.deepEqual(calls, [{ cmd: 'cast', args: ['wallet', 'sign', '--account', 'rq3-bundler', '--no-hash', hash], opts: { encoding: 'utf8', stdio: ['inherit', 'pipe', 'pipe'] } }]);
  const explicit = [];
  await castSigner({ name: 'rq3-bundler', address: account.address, keystorePasswordSource: 'tty' }, 'bundler', (cmd, args, opts) => { explicit.push({ cmd, args, opts }); return sig; }).signMessage({ message: { raw } });
  assert.deepEqual(explicit, calls);
});

test('unknown password source is refused before any spawn', () => {
  for (const source of ['file', 'env', 'Keychain', '', null]) {
    let spawned = false;
    assert.throws(() => castSigner({ name: 'x', address: account.address, keystorePasswordSource: source }, 'owner', () => { spawned = true; }), /password source/);
    assert.equal(spawned, false);
  }
});

test('keychain source routes the identical cast argv through the pty helper', async () => {
  const calls = [];
  const signer = castSigner({ name: 'rq3-bundler', address: account.address, keystorePasswordSource: 'keychain' }, 'bundler', (cmd, args, opts) => { calls.push({ cmd, args, opts }); return `${sig}\n`; });
  assert.equal(await signer.signMessage({ message: { raw } }), sig);
  assert.equal(calls.length, 1);
  const [{ cmd, args, opts }] = calls;
  assert.equal(cmd, '/usr/bin/python3');
  let injected;
  await castSigner({ name: 'rq3-bundler', address: account.address, keystorePasswordSource: 'keychain' }, 'bundler', cmd => { injected = cmd; return sig; }, '/test/python').signMessage({ message: { raw } });
  assert.equal(injected, '/test/python');
  assert.deepEqual(args, ['-I', '-B', formal.KEYCHAIN_HELPER, 'cast', 'wallet', 'sign', '--account', 'rq3-bundler', '--no-hash', hash]);
  assert.equal(opts.stdio[0], 'ignore');
  assert.equal(opts.env, undefined, 'no extra environment is handed to the helper');
});

test('keychain end to end: injected security + fake cast on PATH, password never surfaces', async () => {
  const f = fakeEnv({ 'aastar-rq3-keystore|rq3-bundler': PASSWORD });
  try {
    const signer = castSigner({ name: 'rq3-bundler', address: account.address, keystorePasswordSource: 'keychain' }, 'bundler', f.run('normal'));
    assert.equal(await signer.signMessage({ message: { raw } }), sig);
    const [cast] = f.records('cast');
    assert.equal(cast.early_input, false, 'password written while ECHO was on');
    assert.deepEqual(cast.argv.slice(1), ['wallet', 'sign', '--account', 'rq3-bundler', '--no-hash', hash]);
    assert.deepEqual(f.records('security')[0].argv.slice(1), ['find-generic-password', '-s', 'aastar-rq3-keystore', '-a', 'rq3-bundler', '-w']);
    noPassword(f.runs.map(r => [r.args, r.env]), f.records('cast').map(r => [r.argv, r.env]), f.records('security').map(r => [r.argv, r.env]));

    for (const mode of ['leaky-stdout', 'fail']) {
      let error;
      await assert.rejects(castSigner({ name: 'rq3-bundler', address: account.address, keystorePasswordSource: 'keychain' }, 'bundler', f.run(mode)).signMessage({ message: { raw } }), e => { error = e; return true; });
      assert.equal(error.message, 'keystore signing failed (redacted)');
      noPassword(error.message, error.stack, Object.getOwnPropertyNames(error).map(k => String(error[k])), error.cause);
    }
    // Captured helper stdout/stderr of a leaky cast: signature only, nothing else.
    const out = f.run('leaky')('python3', ['-I', '-B', formal.KEYCHAIN_HELPER, 'cast', 'wallet', 'sign', '--account', 'rq3-bundler', '--no-hash', hash], { encoding: 'utf8', stdio: ['ignore'] });
    assert.equal(out, `${sig}\n`);
  } finally { f.close(); }
});

test('keychain: missing entry fails closed, no cast spawn, no fallback to /dev/tty', async () => {
  const f = fakeEnv({ 'aastar-rq3-keystore|someone-else': PASSWORD });
  try {
    let error;
    await assert.rejects(castSigner({ name: 'rq3-bundler', address: account.address, keystorePasswordSource: 'keychain' }, 'bundler', f.run('normal')).signMessage({ message: { raw } }), e => { error = e; return true; });
    assert.equal(error.message, 'keystore signing failed (redacted)');
    assert.deepEqual(f.runs.map(r => r.cmd), ['/usr/bin/python3'], 'exactly one helper spawn, no direct cast fallback');
    assert.deepEqual(f.records('cast'), []);
    noPassword(error.message, error.stack);
  } finally { f.close(); }
});

test('formalRuntime threads keystorePasswordSource into every signer config and refuses a conflict', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'a6-keychain-rt-'));
  try {
    for (const e of ['a', 'b']) writeFileSync(join(dir, e), `https://${e}.invalid/secret`);
    const accounts = Object.fromEntries(['owner', 'bundler', 'verifyingSigner'].map((r, i) => [r, { name: r, address: privateKeyToAccount(`0x${String(i + 1).repeat(64)}`).address }]));
    const base = { resolver: async h => [{ address: h.startsWith('a') ? '8.8.8.8' : '1.1.1.1' }], rpcAFile: join(dir, 'a'), rpcBFile: join(dir, 'b'), fetchImpl: async () => { throw Error('no RPC expected'); } };
    const seen = [];
    let window = 0;
    const rt = args => formalRuntime({ ...base, outPath: join(dir, `w${window++}`, 'run'), ...args });
    const createSigner = c => { seen.push(c); return privateKeyToAccount(`0x${String(['owner', 'bundler', 'verifyingSigner'].indexOf(c.name) + 1).repeat(64)}`); };
    await rt({ config: { chainId: 1, accounts }, createSigner, keystorePasswordSource: 'keychain' });
    assert.deepEqual(seen.map(c => c.keystorePasswordSource), ['keychain', 'keychain', 'keychain']);
    assert.ok(Object.values(accounts).every(c => !('keystorePasswordSource' in c)), 'caller config is not mutated');
    seen.length = 0;
    await rt({ config: { chainId: 1, accounts }, createSigner });
    assert.deepEqual(seen, Object.values(accounts), 'default leaves the account configs untouched');
    await assert.rejects(rt({ config: { chainId: 1, accounts: { ...accounts, owner: { ...accounts.owner, keystorePasswordSource: 'tty' } } }, createSigner, keystorePasswordSource: 'keychain' }), /password source/);
    await assert.rejects(rt({ config: { chainId: 1, accounts }, createSigner, keystorePasswordSource: 'file' }), /password source/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

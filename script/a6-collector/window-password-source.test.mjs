import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { getAddress } from 'viem';
import * as formal from './formal.mjs';

const source = readFileSync(new URL('./collector.mjs', import.meta.url), 'utf8');
// Run the collector's actual config preflight and window initialization, as in end-checks.test.mjs.
// All signer and transport boundaries are injected; no subprocess or RPC can run.
async function windowOwners(cliSource, ownSources = [undefined, undefined, undefined], identity = {}) {
  const calls = [], processes = [];
  const senders = ownSources.map((own, i) => ({
    sender: `0x${String(i + 1).repeat(40)}`, salt: i,
    owner: { name: `owner-${i}`, address: `0x${String(i + 4).repeat(40)}`,
      ...(own === undefined ? {} : { keystorePasswordSource: own }) },
  }));
  const context = {
    scheduled: true, formal: true, formalInput: { senders, accounts: {} }, getAddress,
    withPasswordSource: formal.withPasswordSource,
    argVal: flag => flag === '--keystore-password-source' ? cliSource : undefined,
    rehearsal: false, adapter: {}, outPath: '/offline/run.jsonl', window: {},
    owners: new Map(), senderPassports: new Map(), senderPassportRefs: new Map(),
    castSigner: async (config, role) => {
      calls.push({ ...config, role });
      return { type: 'local', address: config.address, ...identity,
        sign: () => processes.push(config.name) };
    },
    formalRuntime: async () => {
      processes.push('runtime');
      return { refreshPin: async () => ({ timestamp: 1 }) };
    },
    selectSender: sender => { context.sender = sender; },
    setup: async () => context.owners.get(context.sender).sign(),
    passportAB: async () => ({}), savePassport: () => 'offline',
    writeArtifact() {}, windowPath: '/offline', runId: 'offline',
  };
  context.adapter.beforeSend = async () => {};
  const configs = source.slice(source.indexOf('const senderConfigs ='), source.indexOf('const window ='));
  const runtime = source.slice(source.indexOf('const runtime = formal ?'), source.indexOf('let frozenArm,'));
  const main = source.indexOf('// ── main');
  const windowInit = source.slice(source.indexOf('  if (window) {', main), source.indexOf('  passportStart = window ?', main));
  let error;
  try {
    await vm.runInNewContext(`(async()=>{${configs}\n${runtime}\nlet windowStart;\n${windowInit}})()`, context);
  } catch (e) { error = e; }
  return { calls, processes, error, senders };
}

test('window CLI keychain reaches all three rotating owner constructors', async () => {
  const result = await windowOwners('keychain');
  assert.ifError(result.error);
  assert.equal(result.calls.length, 3);
  assert.deepEqual(result.calls.map(c => c.keystorePasswordSource), ['keychain', 'keychain', 'keychain']);
  assert.ok(result.senders.every(s => !('keystorePasswordSource' in s.owner)));
});

for (const index of [0, 1, 2]) test(`window owner ${index} conflict refuses before any signer process starts`, async () => {
  const own = [undefined, undefined, undefined];
  own[index] = 'tty';
  const result = await windowOwners('keychain', own);
  assert.match(result.error?.message ?? '', /conflicting keystore password source/);
  assert.deepEqual(result.calls, []);
  assert.deepEqual(result.processes, []);
});

test('window without CLI preserves each owner source and implicit tty default', async () => {
  const result = await windowOwners(undefined, [undefined, 'tty', 'keychain']);
  assert.ifError(result.error);
  assert.deepEqual(result.calls.map(c => c.keystorePasswordSource ?? 'tty'), ['tty', 'tty', 'keychain']);
});

for (const identity of [{ type: 'json-rpc' }, { address: `0x${'9'.repeat(40)}` }]) {
  test(`window rejects owner identity mismatch ${JSON.stringify(identity)}`, async () => {
    const result = await windowOwners(undefined, undefined, identity);
    assert.match(result.error?.message ?? '', /injected signer identity mismatch/);
    assert.deepEqual(result.processes, ['runtime']);
  });
}

test('password source helper validates CLI and returns an unmutated copy', () => {
  const account = Object.freeze({ name: 'owner', keystorePasswordSource: 'tty' });
  assert.notEqual(formal.withPasswordSource(account), account);
  assert.deepEqual(formal.withPasswordSource(account), account);
  assert.deepEqual(formal.withPasswordSource(account, 'tty'), account);
  for (const invalid of ['', null, 'env']) {
    assert.throws(() => formal.withPasswordSource(account, invalid), /unknown keystore password source/);
  }
  assert.throws(() => formal.withPasswordSource(account, 'keychain'), /conflicting keystore password source/);
});

import { redact, requireFork } from './calibration_safety.mjs';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';

// Execute the CLI through its guards with an in-memory RPC stub; no sockets or writes.
const source = readFileSync(new URL('./calibrate_ops.mjs', import.meta.url), 'utf8');
const start = source.indexOf('const [requestPath]');
const end = source.indexOf('const bytes = readFileSync(req.bundlePath)');
const guard = source.slice(start, end).replace(/const EP_ABI = parseAbi\([\s\S]*?const lower = v => String\(v\).toLowerCase\(\);/, '');
async function run(url, chain) {
  let calls = 0;
  const context = vm.createContext({
    redact, requireFork: (req, rpc) => requireFork(req, rpc, () => {}),
    process: { argv: ['node', 'helper', 'request'] },
    readFileSync: () => JSON.stringify({ forkUrl: url, forkPid: 123, forkPin: 456 }),
    getAddress: x => x,
    fetch: async (_, options) => { calls++; const { method } = JSON.parse(options.body); return { json: async () => ({ result: method === 'web3_clientVersion' ? 'anvil/v1' : method === 'anvil_nodeInfo' ? { forkConfig: { forkBlockNumber: 456 } } : `0x${chain.toString(16)}` }) }; },
  });
  await vm.runInContext(`(async () => { ${guard} })()`, context);
  return calls;
}
for (const chain of [11155111, 11155420]) {
  test(`accept local chain ${chain}`, async () => assert.equal(await run('http://127.0.0.1:18555', chain), 3));
}
test('reject other chain', async () => assert.rejects(run('http://127.0.0.1:18555', 31337), /chainId/));
for (const url of ['https://example.com', 'http://localhost:18555', 'http://127.0.0.1:18555@evil.test']) {
  test(`reject URL ${url}`, async () => assert.rejects(run(url, 11155420), /fork URL/));
}

test('RPC errors never print upstream URL or data', async () => {
  const context = vm.createContext({
    redact, requireFork: (req, rpc) => requireFork(req, rpc, () => {}),
    process: { argv: ['node', 'helper', 'request'] },
    readFileSync: () => JSON.stringify({ forkUrl: 'http://127.0.0.1:18555' }),
    getAddress: x => x,
    fetch: async () => ({ json: async () => ({ error: {
      message: 'https://host/v2/SECRET wss://host/SECRET', data: 'SECRET',
    }, result: '0xaa37dc' }) }),
  });
  await assert.rejects(vm.runInContext(`(async () => { ${guard} })()`, context), error => {
    assert.doesNotMatch(String(error) + JSON.stringify(error), /SECRET/);
    return true;
  });
});

for (const [client, pin, dead] of [['geth/v1', 456, false], ['anvil/v1', 457, false], ['anvil/v1', 456, true]]) {
  test(`refuse foreign/stale fork ${client} ${pin} ${dead}`, async () => {
    const rpc = async method => method === 'web3_clientVersion' ? client : { forkConfig: { forkBlockNumber: pin } };
    await assert.rejects(requireFork({ forkPid: 123, forkPin: 456 }, rpc, () => { if (dead) throw Error(); }), /live child anvil/);
  });
}
test('metadata fallback and child exit during verification', async () => {
  const rpc = async method => {
    if (method === 'web3_clientVersion') return 'anvil/v1';
    if (method === 'anvil_nodeInfo') throw Error();
    return { forkedNetwork: { forkBlockNumber: '0x1c8' } };
  };
  await requireFork({ forkPid: 123, forkPin: 456 }, rpc, () => {});
  let calls = 0;
  await assert.rejects(requireFork({ forkPid: 123, forkPin: 456 }, rpc, () => { if (++calls === 2) throw Error(); }));
});
test('shared redaction covers every URL scheme and opaque file contents', () => {
  assert.doesNotMatch(redact('HTTP://host/SECRET https://host/v2/SECRET ws://host/SECRET WSS://host/SECRET'), /SECRET/);
  assert.doesNotMatch(redact('BARE_FILE_SECRET', true), /SECRET/);
});
test('direct helper invocation requires a child PID and pin', async () => {
  await assert.rejects(requireFork({}, async () => { throw Error('must not call'); }), /PID and fork pin required/);
});

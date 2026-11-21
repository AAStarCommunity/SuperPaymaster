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
    process: { argv: ['node', 'helper', 'request'] },
    readFileSync: () => JSON.stringify({ forkUrl: url }),
    getAddress: x => x,
    fetch: async () => { calls++; return { json: async () => ({ result: `0x${chain.toString(16)}` }) }; },
  });
  await vm.runInContext(`(async () => { ${guard} })()`, context);
  return calls;
}
for (const chain of [11155111, 11155420]) {
  test(`accept local chain ${chain}`, async () => assert.equal(await run('http://127.0.0.1:18555', chain), 1));
}
test('reject other chain', async () => assert.rejects(run('http://127.0.0.1:18555', 31337), /chainId/));
for (const url of ['https://example.com', 'http://localhost:18555', 'http://127.0.0.1:18555@evil.test']) {
  test(`reject URL ${url}`, async () => assert.rejects(run(url, 11155420), /fork URL/));
}

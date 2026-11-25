import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';
import { waitForHead } from './window-reads.mjs';

// Runs collector.mjs's own lines from A's receipt wait through B's single receipt read.
const source = readFileSync(new URL('./collector.mjs', import.meta.url), 'utf8');
const snippet = source.slice(source.indexOf('  const rcA = await pubA.waitForTransactionReceipt'), source.indexOf('\n', source.indexOf('  const rcB = await pubB.getTransactionReceipt')));
class Stop extends Error { constructor(reason, code, detail) { super(reason); this.reason = reason; this.code = code; this.detail = detail; } }
async function run({ heads, receiptB = { status: 'success' } }) {
  const calls = [];
  const pubA = { waitForTransactionReceipt: async args => { calls.push(['A receipt', args.pollingInterval]); return { blockNumber: 100n }; } };
  const pubB = {
    getBlockNumber: async () => { const h = heads.length > 1 ? heads.shift() : heads[0]; calls.push(['B head', h]); return h; },
    getTransactionReceipt: async () => { calls.push(['B receipt']); if (!receiptB) throw new Error('TransactionReceiptNotFoundError'); return receiptB; },
  };
  const context = { pubA, pubB, txHash: '0x' + 'ab'.repeat(32), Stop, waitForHead: (c, b) => waitForHead(c, b, { timeoutMs: 60, pollMs: 5 }) };
  let error = null;
  try { await vm.runInNewContext(`(async()=>{${snippet}\nreturn rcB;})()`, context); } catch (e) { error = e; }
  return { calls, error };
}

test('A has the receipt and B is behind: wait for B to reach the block, then read once', async () => {
  const { calls, error } = await run({ heads: [98n, 99n, 100n] });
  assert.equal(error, null);
  assert.deepStrictEqual(calls, [['A receipt', 1000], ['B head', 98n], ['B head', 99n], ['B head', 100n], ['B receipt']]);
});
test('B never reaches the receipt block: stop at the timeout with a clear reason, no receipt read', async () => {
  const { calls, error } = await run({ heads: [99n] });
  assert.ok(error instanceof Stop);
  assert.equal(error.reason, 'RECEIPT_B_HEAD_BEHIND'); assert.equal(error.code, 25);
  assert.equal(error.detail.receiptBlock, 100n); assert.equal(error.detail.headB, 99n);
  assert.ok(!calls.some(c => c[0] === 'B receipt'));
});
test('B at the receipt block but without the receipt still fails closed on the one read', async () => {
  const { calls, error } = await run({ heads: [100n], receiptB: null });
  assert.match(String(error), /TransactionReceiptNotFoundError/);
  assert.equal(calls.filter(c => c[0] === 'B receipt').length, 1);
});
test('a transport error while polling B is not turned into a head timeout', async () => {
  const pubB = { getBlockNumber: async () => { throw new Error('RPC B transport failed (redacted)'); } };
  await assert.rejects(waitForHead(pubB, 1n, { timeoutMs: 10, pollMs: 1 }), e => e.head === undefined && /transport/.test(e.message));
});

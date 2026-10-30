import test from 'node:test';
import assert from 'node:assert/strict';
import { INNER_HANDLE_OP, decomposeGas, exactClaimMatches } from './gas-decomposition.mjs';

const address = n => '0x' + n.repeat(40);
export function syntheticTrace({ execution = 105n, preOp = 1000n, call = 100n, post = 200n } = {}) {
  const ep = address('1'), sender = address('2'), pm = address('3'), hash = '0x' + '44'.repeat(32);
  const words = [512n, sender, 0n, 300n, call, 400n, post, 60n, pm, 20n, 2n, hash, 999999n, 0n, preOp, 544n, 0n, 0n];
  const input = INNER_HANDLE_OP + words.map(v => BigInt(v).toString(16).padStart(64, '0')).join('');
  const row = { entryPoint: ep, sender, paymaster: pm, nonce: '0', expectedUserOpHash: hash,
    gas: { callGasLimit: String(call) }, pmGas: { post: String(post) }, tx: { hash, blockHash: hash },
    gasTrace: { tracer: 'callTracer', transactionHash: hash, blockHash: hash,
      result: { type: 'CALL', to: ep, calls: [{ type: 'CALL', from: ep, to: ep, input }] } } };
  const L = call + post;
  const uoe = { actualGasUsed: String(preOp + execution + (L > execution ? (L - execution) / 10n : 0n)) };
  return { row, uoe };
}

test('trace uniquely derives a positive unused-gas penalty and exact reconstruction', () => {
  const { row, uoe } = syntheticTrace();
  const d = decomposeGas(row, uoe);
  assert.equal(d.status, 'exact');
  assert.equal(d.executionGasUsed, '105');
  assert.equal(d.preOpGas, '1000');
  assert.equal(d.unusedGasPenalty, '19');
  assert.equal(BigInt(d.actualGasUsed), BigInt(d.preOpGas) + BigInt(d.executionGasUsed) + BigInt(d.unusedGasPenalty));
  assert.equal(exactClaimMatches(d, d), true);
});

test('L <= E has exactly zero penalty', () => {
  for (const execution of [300n, 301n]) {
    const { row, uoe } = syntheticTrace({ execution });
    const d = decomposeGas(row, uoe);
    assert.equal(d.status, 'exact');
    assert.equal(d.executionGasUsed, String(execution));
    assert.equal(d.unusedGasPenalty, '0');
  }
});

test('missing trace has null derived fields and a reason, never zero', () => {
  const { row, uoe } = syntheticTrace();
  delete row.gasTrace;
  const d = decomposeGas(row, uoe);
  for (const k of ['executionGasUsed', 'preOpGas', 'unusedGasPenalty']) assert.equal(d[k], null);
  assert.equal(d.status, 'unavailable');
  assert.match(d.reason, /no debug_traceTransaction/);
});

test('rounding ambiguity is bounded by one gas, never reported exact', () => {
  const { row, uoe } = syntheticTrace({ execution: 100n });
  const d = decomposeGas(row, uoe);
  assert.equal(d.status, 'bounded');
  assert.equal(d.executionGasUsed, null);
  assert.equal(d.unusedGasPenalty, null);
  assert.deepEqual(d.bounds, { executionGasUsed: ['100', '101'], unusedGasPenalty: ['19', '20'] });
});

test('impossible reconstruction is flagged; a changed exact claim is rejected', () => {
  const { row, uoe } = syntheticTrace();
  const d = decomposeGas(row, uoe);
  assert.equal(exactClaimMatches({ ...d, executionGasUsed: '106' }, d), false);
  const bad = decomposeGas(row, { actualGasUsed: '999' });
  assert.equal(bad.status, 'mismatch');
  assert.equal(bad.reconstructionMatches, false);
});

test('trace binding, reverted self-call and missing frame fail closed', () => {
  for (const mutate of [r => { r.gasTrace.transactionHash = '0x00'; }, r => { r.gasTrace.blockHash = '0x00'; }]) {
    const { row, uoe } = syntheticTrace();
    mutate(row);
    assert.equal(decomposeGas(row, uoe).status, 'mismatch');
  }
  const { row, uoe } = syntheticTrace();
  row.gasTrace.result.calls[0].error = 'execution reverted';
  assert.equal(decomposeGas(row, uoe).status, 'unavailable');
  row.gasTrace.result.calls = [];
  assert.equal(decomposeGas(row, uoe).status, 'unavailable');
});

test('inverse agrees with exhaustive integer candidates at rounding boundaries', () => {
  for (let execution = 0n; execution <= 305n; execution++) {
    const { row, uoe } = syntheticTrace({ execution });
    const d = decomposeGas(row, uoe);
    const candidates = [];
    for (let E = 0n; E <= 305n; E++) if (1000n + E + (E < 300n ? (300n - E) / 10n : 0n) === BigInt(uoe.actualGasUsed)) candidates.push(String(E));
    if (candidates.length === 1) {
      assert.equal(d.status, 'exact');
      assert.equal(d.executionGasUsed, candidates[0]);
    } else {
      assert.equal(d.status, 'bounded');
      assert.deepEqual(d.bounds.executionGasUsed, candidates);
    }
  }
});

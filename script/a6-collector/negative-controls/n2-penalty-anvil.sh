#!/usr/bin/env bash
# Read-only positive control. Requires an existing --trace run and its still-running Anvil.
# Usage: n2-penalty-anvil.sh http://127.0.0.1:8545 path/to/run.jsonl
set -euo pipefail
cd "$(dirname "$0")/../../.."
node --input-type=module - "$@" <<'JS'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { decomposeGas, exactClaimMatches } from './script/a6-collector/gas-decomposition.mjs';
import { decodeUoe } from './script/a6-collector/to-aoa-m3-receive.mjs';
const [url, file] = process.argv.slice(2);
assert.ok(url && file, 'usage: n2-penalty-anvil.sh <anvil-rpc> <run.jsonl>');
let id = 0;
async function rpc(method, params) {
  const response = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }), signal: AbortSignal.timeout(60000) });
  assert.ok(response.ok, `HTTP ${response.status}`);
  const body = await response.json();
  assert.ok(!body.error, `${method} failed`);
  return body.result;
}
const rows = readFileSync(file, 'utf8').split('\n').filter(Boolean).map(JSON.parse);
const attempts = rows.filter(r => r.kind === 'attempt');
assert.ok(attempts.length, 'no attempts');
let failures = 0;
for (const r of attempts) {
  try {
    assert.ok(r.sent && r.gasTrace?.result, 'attempt has no collected trace/transaction');
    const receipt = await rpc('eth_getTransactionReceipt', [r.tx.hash]);
    assert.equal(receipt.blockHash.toLowerCase(), r.tx.blockHash.toLowerCase(), 'block changed');
    const uoe = decodeUoe(receipt.logs, r.entryPoint, r.expectedUserOpHash);
    assert.equal(uoe.count, 1, 'need one live UOE');
    const archived = decodeUoe(r.logs, r.entryPoint, r.expectedUserOpHash);
    const normalize = e => ({ ...e, logIndex: String(BigInt(e.logIndex)) });
    assert.deepEqual(normalize(uoe), normalize(archived), 'live UOE differs from archive');
    const live = { ...r, gasTrace: { ...r.gasTrace,
      result: await rpc('debug_traceTransaction', [r.tx.hash, { tracer: 'callTracer' }]) } };
    const d = decomposeGas(live, uoe);
    assert.deepEqual(d, decomposeGas(r, archived), 'live and archived decomposition differ');
    assert.ok(exactClaimMatches(r.gasDecomposition, d), 'stored exact claim disagrees');
    assert.ok(d.status === 'exact' || d.status === 'bounded', `no decomposition: ${d.reason}`);
    const eLo = BigInt(d.status === 'exact' ? d.executionGasUsed : d.bounds.executionGasUsed[0]);
    if (d.status === 'exact') {
      assert.equal(BigInt(d.actualGasUsed), BigInt(d.preOpGas) + eLo + BigInt(d.unusedGasPenalty));
    } else {
      assert.equal(BigInt(d.bounds.executionGasUsed[1]) - eLo, 1n, 'bounded width must be one gas');
    }
    // Independent cross-check: E is derived algebraically from actualGasUsed, so compare it with
    // the callTracer innerHandleOp frame. The frame also covers the tail after the penalty
    // (event, deposit update), so tail = frame.gasUsed - E must be positive and small.
    const inner = [];
    const own = i => i?.toLowerCase().startsWith('0x0042dc53') && ('0x' + i.slice(10 + 64 * 11, 10 + 64 * 12)).toLowerCase() === r.expectedUserOpHash.toLowerCase();
    const walk = f => { if (own(f.input)) inner.push(f); (f.calls || []).forEach(walk); };
    walk(live.gasTrace.result);
    assert.equal(inner.length, 1, 'need one innerHandleOp frame');
    const tail = BigInt(inner[0].gasUsed) - eLo;
    assert.ok(tail > 0n && tail < 20000n, `innerHandleOp tail out of range: ${tail}`);
    console.log(JSON.stringify({ arm: r.arm, attempt: r.attemptIndex, innerHandleOpTail: String(tail), ...d }));
  } catch (e) {
    failures++;
    console.error(`${r.arm}/${r.attemptIndex}: ${e.message}`);
  }
}
console.log(JSON.stringify({ attempts: attempts.length, decomposed: attempts.length - failures, failures }));
process.exitCode = failures ? 1 : 0;
JS

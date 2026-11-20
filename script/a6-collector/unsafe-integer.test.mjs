// DSR 2026-11-19: plan integers are JSON numbers; values above 2^53 must be read losslessly. A plain
// JSON.parse rounds 9007199254740993 to 9007199254740992 and the rounded value still looks like an integer.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parse } from './frozen-plan.mjs';

const vector = JSON.parse(readFileSync(new URL('../rq3op/sdk-cost-vector.json', import.meta.url), 'utf8')).unsafeIntegerVector;

test('frozen-plan parse keeps integers above 2^53 exact', () => {
  const cost = vector.inputs.maxCost, xmax = vector.Xmax;
  assert.ok(BigInt(cost) > 2n ** 53n);
  const text = `{"shared":{"sdkLive":{"maxCostPerOpWei":${cost},"Xmax":${xmax}}}}`;
  const live = parse(Buffer.from(text)).shared.sdkLive;
  assert.equal(typeof live.maxCostPerOpWei, 'bigint');
  assert.equal(live.maxCostPerOpWei.toString(), cost);
  assert.equal(live.Xmax.toString(), xmax);
  // Control: the plain parser really loses the low bit, so this test guards something.
  assert.notEqual(BigInt(JSON.parse(text).shared.sdkLive.maxCostPerOpWei), BigInt(cost));
});

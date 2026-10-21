#!/usr/bin/env node
// Recompute the G2 overpay distribution from a raw per-op JSONL export
// (schema: docs/design/aoa-balance-mode/data/README.md).
//
// Usage: node script/evidence/overpay-stats.mjs <export.jsonl> [--json]
//
// Definitions (identical to SuperPaymasterV55Fuzz.t.sol `_checkOps` / `_dist`):
//   per op:   ppm   = floor((charge_eth - G) * 1e6 / G)           (settled ops only)
//   mean:     floor(sum(ppm) / n)                                  (ppm; printed as % with 1 decimal)
//   P95:      nearest-rank: sorted ascending a[ceil(0.95 * n) - 1] (Solidity: a[(n*95+99)/100 - 1])
//   median:   a[floor((n - 1) / 2)]  (lower median)
//   max/min:  a[n-1] / a[0]
// Groups: ALL settled; TIGHT = postOpGasLimit <= MIN_POST_OP_GAS + 50,000 (= 250,000);
//         LARGE = postOpGasLimit >= 1,000,000 (the plan draws 1.0M–1.5M; exp-branch fuzz uses >= 1M).
//
// The script also re-derives every settled op's charge from the raw inputs (P, bufWei, price
// snapshot, a0, feeBps) and charge_eth / overpay_ppm from charge, and fails on any mismatch, so the
// JSONL is checked for internal consistency rather than trusted.
import { readFileSync } from 'node:fs';

const MIN_POST_OP_GAS = 200_000n;
const BPS = 10_000n;

const file = process.argv[2];
const asJson = process.argv.includes('--json');
if (!file) {
  console.error('usage: node script/evidence/overpay-stats.mjs <export.jsonl> [--json]');
  process.exit(2);
}

const ceilDiv = (a, b) => (a + b - 1n) / b;
const lines = readFileSync(file, 'utf8').split('\n').filter((l) => l.trim().length > 0);
const ops = lines.map((l, i) => {
  try {
    return JSON.parse(l);
  } catch (e) {
    throw new Error(`line ${i + 1}: invalid JSON`);
  }
});

let mismatches = 0;
const settled = [];
const counts = { admitted: ops.length, settledBalance: 0, settledCredit: 0, injectedBalance: 0, injectedCredit: 0,
  settledAfterEthMove: 0, settledAfterAMove: 0, settledAtMin: 0 };
const formulas = new Set();
for (const o of ops) {
  formulas.add(o.formula);
  if (!o.settled) {
    if (o.mode === 'BALANCE') counts.injectedBalance++; else counts.injectedCredit++;
    continue;
  }
  if (o.mode === 'BALANCE') counts.settledBalance++; else counts.settledCredit++;
  if (o.ethMovedBeforePostOp) counts.settledAfterEthMove++;
  if (o.aMovedBeforePostOp) counts.settledAfterAMove++;
  if (BigInt(o.postOpGasLimit) === MIN_POST_OP_GAS) counts.settledAtMin++;

  const P = BigInt(o.P), fpg = BigInt(o.feePerGas), bufWei = BigInt(o.bufWei);
  const price = BigInt(o.ethUsd), dec = BigInt(o.ethUsdDecimals), aPrice = BigInt(o.aPriceUSD);
  const fee = BigInt(o.feeBps), a0 = BigInt(o.a0), charge = BigInt(o.charge), G = BigInt(o.G);
  const chargeEth = BigInt(o.charge_eth);
  const scale = 10n ** dec;
  // bufWei = bufGas * feePerGas
  if (BigInt(o.bufGas) * fpg !== bufWei) { mismatches++; console.error('bufWei mismatch', o.userOpHash); }
  // R10-M3 exact charge: aGas = ceil((P + bufWei) * price * 1e18 / (10^dec * aPrice));
  //                      charge = min(a0, ceil(aGas * (BPS + fee) / BPS))
  const aGas = ceilDiv((P + bufWei) * price * 10n ** 18n, scale * aPrice);
  let c = ceilDiv(aGas * (BPS + fee), BPS);
  if (c > a0) c = a0;
  if (c !== charge) { mismatches++; console.error('charge mismatch', o.userOpHash, c, charge); }
  // charge_eth = floor(floor(charge * BPS / (BPS + fee)) * 10^dec * aPrice / (price * 1e18))
  const net = (charge * BPS) / (BPS + fee);
  const eth = (net * scale * aPrice) / (price * 10n ** 18n);
  if (eth !== chargeEth) { mismatches++; console.error('charge_eth mismatch', o.userOpHash); }
  if (eth < G) { mismatches++; console.error('SUBSIDISED op (charge_eth < G)', o.userOpHash); }
  const ppm = ((eth - G) * 1_000_000n) / G;
  if (o.overpay_ppm !== null && BigInt(o.overpay_ppm) !== ppm) { mismatches++; console.error('ppm mismatch', o.userOpHash); }
  settled.push({ ppm, postOpGasLimit: BigInt(o.postOpGasLimit), G, eth });
}

function dist(name, arr) {
  const a = arr.map((x) => x.ppm).sort((x, y) => (x < y ? -1 : x > y ? 1 : 0));
  const n = BigInt(a.length);
  if (n === 0n) return { group: name, n: 0 };
  const sum = a.reduce((s, x) => s + x, 0n);
  const p95Idx = Number((n * 95n + 99n) / 100n - 1n);
  const r = {
    group: name,
    n: Number(n),
    mean_ppm: Number(sum / n),
    p95_ppm: Number(a[p95Idx]),
    max_ppm: Number(a[a.length - 1]),
    min_ppm: Number(a[0]),
    median_ppm: Number(a[Math.floor((a.length - 1) / 2)]),
    sumG_wei: arr.reduce((s, x) => s + x.G, 0n).toString(),
    sumChargeEth_wei: arr.reduce((s, x) => s + x.eth, 0n).toString(),
  };
  return r;
}

const groups = [
  dist('ALL settled', settled),
  dist('postOpGasLimit <= MIN+50k (<= 250000)', settled.filter((x) => x.postOpGasLimit <= MIN_POST_OP_GAS + 50_000n)),
  dist('postOpGasLimit >= 1,000,000 (1.0M-1.5M band)', settled.filter((x) => x.postOpGasLimit >= 1_000_000n)),
];
const pct = (ppm) => (ppm / 10_000).toFixed(1) + '%';

if (asJson) {
  console.log(JSON.stringify({ file, formulas: [...formulas], counts, consistencyMismatches: mismatches, groups }, null, 2));
} else {
  console.log(`file: ${file}`);
  console.log(`formula tag(s): ${[...formulas].join(', ')}`);
  console.log(`admitted ops: ${counts.admitted}; settled BALANCE/CREDIT: ${counts.settledBalance}/${counts.settledCredit}; ` +
    `injected BALANCE/CREDIT: ${counts.injectedBalance}/${counts.injectedCredit}`);
  console.log(`settled after mid-bundle ETH move / aPNTs move: ${counts.settledAfterEthMove}/${counts.settledAfterAMove}; ` +
    `settled at postOpGasLimit == MIN: ${counts.settledAtMin}`);
  console.log(`internal consistency (charge / charge_eth / ppm / bufWei re-derived, no subsidy): ` +
    (mismatches === 0 ? 'OK (0 mismatches)' : `${mismatches} MISMATCHES`));
  console.log('overpay (charge_eth - G)/G   [mean = floor(sum ppm / n); P95 = nearest-rank a[ceil(0.95n)-1]]');
  for (const g of groups) {
    if (g.n === 0) { console.log(`  ${g.group}: n = 0`); continue; }
    console.log(`  ${g.group}: n = ${g.n}; mean ${pct(g.mean_ppm)} / P95 ${pct(g.p95_ppm)} / max ${pct(g.max_ppm)}` +
      `  (ppm ${g.mean_ppm} / ${g.p95_ppm} / ${g.max_ppm}; min ${pct(g.min_ppm)}, median ${pct(g.median_ppm)})`);
  }
}
process.exit(mismatches === 0 ? 0 : 1);

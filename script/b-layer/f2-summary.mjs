// R2-F2: per-run verdict table (every case × bundler) and the tx-level preVerificationGas gap of every
// included bundle, from amsterdam/<run>/matrix.json. For a bundle tx: surplus = sum(actualGasUsed) - txGasUsed
// (gas units the beneficiary received beyond what the tx cost); with the fixed op PVG P (100,000 in every
// G1 variant), the break-even PVG per op (equal split) = P - surplus / n.
// Usage: node f2-summary.mjs <out.json> <runDir> [<runDir> ...]
import { readFileSync, writeFileSync } from "node:fs";
import { basename } from "node:path";

const [outPath, ...runs] = process.argv.slice(2);
const PVG = 100_000n;
const out = {};
for (const dir of runs) {
    const run = basename(dir);
    const rows = JSON.parse(readFileSync(`${dir}/matrix.json`, "utf8"));
    const verdicts = rows.map((r) => ({ bundler: r.bundler, case: r.case, verdict: r.verdict, error: r.error ? (typeof r.error === "string" ? r.error : `[${r.error.code}] ${String(r.error.message)}`).slice(0, 200) : null,
        actualGasUsed: r.onchain?.actualGasUsed ?? null, needs: r.needs ? { v: r.needs.v, c: r.needs.c, pmV: r.needs.pmV, pmP: r.needs.pmP } : null }));
    const bundles = {};
    for (const r of rows) {
        if (!r.onchain?.tx) continue;
        const b = (bundles[`${r.bundler}:${r.onchain.tx}`] ??= { bundler: r.bundler, tx: r.onchain.tx, txGasLimit: r.onchain.txGasLimit, txGasUsed: r.onchain.txGasUsed, cases: [], actual: [] });
        b.cases.push(r.case); b.actual.push(BigInt(r.onchain.actualGasUsed));
    }
    const bl = Object.values(bundles).map((b) => {
        const n = BigInt(b.actual.length); const sum = b.actual.reduce((a, x) => a + x, 0n); const surplus = sum - BigInt(b.txGasUsed);
        return { bundler: b.bundler, tx: b.tx, cases: b.cases, nOps: b.actual.length, txGasLimit: b.txGasLimit, txGasUsed: b.txGasUsed,
            sumActualGasUsed: sum.toString(), surplus: surplus.toString(), pvgPerOp: PVG.toString(),
            breakEvenPVGperOp: ((PVG * n - surplus + n - 1n) / n).toString() };
    });
    const counts = {};
    for (const v of verdicts) { const c = (counts[v.bundler] ??= {}); c[v.verdict] = (c[v.verdict] ?? 0) + 1; }
    out[run] = { counts, verdicts, bundles: bl };
    console.log(`== ${run}: ${JSON.stringify(counts)}`);
    for (const b of bl) console.log(`  ${b.bundler.padEnd(9)} ${b.cases.join("+").padEnd(28)} n=${b.nOps} txGasUsed ${b.txGasUsed} sumActual ${b.sumActualGasUsed} surplus ${b.surplus} breakEvenPVG/op ${b.breakEvenPVGperOp}`);
}
writeFileSync(outPath, JSON.stringify(out, null, 1) + "\n");

// R-AMS-2: tabulate a G1 run (rundler/alto/altoMulti *-results.json written by g1-cases.mjs with
// G1_ESTIMATE=1) into Markdown rows + a flat JSON: per op — bundler verdict and exact error, the
// bundler's eth_estimateUserOperationGas (pm gas supplied / omitted), whether that estimate actually
// executes (handleOps), the minimum need per field, inclusion, UserOperationEvent success,
// actualGasUsed / actualGasCost, postOp outcome, and the flags R-AMS-2 asks for.
// Usage: node script/b-layer/ams-report.mjs <workDir> <outMd> <outJson>
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const [W, outMd, outJson] = process.argv.slice(2);
const LABELS = ["rundler", "alto", "altoMulti"];
const n = (x) => (x == null ? null : Number(BigInt(x)));
const fmt = (x) => (x == null ? "–" : Number(x).toLocaleString("en-US"));
const errOf = (r) => (r?.error ? `[${r.error.code ?? "?"}] ${String(r.error.message).replace(/\|/g, "/").replace(/\s*\n\s*/g, " ").slice(0, 110)}` : null);

function ops(c) { // → [{sub, out}] for single- and multi-op cases
    if (c.subs) return c.subs.map((sub, i) => ({ sub, out: c.outs?.[i] ?? { verdict: c.verdicts?.[i] } }));
    if (c.sent) return [{ sub: c.sent, out: c }];
    return [];
}

function estCell(p, k) {
    const e = p?.estimates?.[k]?.response;
    if (!e) return { text: "–" };
    if (e.error) return { text: `ERR ${errOf(e)}`, err: true };
    const x = e.result;
    const v = { v: n(x.verificationGasLimit), c: n(x.callGasLimit), pmV: n(x.paymasterVerificationGasLimit), pmP: n(x.paymasterPostOpGasLimit), pvg: n(x.preVerificationGas) };
    const suf = p.sufficiency?.[k];
    return { v, ok: suf?.ok ?? null, brief: suf?.brief,
        text: `v ${fmt(v.v)} / c ${fmt(v.c)} / pmV ${fmt(v.pmV)} / pmP ${fmt(v.pmP)}${suf?.pmPostOpFilledByUs ? "*" : ""} → ${suf?.ok ? "executes" : `**${suf?.brief}**`}` };
}

const rows = [];
for (const l of LABELS) {
    const f = `${W}/${l}-results.json`;
    if (!existsSync(f)) continue;
    const r = JSON.parse(readFileSync(f, "utf8"));
    for (const [name, c] of Object.entries(r.cases)) {
        const list = ops(c);
        list.forEach(({ sub, out }, i) => {
            const p = sub.gasProbe;
            const ne = p?.needs;
            const es = estCell(p, "pmSupplied"), eo = estCell(p, "pmOmitted");
            const oc = out.onchain;
            const flags = [];
            for (const [k, e] of [["pmSupplied", es], ["pmOmitted", eo]]) {
                if (!e.v || !ne?.pmVerificationGasLimit) continue;
                const low = [];
                if (e.v.v != null && e.v.v < ne.verificationGasLimit) low.push(`v ${e.v.v}<${ne.verificationGasLimit}`);
                if (e.v.c != null && e.v.c < ne.callGasLimit) low.push(`c ${e.v.c}<${ne.callGasLimit}`);
                if (e.v.pmV != null && e.v.pmV < ne.pmVerificationGasLimit) low.push(`pmV ${e.v.pmV}<${ne.pmVerificationGasLimit}`);
                if (e.v.pmP != null && e.v.pmP < ne.pmPostOpGasLimit) low.push(`pmP ${e.v.pmP}<${ne.pmPostOpGasLimit}`);
                if (low.length) flags.push(`EST-LOW(${k}: ${low.join(", ")})`);
                else if (e.ok === false) flags.push(`EST-FAILS(${k}: ${e.brief})`);
            }
            const accepted = !out.error && !sub.response?.error;
            if (accepted && out.verdict !== "included") flags.push(`SIM-PASS/CHAIN-${out.verdict === "included-reverted" ? "REVERT" : "NOT-INCLUDED"}`);
            if (oc && (oc.success !== "true" || oc.postOpReverted)) flags.push(`ONCHAIN-FAIL(success=${oc.success}, postOpReverted=${oc.postOpReverted})`);
            rows.push({
                bundler: l, case: list.length > 1 ? `${name}#${i + 1}` : name, userOpHash: sub.userOpHash,
                verdict: out.verdict ?? (sub.response?.error ? "reject" : "accepted"),
                error: errOf(sub.response) ?? errOf(out),
                submittedHandleOps: p?.submitted?.brief ?? null,
                estimate: { pmSupplied: es.text, pmOmitted: eo.text, raw: { pmSupplied: p?.estimates?.pmSupplied?.response ?? null, pmOmitted: p?.estimates?.pmOmitted?.response ?? null } },
                needs: ne ? { v: ne.verificationGasLimit ?? null, c: ne.callGasLimit ?? null, pmV: ne.pmVerificationGasLimit ?? null, pmP: ne.pmPostOpGasLimit ?? null,
                    baseline: ne.generousBaseline?.brief, frames: ne.generousBaseline?.frames, actualGasUsedGenerous: ne.generousBaseline?.actualGasUsed } : null,
                included: out.verdict === "included" || out.verdict === "included-reverted",
                onchain: oc ? { tx: oc.tx, txGasLimit: oc.txGasLimit, txGasUsed: oc.txGasUsed, success: oc.success, actualGasUsed: oc.actualGasUsed,
                    actualGasCost: oc.actualGasCost, postOp: oc.postOpReverted ? "REVERTED (PostOpRevertReason)" : "ok (no PostOpRevertReason)" } : null,
                flags,
            });
        });
        if (name === "B10") rows.push({ bundler: l, case: "B10", b10: c.est ? Object.fromEntries(Object.entries(c.est).map(([k, v]) => [k, v.response])) : null, summary: c.summary, flags: [] });
    }
}

const md = [];
md.push("| bundler | case | bundler verdict / exact error | est (pm gas supplied) → does it execute | est (pm gas omitted) → does it execute | min need v / c / pmV / pmP | on chain: success, actualGasUsed, actualGasCost, postOp | flags |");
md.push("|---|---|---|---|---|---|---|---|");
for (const r of rows) {
    if (r.case === "B10") { md.push(`| ${r.bundler} | B10 | ${String(r.summary).replace(/\|/g, "/").replace(/\s*\n\s*/g, " ").slice(0, 400)} | | | | | |`); continue; }
    const need = r.needs?.pmV != null ? `${fmt(r.needs.v)} / ${fmt(r.needs.c)} / ${fmt(r.needs.pmV)} / ${fmt(r.needs.pmP)}` : (r.needs ? `baseline ${r.needs.baseline}` : "–");
    const oc = r.onchain ? `${r.onchain.success === "true" ? "✅" : "❌"} ${fmt(r.onchain.actualGasUsed)}, ${fmt(r.onchain.actualGasCost)} wei, postOp ${r.onchain.postOp.split(" ")[0]} (bundle tx gas ${fmt(r.onchain.txGasUsed)}/${fmt(r.onchain.txGasLimit)})` : "not included";
    md.push(`| ${r.bundler} | ${r.case} | ${r.verdict}${r.error ? ` ${r.error}` : ""} | ${r.estimate.pmSupplied} | ${r.estimate.pmOmitted} | ${need} | ${oc} | ${r.flags.join("; ") || "–"} |`);
}
writeFileSync(outMd, md.join("\n") + "\n");
writeFileSync(outJson, JSON.stringify(rows, null, 2));
console.log(`${rows.length} rows → ${outMd}`);

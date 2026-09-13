// F1 — extract the bundler's JOINT bundle check (eth_call / eth_estimateGas of EntryPoint.handleOps,
// logged by g1-proxy.mjs as kind "handleOps-call"): the ops it contained (sender, nonce) and the
// raw EntryPoint answer decoded (FailedOp / FailedOpWithRevert). Rundler v0.11.0 appends one
// sentinel op whose sender is the EntryPoint itself (it fails with AA10 once every real op has
// validated → "validation only"), see crates/provider/src/alloy/entry_point/v0_7.rs:282-312.
// Usage: node script/b-layer/f1-joint.mjs <outJson> <label=traces.jsonl>...
import { readFileSync, writeFileSync } from "node:fs";
import { decodeFunctionData, decodeErrorResult } from "viem";
import { ABI } from "./g1-lib.mjs";

const [outJson, ...pairs] = process.argv.slice(2);
const out = {};
for (const pair of pairs) {
    const [label, file] = pair.split("=");
    const rows = readFileSync(file, "utf8").trim().split("\n").map((l) => JSON.parse(l)).filter((l) => l.kind === "handleOps-call");
    out[label] = rows.map((r) => {
        const call = r.request.params[0];
        const { args } = decodeFunctionData({ abi: ABI.ep, data: call.data ?? call.input });
        const ops = args[0].map((o) => ({ sender: o.sender, nonceKey: (o.nonce >> 64n).toString(), seq: (o.nonce & ((1n << 64n) - 1n)).toString() }));
        let answer = r.response.result !== undefined ? { ok: r.response.result } : null;
        if (r.response.error) {
            const data = r.response.error.data;
            answer = { code: r.response.error.code, message: r.response.error.message };
            if (typeof data === "string" && data.startsWith("0x")) {
                try { const e = decodeErrorResult({ abi: ABI.ep, data }); answer.decoded = { name: e.errorName, args: e.args.map(String) }; } catch { answer.raw = data; }
            }
        }
        return { at: r.at, label: r.label, method: r.request.method, block: r.request.params[1] ?? null, ops, answer };
    });
}
writeFileSync(outJson, JSON.stringify(out, null, 2));
for (const [l, rows] of Object.entries(out)) for (const r of rows)
    console.log(`${l} ${r.label}: ${r.ops.length} ops [${r.ops.map((o) => `${o.sender.slice(0, 8)}:k${o.nonceKey}`).join(" ")}] -> ${JSON.stringify(r.answer.decoded ?? r.answer.message ?? r.answer)}`);

// D5 gate G1 — transparent JSON-RPC logging proxy between ONE bundler and the local anvil node.
// For every debug_traceCall that carries a JS tracer (i.e. the bundler's ERC-7562 validation
// simulation) it
//   1. runs OUR tracer (g1-tracer.mjs) on the identical request (same call object, block,
//      stateOverrides/blockOverrides; only `tracer` swapped) BEFORE forwarding, so the state is
//      the one the bundler is about to trace;
//   2. forwards the bundler's request unchanged and returns anvil's answer unchanged;
//   3. appends {case label, request (tracer code replaced by its sha256), bundler tracer result,
//      our tracer result} to <outJsonl>;
//   4. (F1) also logs every eth_call / eth_estimateGas of EntryPoint.handleOps with its raw answer
//      (kind "handleOps-call"): the bundler's joint, untraced bundle check.
// eth_estimateUserOperationGas traffic (eth_call / eth_estimateGas) and everything else passes
// through untouched. The runner sets the current case label via POST /__label {"label": "..."}.
// Usage: node script/b-layer/g1-proxy.mjs <listenPort> <upstreamUrl> <outJsonl>
import http from "node:http";
import { appendFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { g1TracerSource } from "./g1-tracer.mjs";
import { EP } from "./lib.mjs";

const [portArg, upstream, outJsonl] = process.argv.slice(2);
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(upstream)) throw new Error("local upstream only");
const MY_TRACER = g1TracerSource(EP);
let label = "unlabelled";
const seenTracers = new Set();
writeFileSync(outJsonl, "");

async function up(body) {
    const r = await fetch(upstream, { method: "POST", headers: { "content-type": "application/json" }, body });
    return r.text();
}

async function handleOne(req) {
    if (req && req.method === "debug_traceCall" && Array.isArray(req.params) && typeof req.params[2]?.tracer === "string"
        && req.params[2].tracer.length > 200) {
        const bundlerTracer = req.params[2].tracer;
        const th = createHash("sha256").update(bundlerTracer).digest("hex");
        if (!seenTracers.has(th)) {
            seenTracers.add(th);
            writeFileSync(`${outJsonl}.tracer-${th.slice(0, 12)}.js`, bundlerTracer);
        }
        const mineReq = { jsonrpc: "2.0", id: 1, method: "debug_traceCall",
            params: [req.params[0], req.params[1], { ...req.params[2], tracer: MY_TRACER, timeout: "60s" }] };
        let mine;
        try { mine = JSON.parse(await up(JSON.stringify(mineReq))); } catch (e) { mine = { error: String(e) }; }
        const theirsRaw = await up(JSON.stringify(req));
        const theirs = JSON.parse(theirsRaw);
        const logged = { ...req, params: [req.params[0], req.params[1], { ...req.params[2], tracer: `sha256:${th}` }] };
        appendFileSync(outJsonl, JSON.stringify({ at: new Date().toISOString(), label, request: logged,
            bundlerTrace: theirs.result ?? null, bundlerTraceError: theirs.error ?? null,
            ourTrace: mine.result ?? null, ourTraceError: mine.error ?? null }) + "\n");
        return theirs;
    }
    // F1: also record the bundler's JOINT bundle check — an eth_call/eth_estimateGas of
    // EntryPoint.handleOps (0x765e827f) — with its raw answer (no tracer involved).
    const call = req?.params?.[0];
    const data = call?.data ?? call?.input;
    if ((req?.method === "eth_call" || req?.method === "eth_estimateGas") && typeof data === "string" && data.startsWith("0x765e827f")) {
        const ans = JSON.parse(await up(JSON.stringify(req)));
        appendFileSync(outJsonl, JSON.stringify({ at: new Date().toISOString(), label, kind: "handleOps-call", request: req,
            response: ans }) + "\n");
        return ans;
    }
    return JSON.parse(await up(JSON.stringify(req)));
}

http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", async () => {
        try {
            if (req.url === "/__label") {
                label = JSON.parse(body).label;
                res.writeHead(200).end("{}");
                return;
            }
            const parsed = JSON.parse(body);
            // Only the (rare) traced simulations are intercepted; plain traffic is piped as-is.
            const isHandleOps = (x) => (x?.method === "eth_call" || x?.method === "eth_estimateGas")
                && String(x.params?.[0]?.data ?? x.params?.[0]?.input ?? "").startsWith("0x765e827f");
            const needs = (x) => x && (x.method === "debug_traceCall" || isHandleOps(x));
            let out;
            if (Array.isArray(parsed) ? parsed.some(needs) : needs(parsed)) {
                out = JSON.stringify(Array.isArray(parsed) ? await Promise.all(parsed.map(handleOne)) : await handleOne(parsed));
            } else {
                out = await up(body);
            }
            res.writeHead(200, { "content-type": "application/json" }).end(out);
        } catch (e) {
            res.writeHead(500).end(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32603, message: String(e) } }));
        }
    });
}).listen(Number(portArg), "127.0.0.1", () => console.log(`g1-proxy :${portArg} -> ${upstream}, log ${outJsonl}`));

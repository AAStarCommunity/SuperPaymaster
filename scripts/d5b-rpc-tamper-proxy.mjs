#!/usr/bin/env node
// =============================================================================
// d5b-rpc-tamper-proxy.mjs — SELF-TEST ONLY. A JSON-RPC pass-through in front of a local anvil that can
// falsify eth_getLogs answers, so scripts/d5b-timelock-roles-selftest.sh can show that
// check-timelock-roles.mjs --rpc2 compares the log PAYLOAD (two honest endpoints always agree, so a
// payload mismatch can only be produced synthetically).
//   node scripts/d5b-rpc-tamper-proxy.mjs <listenPort> <upstreamUrl> <mode>
//   mode: pass   — forward unchanged (control: the proxy itself does not break the check)
//         drop   — drop the last log of every non-empty eth_getLogs result
//         sender — rewrite topic[3] (the indexed `sender`) of the first log of every result
// Only ever point it at a local anvil; it holds no key.
// =============================================================================
import http from "node:http";

const [port, upstream, mode] = process.argv.slice(2);
if (!port || !upstream || !["pass", "drop", "sender"].includes(mode)) {
  console.error("usage: <listenPort> <upstreamUrl> pass|drop|sender");
  process.exit(2);
}
const FAKE_SENDER = "0x" + "0".repeat(60) + "bad1"; // 32-byte topic: address 0x…bad1

function tamper(req, res) {
  if (!req || req.method !== "eth_getLogs" || !res || !Array.isArray(res.result) || res.result.length === 0) return res;
  if (mode === "drop") res.result = res.result.slice(0, -1);
  if (mode === "sender") res.result[0] = { ...res.result[0], topics: [...res.result[0].topics.slice(0, 3), FAKE_SENDER] };
  return res;
}

http.createServer((inReq, inRes) => {
  let body = "";
  inReq.on("data", (c) => (body += c));
  inReq.on("end", async () => {
    try {
      const up = await fetch(upstream, { method: "POST", headers: { "content-type": "application/json" }, body });
      let out = await up.json();
      const req = JSON.parse(body);
      if (Array.isArray(out)) out = out.map((r, i) => tamper(Array.isArray(req) ? req[i] : req, r));
      else out = tamper(req, out);
      inRes.writeHead(200, { "content-type": "application/json" });
      inRes.end(JSON.stringify(out));
    } catch (e) {
      inRes.writeHead(502);
      inRes.end(String(e));
    }
  });
}).listen(Number(port), "127.0.0.1");

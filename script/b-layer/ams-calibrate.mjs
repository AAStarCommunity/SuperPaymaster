// R-AMS-2 step 0 — calibration gate: binary-search the minimum gas at which eth_call from anvil
// account 0 succeeds, for five probes whose live-Sepolia (Amsterdam) values are known.
// Local node only. Usage: node script/b-layer/ams-calibrate.mjs <rpcUrl> <out.json>
import { writeFileSync } from "node:fs";
const [rpc, out] = process.argv.slice(2);
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(rpc)) throw new Error("local node only");
const FROM = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const PROBES = [
  { name: "create 0x00", tx: { data: "0x00" }, expected: 207606 },
  { name: "create 0x6101006000f3", tx: { data: "0x6101006000f3" }, expected: 599432 },
  { name: "create 0x600160005500", tx: { data: "0x600160005500" }, expected: 317700 },
  { name: "create 0x6001600055600260005500", tx: { data: "0x6001600055600260005500" }, expected: 320075 },
  { name: "1 wei to fresh 0xa3a3..a3", tx: { to: "0x" + "a3".repeat(20), value: "0x1" }, expected: 204600 },
];
let id = 0;
async function call(method, params) {
  const r = await fetch(rpc, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }) });
  return r.json();
}
const ok = async (tx, gas) => !(await call("eth_call", [{ from: FROM, ...tx, gas: "0x" + gas.toString(16) }, "latest"])).error;
const meta = { clientVersion: (await call("web3_clientVersion", [])).result, chainId: (await call("eth_chainId", [])).result };
const rows = [];
for (const p of PROBES) {
  let lo = 0, hi = 30_000_000; // invariant: !ok(lo) (gas 0 always fails), ok(hi)
  if (!(await ok(p.tx, hi))) { rows.push({ ...p, measured: null, match: false, note: "fails at 30M" }); continue; }
  while (hi - lo > 1) { const m = Math.floor((lo + hi) / 2); if (await ok(p.tx, m)) hi = m; else lo = m; }
  const err = (await call("eth_call", [{ from: FROM, ...p.tx, gas: "0x" + (hi - 1).toString(16) }, "latest"])).error;
  const est = (await call("eth_estimateGas", [{ from: FROM, ...p.tx }, "latest"])).result;
  rows.push({ ...p, measured: hi, match: hi === p.expected, estimateGas: est ? parseInt(est, 16) : null, errorAtMinus1: err?.message });
}
const pass = rows.every((r) => r.match);
writeFileSync(out, JSON.stringify({ meta, pass, rows }, null, 2));
for (const r of rows) console.log(`${r.match ? "OK  " : "FAIL"} ${r.name.padEnd(36)} expected ${r.expected} measured ${r.measured} (estimateGas ${r.estimateGas})`);
console.log(pass ? "CALIBRATION PASS" : "BLOCKED-TOOL: calibration mismatch");
process.exit(pass ? 0 : 2);

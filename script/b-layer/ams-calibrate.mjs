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
const EXPECTED_CHAIN = BigInt(process.env.EXPECTED_CHAIN_ID ?? "31337"); // local anvil as started by the B-layer scripts
const HEXDATA = /^0x([0-9a-fA-F]{2})*$/, QTY = /^0x(0|[1-9a-fA-F][0-9a-fA-F]{0,63})$/;
// Deterministic EVM failure at this gas limit: an explicit (code, full message) whitelist, mirrored from
// script/evidence/lib/rpc_strict.py. Known RPC-fault codes always win; anything else aborts the run and is
// never read as a gas boundary.
const FAULT_CODES = new Set([-32700, -32600, -32601, -32602, -32603, -32004, -32005, -32006, -32016, -32099, 429]);
// ASCII only, same strings as rpc_strict.py: [0-9] digits, printable-ASCII revert reasons.
const EVM_FAILURES = [
  [[-32003, -32015], /^out of gas: gas required exceeds: [0-9]{1,20}$/],
  [[-32003, -32015], /^out of gas: gas exhausted during [a-z ]{1,40}: [0-9]{1,20}$/],
  [[-32000], /^intrinsic gas too low$/],
  [[3, -32003, -32015], /^execution reverted(: [\x20-\x7e]{0,200})?$/],
  [[-32003], /^EVM error (OutOfGas|MemoryOOG|MemoryLimitOOG|PrecompileOOG|InvalidOperandOOG|ReentrancySentryOOG)$/],
  [[-32000], /^intrinsic gas too high -- (CallGasCostMoreThanGasLimit|GasFloorMoreThanGasLimit)$/],
];
const EVM_METHODS = new Set(["eth_call", "eth_estimateGas"]);
const isEvmFailure = (method, e) => EVM_METHODS.has(method) && !FAULT_CODES.has(e.code)
  && EVM_FAILURES.some(([codes, rx]) => codes.includes(e.code) && rx.test(e.message));
const INT_TOKEN = /^-?(0|[1-9][0-9]{0,15})$/;
// Parse JSON keeping the source text of every number, so `1.0` / `-32003.000…1` cannot round into an
// integer id or a whitelisted error code (JSON.parse source-text access, Node >= 21).
const parseStrict = (text) => JSON.parse(text, (key, value, ctx) =>
  typeof value === "number" ? { __num: value, __src: ctx?.source } : value);
const intOf = (x) => (x && typeof x === "object" && "__num" in x && typeof x.__src === "string" && INT_TOKEN.test(x.__src)) ? x.__num : NaN;
function die(msg) { console.error(`BLOCKED-TOOL: ${msg}`); process.exit(3); }
let id = 0;
async function call(method, params) {
  const rid = ++id;
  let d;
  try {
    const r = await fetch(rpc, { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: rid, method, params }) });
    if (!r.ok || r.status !== 200) die(`${method}: HTTP status ${r.status}`);
    d = parseStrict(typeof r.text === "function" ? await r.text() : JSON.stringify(await r.json()));
  } catch (e) { die(`${method}: transport error (${e?.name ?? "error"})`); }
  if (!d || typeof d !== "object" || d.jsonrpc !== "2.0" || intOf(d.id) !== rid || (("result" in d) === ("error" in d)))
    die(`${method}: malformed envelope`);
  if ("error" in d) {
    const e = d.error;
    const code = intOf(e?.code);
    if (!e || typeof e !== "object" || !Number.isInteger(code) || typeof e.message !== "string") die(`${method}: malformed error`);
    if (isEvmFailure(method, { code, message: e.message })) return { evmFailure: { code, message: e.message.slice(0, 120) } };
    die(`${method}: RPC fault code=${e.code} (not an EVM gas/execution failure)`);
  }
  return { result: d.result };
}
// true / false for a well-formed eth_call outcome; aborts on anything else.
async function outcome(tx, gas) {
  const r = await call("eth_call", [{ from: FROM, ...tx, gas: "0x" + gas.toString(16) }, "latest"]);
  if (r.evmFailure) return { ok: false, raw: r.evmFailure };
  if (typeof r.result !== "string" || !HEXDATA.test(r.result)) die("eth_call: malformed result");
  return { ok: true, raw: { returnBytes: (r.result.length - 2) / 2 } };
}
const ok = async (tx, gas) => (await outcome(tx, gas)).ok;
const cv = await call("web3_clientVersion", []);
const ch = await call("eth_chainId", []);
if (typeof ch.result !== "string" || !QTY.test(ch.result)) die("eth_chainId: malformed result");
if (BigInt(ch.result) !== EXPECTED_CHAIN) die(`chain id ${BigInt(ch.result)} != expected ${EXPECTED_CHAIN}`);
if (typeof cv.result !== "string") die("web3_clientVersion: malformed result");
const meta = { clientVersion: cv.result, chainId: ch.result };
const rows = [];
for (const p of PROBES) {
  // Two independent binary searches must agree, so a transient fault inside one cannot move the threshold.
  const search = async () => {
    let lo = 0, hi = 30_000_000; // invariant: !ok(lo) (gas 0 always fails), ok(hi)
    if (!(await ok(p.tx, hi))) return null;
    while (hi - lo > 1) { const m = Math.floor((lo + hi) / 2); if (await ok(p.tx, m)) hi = m; else lo = m; }
    return hi;
  };
  const h1 = await search(), h2 = await search();
  if (h1 !== h2) die(`${p.name}: threshold not stable across two searches (${h1} vs ${h2})`);
  if (h1 === null) { rows.push({ ...p, measured: null, match: false, note: "fails at 30M" }); continue; }
  const hi = h1;
  const below = await outcome(p.tx, hi - 1), at = await outcome(p.tx, hi);
  if (below.ok || !at.ok) die(`${p.name}: threshold not reproducible`);
  const e = await call("eth_estimateGas", [{ from: FROM, ...p.tx }, "latest"]);
  if (e.result !== undefined && (typeof e.result !== "string" || !QTY.test(e.result))) die("eth_estimateGas: malformed result");
  // Exact decimal string (BigInt), never a lossy JS number.
  rows.push({ ...p, measured: hi, match: hi === p.expected, estimateGas: e.result ? BigInt(e.result).toString() : null,
              thresholdSides: { minMinus1: below.raw, min: at.raw } });
}
const pass = rows.every((r) => r.match);
writeFileSync(out, JSON.stringify({ meta, pass, rows }, null, 2));
for (const r of rows) console.log(`${r.match ? "OK  " : "FAIL"} ${r.name.padEnd(36)} expected ${r.expected} measured ${r.measured} (estimateGas ${r.estimateGas})`);
console.log(pass ? "CALIBRATION PASS" : "BLOCKED-TOOL: calibration mismatch");
process.exit(pass ? 0 : 2);

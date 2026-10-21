// Runbook step 0 (D5.3): inventory of the live SP before the 5.5.0 upgrade. READ-ONLY.
// Scans SP logs on TWO independent endpoints and cross-checks (completeness cannot be inferred
// from returned data — a missing range looks exactly like an empty one). Every hit is then
// read back against live state (positive control for the event selectors).
// Usage: node script/rehearsal/inventory.mjs <envFileWithRPC_URL> <secondRpcUrl> <out.json>
//   The first endpoint's URL is read from RPC_URL in the env file and NEVER printed.
import { readFileSync, writeFileSync } from "node:fs";
import { createPublicClient, http, parseAbiItem, getAddress } from "viem";

const [envFile, secondRpc, outPath] = process.argv.slice(2);
const env = Object.fromEntries(readFileSync(envFile, "utf8").split("\n")
    .filter((l) => /^\s*[A-Z0-9_]+\s*=/.test(l))
    .map((l) => { const i = l.indexOf("="); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, "")]; }));
if (!env.RPC_URL) throw new Error("RPC_URL missing in env file");

const SP = "0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9";
const EVENTS = {
    OperatorConfigured: parseAbiItem("event OperatorConfigured(address indexed operator, address xPNTsToken, address treasury)"),
    OperatorDeposited: parseAbiItem("event OperatorDeposited(address indexed operator, uint256 amount)"),
    DebtRecordFailed: parseAbiItem("event DebtRecordFailed(address indexed token, address indexed user, uint256 amount)"),
    PendingDebtRetried: parseAbiItem("event PendingDebtRetried(address indexed token, address indexed user, uint256 amount)"),
    PendingDebtCleared: parseAbiItem("event PendingDebtCleared(address indexed token, address indexed user, uint256 amount)"),
    APNTsTokenChangeQueued: parseAbiItem("event APNTsTokenChangeQueued(address indexed pendingToken, uint256 eta)"),
    APNTsTokenChangeCancelled: parseAbiItem("event APNTsTokenChangeCancelled(address indexed pendingToken)"),
    APNTsTokenChangeExecuted: parseAbiItem("event APNTsTokenChangeExecuted(address indexed oldToken, address indexed newToken, uint256 executedAt)"),
    OperatorPaused: parseAbiItem("event OperatorPaused(address indexed operator)"),
    OperatorUnpaused: parseAbiItem("event OperatorUnpaused(address indexed operator)"),
};
const SP_ABI = [
    { type: "function", name: "operators", stateMutability: "view", inputs: [{ type: "address" }], outputs: [
        { type: "uint128" }, { type: "bool" }, { type: "bool" }, { type: "address" }, { type: "uint32" },
        { type: "uint48" }, { type: "address" }, { type: "uint256" }, { type: "uint256" }] },
    { type: "function", name: "pendingDebts", stateMutability: "view", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }] },
    { type: "function", name: "pendingAPNTsToken", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
    { type: "function", name: "pendingAPNTsEta", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
    { type: "function", name: "APNTS_TOKEN", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
    { type: "function", name: "version", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
];

const endpoints = [
    { label: "archive(env RPC_URL)", client: createPublicClient({ transport: http(env.RPC_URL, { timeout: 60_000 }) }) },
    { label: `second(${new URL(secondRpc).host})`, client: createPublicClient({ transport: http(secondRpc, { timeout: 60_000 }) }) },
];

async function deployBlock(c, head) {
    // binary search the first block where SP has code (needs archive state)
    let lo = 0n, hi = head;
    while (lo < hi) {
        const mid = (lo + hi) / 2n;
        const code = await c.getCode({ address: SP, blockNumber: mid }).catch(() => null);
        if (code === null) throw new Error("state read failed at " + mid + " (endpoint not archive?)");
        if (code && code !== "0x") hi = mid; else lo = mid + 1n;
    }
    return lo;
}

async function scan(c, from, to) {
    const out = {};
    for (const [name, ev] of Object.entries(EVENTS)) out[name] = [];
    let step = 50_000n;
    for (let start = from; start <= to;) {
        const end = start + step - 1n > to ? to : start + step - 1n;
        try {
            const logs = await c.getLogs({ address: SP, events: Object.values(EVENTS), fromBlock: start, toBlock: end });
            for (const l of logs) out[l.eventName].push({ block: Number(l.blockNumber), tx: l.transactionHash, logIndex: l.logIndex, args: l.args });
            start = end + 1n;
            if (step < 50_000n) step *= 2n;
        } catch (e) {
            if (step <= 100n) throw new Error(`getLogs failed at ${start}-${end}: ${String(e.message).slice(0, 120)}`);
            step /= 4n;
        }
    }
    return out;
}

const key = (x) => `${x.block}:${x.logIndex}`;
const res = { sp: SP, at: new Date().toISOString(), endpoints: [], crossCheck: {}, state: {} };
const head = await endpoints[1].client.getBlockNumber();
const d0 = await deployBlock(endpoints[0].client, head);
const d1 = await deployBlock(endpoints[1].client, head).catch((e) => `unavailable: ${e.message}`);
res.deployBlock = { archive: Number(d0), second: typeof d1 === "bigint" ? Number(d1) : d1 };
res.range = { from: Number(d0), to: Number(head) };

const scans = [];
for (const ep of endpoints) {
    try { scans.push(await scan(ep.client, d0, head)); res.endpoints.push({ label: ep.label, ok: true }); }
    catch (e) { scans.push(null); res.endpoints.push({ label: ep.label, ok: false, error: String(e.message).slice(0, 200) }); }
}
for (const name of Object.keys(EVENTS)) {
    const a = scans[0]?.[name], b = scans[1]?.[name];
    const sa = new Set((a ?? []).map(key)), sb = new Set((b ?? []).map(key));
    res.crossCheck[name] = {
        archive: a ? a.length : null, second: b ? b.length : null,
        identical: !!(a && b) && a.length === b.length && [...sa].every((k) => sb.has(k)),
    };
}
const ev = scans[0] ?? scans[1];

// state read-back (positive control: every OperatorConfigured operator must read isConfigured)
const c = endpoints[0].client;
const read = (fn, args = []) => c.readContract({ address: SP, abi: SP_ABI, functionName: fn, args });
res.state.version = await read("version");
res.state.APNTS_TOKEN = await read("APNTS_TOKEN");
res.state.pendingAPNTsToken = await read("pendingAPNTsToken");
res.state.pendingAPNTsEta = (await read("pendingAPNTsEta").catch(() => null))?.toString() ?? null;
const ops = [...new Set(ev.OperatorConfigured.map((x) => getAddress(x.args.operator)))];
res.state.operators = [];
for (const op of ops) {
    const o = await read("operators", [op]);
    res.state.operators.push({ operator: op, aPNTsBalance: o[0].toString(), isConfigured: o[1], isPaused: o[2], xPNTsToken: o[3], treasury: o[6] });
}
const pairs = [...new Set(ev.DebtRecordFailed.map((x) => `${getAddress(x.args.token)}|${getAddress(x.args.user)}`))];
res.state.pendingDebts = [];
for (const p of pairs) {
    const [token, user] = p.split("|");
    res.state.pendingDebts.push({ token, user, amount: (await read("pendingDebts", [token, user])).toString() });
}
res.events = Object.fromEntries(Object.entries(ev).map(([k, v]) => [k, v.length]));
res.positiveControl = {
    operatorConfiguredEventsFound: ev.OperatorConfigured.length > 0,
    everyEventOperatorReadsConfigured: res.state.operators.every((o) => o.isConfigured),
};
writeFileSync(outPath, JSON.stringify(res, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2));
console.log(JSON.stringify({ deployBlock: res.deployBlock, range: res.range, endpoints: res.endpoints, crossCheck: res.crossCheck,
    operators: res.state.operators.length, pendingDebtPairs: res.state.pendingDebts.length,
    nonzeroPendingDebts: res.state.pendingDebts.filter((d) => d.amount !== "0").length,
    pendingAPNTsToken: res.state.pendingAPNTsToken, positiveControl: res.positiveControl }, null, 2));

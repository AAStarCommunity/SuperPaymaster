// Runbook step 0 (D5.3): inventory of SP logs across upgrades. READ-ONLY.
// Scans SP logs on TWO independent endpoints and cross-checks (completeness cannot be inferred
// from returned data — a missing range looks exactly like an empty one). Every hit is then
// read back against live state (positive control for the event selectors).
// Completeness against event-signature drift:
//   - logs are fetched WITHOUT a topic filter; every topic0 must decode as an event of the current
//     SuperPaymaster ABI or of a listed historical (5.4.x) form, otherwise the run fails;
//   - the two endpoints must return byte-identical log sets over the same pinned range;
//   - every address in an indexed `operator` argument of any event, and every current Registry
//     PAYMASTER_SUPER holder (read from storage, not from logs), must be in the operator list or
//     read back as not configured.
// Residual: an operator configured without any SP log and without the PAYMASTER_SUPER role is not
// detectable from logs. In every deployed implementation only configureOperator sets isConfigured,
// and it emits OperatorConfigured.
// Usage: node script/rehearsal/inventory.mjs <envFileWithRPC_URL> <secondRpcUrl> <out.json>
//   Neither endpoint URL is printed or written; errors are redacted before output.
import { readFileSync, writeFileSync } from "node:fs";
import {
    createPublicClient, http, parseAbiItem, getAddress, decodeEventLog, toEventSelector,
    keccak256, encodeAbiParameters, stringToHex, hexToBigInt, numberToHex,
} from "viem";

const [envFile, secondRpc, outPath] = process.argv.slice(2);
const env = Object.fromEntries(readFileSync(envFile, "utf8").split("\n")
    .filter((l) => /^\s*[A-Z0-9_]+\s*=/.test(l))
    .map((l) => { const i = l.indexOf("="); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, "")]; }));
if (!env.RPC_URL) throw new Error("RPC_URL missing in env file");

const URLS = [env.RPC_URL, secondRpc];
function redact(s) {
    let t = String(s);
    for (const u of URLS) {
        t = t.split(u).join("<rpc>");
        const { pathname, search } = new URL(u);
        if (pathname.length > 1) t = t.split(pathname).join("/<redacted>");
        if (search.length > 1) t = t.split(search).join("?<redacted>");
    }
    return t;
}

const SP = "0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9";
const MAX_HEAD_SKEW = 64n;
const ROLE_MEMBERS_SLOT = 9n; // Registry `roleMembers` (forge inspect storageLayout), checked against getRoleUserCount
const PAYMASTER_SUPER = keccak256(stringToHex("PAYMASTER_SUPER"));

// Events of the current SP (core + admin extension) plus every 5.4.x form whose selector differs.
const currentAbi = JSON.parse(readFileSync(new URL("../../abis/SuperPaymaster.full.json", import.meta.url), "utf8"));
const HISTORICAL = [
    // 4-argument form up to SuperPaymaster 5.3.2 (never emitted at this proxy; listed so a drift fails loudly).
    "event OperatorConfigured(address indexed operator, address xPNTsToken, address treasury, uint256 exchangeRate)",
    // 5.4.0 / 5.4.1 / 5.4.2 forms (tags v5.4.0-beta.1-redeploy, v5.4.1-rc.1, v5.4.2) absent from the current ABI.
    "event OperatorPaused(address indexed operator)",
    "event OperatorUnpaused(address indexed operator)",
    "event OperatorSlashed(address indexed operator, uint256 amount, uint8 level)",
    "event PriceModeChanged(uint8 oldMode, uint8 newMode)",
    "event PriceUpdated(int256 indexed price, uint256 indexed timestamp)",
    "event ReputationUpdated(address indexed operator, uint256 newScore)",
    "event SlashCancelled(address indexed operator)",
    "event SlashQueued(address indexed operator)",
].map(parseAbiItem);
const KNOWN = new Map();
for (const e of [...(Array.isArray(currentAbi) ? currentAbi : currentAbi.abi).filter((x) => x.type === "event"), ...HISTORICAL]) {
    KNOWN.set(toEventSelector(e), e);
}
const INVENTORY = ["OperatorConfigured", "OperatorDeposited", "DebtRecordFailed", "PendingDebtRetried", "PendingDebtCleared",
    "APNTsTokenChangeQueued", "APNTsTokenChangeCancelled", "APNTsTokenChangeExecuted", "OperatorPaused", "OperatorUnpaused"];
for (const name of INVENTORY) {
    if (![...KNOWN.values()].some((e) => e.name === name)) throw new Error(`inventory event ${name} missing from the known set`);
}

const SP_ABI = [
    { type: "function", name: "operators", stateMutability: "view", inputs: [{ type: "address" }], outputs: [
        { type: "uint128" }, { type: "bool" }, { type: "bool" }, { type: "address" }, { type: "uint32" },
        { type: "uint48" }, { type: "address" }, { type: "uint256" }, { type: "uint256" }] },
    { type: "function", name: "pendingDebts", stateMutability: "view", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }] },
    { type: "function", name: "pendingAPNTsToken", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
    { type: "function", name: "pendingAPNTsEta", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
    { type: "function", name: "APNTS_TOKEN", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
    { type: "function", name: "REGISTRY", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
    { type: "function", name: "version", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
];
const REGISTRY_ABI = [
    { type: "function", name: "getRoleUserCount", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: [{ type: "uint256" }] },
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

async function fetchLogs(c, from, to) {
    const logs = [];
    let step = 50_000n;
    for (let start = from; start <= to;) {
        const end = start + step - 1n > to ? to : start + step - 1n;
        try {
            // No topic filter: a signature this script does not know must show up, not vanish.
            logs.push(...await c.getLogs({ address: SP, fromBlock: start, toBlock: end }));
            start = end + 1n;
            if (step < 50_000n) step *= 2n;
        } catch (e) {
            if (step <= 100n) throw new Error(`getLogs failed at ${start}-${end}: ${redact(e.message).slice(0, 160)}`);
            step /= 4n;
        }
    }
    return logs;
}

const fingerprint = (l) => [l.blockNumber, l.logIndex, l.transactionHash, l.topics.join(","), l.data].join(":");

function classify(logs) {
    const out = { unclassified: [], operatorArgs: [] };
    for (const name of INVENTORY) out[name] = [];
    for (const l of logs) {
        const at = { block: Number(l.blockNumber), tx: l.transactionHash, logIndex: l.logIndex };
        const e = KNOWN.get(l.topics[0]);
        if (!e) { out.unclassified.push({ ...at, topic0: l.topics[0] ?? "anonymous" }); continue; }
        const { args } = decodeEventLog({ abi: [e], data: l.data, topics: l.topics, strict: true });
        if (INVENTORY.includes(e.name)) out[e.name].push({ ...at, args });
        if (e.inputs.some((i) => i.indexed && i.name === "operator")) {
            out.operatorArgs.push({ ...at, event: e.name, operator: getAddress(args.operator) });
        }
    }
    return out;
}

async function main() {
    if (new URL(env.RPC_URL).host === new URL(secondRpc).host) throw new Error("the two endpoints must be different providers");
    const endpoints = [
        { label: "archive(env RPC_URL)", client: createPublicClient({ transport: http(env.RPC_URL, { timeout: 60_000 }) }) },
        { label: `second(${new URL(secondRpc).host})`, client: createPublicClient({ transport: http(secondRpc, { timeout: 60_000 }) }) },
    ];
    const res = { sp: SP, at: new Date().toISOString(), endpoints: [], crossCheck: {}, state: {} };

    // One pinned range for both endpoints: the lower head, provided the two agree to within MAX_HEAD_SKEW.
    const heads = await Promise.all(endpoints.map((ep) => ep.client.getBlockNumber()));
    const head = heads[0] < heads[1] ? heads[0] : heads[1];
    const skew = heads[0] > heads[1] ? heads[0] - heads[1] : heads[1] - heads[0];
    res.heads = heads.map(Number);
    if (skew > MAX_HEAD_SKEW) throw new Error(`endpoint heads differ by ${skew} blocks`);
    const deploy = await Promise.all(endpoints.map((ep) => deployBlock(ep.client, head)));
    res.deployBlock = { archive: Number(deploy[0]), second: Number(deploy[1]) };
    if (deploy[0] !== deploy[1]) throw new Error("endpoints disagree on the SP deploy block");
    res.range = { from: Number(deploy[0]), to: Number(head) };

    const raw = [];
    for (const ep of endpoints) {
        raw.push(await fetchLogs(ep.client, deploy[0], head));
        res.endpoints.push({ label: ep.label, ok: true });
    }
    const fa = raw[0].map(fingerprint).sort(), fb = raw[1].map(fingerprint).sort();
    res.crossCheck.allLogs = { archive: fa.length, second: fb.length, identical: fa.length === fb.length && fa.every((x, i) => x === fb[i]) };
    const ev = classify(raw[0]);
    res.events = Object.fromEntries(Object.entries(ev).map(([k, v]) => [k, v.length]));
    res.topic0Seen = [...new Set(raw[0].map((l) => l.topics[0] ?? "anonymous"))].map((t) => ({ topic0: t, event: KNOWN.get(t)?.name ?? null }));
    res.unclassifiedTopic0 = [...new Set(ev.unclassified.map((x) => x.topic0))];

    // State read-back at the pinned head (positive control: every OperatorConfigured operator must read isConfigured).
    const c = endpoints[0].client;
    const read = (fn, args = []) => c.readContract({ address: SP, abi: SP_ABI, functionName: fn, args, blockNumber: head });
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

    // Independent source: current PAYMASTER_SUPER holders, read from Registry storage (not from logs).
    const registry = await read("REGISTRY");
    const base = keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [PAYMASTER_SUPER, ROLE_MEMBERS_SLOT]));
    const storageAt = (slot) => c.getStorageAt({ address: registry, slot, blockNumber: head });
    const count = hexToBigInt(await storageAt(base));
    const viewCount = await c.readContract({ address: registry, abi: REGISTRY_ABI, functionName: "getRoleUserCount", args: [PAYMASTER_SUPER], blockNumber: head });
    const first = hexToBigInt(keccak256(base));
    const holders = [];
    for (let i = 0n; i < count; i++) holders.push(getAddress("0x" + (await storageAt(numberToHex(first + i, { size: 32 }))).slice(26)));
    res.state.registry = registry;
    res.state.superHolders = { fromStorage: holders, storageCount: count.toString(), getRoleUserCount: viewCount.toString() };

    // Every address seen as an `operator` argument, and every PAYMASTER_SUPER holder, outside the list
    // must read back as not configured.
    const listed = new Set(ops);
    const others = [...new Set([...ev.operatorArgs.map((x) => x.operator), ...holders])].filter((a) => !listed.has(a));
    res.state.outsideList = [];
    for (const op of others) {
        const o = await read("operators", [op]);
        res.state.outsideList.push({ operator: op, isConfigured: o[1], superHolder: holders.includes(op) });
    }

    const pairs = [...new Set(ev.DebtRecordFailed.map((x) => `${getAddress(x.args.token)}|${getAddress(x.args.user)}`))];
    res.state.pendingDebts = [];
    for (const p of pairs) {
        const [token, user] = p.split("|");
        res.state.pendingDebts.push({ token, user, amount: (await read("pendingDebts", [token, user])).toString() });
    }
    res.positiveControl = {
        operatorConfiguredEventsFound: ev.OperatorConfigured.length > 0,
        everyEventOperatorReadsConfigured: res.state.operators.every((o) => o.isConfigured),
        noUnclassifiedTopic0: res.unclassifiedTopic0.length === 0,
        endpointsReturnIdenticalLogs: res.crossCheck.allLogs.identical,
        roleMembersSlotMatchesView: count === viewCount,
        noConfiguredOperatorOutsideList: res.state.outsideList.every((o) => !o.isConfigured),
    };
    writeFileSync(outPath, JSON.stringify(res, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2));
    console.log(JSON.stringify({ heads: res.heads, deployBlock: res.deployBlock, range: res.range, endpoints: res.endpoints,
        crossCheck: res.crossCheck, events: res.events, operators: res.state.operators.map((o) => o.operator),
        superHolders: res.state.superHolders, outsideList: res.state.outsideList,
        pendingDebtPairs: res.state.pendingDebts.length,
        nonzeroPendingDebts: res.state.pendingDebts.filter((d) => d.amount !== "0").length,
        pendingAPNTsToken: res.state.pendingAPNTsToken, unclassifiedTopic0: res.unclassifiedTopic0,
        positiveControl: res.positiveControl }, null, 2));
    if (!Object.values(res.positiveControl).every(Boolean)) {
        console.error("INVENTORY INCOMPLETE: see positiveControl");
        process.exit(1);
    }
}

main().catch((e) => {
    console.error("INVENTORY FAILED: " + redact(e?.stack ?? e));
    process.exit(1);
});

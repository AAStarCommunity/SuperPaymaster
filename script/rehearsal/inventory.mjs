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
//   - a second candidate source from another contract: every address Registry ever registered for
//     PAYMASTER_SUPER (RoleRegistered), which configureOperator requires.
// Range end = the FINALIZED block, which both endpoints must report with the same number and hash;
// state is read at that block and its hash is re-checked afterwards.
// Residual premise (not checkable from logs): in the deployed implementations 5.4.0/5.4.1/5.4.2
// (tags v5.4.0-beta.1-redeploy, v5.4.1-rc.1, v5.4.2) the only write of isConfigured = true is in
// configureOperator, which requires PAYMASTER_SUPER and emits OperatorConfigured; the proxy was
// initialized once at deploy, with no migrated operator state. Registry role grants go through
// _firstTimeRegister, whose two callers emit RoleRegistered.
// Usage: node script/rehearsal/inventory.mjs <envFileWithRPC_URL> <secondRpcUrl> <out.json>
//   Neither endpoint URL is printed or written; errors are redacted before output.
//   The output file is written ONLY when every positive control holds (exit 1 and no file otherwise).
//   Two-endpoint helpers (redaction, independence, finalized pin, log comparison) live in lib/two-endpoint.mjs.
import { readFileSync } from "node:fs";
import {
    createPublicClient, http, parseAbiItem, getAddress, decodeEventLog, toEventSelector,
    keccak256, encodeAbiParameters, stringToHex, hexToBigInt, numberToHex,
} from "viem";
import { makeRedactor, assertIndependent, both, compareLogs, pinFinalized, writeAtomic } from "./lib/two-endpoint.mjs";
import { INVENTORY_SCHEMA, REQUIRED_CONTROLS } from "./lib/inventory-accept.mjs";

const [envFile, secondRpc, outPath] = process.argv.slice(2);
const env = Object.fromEntries(readFileSync(envFile, "utf8").split("\n")
    .filter((l) => /^\s*[A-Z0-9_]+\s*=/.test(l))
    .map((l) => { const i = l.indexOf("="); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, "")]; }));
if (!env.RPC_URL) throw new Error("RPC_URL missing in env file");

const redact = makeRedactor([env.RPC_URL, secondRpc]);
const CHAIN_ID = 11155111;

const SP = "0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9";
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
const KNOWN = new Map(), CURRENT = new Set();
for (const e of (Array.isArray(currentAbi) ? currentAbi : currentAbi.abi).filter((x) => x.type === "event")) {
    KNOWN.set(toEventSelector(e), e);
    CURRENT.add(toEventSelector(e));
}
for (const e of HISTORICAL) if (!KNOWN.has(toEventSelector(e))) KNOWN.set(toEventSelector(e), e);
const HISTORICAL_SOURCE = "SuperPaymaster ABI at tags v5.4.0-beta.1-redeploy / v5.4.1-rc.1 / v5.4.2 (4-argument OperatorConfigured: up to v5.3.2)";
const signatureOf = (e) => `${e.name}(${e.inputs.map((i) => i.type).join(",")})`;
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
// Two 5.5.x-development forms (95f486ef, replaced in 0aa69589) are NOT listed: they are absent from
// the bytecode of all three implementations this proxy ever ran, so they cannot appear; an unknown
// topic0 fails the run by design.
const ROLE_REGISTERED = parseAbiItem("event RoleRegistered(bytes32 indexed roleId, address indexed user, uint256 burnAmount, uint256 timestamp)");
const REGISTRY_ABI = [
    { type: "function", name: "getRoleUserCount", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: [{ type: "uint256" }] },
];

async function deployBlockOf(c, address, head) {
    // binary search the first block where `address` has code (needs archive state)
    let lo = 0n, hi = head;
    while (lo < hi) {
        const mid = (lo + hi) / 2n;
        const code = await c.getCode({ address, blockNumber: mid }).catch(() => null);
        if (code === null) throw new Error("state read failed at " + mid + " (endpoint not archive?)");
        if (code && code !== "0x") hi = mid; else lo = mid + 1n;
    }
    return lo;
}

async function fetchLogs(c, address, from, to, filter) {
    const logs = [];
    let step = 50_000n;
    for (let start = from; start <= to;) {
        const end = start + step - 1n > to ? to : start + step - 1n;
        try {
            // No topic filter: a signature this script does not know must show up, not vanish.
            logs.push(...await c.getLogs({ address, fromBlock: start, toBlock: end, ...(filter ?? {}) }));
            start = end + 1n;
            if (step < 50_000n) step *= 2n;
        } catch (e) {
            if (step <= 100n) throw new Error(`getLogs failed at ${start}-${end}: ${redact(e.message).slice(0, 160)}`);
            step /= 4n;
        }
    }
    return logs;
}

const sameLogs = compareLogs; // full-payload fingerprints, shared implementation

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
    const providers = assertIndependent(env.RPC_URL, secondRpc);
    const endpoints = [
        { label: `archive(${providers[0]})`, client: createPublicClient({ transport: http(env.RPC_URL, { timeout: 60_000 }) }) },
        { label: `second(${providers[1]})`, client: createPublicClient({ transport: http(secondRpc, { timeout: 60_000 }) }) },
    ];
    const clients = endpoints.map((ep) => ep.client);
    const res = { schema: INVENTORY_SCHEMA, sp: SP, chainId: CHAIN_ID, at: new Date().toISOString(), endpoints: [], crossCheck: {}, state: {} };

    // One pinned, reorg-safe range: the finalized block, identical (number and hash) on both endpoints,
    // both reporting chain id 11155111.
    const pin = await pinFinalized(clients, CHAIN_ID);
    const head = pin.number;
    res.pinnedBlock = { number: Number(head), hash: pin.hash, finalized: pin.finalized };
    const deploy = await Promise.all(endpoints.map((ep) => deployBlockOf(ep.client, SP, head)));
    res.deployBlock = { archive: Number(deploy[0]), second: Number(deploy[1]) };
    if (deploy[0] !== deploy[1]) throw new Error("endpoints disagree on the SP deploy block");
    res.range = { from: Number(deploy[0]), to: Number(head) };

    const raw = [];
    for (const ep of endpoints) {
        raw.push(await fetchLogs(ep.client, SP, deploy[0], head));
        res.endpoints.push({ label: ep.label, ok: true });
    }
    res.crossCheck.allLogs = sameLogs(raw[0], raw[1]);
    // Nothing is derived from the logs unless both endpoints returned the identical full payload.
    if (!res.crossCheck.allLogs.identical) throw new Error("endpoints return different SP logs");
    const ev = classify(raw[0]);
    res.events = Object.fromEntries(Object.entries(ev).map(([k, v]) => [k, v.length]));
    // Per-topic0 table for the deploy-day readback (DVT's detector takes the non-current rows as its supplement).
    const seen = new Map();
    for (const l of raw[0]) {
        const t = l.topics[0] ?? "anonymous";
        const row = seen.get(t) ?? { topic0: t, count: 0, firstBlock: Number(l.blockNumber) };
        row.count += 1;
        seen.set(t, row);
    }
    res.topic0Table = [...seen.values()].sort((x, y) => x.firstBlock - y.firstBlock).map((r) => {
        const e = KNOWN.get(r.topic0);
        return { ...r, signature: e ? signatureOf(e) : null,
            class: !e ? "unclassified" : CURRENT.has(r.topic0) ? "current-abi" : "historical",
            source: !e ? null : CURRENT.has(r.topic0) ? "abis/SuperPaymaster.full.json" : HISTORICAL_SOURCE };
    });
    res.unclassifiedTopic0 = [...new Set(ev.unclassified.map((x) => x.topic0))];

    // State read-back at the pinned head, on BOTH endpoints with equal results (positive control: every
    // OperatorConfigured operator must read isConfigured).
    const must = async (label, fn) => {
        const r = await both(clients, fn, redact);
        if (!r.ok) throw new Error(`${label}: ${r.error}`);
        return r.value;
    };
    const read = (fn, args = []) => must(`SP.${fn}`, (c) => c.readContract({ address: SP, abi: SP_ABI, functionName: fn, args, blockNumber: head }));
    res.state.version = await read("version");
    res.state.APNTS_TOKEN = await read("APNTS_TOKEN");
    res.state.pendingAPNTsToken = await read("pendingAPNTsToken");
    const eta = await both(clients, (c) => c.readContract({ address: SP, abi: SP_ABI, functionName: "pendingAPNTsEta", blockNumber: head }), redact);
    res.state.pendingAPNTsEta = eta.ok ? eta.value.toString() : null;
    const ops = [...new Set(ev.OperatorConfigured.map((x) => getAddress(x.args.operator)))];
    res.state.operators = [];
    for (const op of ops) {
        const o = await read("operators", [op]);
        res.state.operators.push({ operator: op, aPNTsBalance: o[0].toString(), isConfigured: o[1], isPaused: o[2], xPNTsToken: o[3], treasury: o[6] });
    }

    // Independent sources from Registry: every address ever registered for PAYMASTER_SUPER (logs of
    // another contract, both endpoints) and the current holders (storage, not logs).
    const registry = await read("REGISTRY");
    const regDeploy = await Promise.all(endpoints.map((ep) => deployBlockOf(ep.client, registry, head)));
    if (regDeploy[0] !== regDeploy[1]) throw new Error("endpoints disagree on the Registry deploy block");
    const grants = [];
    for (const ep of endpoints) {
        grants.push(await fetchLogs(ep.client, registry, regDeploy[0], head, { event: ROLE_REGISTERED, args: { roleId: PAYMASTER_SUPER } }));
    }
    res.crossCheck.registryGrants = sameLogs(grants[0], grants[1]);
    if (!res.crossCheck.registryGrants.identical) throw new Error("endpoints return different Registry RoleRegistered logs");
    const everRegistered = [...new Set(grants[0].map((l) => getAddress(l.args.user)))];
    const base = keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [PAYMASTER_SUPER, ROLE_MEMBERS_SLOT]));
    const storageAt = (slot) => must("Registry storage", (c) => c.getStorageAt({ address: registry, slot, blockNumber: head }));
    const count = hexToBigInt(await storageAt(base));
    const viewCount = await must("Registry.getRoleUserCount", (c) => c.readContract({ address: registry, abi: REGISTRY_ABI,
        functionName: "getRoleUserCount", args: [PAYMASTER_SUPER], blockNumber: head }));
    const first = hexToBigInt(keccak256(base));
    const holders = [];
    for (let i = 0n; i < count; i++) holders.push(getAddress("0x" + (await storageAt(numberToHex(first + i, { size: 32 }))).slice(26)));
    res.state.registry = registry;
    res.state.superHolders = { fromStorage: holders, storageCount: count.toString(), getRoleUserCount: viewCount.toString(),
        everRegistered, registryDeployBlock: Number(regDeploy[0]) };

    // Every address seen as an `operator` argument, and every PAYMASTER_SUPER holder, outside the list
    // must read back as not configured.
    const listed = new Set(ops);
    const others = [...new Set([...ev.operatorArgs.map((x) => x.operator), ...holders, ...everRegistered])].filter((a) => !listed.has(a));
    res.state.outsideList = [];
    for (const op of others) {
        const o = await read("operators", [op]);
        res.state.outsideList.push({ operator: op, isConfigured: o[1], superHolder: holders.includes(op), everRegistered: everRegistered.includes(op) });
    }

    const pairs = [...new Set(ev.DebtRecordFailed.map((x) => `${getAddress(x.args.token)}|${getAddress(x.args.user)}`))];
    res.state.pendingDebts = [];
    for (const p of pairs) {
        const [token, user] = p.split("|");
        res.state.pendingDebts.push({ token, user, amount: (await read("pendingDebts", [token, user])).toString() });
    }
    const after = await Promise.all(clients.map((c) => c.getBlock({ blockNumber: head })));
    res.positiveControl = {
        pinnedBlockUnchanged: after.every((b) => b.hash === res.pinnedBlock.hash),
        endpointsReturnIdenticalRegistryGrants: res.crossCheck.registryGrants.identical,
        everyHolderEverRegistered: holders.every((h) => everRegistered.includes(h)),
        operatorConfiguredEventsFound: ev.OperatorConfigured.length > 0,
        everyEventOperatorReadsConfigured: res.state.operators.every((o) => o.isConfigured),
        noUnclassifiedTopic0: res.unclassifiedTopic0.length === 0,
        endpointsReturnIdenticalLogs: res.crossCheck.allLogs.identical,
        roleMembersSlotMatchesView: count === viewCount,
        noConfiguredOperatorOutsideList: res.state.outsideList.every((o) => !o.isConfigured),
    };
    console.log(JSON.stringify({ pinnedBlock: res.pinnedBlock, deployBlock: res.deployBlock, range: res.range, endpoints: res.endpoints,
        crossCheck: res.crossCheck, events: res.events,
        topic0Table: res.topic0Table.map((r) => `${r.topic0} ${r.signature} ${r.count} ${r.firstBlock} ${r.class}`), operators: res.state.operators.map((o) => o.operator),
        superHolders: res.state.superHolders, outsideList: res.state.outsideList,
        pendingDebtPairs: res.state.pendingDebts.length,
        nonzeroPendingDebts: res.state.pendingDebts.filter((d) => d.amount !== "0").length,
        pendingAPNTsToken: res.state.pendingAPNTsToken, unclassifiedTopic0: res.unclassifiedTopic0,
        positiveControl: res.positiveControl }, null, 2));
    if (!Object.values(res.positiveControl).every(Boolean)) {
        console.error("INVENTORY INCOMPLETE: see positiveControl (no output file written)");
        process.exit(1);
    }
    if (JSON.stringify(Object.keys(res.positiveControl).sort()) !== JSON.stringify([...REQUIRED_CONTROLS[INVENTORY_SCHEMA]].sort())) {
        throw new Error("positiveControl names differ from REQUIRED_CONTROLS for " + INVENTORY_SCHEMA);
    }
    // Written only after every control holds, atomically: temp file in the same directory, then rename.
    writeAtomic(outPath, JSON.stringify(res, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2));
}

main().catch((e) => {
    console.error("INVENTORY FAILED: " + redact(e?.stack ?? e));
    process.exit(1);
});

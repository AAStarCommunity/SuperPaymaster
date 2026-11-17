// Runbook step 0 (D5.3): inventory of SP logs across upgrades. READ-ONLY.
// Scans SP logs on TWO independent endpoints and cross-checks (completeness cannot be inferred
// from returned data — a missing range looks exactly like an empty one). Every hit is then
// read back against live state (positive control for the event selectors).
// Completeness against event-signature drift: logs are fetched WITHOUT a topic filter. Every
// topic0 must be either an inventory event (all historical variants, merged under one key) or a
// listed non-inventory event; any other topic0 fails the run. Every address indexed by an
// operator-keyed event must be in the operator list or read back as not configured.
// Usage: node script/rehearsal/inventory.mjs <envFileWithRPC_URL> <secondRpcUrl> <out.json>
//   The first endpoint's URL is read from RPC_URL in the env file and NEVER printed.
import { readFileSync, writeFileSync } from "node:fs";
import { createPublicClient, http, parseAbiItem, getAddress, decodeEventLog, toEventSelector } from "viem";

const [envFile, secondRpc, outPath] = process.argv.slice(2);
const env = Object.fromEntries(readFileSync(envFile, "utf8").split("\n")
    .filter((l) => /^\s*[A-Z0-9_]+\s*=/.test(l))
    .map((l) => { const i = l.indexOf("="); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, "")]; }));
if (!env.RPC_URL) throw new Error("RPC_URL missing in env file");

const SP = "0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9";
const EVENTS = {
    // 4-argument form up to SuperPaymaster 5.3.2; 3-argument form from 5.4.x.
    OperatorConfigured: [
        parseAbiItem("event OperatorConfigured(address indexed operator, address xPNTsToken, address treasury)"),
        parseAbiItem("event OperatorConfigured(address indexed operator, address xPNTsToken, address treasury, uint256 exchangeRate)"),
    ],
    OperatorDeposited: parseAbiItem("event OperatorDeposited(address indexed operator, uint256 amount)"),
    DebtRecordFailed: parseAbiItem("event DebtRecordFailed(address indexed token, address indexed user, uint256 amount)"),
    PendingDebtRetried: parseAbiItem("event PendingDebtRetried(address indexed token, address indexed user, uint256 amount)"),
    PendingDebtCleared: parseAbiItem("event PendingDebtCleared(address indexed token, address indexed user, uint256 amount)"),
    APNTsTokenChangeQueued: parseAbiItem("event APNTsTokenChangeQueued(address indexed pendingToken, uint256 eta)"),
    APNTsTokenChangeCancelled: parseAbiItem("event APNTsTokenChangeCancelled(address indexed pendingToken)"),
    APNTsTokenChangeExecuted: parseAbiItem("event APNTsTokenChangeExecuted(address indexed oldToken, address indexed newToken, uint256 executedAt)"),
    // The same proxy emits 5.4.2 and 5.5.2 logs; merge both generations under the existing keys.
    OperatorPaused: [
        parseAbiItem("event OperatorPaused(address indexed operator)"),
        parseAbiItem("event OperatorPaused(address indexed operator, address indexed by, uint8 reason)"),
    ],
    OperatorUnpaused: [
        parseAbiItem("event OperatorUnpaused(address indexed operator)"),
        parseAbiItem("event OperatorUnpaused(address indexed operator, address indexed by, uint8 reason)"),
    ],
};
// Seen on this proxy and not needed for the inventory. Operator-keyed ones (first indexed argument
// is the operator) feed the cross-check below.
const OPERATOR_KEYED = [
    "event TransactionSponsored(address indexed operator, address indexed user, uint256 aPNTsCost, uint256 xPNTsCost)",
    "event OperatorWithdrawn(address indexed operator, uint256 amount)",
    "event TreasuryUpdated(address indexed operator, address indexed treasury)",
    "event OperatorMinTxIntervalUpdated(address indexed operator, uint48 minTxInterval)",
].map(parseAbiItem);
const NON_INVENTORY = [
    "event PriceUpdated(int256 price, uint256 updatedAt)",
    "event ReputationUpdated(address indexed user, uint256 score)",
    "event BLSAggregatorUpdated(address indexed oldAggregator, address indexed newAggregator)",
    "event BLSAggregatorQueued(address indexed aggregator, uint48 eta)",
    "event Upgraded(address indexed implementation)",
    "event AgentRegistriesUpdated(address identity, address reputation)",
    "event SlashQueued(address indexed operator)",
    "event OperatorSlashed(address indexed operator, uint256 amount, uint8 level)",
    "event SlashExecutedWithProof(address indexed operator, uint8 level, uint256 penalty, bytes32 proofHash, uint256 timestamp)",
    "event APNTsPriceUpdated(uint256 oldPrice, uint256 newPrice)",
    "event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee)",
    "event OwnershipTransferred(address indexed previousOwner, address indexed newOwner)",
    "event Initialized(uint64 version)",
    "event XPNTsFactoryUpdated(address indexed oldFactory, address indexed newFactory)",
    "event BlsSlashCooldownPrimed(uint48 primedAt)",
    "event ProtocolRevenueWithdrawn(address indexed to, uint256 amount)",
].map(parseAbiItem);
const INVENTORY_ITEMS = Object.entries(EVENTS).flatMap(([name, v]) => (Array.isArray(v) ? v : [v]).map((item) => ({ name, item })));
const BY_TOPIC = new Map(INVENTORY_ITEMS.map(({ name, item }) => [toEventSelector(item), { name, item }]));
const KEYED_TOPICS = new Set(OPERATOR_KEYED.map((e) => toEventSelector(e)));
const OTHER_TOPICS = new Set(NON_INVENTORY.map((e) => toEventSelector(e)));
for (const t of KEYED_TOPICS) OTHER_TOPICS.add(t);

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
    const out = { _unclassified: [], _operatorKeyed: [] };
    for (const name of Object.keys(EVENTS)) out[name] = [];
    let step = 50_000n;
    for (let start = from; start <= to;) {
        const end = start + step - 1n > to ? to : start + step - 1n;
        try {
            // No topic filter: a signature this script does not know must show up, not vanish.
            const logs = await c.getLogs({ address: SP, fromBlock: start, toBlock: end });
            for (const l of logs) {
                const t0 = l.topics[0] ?? "anonymous";
                const at = { block: Number(l.blockNumber), tx: l.transactionHash, logIndex: l.logIndex };
                const hit = BY_TOPIC.get(t0);
                if (hit) {
                    const { args } = decodeEventLog({ abi: [hit.item], data: l.data, topics: l.topics });
                    out[hit.name].push({ ...at, args });
                } else if (KEYED_TOPICS.has(t0)) {
                    out._operatorKeyed.push({ ...at, topic0: t0, operator: getAddress("0x" + l.topics[1].slice(26)) });
                } else if (!OTHER_TOPICS.has(t0)) {
                    out._unclassified.push({ ...at, topic0: t0 });
                }
            }
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
for (const name of [...Object.keys(EVENTS), "_unclassified", "_operatorKeyed"]) {
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
// Every operator-keyed address outside the list must read back as not configured.
const listed = new Set(ops);
const others = [...new Set([...ev._operatorKeyed.map((x) => x.operator),
    ...ev.OperatorDeposited.map((x) => getAddress(x.args.operator)),
    ...ev.OperatorPaused.map((x) => getAddress(x.args.operator)),
    ...ev.OperatorUnpaused.map((x) => getAddress(x.args.operator))])].filter((a) => !listed.has(a));
res.state.operatorKeyedOutsideList = [];
for (const op of others) {
    const o = await read("operators", [op]);
    res.state.operatorKeyedOutsideList.push({ operator: op, isConfigured: o[1] });
}
res.unclassifiedTopic0 = [...new Set(ev._unclassified.map((x) => x.topic0))];
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
    noUnclassifiedTopic0: res.unclassifiedTopic0.length === 0,
    noConfiguredOperatorOutsideList: res.state.operatorKeyedOutsideList.every((o) => !o.isConfigured),
};
writeFileSync(outPath, JSON.stringify(res, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2));
console.log(JSON.stringify({ deployBlock: res.deployBlock, range: res.range, endpoints: res.endpoints, crossCheck: res.crossCheck,
    operators: res.state.operators.length, pendingDebtPairs: res.state.pendingDebts.length,
    nonzeroPendingDebts: res.state.pendingDebts.filter((d) => d.amount !== "0").length,
    pendingAPNTsToken: res.state.pendingAPNTsToken, unclassifiedTopic0: res.unclassifiedTopic0,
    operatorKeyedOutsideList: res.state.operatorKeyedOutsideList, positiveControl: res.positiveControl }, null, 2));
const pc = res.positiveControl;
const crossOk = Object.values(res.crossCheck).every((x) => x.identical);
if (!(pc.operatorConfiguredEventsFound && pc.everyEventOperatorReadsConfigured && pc.noUnclassifiedTopic0
    && pc.noConfiguredOperatorOutsideList && crossOk)) {
    console.error("INVENTORY INCOMPLETE: see positiveControl / crossCheck / unclassifiedTopic0");
    process.exit(1);
}

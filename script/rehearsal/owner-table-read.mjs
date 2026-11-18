// rc.8 owner table v1: fill the `current` column of docs/security/rc8-owner-table.json from
// Sepolia. READ-ONLY (eth_call / eth_getStorageAt / eth_getCode / eth_getLogs by address+topic).
// Every read is made at the inventory's pinned block on BOTH endpoints and must agree.
//
// Usage: node script/rehearsal/owner-table-read.mjs <envFileWithRPC_URL> <secondRpcUrl> <inventory.json> [table.json]
//   inventory.json = output of script/rehearsal/inventory.mjs (gives the pinned block and the operator lists).
//   Neither endpoint URL is printed or written; endpoints are recorded by provider name only.
// After a read, regenerate the doc: node scripts/gen-rc8-owner-table.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { createPublicClient, http, parseAbi, parseAbiItem, getAddress, keccak256, stringToHex } from "viem";

const [envFile, secondRpc, inventoryPath, tablePath = "docs/security/rc8-owner-table.json"] = process.argv.slice(2);
const env = Object.fromEntries(readFileSync(envFile, "utf8").split("\n").filter((l) => /^\s*RPC_URL\s*=/.test(l))
    .map((l) => { const i = l.indexOf("="); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, "")]; }));
if (!env.RPC_URL || !secondRpc) throw new Error("RPC_URL (env file) and second RPC URL are required");
const SECRETS = [env.RPC_URL, secondRpc].flatMap((u) => { try { const x = new URL(u); return [u, x.host, x.pathname, x.search]; } catch { return [u]; } })
    .filter((s) => s && s.length > 3).sort((a, b) => b.length - a.length);
const redact = (s) => SECRETS.reduce((t, f) => t.split(f).join("<redacted>"), String(s));
// Provider names, never URLs (rpca = Alchemy, rpcb = Tenderly; see the runbook endpoint note).
const PROVIDERS = ["Alchemy", "Tenderly"];
const clients = [env.RPC_URL, secondRpc].map((u) => createPublicClient({ transport: http(u, { timeout: 60_000 }) }));

const table = JSON.parse(readFileSync(tablePath, "utf8"));
const invRaw = readFileSync(inventoryPath);
const inv = JSON.parse(invRaw);
const block = BigInt(inv.pinnedBlock.number);
const ID = table.identities;
for (const k of Object.keys(ID)) if (ID[k] !== null) ID[k] = getAddress(ID[k]); // stored checksummed
const resolve = (v) => (typeof v === "string" && Object.hasOwn(ID, v) ? ID[v] : v);
const norm = (v) => (typeof v === "string" && /^0x[0-9a-fA-F]{40}$/.test(v) ? getAddress(v) : typeof v === "bigint" ? v.toString() : v);

async function both(fn) {
    const r = await Promise.all(clients.map((c) => fn(c).then((v) => ({ v }), (e) => ({ e: e.shortMessage ?? e.message }))));
    const k = r.map((x) => JSON.stringify(x.v ?? null, (_, y) => (typeof y === "bigint" ? y.toString() : y)) + (x.e ? "!" : ""));
    if (k[0] !== k[1]) throw new Error("endpoints disagree: " + redact(k.join(" | ")).slice(0, 300));
    if (r[0].e) return { error: "reverted or absent: " + redact(r[0].e).split("\n")[0].slice(0, 120) };
    return { value: r[0].v };
}

async function deployBlock(c, address) {
    let lo = 0n, hi = block;
    while (lo < hi) {
        const mid = (lo + hi) / 2n;
        const code = await c.getCode({ address, blockNumber: mid });
        if (code && code !== "0x") hi = mid; else lo = mid + 1n;
    }
    return lo;
}

async function logs(c, address, from, event, args) {
    const out = [];
    for (let start = from, step = 50_000n; start <= block;) {
        const end = start + step - 1n > block ? block : start + step - 1n;
        try { out.push(...await c.getLogs({ address, event, args, fromBlock: start, toBlock: end })); start = end + 1n; }
        catch (e) { if (step <= 500n) throw new Error(redact(e.message).slice(0, 160)); step /= 4n; }
    }
    return out;
}

// "$member" = the set candidate; "$keccak:NAME" = keccak256(NAME); identity names resolve to addresses.
const word = (a) => (typeof a === "string" && a.startsWith("$keccak:") ? keccak256(stringToHex(a.slice(8))) : resolve(a));
const subst = (args, member) => (args ?? []).map((a) => (a === "$member" ? member : word(a)));

async function readCall(address, r, member) {
    const abi = parseAbi([r.fn]);
    const res = await both((c) => c.readContract({ address, abi, functionName: abi[0].name, args: subst(r.args, member), blockNumber: block }));
    if (res.value !== undefined && r.pick !== undefined) res.value = res.value[r.pick];
    if (res.value !== undefined) res.value = norm(res.value);
    return res;
}

async function readSet(address, r) {
    // Candidates = every member named by an event of the listed kinds + every named identity;
    // membership = the getter at the pinned block (events seed, state decides).
    const from = async (a) => {
        const b = await Promise.all(clients.map((c) => deployBlock(c, a)));
        if (b[0] !== b[1]) throw new Error("endpoints disagree on deploy block of " + a);
        return b[0];
    };
    const fromBlocks = [await from(address)];
    const candidates = new Set(Object.values(ID).filter((a) => /^0x[0-9a-fA-F]{40}$/.test(a)).map((a) => getAddress(a)));
    const seeds = [];
    for (const s of r.seeds) {
        const ev = parseAbiItem(s.event);
        const filter = s.args ? Object.fromEntries(Object.entries(s.args).map(([k, v]) => [k, word(v)])) : undefined;
        // A seed may come from another contract (e.g. Registry RoleRegistered for a precondition role).
        const at = s.address ? resolve(s.address) : address;
        const start = s.address ? await from(at) : fromBlocks[0];
        const got = await Promise.all(clients.map((c) => logs(c, at, start, ev, filter)));
        const fp = (ls) => ls.map((l) => `${l.blockHash}:${l.logIndex}`).sort().join(",");
        if (fp(got[0]) !== fp(got[1])) throw new Error("endpoints return different logs for " + s.event);
        const members = [...new Set(got[0].map((l) => getAddress(l.args[s.member])))];
        members.forEach((m) => candidates.add(m));
        seeds.push({ event: ev.name, address: getAddress(at), fromBlock: Number(start), filter: s.args ?? null, logs: got[0].length, members });
    }
    const holders = [];
    for (const m of [...candidates].sort()) {
        const res = await readCall(address, r.check, m);
        if (res.error) return { error: `${m}: ${res.error}` };
        if (res.value === true) holders.push(m);
    }
    return { value: holders, deployBlock: Number(fromBlocks[0]), seeds, candidates: candidates.size };
}

async function main() {
    const pinned = await both((c) => c.getBlock({ blockNumber: block }).then((b) => b.hash));
    if (pinned.value !== inv.pinnedBlock.hash) throw new Error("pinned block hash differs from the inventory");
    // Role ids from IRegistry.sol, cross-checked against Registry.getRoleConfig on Sepolia.
    const src = readFileSync(new URL("../../contracts/src/interfaces/v3/IRegistry.sol", import.meta.url), "utf8");
    const roles = [...src.matchAll(/^bytes32 constant (ROLE_\w+)\s*=\s*keccak256\("(\w+)"\);/gm)].map((m) => ({ constant: m[1], name: m[2], id: keccak256(stringToHex(m[2])) }));
    for (const r of roles) {
        const cfg = await readCall(ID.REGISTRY, { fn: table.roleConfigFn, args: [r.id] });
        if (cfg.error) throw new Error(`getRoleConfig(${r.name}) failed: ${cfg.error}`);
        Object.assign(r, { description: cfg.value.description, owner: norm(cfg.value.owner), isActive: cfg.value.isActive,
            minStake: cfg.value.minStake.toString(), configured: cfg.value.minStake > 0n || cfg.value.owner !== "0x0000000000000000000000000000000000000000" });
    }
    // Negative control: an id that is not a role must read back unconfigured, or "configured" proves nothing.
    const none = await readCall(ID.REGISTRY, { fn: table.roleConfigFn, args: [keccak256(stringToHex("NOT_A_ROLE"))] });
    if (none.error || none.value.isActive || none.value.owner !== "0x0000000000000000000000000000000000000000") throw new Error("role negative control failed");
    if (roles.length !== 7 || !roles.every((r) => r.configured)) throw new Error("expected 7 configured roles from IRegistry.sol");
    table.roles = roles;
    for (const row of table.rows) {
        const address = resolve(row.address);
        let res;
        if (address === null) res = { error: "not deployed at the pinned block (address assigned at deploy)" };
        else if (row.read.fn) res = await readCall(address, row.read);
        else if (row.read.storage) res = await both((c) => c.getStorageAt({ address, slot: row.read.storage, blockNumber: block }))
            .then((x) => (x.value ? { value: getAddress("0x" + x.value.slice(26)) } : x));
        else if (row.read.code) res = await both((c) => c.getCode({ address, blockNumber: block })).then((x) => ({ value: x.value && x.value !== "0x" ? "has code" : "no code" }));
        else if (row.read.set) res = await readSet(address, row.read.set);
        else if (row.read.inventory) res = { value: row.read.inventory.split(".").reduce((o, k) => o[k], inv) };
        else throw new Error("row " + row.id + ": unknown read kind");
        row.current = res.error ? { error: res.error } : { value: res.value, ...(res.seeds ? { seeds: res.seeds, deployBlock: res.deployBlock, candidates: res.candidates } : {}) };
        console.log(row.id, JSON.stringify(row.current.value ?? row.current.error).slice(0, 140));
    }
    table.readAt = { chainId: 11155111, block: inv.pinnedBlock.number, hash: inv.pinnedBlock.hash, endpoints: PROVIDERS,
        rule: "every value read on both endpoints at this block and required to be identical" };
    table.inventory = {
        path: inventoryPath.replace(/^.*?(script\/evidence\/)/, "$1"), sha256: createHash("sha256").update(invRaw).digest("hex"),
        configuredOperators: inv.state.operators.filter((o) => o.isConfigured).map((o) => o.operator),
        superRoleHolders: inv.state.superHolders.fromStorage, everRegisteredSuper: inv.state.superHolders.everRegistered,
        registryDeployBlock: inv.state.superHolders.registryDeployBlock, topic0Table: inv.topic0Table,
    };
    writeFileSync(tablePath, JSON.stringify(table, null, 2) + "\n");
}

main().catch((e) => { console.error("OWNER TABLE READ FAILED: " + redact(e?.stack ?? e)); process.exit(1); });

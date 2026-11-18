// rc.8 owner table v1: fill the `current` column of docs/security/rc8-owner-table.json from
// Sepolia. READ-ONLY (eth_call / eth_getStorageAt / eth_getCode / eth_getLogs by address+topic).
// Every read is made at the inventory's pinned block on BOTH endpoints and must agree.
//
// Usage: node script/rehearsal/owner-table-read.mjs <envFileWithRPC_URL> <secondRpcUrl> <inventory.json> [table.json]
//   inventory.json = output of script/rehearsal/inventory.mjs (gives the pinned block and the operator lists).
//   Neither endpoint URL is printed or written; endpoints are recorded by a provider name derived from
//   the host (lib/two-endpoint.mjs PROVIDERS), with the verified chain id and finalized heights.
//   The inventory is refused unless all its controls are true and it is bound to this chain, SP and Registry.
// After a read, regenerate the doc: node scripts/gen-rc8-owner-table.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { createPublicClient, http, parseAbi, parseAbiItem, getAddress, keccak256, stringToHex, toFunctionSelector } from "viem";
import { makeRedactor, assertIndependent, both as both2, verifyPin, requireIdenticalLogs, codeAt, classifyRead } from "./lib/two-endpoint.mjs";
import { inventoryErrors } from "./lib/inventory-accept.mjs";

const [envFile, secondRpc, inventoryPath, tablePath = "docs/security/rc8-owner-table.json"] = process.argv.slice(2);
const env = Object.fromEntries(readFileSync(envFile, "utf8").split("\n").filter((l) => /^\s*RPC_URL\s*=/.test(l))
    .map((l) => { const i = l.indexOf("="); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, "")]; }));
if (!env.RPC_URL || !secondRpc) throw new Error("RPC_URL (env file) and second RPC URL are required");
const redact = makeRedactor([env.RPC_URL, secondRpc]);
const PROVIDERS = assertIndependent(env.RPC_URL, secondRpc); // throws on an identical host or provider
const CHAIN_ID = 11155111;
const clients = [env.RPC_URL, secondRpc].map((u) => createPublicClient({ transport: http(u, { timeout: 60_000 }) }));

const table = JSON.parse(readFileSync(tablePath, "utf8"));
const invRaw = readFileSync(inventoryPath);
const inv = JSON.parse(invRaw);
const ID = table.identities;
for (const k of Object.keys(ID)) if (ID[k] !== null) ID[k] = getAddress(ID[k]); // stored checksummed
const refused = inventoryErrors(inv, { chainId: CHAIN_ID, sp: ID.SP, registry: ID.REGISTRY });
if (refused.length) throw new Error("inventory refused:\n  " + refused.join("\n  "));
const block = BigInt(inv.pinnedBlock.number);
const resolve = (v) => (typeof v === "string" && Object.hasOwn(ID, v) ? ID[v] : v);
const norm = (v) => (typeof v === "string" && /^0x[0-9a-fA-F]{40}$/.test(v) ? getAddress(v) : typeof v === "bigint" ? v.toString() : v);

async function both(fn) {
    const r = await both2(clients, fn, redact);
    return r.ok ? r : { ok: false, revert: r.revert, error: (r.revert ? "reverted: " : "read failed: ") + r.error.slice(0, 120) };
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
    if (res.ok && r.pick !== undefined) res.value = res.value[r.pick];
    if (res.ok) res.value = norm(res.value);
    return res;
}

async function readRange(address, r) {
    // fn(i) for i in [from, to]; the non-zero results, with their index (e.g. validatorAtSlot(1..13)).
    const out = [];
    for (let i = r.range[0]; i <= r.range[1]; i++) {
        const res = await readCall(address, r, i);
        if (!res.ok) return { ok: false, error: `index ${i}: ${res.error}` };
        if (res.value !== "0x0000000000000000000000000000000000000000") out.push({ index: i, value: res.value });
    }
    return { ok: true, value: out.map((x) => x.value), indexed: out };
}

// Class-3 (legacy) evidence: no deployed rc.8 contract returns a legacy subject from any zero-argument
// address getter of its rc.8 ABI, and no rc.8 role mapping holds it. Every read is classified:
//   ok          - answered on both endpoints (the value is the evidence);
//   notInCode   - reverted AND the 4-byte selector occurs in no reachable runtime (the address, its EIP-1967
//                 implementation, its EXTENSION()): the getter does not exist on the deployed version;
//   reverted    - reverted and absence could not be established (selector present, or a slot/code read
//                 failed, or a beacon): NOT evidence of absence;
//   failed      - transport/provider failure: NOT evidence of absence.
// The generator keeps every class-3 row PENDING while any read is reverted or failed.
async function legacyProbe(lp) {
    const subjects = [...new Set(lp.subjects.map((k) => getAddress(resolve(k))))];
    const hit = (v) => [v].flat().filter((x) => typeof x === "string" && /^0x[0-9a-fA-F]{40}$/.test(x)).map((x) => getAddress(x)).filter((x) => subjects.includes(x));
    // Code holders beyond the address itself: an EXTENSION() the target delegates to (when it has one).
    const extras = {};
    const extraOf = async (target) => {
        if (!(target in extras)) {
            const r = await readCall(resolve(target), { fn: "function EXTENSION() view returns (address)" });
            // A revert means the target has no EXTENSION(); any other failure leaves the holder set unknown,
            // which classifyRead must treat as "absence not established" (null -> reverted).
            extras[target] = r.ok ? (r.value !== "0x0000000000000000000000000000000000000000" ? [r.value] : [])
                : r.revert ? [] : null;
        }
        return extras[target];
    };
    const classify = async (target, fn, res) => classifyRead(clients, { address: resolve(target), blockNumber: block,
        selector: toFunctionSelector(fn), res, extra: res.ok ? [] : await extraOf(target) }, redact);
    const getters = [], hits = [];
    for (const [target, spec] of Object.entries(lp.getterTargets)) {
        const abiJson = spec.abi ? JSON.parse(readFileSync(new URL("../../" + spec.abi, import.meta.url), "utf8")) : [];
        const fns = (Array.isArray(abiJson) ? abiJson : abiJson.abi).filter((f) => f.type === "function" && f.inputs.length === 0 &&
            ["view", "pure"].includes(f.stateMutability) && f.outputs.length === 1 && ["address", "address[]"].includes(f.outputs[0].type))
            .map((f) => `function ${f.name}() view returns (${f.outputs[0].type})`).concat((spec.extra ?? []).map((n) => `function ${n}() view returns (address)`));
        for (const fn of [...new Set(fns)].sort()) {
            const res = await readCall(resolve(target), { fn });
            const name = fn.slice(9, fn.indexOf("("));
            getters.push({ target, getter: name, status: await classify(target, fn, res) });
            for (const h of res.ok ? hit(res.value) : []) hits.push({ subject: h, probe: `${target}.${name}()` });
        }
    }
    const members = [];
    for (const subject of subjects) for (const m of lp.memberProbes) {
        const res = await readCall(resolve(m.target), { fn: m.fn, args: m.args, pick: m.pick }, subject);
        const label = `${m.target}.${m.label}`;
        members.push({ subject, probe: label, status: await classify(m.target, m.fn, res) });
        if (res.ok && res.value === true) hits.push({ subject, probe: label });
    }
    const by = (list, st, f) => [...new Set(list.filter((g) => g.status === st).map(f))];
    const gname = (g) => `${g.target}.${g.getter}()`;
    return { subjects, gettersRead: getters.filter((g) => g.status === "ok").length,
        gettersNotInCode: by(getters, "notInCode", gname), gettersReverted: by(getters, "reverted", gname), gettersFailed: by(getters, "failed", gname),
        memberReads: members.filter((m) => m.status === "ok").length,
        // Any member probe that did not answer for some subject: keeps every class-3 row PENDING.
        memberAbsent: [...new Set(members.filter((m) => m.status !== "ok").map((m) => m.probe))], hits };
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
        // Full payload (address, topics, data, blockHash, logIndex, txHash); candidates only after agreement.
        requireIdenticalLogs(got[0], got[1], s.event);
        const members = [...new Set(got[0].map((l) => getAddress(l.args[s.member])))];
        members.forEach((m) => candidates.add(m));
        seeds.push({ event: ev.name, address: getAddress(at), fromBlock: Number(start), filter: s.args ?? null, logs: got[0].length, members });
    }
    const holders = [];
    for (const m of [...candidates].sort()) {
        const res = await readCall(address, r.check, m);
        if (!res.ok) return { ok: false, error: `${m}: ${res.error}` };
        if (res.value === true) holders.push(m);
    }
    return { ok: true, value: holders, deployBlock: Number(fromBlocks[0]), seeds, candidates: candidates.size };
}

async function main() {
    // Both endpoints: chain id 11155111, pin <= finalized head, and the inventory's hash at the pin.
    const provenance = await verifyPin(clients, CHAIN_ID, inv.pinnedBlock.number, inv.pinnedBlock.hash);
    // Role ids from IRegistry.sol, cross-checked against Registry.getRoleConfig on Sepolia.
    const src = readFileSync(new URL("../../contracts/src/interfaces/v3/IRegistry.sol", import.meta.url), "utf8");
    const roles = [...src.matchAll(/^bytes32 constant (ROLE_\w+)\s*=\s*keccak256\("(\w+)"\);/gm)].map((m) => ({ constant: m[1], name: m[2], id: keccak256(stringToHex(m[2])) }));
    for (const r of roles) {
        const cfg = await readCall(ID.REGISTRY, { fn: table.roleConfigFn, args: [r.id] });
        if (!cfg.ok) throw new Error(`getRoleConfig(${r.name}) failed: ${cfg.error}`);
        Object.assign(r, { description: cfg.value.description, owner: norm(cfg.value.owner), isActive: cfg.value.isActive,
            minStake: cfg.value.minStake.toString(), configured: cfg.value.minStake > 0n || cfg.value.owner !== "0x0000000000000000000000000000000000000000" });
    }
    // Negative control: an id that is not a role must read back unconfigured, or "configured" proves nothing.
    const none = await readCall(ID.REGISTRY, { fn: table.roleConfigFn, args: [keccak256(stringToHex("NOT_A_ROLE"))] });
    if (!none.ok || none.value.isActive || none.value.owner !== "0x0000000000000000000000000000000000000000") throw new Error("role negative control failed");
    if (roles.length !== 7 || !roles.every((r) => r.configured)) throw new Error("expected 7 configured roles from IRegistry.sol");
    table.roles = roles;
    for (const row of table.rows) {
        const address = resolve(row.address);
        let res;
        if (address === null) res = { ok: false, error: "not deployed at the pinned block (address assigned at deploy)" };
        else if (row.read.fn && !row.read.range) res = await readCall(address, row.read);
        else if (row.read.storage) res = await both((c) => c.getStorageAt({ address, slot: row.read.storage, blockNumber: block }))
            .then((x) => (x.ok ? { ok: true, value: getAddress("0x" + x.value.slice(26)) } : x));
        else if (row.read.code) res = await codeAt(clients, address, block, redact); // a failed read stays an error
        else if (row.read.set) res = await readSet(address, row.read.set);
        else if (row.read.range) res = await readRange(address, row.read);
        else if (row.read.inventory) res = { ok: true, value: row.read.inventory.split(".").reduce((o, k) => o[k], inv) };
        else throw new Error("row " + row.id + ": unknown read kind");
        row.current = !res.ok ? { error: res.error } : { value: res.value, ...(res.seeds ? { seeds: res.seeds, deployBlock: res.deployBlock, candidates: res.candidates } : {}) };
        console.log(row.id, JSON.stringify(row.current.value ?? row.current.error).slice(0, 140));
    }
    if (table.legacyProbe) table.legacyProbe.results = await legacyProbe(table.legacyProbe);
    table.readAt = { chainId: provenance.chainId, block: provenance.number, hash: provenance.hash, endpoints: PROVIDERS,
        finalizedAtRead: provenance.finalized,
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

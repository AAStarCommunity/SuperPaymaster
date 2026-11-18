// Shared two-endpoint discipline for the read-only rehearsal scripts (inventory.mjs, owner-table-read.mjs).
// One implementation of: URL redaction, endpoint independence, provider naming, finalized-pin
// selection/verification, full-payload log comparison and "read on both, require equality".
// Nothing here prints or returns a URL or any part of one.

import { writeFileSync, renameSync, rmSync } from "node:fs";
import { dirname, basename, join } from "node:path";

// Write `text` to `path` atomically: a temp file in the same directory, renamed into place; the temp
// file is removed if anything fails, and `path` is then left as it was.
export function writeAtomic(path, text) {
    const tmp = join(dirname(path), `.${basename(path)}.tmp-${process.pid}`);
    try {
        writeFileSync(tmp, text);
        renameSync(tmp, path);
    } catch (e) {
        rmSync(tmp, { force: true });
        throw e;
    }
}

// Host suffix -> provider name. A host that matches nothing is recorded as "unlisted", never by name.
export const PROVIDERS = [
    ["alchemy.com", "Alchemy"], ["tenderly.co", "Tenderly"], ["infura.io", "Infura"], ["publicnode.com", "PublicNode"],
    ["drpc.org", "dRPC"], ["ankr.com", "Ankr"], ["quiknode.pro", "QuickNode"], ["blastapi.io", "Blast"],
];

// Normalized hostname: lower-case, no trailing dot, port ignored (URL.hostname never carries the port).
export function hostOf(url) {
    let h;
    try { h = new URL(url).hostname; } catch { throw new Error("an endpoint is not a valid URL"); }
    return h.toLowerCase().replace(/\.+$/, "");
}

export function providerOf(url) {
    const host = hostOf(url);
    const hit = PROVIDERS.find(([suffix]) => host === suffix || host.endsWith("." + suffix));
    return hit ? hit[1] : "unlisted";
}

// Every secret-bearing fragment of the URLs, in the forms a library may echo back (host included).
export function makeRedactor(urls) {
    const secrets = [];
    for (const u of urls) {
        if (typeof u !== "string" || u.length === 0) continue;
        secrets.push(u, u.replace(/\/+$/, ""));
        try {
            const x = new URL(u);
            secrets.push(x.href, x.host, x.hostname);
            if (x.pathname.length > 1) secrets.push(x.pathname, x.pathname.replace(/\/+$/, ""));
            if (x.search.length > 1) secrets.push(x.search);
            // Each path segment and each query value on its own, raw and decoded, so a credential echoed in
            // pieces is still caught. Each decode has its own try: one malformed %-escape must not stop the rest.
            const decoded = (v) => { try { return decodeURIComponent(v.replace(/\+/g, " ")); } catch { return v; } };
            for (const seg of x.pathname.split("/")) if (seg) secrets.push(seg, decoded(seg));
            for (const pair of x.search.replace(/^\?/, "").split("&")) {
                const i = pair.indexOf("=");
                if (i < 0) { if (pair) secrets.push(pair, decoded(pair)); continue; }
                const k = pair.slice(0, i), v = pair.slice(i + 1);
                secrets.push(pair, v, decoded(v), decoded(k) + "=" + decoded(v));
            }
            if (x.username) secrets.push(x.username);
            if (x.password) secrets.push(x.password);
        } catch { /* malformed: the raw string is still redacted */ }
    }
    const list = [...new Set(secrets.filter((s) => s.length >= 3))].sort((a, b) => b.length - a.length);
    return (s) => {
        let t = String(s);
        for (const f of list) t = t.split(f).join("<redacted>").split(f.toLowerCase()).join("<redacted>");
        return t;
    };
}

// The two endpoints must be different normalized hostnames, and two named providers must differ.
// Trust root: both endpoints are operator-configured honest providers, so no registrable-domain heuristic.
// Hosts are compared, never printed.
export function assertIndependent(urlA, urlB) {
    const [ha, hb] = [hostOf(urlA), hostOf(urlB)];
    if (ha === hb) throw new Error("the two endpoints must be different hosts (identical host)");
    const [a, b] = [providerOf(urlA), providerOf(urlB)];
    if (a === b && a !== "unlisted") throw new Error(`the two endpoints must be different providers (both ${a})`);
    return [a, b];
}

const json = (v) => JSON.stringify(v ?? null, (_, y) => (typeof y === "bigint" ? y.toString() : y));

// A JSON-RPC revert (the call executed and reverted) vs anything else (transport, timeout, provider error).
// Decided from structured fields of the error and its `cause` chain, never from message text:
// a viem ContractFunctionRevertedError / ExecutionRevertedError, or a JSON-RPC error with code 3 and data.
// Any transport error in the chain (HTTP, timeout, socket) means it is NOT a revert.
const TRANSPORT_ERRORS = new Set(["HttpRequestError", "TimeoutError", "WebSocketRequestError", "SocketClosedError", "UrlRequiredError"]);
const REVERT_ERRORS = new Set(["ContractFunctionRevertedError", "ExecutionRevertedError"]);
export function isRevert(e) {
    const chain = [];
    for (let x = e, i = 0; x && typeof x === "object" && i < 16; x = x.cause, i++) chain.push(x);
    if (chain.some((x) => TRANSPORT_ERRORS.has(x.name))) return false;
    return chain.some((x) => REVERT_ERRORS.has(x.name) || (x.code === 3 && x.data !== undefined));
}

// Read on both endpoints and require identical results (both succeed with the same value, or both fail).
// Result: { ok: true, value } or { ok: false, error, revert } -- the discriminant is `ok`, never the error text.
export async function both(clients, fn, redact = String) {
    const r = await Promise.all(clients.map((c) => fn(c).then((v) => ({ ok: true, v }),
        (e) => ({ ok: false, e: String(e?.shortMessage ?? e?.message ?? e ?? ""), revert: isRevert(e) }))));
    if (r[0].ok !== r[1].ok || (r[0].ok && json(r[0].v) !== json(r[1].v))) {
        throw new Error("endpoints disagree: " + redact(r.map((x) => (x.ok ? json(x.v) : x.e)).join(" | ")).slice(0, 300));
    }
    if (!r[0].ok) return { ok: false, error: redact(r[0].e).split("\n")[0].slice(0, 160) || "(empty error)", revert: r[0].revert && r[1].revert };
    return { ok: true, value: r[0].v };
}

// Full payload of a log; two endpoints agree only if the sorted fingerprint lists are identical.
export const fingerprint = (l) => [l.address?.toLowerCase(), l.blockNumber, l.blockHash, l.logIndex, l.transactionHash,
    l.transactionIndex, l.removed === true, (l.topics ?? []).join(","), l.data].join(":");
const identity = (l) => `${l.blockHash}:${l.logIndex}:${l.transactionHash}`;

// Per endpoint: no removed log (the range ends at a finalized block) and no repeated log identity.
export function logDefects(list) {
    const seen = new Set(), dup = new Set();
    for (const l of list) { const k = identity(l); if (seen.has(k)) dup.add(k); seen.add(k); }
    return { removed: list.filter((l) => l.removed === true).length, duplicates: dup.size };
}

export function compareLogs(a, b) {
    const fa = a.map(fingerprint).sort(), fb = b.map(fingerprint).sort();
    const da = logDefects(a), db = logDefects(b);
    const clean = !da.removed && !db.removed && !da.duplicates && !db.duplicates;
    return { archive: fa.length, second: fb.length, removed: da.removed + db.removed, duplicates: da.duplicates + db.duplicates,
        identical: clean && fa.length === fb.length && fa.every((v, i) => v === fb[i]) };
}

export function requireIdenticalLogs(a, b, label) {
    const r = compareLogs(a, b);
    if (r.removed) throw new Error(`removed log returned for ${label} in a finalized range`);
    if (r.duplicates) throw new Error(`duplicate log identity returned for ${label}`);
    if (!r.identical) throw new Error(`endpoints return different logs for ${label} (${r.archive} vs ${r.second})`);
    return a;
}

async function chainIds(clients) {
    return Promise.all(clients.map((c) => c.getChainId()));
}

// Pin = the lower of the two finalized heads; both endpoints must report the expected chain id and the
// same hash at the pin.
export async function pinFinalized(clients, chainId) {
    const ids = await chainIds(clients);
    if (!ids.every((x) => x === chainId)) throw new Error(`eth_chainId mismatch: expected ${chainId}, got ${ids.join("/")}`);
    const fin = await Promise.all(clients.map((c) => c.getBlock({ blockTag: "finalized" })));
    const number = fin[0].number < fin[1].number ? fin[0].number : fin[1].number;
    const at = await Promise.all(clients.map((c) => c.getBlock({ blockNumber: number })));
    if (at[0].hash !== at[1].hash) throw new Error(`endpoints disagree on block ${number}`);
    return { chainId, number, hash: at[0].hash, finalized: fin.map((b) => Number(b.number)) };
}

// Verify an already chosen pin: chain id on both, pin <= both finalized heads, hash equal on both.
export async function verifyPin(clients, chainId, number, hash) {
    const ids = await chainIds(clients);
    if (!ids.every((x) => x === chainId)) throw new Error(`eth_chainId mismatch: expected ${chainId}, got ${ids.join("/")}`);
    const fin = await Promise.all(clients.map((c) => c.getBlock({ blockTag: "finalized" })));
    if (!fin.every((b) => b.number >= BigInt(number))) throw new Error(`pinned block ${number} is above a finalized head`);
    const at = await Promise.all(clients.map((c) => c.getBlock({ blockNumber: BigInt(number) })));
    if (!at.every((b) => b.hash === hash)) throw new Error(`pinned block ${number}: hash differs from the pin on an endpoint`);
    return { chainId, number: Number(number), hash, finalized: fin.map((b) => Number(b.number)) };
}

// Code at an address on both endpoints. A failed read stays an error; only a successful "0x" means no code.
export async function codeAt(clients, address, blockNumber, redact) {
    const r = await both(clients, (c) => c.getCode({ address, blockNumber }), redact);
    if (!r.ok) return { ok: false, error: "getCode failed: " + r.error };
    return { ok: true, value: typeof r.value === "string" && r.value !== "0x" ? "has code" : "no code" };
}

// ---- probe classification ------------------------------------------------------------------------
export const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
export const BEACON_SLOT = "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50";
const ZERO_WORD = "0x" + "00".repeat(32);

const hasSelector = (code, selector) => code.includes("63" + selector) || (selector.startsWith("00") && code.includes("62" + selector.slice(2)));
const EIP1167_PREFIX = "363d3d373d3d3d363d73";

// True if the runtime executes a DELEGATECALL (0xf4) opcode; PUSH immediates are skipped.
export function hasDelegatecall(codeHex) {
    const c = codeHex.replace(/^0x/, "");
    for (let i = 0; i < c.length; i += 2) {
        const op = parseInt(c.slice(i, i + 2), 16);
        if (op === 0xf4) return true;
        if (op >= 0x60 && op <= 0x7f) i += (op - 0x5f) * 2;
    }
    return false;
}

// Classify a probe read that did not succeed. "notInCode" is returned for exactly ONE shape, established on
// both endpoints: a plain runtime (not an EIP-1167 clone, no DELEGATECALL unless it is an EIP-1967 proxy),
// optionally an EIP-1967 implementation (slot read on both endpoints, must agree, code readable), optionally
// the given extra code holders (e.g. an EXTENSION()), no beacon, a selector whose first two bytes are not
// both zero, and the selector in none of those runtimes. Every other shape, and every read that cannot be
// established, returns "reverted" (PENDING), never "notInCode".
//   res: the { ok, revert } result of the read (revert only when BOTH endpoints reverted, see both()).
//   extra: further code holders to search; null = the caller could not establish them.
export async function classifyRead(clients, { address, blockNumber, selector, res, extra = [] }, redact = String) {
    if (res.ok) return "ok";
    if (!res.revert) return "failed";
    if (extra === null) return "reverted"; // the caller could not establish the extra code holders
    const sel = selector.replace(/^0x/, "").toLowerCase();
    if (sel.startsWith("0000")) return "reverted"; // PUSH2/PUSH3 forms not searched: absence not established
    // Each read returns null when it fails or the endpoints disagree; no outer catch, so a missing branch is visible.
    const codeOf = async (a) => {
        try {
            const r = await both(clients, (c) => c.getCode({ address: a, blockNumber }), redact);
            return r.ok && typeof r.value === "string" && r.value !== "0x" ? r.value.toLowerCase() : null;
        } catch { return null; }
    };
    const slot = async (s) => {
        try {
            const r = await both(clients, (c) => c.getStorageAt({ address, slot: s, blockNumber }), redact);
            return r.ok && typeof r.value === "string" ? r.value.toLowerCase() : null;
        } catch { return null; }
    };
    const own = await codeOf(address);
    if (own === null) return "reverted";
    if (own.replace(/^0x/, "").startsWith(EIP1167_PREFIX)) return "reverted"; // EIP-1167 clone: implementation not followed
    const holders = [own];
    const impl = await slot(IMPL_SLOT), beacon = await slot(BEACON_SLOT);
    if (impl === null || beacon === null) return "reverted";
    if (beacon !== ZERO_WORD) return "reverted"; // beacon indirection: not followed
    if (impl !== ZERO_WORD) {
        const implCode = await codeOf("0x" + impl.slice(26));
        if (implCode === null) return "reverted";
        holders.push(implCode);
    } else if (hasDelegatecall(own)) {
        return "reverted"; // delegates somewhere without an EIP-1967 slot: target unknown
    }
    for (const a of extra ?? []) { // null is handled above
        const c = await codeOf(a);
        if (c === null) return "reverted";
        holders.push(c);
    }
    return holders.some((c) => hasSelector(c, sel)) ? "reverted" : "notInCode";
}

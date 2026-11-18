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

// Registrable domain, approximated by the last two labels (no public-suffix list).
export const registrableDomain = (host) => host.split(".").slice(-2).join(".");

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
            // Each path segment and each query value on its own, so a credential echoed in pieces is still caught.
            for (const seg of x.pathname.split("/")) if (seg) secrets.push(seg, decodeURIComponent(seg));
            for (const [k, v] of x.searchParams) secrets.push(v, k + "=" + v);
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

// The two endpoints must be different hosts and different providers: two named providers must differ,
// and an unlisted host must not share its registrable domain with the other. Hosts are compared, never printed.
export function assertIndependent(urlA, urlB) {
    const [ha, hb] = [hostOf(urlA), hostOf(urlB)];
    if (ha === hb) throw new Error("the two endpoints must be different hosts (identical host)");
    const [a, b] = [providerOf(urlA), providerOf(urlB)];
    if (a === b && a !== "unlisted") throw new Error(`the two endpoints must be different providers (both ${a})`);
    if ((a === "unlisted" || b === "unlisted") && registrableDomain(ha) === registrableDomain(hb)) {
        throw new Error("the two endpoints must be different providers (same registrable domain)");
    }
    return [a, b];
}

const json = (v) => JSON.stringify(v ?? null, (_, y) => (typeof y === "bigint" ? y.toString() : y));

// A JSON-RPC revert (the call executed and reverted) vs anything else (transport, timeout, provider error).
export const isRevert = (e) => /revert/i.test(`${e?.name ?? ""} ${e?.shortMessage ?? ""} ${e?.message ?? ""} ${e?.cause?.name ?? ""}`);

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

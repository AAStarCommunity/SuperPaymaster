// Shared two-endpoint discipline for the read-only rehearsal scripts (inventory.mjs, owner-table-read.mjs).
// One implementation of: URL redaction, endpoint independence, provider naming, finalized-pin
// selection/verification, full-payload log comparison and "read on both, require equality".
// Nothing here prints or returns a URL or any part of one.

// Host suffix -> provider name. A host that matches nothing is recorded as "unlisted", never by name.
export const PROVIDERS = [
    ["alchemy.com", "Alchemy"], ["tenderly.co", "Tenderly"], ["infura.io", "Infura"], ["publicnode.com", "PublicNode"],
    ["drpc.org", "dRPC"], ["ankr.com", "Ankr"], ["quiknode.pro", "QuickNode"], ["blastapi.io", "Blast"],
];

function hostOf(url) {
    try { return new URL(url).host.toLowerCase(); } catch { throw new Error("an endpoint is not a valid URL"); }
}

export function providerOf(url) {
    const host = hostOf(url).replace(/:\d+$/, "");
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

// The two endpoints must be different hosts and different named providers. Hosts are compared, never printed.
export function assertIndependent(urlA, urlB) {
    if (hostOf(urlA) === hostOf(urlB)) throw new Error("the two endpoints must be different hosts (identical host)");
    const [a, b] = [providerOf(urlA), providerOf(urlB)];
    if (a === b && a !== "unlisted") throw new Error(`the two endpoints must be different providers (both ${a})`);
    return [a, b];
}

const json = (v) => JSON.stringify(v ?? null, (_, y) => (typeof y === "bigint" ? y.toString() : y));

// Read on both endpoints and require identical results (both succeed with the same value, or both fail).
export async function both(clients, fn, redact = String) {
    const r = await Promise.all(clients.map((c) => fn(c).then((v) => ({ v }), (e) => ({ e: e?.shortMessage ?? e?.message ?? String(e) }))));
    if (Boolean(r[0].e) !== Boolean(r[1].e) || (!r[0].e && json(r[0].v) !== json(r[1].v))) {
        throw new Error("endpoints disagree: " + redact([r[0].e ?? json(r[0].v), r[1].e ?? json(r[1].v)].join(" | ")).slice(0, 300));
    }
    if (r[0].e) return { error: redact(r[0].e).split("\n")[0].slice(0, 160) };
    return { value: r[0].v };
}

// Full payload of a log; two endpoints agree only if the sorted fingerprint lists are identical.
export const fingerprint = (l) => [l.address?.toLowerCase(), l.blockNumber, l.blockHash, l.logIndex, l.transactionHash,
    (l.topics ?? []).join(","), l.data].join(":");

export function compareLogs(a, b) {
    const fa = a.map(fingerprint).sort(), fb = b.map(fingerprint).sort();
    return { archive: fa.length, second: fb.length, identical: fa.length === fb.length && fa.every((v, i) => v === fb[i]) };
}

export function requireIdenticalLogs(a, b, label) {
    const r = compareLogs(a, b);
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
    if (r.error) return { error: "getCode failed: " + r.error };
    return { value: r.value && r.value !== "0x" ? "has code" : "no code" };
}

// node --test script/rehearsal/lib/two-endpoint.test.mjs — offline; fake clients, no network.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { mkdtempSync, mkdirSync, existsSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { assertIndependent, providerOf, makeRedactor, both, compareLogs, requireIdenticalLogs, verifyPin, pinFinalized, codeAt, writeAtomic } from "./two-endpoint.mjs";
import { inventoryErrors, INVENTORY_SCHEMA, REQUIRED_CONTROLS } from "./inventory-accept.mjs";

const A = "https://fake-a.alchemy.com/v2/SECRETKEY123", B = "https://fake-b.tenderly.co/SECRET456";
const H = (n) => "0x" + n.toString(16).padStart(64, "0");
function fake({ chainId = 11155111, finalized = 100n, hashes = {}, code, codeError } = {}) {
    return {
        getChainId: async () => chainId,
        getBlock: async ({ blockTag, blockNumber }) => (blockTag === "finalized"
            ? { number: finalized, hash: hashes[finalized] ?? H(finalized) }
            : { number: blockNumber, hash: hashes[blockNumber] ?? H(blockNumber) }),
        getCode: async () => { if (codeError !== undefined) throw new Error(codeError); return code; },
    };
}

test("H1: identical endpoints are rejected without printing the host", () => {
    assert.throws(() => assertIndependent(A, A), (e) => !e.message.includes("alchemy") && /identical host/.test(e.message));
    assert.throws(() => assertIndependent(A, "https://fake-a.alchemy.com/v2/OTHER"), /identical host/);
    assert.throws(() => assertIndependent(A, "https://fake-c.alchemy.com/v2/X"), /different providers/);
    assert.deepEqual(assertIndependent(A, B), ["Alchemy", "Tenderly"]);
});

test("H1: provider names come from a fixed host map, never the URL", () => {
    assert.equal(providerOf(A), "Alchemy");
    assert.equal(providerOf(B), "Tenderly");
    assert.equal(providerOf("https://rpc.example.org/k"), "unlisted");
    assert.equal(providerOf("https://evil-alchemy.com.example.org/"), "unlisted");
    const r = makeRedactor([A, B]);
    assert.ok(!/SECRET|alchemy|tenderly/i.test(r(`fail ${A} and ${B} at fake-b.tenderly.co`)));
});

test("H1: verifyPin checks chain id, finalized height and hash on BOTH endpoints", async () => {
    const ok = await verifyPin([fake(), fake()], 11155111, 90, H(90n));
    assert.deepEqual(ok, { chainId: 11155111, number: 90, hash: H(90n), finalized: [100, 100] });
    await assert.rejects(verifyPin([fake(), fake({ chainId: 1 })], 11155111, 90, H(90n)), /eth_chainId/);
    await assert.rejects(verifyPin([fake(), fake({ finalized: 80n })], 11155111, 90, H(90n)), /above a finalized head/);
    await assert.rejects(verifyPin([fake(), fake({ hashes: { 90n: H(7n) } })], 11155111, 90, H(90n)), /hash differs/);
    const pin = await pinFinalized([fake({ finalized: 100n }), fake({ finalized: 95n })], 11155111);
    assert.equal(pin.number, 95n);
    await assert.rejects(pinFinalized([fake(), fake({ chainId: 10 })], 11155111), /eth_chainId/);
});

test("H2: log agreement compares the full payload", () => {
    const l = { address: "0xAb", blockNumber: 1n, blockHash: H(1n), logIndex: 0, transactionHash: H(2n), topics: [H(3n)], data: "0x01" };
    assert.equal(compareLogs([l], [{ ...l }]).identical, true);
    // Same blockHash and logIndex (the old owner-table fingerprint) but different data / topics / tx / address.
    for (const k of ["data", "topics", "transactionHash", "address"]) {
        const m = { ...l, [k]: k === "topics" ? [H(4n)] : k === "data" ? "0x02" : k === "address" ? "0xCd" : H(9n) };
        assert.equal(compareLogs([l], [m]).identical, false, k);
        assert.throws(() => requireIdenticalLogs([l], [m], "E"), /different logs/);
    }
    assert.equal(compareLogs([l, { ...l, logIndex: 1 }], [{ ...l, logIndex: 1 }, l]).identical, true); // order-insensitive
});

test("both(): one endpoint failing while the other answers is a disagreement", async () => {
    await assert.rejects(both([{ x: 1 }, { x: 2 }], async (c) => { if (c.x === 2) throw new Error("boom"); return 1; }), /disagree/);
    await assert.rejects(both([{ x: 1 }, { x: 2 }], async (c) => c.x), /disagree/);
    assert.deepEqual(await both([{}, {}], async () => 5n), { ok: true, value: 5n });
});

test("M5: a failed getCode stays an error, never 'no code'", async () => {
    assert.match((await codeAt([fake({ codeError: "timeout" }), fake({ codeError: "timeout" })], "0x1", 1n)).error, /getCode failed/);
    assert.deepEqual(await codeAt([fake({ code: undefined }), fake({ code: undefined })], "0x1", 1n), { ok: true, value: "no code" });
    assert.deepEqual(await codeAt([fake({ code: "0x60" }), fake({ code: "0x60" })], "0x1", 1n), { ok: true, value: "has code" });
});

test("M4: the gate requires exactly the named controls of a supported version, each exactly true", () => {
    const SP = "0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9", REG = "0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71";
    const controls = Object.fromEntries(REQUIRED_CONTROLS[INVENTORY_SCHEMA].map((k) => [k, true]));
    const good = { schema: INVENTORY_SCHEMA, chainId: 11155111, sp: SP, state: { registry: REG }, positiveControl: controls, pinnedBlock: { number: 5, hash: H(5n) } };
    const want = { chainId: 11155111, sp: SP, registry: REG };
    assert.deepEqual(inventoryErrors(good, want), []);
    const { endpointsReturnIdenticalLogs, ...missing } = controls;
    assert.ok(inventoryErrors({ ...good, positiveControl: missing }, want).some((e) => e.includes("endpointsReturnIdenticalLogs is missing")));
    assert.ok(inventoryErrors({ ...good, positiveControl: { irrelevant: true } }, want).some((e) => e.includes("irrelevant is not a control")));
    assert.ok(inventoryErrors({ ...good, positiveControl: { ...controls, extra: true } }, want).some((e) => e.includes("extra")));
    assert.ok(inventoryErrors({ ...good, positiveControl: { ...controls, noUnclassifiedTopic0: "true" } }, want).some((e) => e.includes("exactly true")));
    assert.ok(inventoryErrors({ ...good, schema: "sp-inventory/1" }, want).some((e) => e.includes("unsupported")));
    assert.ok(inventoryErrors({ ...good, schema: undefined }, want).some((e) => e.includes("unsupported")));
    assert.ok(inventoryErrors({ ...good, chainId: undefined }, want).some((e) => e.includes("chainId")));
    assert.ok(inventoryErrors({ ...good, sp: REG }, want).some((e) => e.includes("SuperPaymaster")));
    assert.ok(inventoryErrors({ ...good, state: { registry: SP } }, want).some((e) => e.includes("Registry")));
});

test("M5: success vs failure is an explicit discriminant; an empty error message stays a failure", async () => {
    const r = await both([{}, {}], async () => { throw new Error(""); });
    assert.equal(r.ok, false);
    assert.equal(r.error, "(empty error)");
    const c = await codeAt([fake({ codeError: "" }), fake({ codeError: "" })], "0x1", 1n);
    assert.equal(c.ok, false);
    assert.match(c.error, /getCode failed/);
    assert.deepEqual(await both([{}, {}], async () => 0), { ok: true, value: 0 });
});

test("H2: removed logs, transactionIndex and duplicate identities", () => {
    const l = { address: "0xAb", blockNumber: 1n, blockHash: H(1n), logIndex: 0, transactionHash: H(2n), transactionIndex: 0, removed: false, topics: [H(3n)], data: "0x01" };
    assert.equal(compareLogs([l], [{ ...l, transactionIndex: 1 }]).identical, false);
    assert.throws(() => requireIdenticalLogs([{ ...l, removed: true }], [{ ...l, removed: true }], "E"), /removed log/);
    assert.throws(() => requireIdenticalLogs([l, { ...l }], [l, { ...l }], "E"), /duplicate log identity/);
    assert.equal(compareLogs([l, { ...l }], [l, { ...l }]).identical, false);
});

test("H1: hostnames are normalized (case, trailing dot, port); unlisted hosts need different registrable domains", () => {
    assert.throws(() => assertIndependent("https://host/key1", "https://host./key2"), /identical host/);
    assert.throws(() => assertIndependent("https://x.example:8545", "https://x.example:443"), /identical host/);
    assert.throws(() => assertIndependent("https://RPC.Example.org/a", "https://rpc.example.org./b"), /identical host/);
    assert.throws(() => assertIndependent("https://a.example.org/k", "https://b.example.org/k"), /registrable domain/);
    assert.deepEqual(assertIndependent("https://a.example.org/k", "https://fake-a.alchemy.com/k"), ["unlisted", "Alchemy"]);
    assert.equal(providerOf("https://FAKE-A.Alchemy.com./v2/k"), "Alchemy");
    assert.equal(providerOf("https://fake-b.tenderly.co:8443/k"), "Tenderly");
    assert.deepEqual(assertIndependent("https://a.example.org/k", "https://b.example.net/k"), ["unlisted", "unlisted"]);
});

test("L7: a credential echoed in pieces is still redacted", () => {
    const u1 = "https://x.example.org/abc123key/proj987xyz?token=sek42val&mode=1", u2 = "https://y.example.net/v3/zzKEY9";
    const r = makeRedactor([u1, u2]);
    const out = r("auth failed for abc123key in project proj987xyz, token sek42val; second key zzKEY9");
    for (const piece of ["abc123key", "proj987xyz", "sek42val", "zzKEY9"]) assert.ok(!out.includes(piece), piece);
});

test("L6: writeAtomic renames into place and leaves no temp file on failure", () => {
    const d = mkdtempSync(join(tmpdir(), "atomic-"));
    try {
        writeAtomic(join(d, "out.json"), "{}");
        assert.ok(existsSync(join(d, "out.json")));
        mkdirSync(join(d, "isdir"));
        assert.throws(() => writeAtomic(join(d, "isdir"), "x"));
        assert.deepEqual(readdirSync(d).sort(), ["isdir", "out.json"]);
    } finally { rmSync(d, { recursive: true, force: true }); }
});

test("structure: one shared implementation; inventory reads both endpoints and writes only after its controls", () => {
    const inv = readFileSync(new URL("../inventory.mjs", import.meta.url), "utf8");
    const reader = readFileSync(new URL("../owner-table-read.mjs", import.meta.url), "utf8");
    for (const src of [inv, reader]) {
        assert.match(src, /from "\.\/lib\/two-endpoint\.mjs"/);
        assert.doesNotMatch(src, /const fingerprint\s*=|SECRETS\s*=|endpoints\[0\]\.client/);
    }
    // Every state read in inventory goes through the two-endpoint helper (no single-client `c.` reads at the pin).
    const body = inv.slice(inv.indexOf("// State read-back"));
    assert.doesNotMatch(body, /\bconst c = /);
    assert.ok(inv.lastIndexOf("writeAtomic(outPath") > inv.indexOf("INVENTORY INCOMPLETE"), "output written only after the control check");
    assert.doesNotMatch(inv, /writeFileSync\(/); // only writeAtomic writes
    assert.match(inv, /writeAtomic\(outPath/);
    assert.match(reader, /inventoryErrors\(inv/);
    assert.match(reader, /verifyPin\(clients, CHAIN_ID/);
    assert.doesNotMatch(reader, /"Alchemy"|"Tenderly"/);
});

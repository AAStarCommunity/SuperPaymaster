// node --test scripts/gen-rc8-owner-table.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, cpSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { load, validate, render, flags, status, main, renderedRowIds, digestOf, TABLE, DOC } from "./gen-rc8-owner-table.mjs";

const R = join(dirname(fileURLToPath(import.meta.url)), "..");
const { t: T0, ctx: CTX } = load();
const clone = () => structuredClone(T0);
const row = (t, id) => t.rows.find((r) => r.id === id);
const quiet = (fn) => { const e = console.error, l = console.log; console.error = console.log = () => {}; try { return fn(); } finally { console.error = e; console.log = l; } };
// Pinned row count of the committed table: dropping or adding a row must be a deliberate edit of this number.
const EXPECTED_ROWS = 87;

function tempRoot(editTable) {
    const root = mkdtempSync(join(tmpdir(), "owner-table-"));
    for (const p of [TABLE, DOC, T0.inventory.path, ...T0.legacyProbe.sourceScan]) {
        mkdirSync(join(root, dirname(p)), { recursive: true });
        cpSync(join(R, p), join(root, p), { recursive: true });
    }
    if (editTable) {
        const t = JSON.parse(readFileSync(join(root, TABLE), "utf8"));
        editTable(t);
        writeFileSync(join(root, TABLE), JSON.stringify(t, null, 2) + "\n");
    }
    return root;
}
function checkWith(edit) {
    const root = tempRoot(edit);
    try { return quiet(() => main(["--check"], root)); } finally { rmSync(root, { recursive: true, force: true }); }
}
function completeness(t, md) {
    const ids = t.rows.map((r) => r.id), shown = renderedRowIds(md), e = [];
    if (new Set(ids).size !== ids.length) e.push("duplicate ids");
    if (JSON.stringify(shown) !== JSON.stringify([...t.rows.filter((r) => r.kind === "authority"), ...t.rows.filter((r) => r.kind !== "authority")].map((r) => r.id))) e.push("rendered ids differ");
    if (shown.length !== EXPECTED_ROWS) e.push(`rendered ${shown.length} rows, expected ${EXPECTED_ROWS}`);
    return e;
}

test("committed doc is up to date and the data validates", () => {
    assert.deepEqual(validate(T0, CTX), []);
    assert.equal(quiet(() => main(["--check"])), 0);
});

test("L7: unique ids and the exact rendered row count; dropping one row fails", () => {
    assert.deepEqual(completeness(T0, render(T0, CTX)), []);
    const t = clone();
    t.rows.splice(5, 1);
    assert.ok(completeness(t, render(t, CTX)).some((e) => e.startsWith("rendered")));
    const d = clone();
    d.rows[1].id = d.rows[0].id;
    assert.ok(validate(d, CTX).some((e) => e.includes("duplicate row id")));
});

test("--check fails on a stale doc and passes after regeneration", () => {
    const root = tempRoot();
    try {
        writeFileSync(join(root, DOC), readFileSync(join(root, DOC), "utf8").replace("| D |", "| X |"));
        assert.equal(quiet(() => main(["--check"], root)), 1);
        assert.equal(quiet(() => main([], root)), 0);
        assert.equal(quiet(() => main(["--check"], root)), 0);
    } finally { rmSync(root, { recursive: true, force: true }); }
});

test("M3: the reviewer's four edits each fail --check", () => {
    assert.equal(checkWith(), 0); // control: an unedited temp copy passes, so a 1 below is the edit's doing
    assert.equal(checkWith((t) => { row(t, "sp.owner").read.fn = "function treasury() view returns (address)"; }), 1);
    assert.equal(checkWith((t) => { row(t, "sp.owner").read.args = ["D"]; }), 1);
    // sp.guardian is now a storage read with a value; the reviewer's "value next to an existing error" case is
    // applied to rows that do carry an error at the pin (an undeployed A7 row and a reverting eth_call row).
    assert.equal(checkWith((t) => { row(t, "a7.owner").current.value = t.identities.SAFE; }), 1);
    assert.equal(checkWith((t) => { row(t, "apnts.balanceMode").current.value = 1; }), 1);
    assert.equal(checkWith((t) => { delete row(t, "reg.reputationSources").current.seeds[1].members; }), 1);
    // The guardian row is the reviewer's case: an error row that also gains a value.
    const g = clone();
    row(g, "sp.operator.ANNI.isPaused").current = { error: "x", value: true };
    assert.ok(validate(g, CTX).some((e) => e.includes("exactly one of value / error")));
});

test("M3: read specs are validated, not only digested", () => {
    const a = clone();
    row(a, "sp.owner").read.fn = "function treasury() view returns (address)";
    assert.ok(validate(a, CTX).some((e) => e.includes("readback does not name treasury")));
    const b = clone();
    row(b, "sp.owner").read.args = ["D"];
    assert.ok(validate(b, CTX).some((e) => e.includes("takes 0 args")));
    const c = clone();
    row(c, "sp.owner").read = { fn: "function owner() view returns (address)", storage: "0x" + "00".repeat(32) };
    assert.ok(validate(c, CTX).some((e) => e.includes("exactly one of")));
    const d = clone();
    delete row(d, "reg.reputationSources").current.seeds[1].members;
    assert.notEqual(digestOf(d), digestOf(T0));
    assert.ok(render(T0, CTX).includes(`source-sha256: ${digestOf(T0)}`));
});

test("a non-checksummed address is rejected, including inside read specs", () => {
    const t = clone();
    t.identities.D = t.identities.D.toLowerCase();
    assert.ok(validate(t, CTX).some((e) => e.includes("not checksummed")));
    const u = clone();
    row(u, "sp.operator.ANNI.isPaused").read.args = [T0.identities.ANNI.toLowerCase()];
    assert.ok(validate(u, CTX).some((e) => e.includes("not checksummed")));
});

test("evidence tampering, refused inventories and role drift are rejected", () => {
    assert.ok(validate(T0, { ...CTX, evidence: Buffer.concat([CTX.evidence, Buffer.from(" ")]) }).includes("inventory sha256 mismatch"));
    const inv = JSON.parse(CTX.evidence);
    inv.positiveControl.endpointsReturnIdenticalLogs = false;
    assert.ok(validate(T0, { ...CTX, evidence: Buffer.from(JSON.stringify(inv)) }).some((e) => e.includes("endpointsReturnIdenticalLogs")));
    const six = CTX.iregistrySrc.replace(/^bytes32 constant ROLE_KMS.*$/m, "");
    assert.ok(validate(T0, { ...CTX, iregistrySrc: six }).some((e) => e.includes("roles")));
    const t = clone();
    t.roles[0].id = t.roles[1].id;
    assert.ok(validate(t, CTX).some((e) => e.includes("keccak256")));
});

test("three classes: rules per class", () => {
    const a = clone();
    row(a, "staking.owner").expected = "D";
    assert.ok(validate(a, CTX).some((e) => e.includes("class 1 expects")));
    const b = clone();
    row(b, "pntsPmv4.owner").operatorOwner = "D";
    assert.ok(validate(b, CTX).some((e) => e.includes("class 2")));
    const c = clone();
    delete row(c, "dvt.validators").pending;
    assert.ok(validate(c, CTX).some((e) => e.includes("pending author decision")));
    const d = clone();
    row(d, "sp.xpntsFactory").class = 1;
    assert.ok(validate(d, CTX).some((e) => e.includes("only authority rows")));
    const e = clone();
    delete row(e, "liveness.owner").class;
    assert.ok(validate(e, CTX).some((x) => x.includes("class must be 1, 2 or 3")));
});

test("M6: a legacy row stays PENDING while a non-legacy row or probe still references its subject", () => {
    // AGG_4_1_B is an unrevoked staking slasher at the pin: both the probe and the staking.slashers row hold it.
    assert.match(status(T0, CTX, row(T0, "agg_4_1_b.owner")), /PENDING.*STAKING\.authorizedSlashers.*row staking\.slashers/);
    const t = clone();
    t.legacyProbe.results.hits = t.legacyProbe.results.hits.filter((h) => h.subject !== t.identities.AGG_4_1_B);
    assert.match(status(t, CTX, row(t, "agg_4_1_b.owner")), /PENDING.*row staking\.slashers/); // the row alone keeps it pending
    row(t, "staking.slashers").current.value = [t.identities.AGG_4_11];
    assert.equal(status(t, CTX, row(t, "agg_4_1_b.owner")), "legacy (verified at pin)");
    // A source hit also keeps it pending; a declared requirement too.
    const ctx = { ...CTX, sourceScan: { ...CTX.sourceScan, [t.identities.AGG_4_1_B]: ["contracts/src/x.sol"] } };
    assert.match(status(t, ctx, row(t, "agg_4_1_b.owner")), /PENDING.*source contracts\/src\/x\.sol/);
    assert.match(status(T0, CTX, row(T0, "pmFactory.owner")), /PENDING.*disable step/);
    assert.equal(status(T0, CTX, row(T0, "mpc.owner")), "legacy (author decision)");
});

test("aggregator flag: authority slot held by an aggregator is a violation unless allow-listed", () => {
    const t = clone();
    const r = { id: "x", kind: "authority", expected: "SAFE", current: { value: t.identities.AGG_4_11 }, aggAllowed: false };
    assert.equal(flags(t, r), "**VIOLATION (current)**");
    assert.equal(flags(t, { ...r, expected: "A7" }), "**VIOLATION (expected)**");
    assert.equal(flags(t, { ...r, aggAllowed: true }), "allowed (by design)");
    assert.equal(flags(t, { ...r, current: { value: t.identities.SAFE } }), "ok");
    assert.equal(flags(T0, row(T0, "staking.slashers")), "**VIOLATION (current)**");
});

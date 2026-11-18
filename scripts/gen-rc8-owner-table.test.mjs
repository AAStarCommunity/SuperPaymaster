// node --test scripts/gen-rc8-owner-table.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, copyFileSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { load, validate, render, flags, main, TABLE, DOC } from "./gen-rc8-owner-table.mjs";

const R = join(dirname(fileURLToPath(import.meta.url)), "..");
const REPO = { t: null, ctx: null };
({ t: REPO.t, ctx: REPO.ctx } = load());
const clone = () => structuredClone(REPO.t);
const quiet = (fn) => { const e = console.error, l = console.log; console.error = console.log = () => {}; try { return fn(); } finally { console.error = e; console.log = l; } };

function tempRoot(edit) {
    const root = mkdtempSync(join(tmpdir(), "owner-table-"));
    for (const p of [TABLE, DOC, REPO.t.inventory.path, "contracts/src/interfaces/v3/IRegistry.sol"]) {
        mkdirSync(join(root, dirname(p)), { recursive: true });
        copyFileSync(join(R, p), join(root, p));
    }
    edit?.(root);
    return root;
}

test("committed doc is up to date and the data validates", () => {
    assert.deepEqual(validate(REPO.t, REPO.ctx), []);
    assert.equal(quiet(() => main(["--check"])), 0);
});

test("--check fails on a stale doc and passes after regeneration", () => {
    const root = tempRoot((r) => writeFileSync(join(r, DOC), readFileSync(join(r, DOC), "utf8").replace("| D |", "| X |")));
    try {
        assert.equal(quiet(() => main(["--check"], root)), 1);
        assert.equal(quiet(() => main([], root)), 0);
        assert.equal(quiet(() => main(["--check"], root)), 0);
    } finally { rmSync(root, { recursive: true, force: true }); }
});

test("--check fails when the JSON changes but the doc does not", () => {
    const root = tempRoot((r) => {
        const t = JSON.parse(readFileSync(join(r, TABLE), "utf8"));
        t.rows[0].step = "edited";
        writeFileSync(join(r, TABLE), JSON.stringify(t, null, 2) + "\n");
    });
    try { assert.equal(quiet(() => main(["--check"], root)), 1); } finally { rmSync(root, { recursive: true, force: true }); }
});

test("a non-checksummed address is rejected", () => {
    const t = clone();
    t.identities.D = t.identities.D.toLowerCase();
    assert.ok(validate(t, REPO.ctx).some((e) => e.includes("not checksummed")));
});

test("evidence tampering and role drift are rejected", () => {
    assert.ok(validate(REPO.t, { ...REPO.ctx, evidence: Buffer.concat([REPO.ctx.evidence, Buffer.from(" ")]) }).includes("inventory sha256 mismatch"));
    const six = REPO.ctx.iregistrySrc.replace(/^bytes32 constant ROLE_KMS.*$/m, "");
    assert.ok(validate(REPO.t, { ...REPO.ctx, iregistrySrc: six }).some((e) => e.includes("roles")));
    const t = clone();
    t.roles[0].id = t.roles[1].id;
    assert.ok(validate(t, REPO.ctx).some((e) => e.includes("keccak256")));
});

test("aggregator flag: authority slot held by an aggregator is a violation unless allow-listed", () => {
    const t = clone();
    const row = { id: "x", kind: "authority", expected: "SAFE", current: { value: t.identities.AGG_4_11 }, aggAllowed: false };
    assert.equal(flags(t, row).agg, "**VIOLATION (current)**");
    assert.equal(flags(t, { ...row, expected: "A7" }).agg, "**VIOLATION (expected)**");
    assert.equal(flags(t, { ...row, aggAllowed: true }).agg, "allowed (by design)");
    assert.equal(flags(t, { ...row, current: { value: t.identities.SAFE } }).agg, "ok");
    assert.equal(flags(t, { ...row, kind: "info" }).agg, "-");
});

test("deployer flag: D needs a written exception; GAP/VIOLATION texts stay open", () => {
    const t = clone();
    const row = { id: "x", kind: "authority", expected: "D", current: { value: t.identities.D } };
    assert.equal(flags(t, row).dep, "**GAP (no exception text)**");
    assert.equal(flags(t, { ...row, exception: "GAP: none" }).dep, "**GAP**");
    assert.equal(flags(t, { ...row, exception: "Legacy (not an rc.8 contract): ..." }).dep, "exception");
    assert.equal(flags(t, { ...row, expected: "TL48" }).dep, "-");
});

test("render lists every row and the open items", () => {
    const md = render(REPO.t);
    for (const r of REPO.t.rows) assert.ok(md.includes(r.readback.replace(/\|/g, "\\|")), r.id);
    assert.match(md, /## Open items \(\d+\)/);
    assert.ok(md.includes("`staking.slashers`: VIOLATION (expected)"));
});

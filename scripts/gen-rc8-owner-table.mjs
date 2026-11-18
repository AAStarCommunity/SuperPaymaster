#!/usr/bin/env node
// gen-rc8-owner-table.mjs — render docs/security/rc8-owner-table.md from the source of truth
// docs/security/rc8-owner-table.json (rc.8 owner / role table v1). Offline: no network.
//
// The JSON's `current` column and `legacyProbe.results` are filled by script/rehearsal/owner-table-read.mjs
// (read-only Sepolia, both endpoints, pinned block). This script validates the data and renders the doc:
//   - every address is full 40-hex and EIP-55 checksummed; every read spec is well formed and matches its readback;
//   - every row has exactly one of current.value / current.error;
//   - the 7 role ids/names equal contracts/src/interfaces/v3/IRegistry.sol and read back configured;
//   - the inventory evidence matches its sha256, passes its own controls and is bound to this chain/SP/Registry;
//   - every authority row is in exactly one class: (1) handed over, (2) operator-owned, (3) legacy, or is
//     explicitly pending an author decision. A class-3 row is shown as PENDING until its subject has no
//     reference from an rc.8 contract: getter/role probes, other (non-legacy) rows, and the source scan;
//   - the doc embeds the sha256 of the canonical JSON, so any JSON edit makes --check fail.
// Usage:
//   node scripts/gen-rc8-owner-table.mjs           # write the doc
//   node scripts/gen-rc8-owner-table.mjs --check   # exit 1 if the doc is stale or the data is invalid
import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { getAddress, keccak256, stringToHex, parseAbiItem } from "viem";
import { inventoryErrors } from "../script/rehearsal/lib/inventory-accept.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
export const TABLE = "docs/security/rc8-owner-table.json";
export const DOC = "docs/security/rc8-owner-table.md";
const HEX40 = /^0x[0-9a-fA-F]{40}$/;
const COLUMNS = ["id", "contract", "address", "slot", "read", "current", "expected", "step", "readback", "kind"];
const READ_KINDS = ["fn", "storage", "code", "set", "inventory"];
const GOVERNANCE = ["TL48", "SAFE", "ZERO"];

export function iregistryRoles(src) {
    return [...src.matchAll(/^bytes32 constant (ROLE_\w+)\s*=\s*keccak256\("(\w+)"\);/gm)].map((m) => ({ constant: m[1], name: m[2] }));
}

const canon = (v) => (Array.isArray(v) ? `[${v.map(canon).join(",")}]` : v && typeof v === "object"
    ? `{${Object.keys(v).sort().map((k) => JSON.stringify(k) + ":" + canon(v[k])).join(",")}}` : JSON.stringify(v));
export const digestOf = (t) => createHash("sha256").update(canon(t)).digest("hex");

function walkAddresses(v, out = []) {
    if (typeof v === "string" && /^0x[0-9a-fA-F]{40}$/i.test(v)) out.push(v);
    else if (Array.isArray(v)) v.forEach((x) => walkAddresses(x, out));
    else if (v && typeof v === "object") Object.values(v).forEach((x) => walkAddresses(x, out));
    return out;
}

function readSpecErrors(r) {
    const e = [];
    const kinds = READ_KINDS.filter((k) => r.read && k in r.read);
    if (kinds.length !== 1) return [`row ${r.id}: read must have exactly one of ${READ_KINDS.join("/")}`];
    const check = (fn, args, label) => {
        let item;
        try { item = parseAbiItem(fn); } catch { return e.push(`row ${r.id}: ${label} is not a valid function signature`); }
        if ((args ?? []).length !== item.inputs.length) e.push(`row ${r.id}: ${label} takes ${item.inputs.length} args, read gives ${(args ?? []).length}`);
        return item;
    };
    if (r.read.fn) {
        const item = check(r.read.fn, r.read.args, "read.fn");
        // The rendered readback must name the function actually called.
        if (item && !r.readback.includes(item.name)) e.push(`row ${r.id}: readback does not name ${item.name}()`);
        if (r.read.range && !(Array.isArray(r.read.range) && r.read.range.length === 2)) e.push(`row ${r.id}: bad range`);
    }
    if (r.read.storage && !/^0x[0-9a-f]{64}$/.test(r.read.storage)) e.push(`row ${r.id}: storage slot must be 32-byte hex`);
    if (r.read.set) {
        if (!Array.isArray(r.read.set.seeds) || !r.read.set.check) e.push(`row ${r.id}: set needs seeds and check`);
        else {
            check(r.read.set.check.fn, r.read.set.check.args, "set.check.fn");
            for (const s of r.read.set.seeds) { try { parseAbiItem(s.event); } catch { e.push(`row ${r.id}: bad seed event`); } }
        }
    }
    return e;
}

// Resolve a value to a list of addresses (identity names -> address; unassigned identities -> the name).
function members(t, v) {
    if (v === null || v === undefined) return [];
    if (Array.isArray(v)) return v.flatMap((x) => members(t, x));
    if (typeof v !== "string") return [];
    if (Object.hasOwn(t.identities, v)) return [t.identities[v] ?? v];
    return HEX40.test(v) ? [v] : [];
}
const resolveId = (t, k) => t.identities[k] ?? k;

// Every reference to a class-3 subject from something that is not itself legacy.
export function legacyHits(t, ctx, subjectKey) {
    const subject = resolveId(t, subjectKey);
    const hits = (t.legacyProbe?.results?.hits ?? []).filter((h) => h.subject === subject).map((h) => `probe ${h.probe}`);
    for (const r of t.rows) {
        if (r.kind !== "authority" || r.class === 3 || r.address === subjectKey) continue;
        if (members(t, r.current?.value).includes(subject)) hits.push(`row ${r.id}`);
    }
    for (const f of ctx.sourceScan?.[subject] ?? []) hits.push(`source ${f}`);
    return hits;
}

// Reads that did not answer cannot show absence: any of them keeps every class-3 row PENDING.
export function probeGaps(t) {
    const res = t.legacyProbe?.results ?? {};
    const gaps = [];
    for (const g of res.gettersFailed ?? []) gaps.push(`getter read failed: ${g}`);
    for (const g of res.gettersReverted ?? []) gaps.push(`getter reverted although present in code: ${g}`);
    for (const m of res.memberAbsent ?? []) gaps.push(`member probe did not answer: ${m}`);
    for (const r of t.rows) {
        if (r.kind !== "authority" || r.class === 3 || !r.current || !("error" in r.current)) continue;
        if (Object.hasOwn(t.identities, r.address) && t.identities[r.address] === null) continue; // not deployed at the pin: holds nothing yet
        gaps.push(`row ${r.id} unreadable`);
    }
    return gaps;
}

export function validate(t, ctx) {
    const errors = [];
    const err = (m) => errors.push(m);
    if (t.schema !== "rc8-owner-table/v1") err("schema must be rc8-owner-table/v1");
    for (const a of walkAddresses(t)) if (a !== getAddress(a)) err(`address not checksummed: ${a}`);
    for (const [k, v] of Object.entries(t.identities)) if (v !== null && !HEX40.test(v)) err(`identity ${k} is not a full address`);
    for (const k of [...t.aggregators, ...(t.protocolContracts ?? [])]) if (!Object.hasOwn(t.identities, k)) err(`${k} is not an identity`);
    const src = iregistryRoles(ctx.iregistrySrc);
    if (src.length !== 7) err(`IRegistry.sol declares ${src.length} roles, expected 7`);
    if (JSON.stringify(src.map((r) => r.name)) !== JSON.stringify(t.roles.map((r) => r.name))) err("roles differ from IRegistry.sol");
    for (const r of t.roles) {
        if (r.id !== keccak256(stringToHex(r.name))) err(`role ${r.name}: id != keccak256(name)`);
        if (r.configured !== true || r.isActive !== true) err(`role ${r.name}: not configured on Sepolia`);
    }
    if (!ctx.evidence) err(`inventory evidence missing: ${t.inventory?.path}`);
    else {
        if (createHash("sha256").update(ctx.evidence).digest("hex") !== t.inventory.sha256) err("inventory sha256 mismatch");
        const inv = JSON.parse(ctx.evidence);
        for (const e of inventoryErrors(inv, { chainId: t.readAt.chainId, sp: t.identities.SP, registry: t.identities.REGISTRY })) err(e);
        const configured = (inv.state?.operators ?? []).filter((o) => o.isConfigured).map((o) => o.operator);
        if (JSON.stringify(configured) !== JSON.stringify(t.inventory.configuredOperators)) err("configured operators differ from the evidence");
        if (JSON.stringify(inv.state?.superHolders?.fromStorage) !== JSON.stringify(t.inventory.superRoleHolders)) err("PAYMASTER_SUPER holders differ from the evidence");
        if (JSON.stringify(inv.topic0Table) !== JSON.stringify(t.inventory.topic0Table)) err("topic0 table differs from the evidence");
        if (inv.pinnedBlock?.number !== t.readAt.block || inv.pinnedBlock?.hash !== t.readAt.hash) err("readAt differs from the inventory pinned block");
    }
    const ids = new Set();
    const probed = new Set((t.legacyProbe?.subjects ?? []));
    if (!t.legacyProbe?.results) err("legacyProbe results missing");
    else for (const k of ["hits", "gettersNotInCode", "gettersReverted", "gettersFailed", "memberAbsent"]) {
        if (!Array.isArray(t.legacyProbe.results[k])) err(`legacyProbe.results.${k} must be a list`);
    }
    for (const r of t.rows) {
        for (const c of COLUMNS) if (!(c in r)) err(`row ${r.id}: missing column ${c}`);
        if (ids.has(r.id)) err(`duplicate row id ${r.id}`);
        ids.add(r.id);
        errors.push(...readSpecErrors(r));
        const c = r.current;
        if (!c || typeof c !== "object" || ("value" in c) === ("error" in c)) err(`row ${r.id}: current must have exactly one of value / error`);
        if (!["authority", "wiring", "info"].includes(r.kind)) err(`row ${r.id}: bad kind`);
        if (r.kind !== "authority") { if ("class" in r) err(`row ${r.id}: only authority rows carry a class`); continue; }
        const exp = members(t, r.expected);
        if (r.class === null) { if (!r.pending) err(`row ${r.id}: class null needs a pending author decision`); continue; }
        if (![1, 2, 3].includes(r.class)) { err(`row ${r.id}: class must be 1, 2 or 3`); continue; }
        if (!r.classReason) err(`row ${r.id}: class reason missing`);
        if (r.class === 1) {
            const ok = new Set([...GOVERNANCE, ...(t.protocolContracts ?? [])].map((k) => resolveId(t, k)));
            if (!exp.every((a) => ok.has(a))) err(`row ${r.id}: class 1 expects only TL48 / SAFE / no holder / rc.8 protocol contracts`);
        }
        // Nothing may read as "the deployer holds no privilege": an operator-owned row held by D says so.
        if (r.class === 2 && resolveId(t, r.operatorOwner) === t.identities.D && !/same address as the deployer EOA/.test(r.notes ?? "")) err(`row ${r.id}: class 2 owned by D must note that the operator identity is the deployer EOA`);
        if (r.class === 2 && (!r.operatorOwner || JSON.stringify(exp) !== JSON.stringify([resolveId(t, r.operatorOwner)]))) err(`row ${r.id}: class 2 must name its operator owner as the expected value`);
        if (r.class === 3) {
            const subj = r.class3?.subjects ?? [];
            if (!subj.length) err(`row ${r.id}: class 3 needs subjects`);
            for (const s of subj) if (!probed.has(s)) err(`row ${r.id}: subject ${s} is not in legacyProbe.subjects`);
        }
    }
    return errors;
}

export function status(t, ctx, r) {
    if (r.kind !== "authority") return "-";
    if (r.class === null) return "**PENDING (author decision)**";
    if (r.class === 1) return /^MISSING/.test(r.step) || /: MISSING/.test(r.step) ? "**GAP (step missing)**" : "handed over";
    if (r.class === 2) return `operator-owned (${r.operatorOwner})`;
    const hits = (r.class3.subjects ?? []).flatMap((s) => legacyHits(t, ctx, s));
    const reqs = r.class3.requires ?? [], gaps = probeGaps(t);
    if (hits.length || reqs.length || gaps.length) return `**PENDING (legacy once cleared: ${[...hits, ...gaps, ...reqs].join("; ")})**`;
    return r.class3.authorDecision ? "legacy (author decision)" : "legacy (verified at pin)";
}

export function flags(t, r) {
    const aggs = new Set(t.aggregators.map((k) => resolveId(t, k)));
    const hit = (v) => members(t, v).filter((a) => aggs.has(a));
    const cur = hit(r.current?.value), exp = hit(r.expected);
    if (r.aggAllowed) return cur.length || exp.length ? "allowed (by design)" : "ok";
    return exp.length ? "**VIOLATION (expected)**" : cur.length ? "**VIOLATION (current)**" : "ok";
}

const esc = (s) => String(s).replace(/\|/g, "\\|").replace(/\n/g, " ");
function nameOf(t, a) {
    const k = Object.keys(t.identities).find((n) => t.identities[n] === a);
    return k ? `${k} \`${a}\`` : `\`${a}\``;
}
function show(t, v) {
    if (v === null || v === undefined) return "";
    if (Array.isArray(v)) return v.length ? v.map((x) => show(t, x)).join("<br>") : "(empty)";
    if (typeof v === "string" && HEX40.test(v)) return nameOf(t, v);
    if (typeof v === "string" && Object.hasOwn(t.identities, v)) return t.identities[v] ? nameOf(t, t.identities[v]) : `${v} (address assigned at deploy)`;
    return esc(v);
}
const showCurrent = (t, c) => ("error" in c ? `_unreadable: ${esc(c.error)}_` : show(t, c.value));
const where = (t, r) => (r.address === null ? "" : `<br>${show(t, r.address)}`);

export function render(t, ctx) {
    const L = [];
    const p = (...x) => L.push(...x);
    p("<!-- GENERATED by scripts/gen-rc8-owner-table.mjs from docs/security/rc8-owner-table.json. Do not edit by hand. -->",
        `<!-- source-sha256: ${digestOf(t)} -->`, `# ${t.title}`, "",
        `Sepolia (chain ${t.readAt.chainId}), read-only, pinned block **${t.readAt.block}** \`${t.readAt.hash}\`. ` +
        `Endpoints: ${t.readAt.endpoints.join(" + ")} (provider names derived from the host); finalized heads at read time ${t.readAt.finalizedAtRead.join(" / ")}; ${t.readAt.rule}.`, "",
        `Operator inputs and the topic0 table come from \`${t.inventory.path}\` (sha256 \`${t.inventory.sha256}\`), ` +
        "an actual run of `script/rehearsal/inventory.mjs` whose controls are all true and which is bound to this chain, SP and Registry.", "",
        "Regenerate: `node script/rehearsal/inventory.mjs <env> <secondRpc> <out.json>`, `node script/rehearsal/owner-table-read.mjs <env> <secondRpc> <inventory.json>` (network, read-only), then " +
        "`node scripts/gen-rc8-owner-table.mjs`; check: `node scripts/gen-rc8-owner-table.mjs --check`.", "",
        "**Expected** is the post-rc.8 value. **Class**: (1) handed over to TL48 / the community Safe (or no holder); (2) operator-owned by design; " +
        "(3) legacy: not referenced or trusted by any rc.8 contract (mechanical evidence in the legacy probe section), shown PENDING until every reference is cleared. " +
        "**D is both the deployer EOA and the AAStar operator**: a class-2 row owned by D is a privilege the deployer EOA keeps. " +
        "**Agg** = no aggregator may hold an owner/admin/proposer/executor/ProxyAdmin/role slot (wiring that must point at the aggregator is allow-listed).", "");
    p("## Identities", "", "| Name | Address |", "|---|---|");
    for (const [k, v] of Object.entries(t.identities)) p(`| ${k}${t.aggregators.includes(k) ? " (aggregator)" : ""} | ${v ? `\`${v}\`` : "assigned at deploy"} |`);
    p("", "## Registry role ids (IRegistry.sol, cross-checked with Registry.getRoleConfig at the pinned block)", "",
        "| Constant | Name | Id | isActive | minStake | roleConfigs.owner |", "|---|---|---|---|---|---|");
    for (const r of t.roles) p(`| ${r.constant} | ${r.name} | \`${r.id}\` | ${r.isActive} | ${r.minStake} | ${nameOf(t, r.owner)} |`);
    p("", "Negative control: `getRoleConfig(keccak256(\"NOT_A_ROLE\"))` reads back inactive with owner 0.", "");
    p("## Operators", "", "The paper's operator count is the **configured** count.", "",
        `- **Configured in SP** (\`operators(addr).isConfigured\`), ${t.inventory.configuredOperators.length}: ${t.inventory.configuredOperators.map((a) => nameOf(t, a)).join(", ")}`,
        `- **Holds PAYMASTER_SUPER** (Registry \`roleMembers\` storage), ${t.inventory.superRoleHolders.length}: ${t.inventory.superRoleHolders.map((a) => nameOf(t, a)).join(", ")}`,
        `- Ever registered PAYMASTER_SUPER (RoleRegistered since Registry deploy block ${t.inventory.registryDeployBlock}), ${t.inventory.everRegisteredSuper.length}: ${t.inventory.everRegisteredSuper.map((a) => nameOf(t, a)).join(", ")}`, "");
    const auth = t.rows.filter((r) => r.kind === "authority"), other = t.rows.filter((r) => r.kind !== "authority");
    const issues = [];
    p("## Owner / privilege table", "",
        "| Id | Contract | Slot | Current (Sepolia) | Expected post-rc.8 | Set by | Readback | Class | Status | Agg | Reason / notes |", "|---|---|---|---|---|---|---|---|---|---|---|");
    for (const r of auth) {
        const st = status(t, ctx, r), ag = flags(t, r);
        for (const x of [st, ag]) if (/GAP|PENDING|VIOLATION/.test(x)) issues.push(`- \`${r.id}\`: ${x.replace(/\*/g, "")}`);
        const reason = [r.class === null ? r.pending : r.classReason, r.notes].filter(Boolean).map(esc).join(" ");
        p(`| ${r.id} | ${esc(r.contract)}${where(t, r)} | ${esc(r.slot)} | ${showCurrent(t, r.current)} | ${show(t, r.expected)} | ${esc(r.step)} | ${esc(r.readback)} | ${r.class ?? "-"} | ${st} | ${ag} | ${reason} |`);
    }
    p("", "## Wiring and identification readbacks (not privileges)", "",
        "| Id | Contract | Slot | Current (Sepolia) | Expected post-rc.8 | Set by | Readback | Agg | Notes |", "|---|---|---|---|---|---|---|---|---|");
    for (const r of other) {
        const ag = flags(t, r);
        if (/VIOLATION/.test(ag)) issues.push(`- \`${r.id}\`: ${ag.replace(/\*/g, "")}`);
        p(`| ${r.id} | ${esc(r.contract)}${where(t, r)} | ${esc(r.slot)} | ${showCurrent(t, r.current)} | ${show(t, r.expected)} | ${esc(r.step)} | ${esc(r.readback)} | ${ag} | ${esc(r.notes ?? "")} |`);
    }
    p("", `## Open items (${issues.length})`, "", ...(issues.length ? issues : ["- none"]), "");
    const lp = t.legacyProbe, res = lp.results;
    p("## Legacy (class 3) evidence", "",
        `Probes at the pinned block, both endpoints: ${res.gettersRead} zero-argument address getters of the rc.8 ABIs on ${Object.keys(lp.getterTargets).join(", ")}; ` +
        `${res.memberReads} role/mapping reads (${lp.memberProbes.map((m) => `${m.target}.${m.label}`).join(", ")}) for each subject. ` +
        `Getters whose selector is in no reachable deployed runtime (the address, its EIP-1967 implementation, its EXTENSION()), so they cannot return a subject: ${res.gettersNotInCode.join(", ") || "none"}. ` +
        `Reads that did not answer (keep every class-3 row PENDING): reverted although present ${res.gettersReverted.join(", ") || "none"}; ` +
        `transport failures ${res.gettersFailed.join(", ") || "none"}; member probes ${res.memberAbsent.join(", ") || "none"}. ` +
        `Source scan (address, case-insensitive): ${lp.sourceScan.join(", ")}. ${esc(lp.note)}`, "",
        "| Subject | Probe hits | Row hits (non-legacy rows whose current value holds it) | Source hits |", "|---|---|---|---|");
    for (const k of lp.subjects) {
        const a = resolveId(t, k), all = legacyHits(t, ctx, k);
        const col = (pre) => all.filter((h) => h.startsWith(pre)).map((h) => h.slice(pre.length)).join("<br>") || "none";
        p(`| ${nameOf(t, a)} | ${col("probe ")} | ${col("row ")} | ${col("source ")} |`);
    }
    p("", "## Set enumeration (getter-less sets)", "");
    for (const r of t.rows.filter((x) => x.current?.seeds)) {
        p(`- \`${r.id}\` (deploy block ${r.current.deployBlock}, ${r.current.candidates} candidates): ` +
            r.current.seeds.map((s) => `${s.event} on ${nameOf(t, s.address)} from ${s.fromBlock}${s.filter ? " " + esc(JSON.stringify(s.filter)) : ""}: ${s.logs} logs`).join("; "));
    }
    p("", "## SuperPaymaster topic0 table (input to the DVT detector supplement)", "",
        "| topic0 | Signature | Count | First block | Class | Source |", "|---|---|---|---|---|---|");
    for (const r of t.inventory.topic0Table) p(`| \`${r.topic0}\` | ${esc(r.signature)} | ${r.count} | ${r.firstBlock} | ${r.class} | ${esc(r.source ?? "")} |`);
    return L.join("\n") + "\n";
}

// Ids of the rendered table rows, in order (both tables).
export const renderedRowIds = (md) => md.split("\n").filter((l) => /^\| [a-z][\w.]*\.[\w.]+ \| /.test(l)).map((l) => l.split(" | ")[0].slice(2));

function scanFiles(root, rel, out = []) {
    const abs = join(root, rel);
    if (!existsSync(abs)) throw new Error(`source scan path missing: ${rel}`);
    if (statSync(abs).isDirectory()) for (const n of readdirSync(abs).sort()) scanFiles(root, join(rel, n), out);
    else out.push(rel);
    return out;
}

export function sourceScan(root, t) {
    const files = (t.legacyProbe?.sourceScan ?? []).flatMap((p) => scanFiles(root, p));
    const text = Object.fromEntries(files.map((f) => [f, readFileSync(join(root, f), "utf8").toLowerCase()]));
    const out = {};
    for (const k of t.legacyProbe?.subjects ?? []) {
        const a = resolveId(t, k).toLowerCase().slice(2);
        out[resolveId(t, k)] = files.filter((f) => text[f].includes(a));
    }
    return out;
}

export function load(root = ROOT, table = TABLE) {
    const t = JSON.parse(readFileSync(join(root, table), "utf8"));
    const ev = t.inventory?.path && existsSync(join(root, t.inventory.path)) ? readFileSync(join(root, t.inventory.path)) : null;
    const iregistrySrc = readFileSync(join(root, "contracts/src/interfaces/v3/IRegistry.sol"), "utf8");
    return { t, ctx: { iregistrySrc, evidence: ev, sourceScan: sourceScan(root, t) } };
}

export function main(argv = process.argv.slice(2), root = ROOT) {
    let t, ctx;
    try { ({ t, ctx } = load(root)); } catch (e) { console.error("owner table INVALID: " + e.message); return 1; }
    const errors = validate(t, ctx);
    if (errors.length) { console.error("owner table INVALID:\n  " + errors.join("\n  ")); return 1; }
    const md = render(t, ctx);
    const doc = join(root, DOC);
    if (argv.includes("--check")) {
        if (!existsSync(doc) || readFileSync(doc, "utf8") !== md) { console.error(`STALE: ${DOC} differs from ${TABLE} (source-sha256 ${digestOf(t)}); run node scripts/gen-rc8-owner-table.mjs`); return 1; }
        console.log(`OK: ${DOC} is up to date (${t.rows.length} rows, source-sha256 ${digestOf(t)})`);
        return 0;
    }
    writeFileSync(doc, md);
    console.log(`wrote ${DOC} (${t.rows.length} rows, source-sha256 ${digestOf(t)})`);
    return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) process.exit(main());

#!/usr/bin/env node
// gen-rc8-owner-table.mjs — render docs/security/rc8-owner-table.md from the source of truth
// docs/security/rc8-owner-table.json (rc.8 owner / role table v1). Offline: no network.
//
// The JSON's `current` column is filled by script/rehearsal/owner-table-read.mjs (read-only Sepolia,
// both endpoints, pinned block). This script validates the data and renders the doc:
//   - every address is full 40-hex and EIP-55 checksummed;
//   - the 7 role ids/names equal contracts/src/interfaces/v3/IRegistry.sol and read back configured;
//   - the inventory evidence file matches its recorded sha256 and the operator lists taken from it;
//   - per row: aggregator flag (no aggregator may hold an authority slot unless the row allow-lists it)
//     and deployer flag (a value left with D needs a written exception or is a GAP).
// Usage:
//   node scripts/gen-rc8-owner-table.mjs           # write the doc
//   node scripts/gen-rc8-owner-table.mjs --check   # exit 1 if the doc is stale or the data is invalid
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { getAddress, keccak256, stringToHex } from "viem";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
export const TABLE = "docs/security/rc8-owner-table.json";
export const DOC = "docs/security/rc8-owner-table.md";
const HEX40 = /^0x[0-9a-fA-F]{40}$/;
const COLUMNS = ["id", "contract", "address", "slot", "read", "current", "expected", "step", "readback", "kind"];

export function iregistryRoles(src) {
    return [...src.matchAll(/^bytes32 constant (ROLE_\w+)\s*=\s*keccak256\("(\w+)"\);/gm)].map((m) => ({ constant: m[1], name: m[2] }));
}

function walkAddresses(v, out = []) {
    if (typeof v === "string" && /^0x[0-9a-fA-F]{40}$/i.test(v)) out.push(v);
    else if (Array.isArray(v)) v.forEach((x) => walkAddresses(x, out));
    else if (v && typeof v === "object") Object.values(v).forEach((x) => walkAddresses(x, out));
    return out;
}

export function validate(t, { iregistrySrc, evidence }) {
    const errors = [];
    const err = (m) => errors.push(m);
    if (t.schema !== "rc8-owner-table/v1") err("schema must be rc8-owner-table/v1");
    // Addresses: every 40-hex string anywhere in the data must be checksummed (row `read` specs hold none).
    for (const a of walkAddresses({ ...t, rows: t.rows.map(({ read, ...r }) => r) })) {
        if (a !== getAddress(a)) err(`address not checksummed: ${a}`);
    }
    for (const [k, v] of Object.entries(t.identities)) if (v !== null && !HEX40.test(v)) err(`identity ${k} is not a full address`);
    for (const k of t.aggregators) if (!Object.hasOwn(t.identities, k)) err(`aggregator ${k} is not an identity`);
    // Roles: names/order from IRegistry.sol, ids = keccak256(name), all configured on Sepolia.
    const src = iregistryRoles(iregistrySrc);
    if (src.length !== 7) err(`IRegistry.sol declares ${src.length} roles, expected 7`);
    if (JSON.stringify(src.map((r) => r.name)) !== JSON.stringify(t.roles.map((r) => r.name))) err("roles differ from IRegistry.sol");
    for (const r of t.roles) {
        if (r.id !== keccak256(stringToHex(r.name))) err(`role ${r.name}: id != keccak256(name)`);
        if (r.configured !== true || r.isActive !== true) err(`role ${r.name}: not configured on Sepolia`);
    }
    // Evidence: the inventory file must still hash to what the table cites.
    if (!evidence) err(`inventory evidence missing: ${t.inventory?.path}`);
    else {
        if (createHash("sha256").update(evidence).digest("hex") !== t.inventory.sha256) err("inventory sha256 mismatch");
        const inv = JSON.parse(evidence);
        const configured = inv.state.operators.filter((o) => o.isConfigured).map((o) => o.operator);
        if (JSON.stringify(configured) !== JSON.stringify(t.inventory.configuredOperators)) err("configured operators differ from the evidence");
        if (JSON.stringify(inv.state.superHolders.fromStorage) !== JSON.stringify(t.inventory.superRoleHolders)) err("PAYMASTER_SUPER holders differ from the evidence");
        if (JSON.stringify(inv.topic0Table) !== JSON.stringify(t.inventory.topic0Table)) err("topic0 table differs from the evidence");
        if (inv.pinnedBlock.number !== t.readAt.block || inv.pinnedBlock.hash !== t.readAt.hash) err("readAt differs from the inventory pinned block");
    }
    const ids = new Set();
    for (const r of t.rows) {
        for (const c of COLUMNS) if (!(c in r)) err(`row ${r.id}: missing column ${c}`);
        if (ids.has(r.id)) err(`duplicate row id ${r.id}`);
        ids.add(r.id);
        if (!r.current || !("value" in r.current || "error" in r.current)) err(`row ${r.id}: current not read`);
        if (!["authority", "wiring", "info"].includes(r.kind)) err(`row ${r.id}: bad kind`);
    }
    return errors;
}

// Resolve a value to a list of addresses (identity names -> address; "A7"-style unassigned identities -> the name).
function members(t, v) {
    if (v === null || v === undefined) return [];
    if (Array.isArray(v)) return v.flatMap((x) => members(t, x));
    if (typeof v !== "string") return [];
    if (Object.hasOwn(t.identities, v)) return [t.identities[v] ?? v];
    return HEX40.test(v) ? [v] : [];
}

export function flags(t, r) {
    const aggs = new Set(t.aggregators.map((k) => t.identities[k] ?? k));
    const allow = new Set((t.aggregatorAllowList ?? []).map((k) => t.identities[k] ?? k));
    const hit = (v) => members(t, v).filter((a) => aggs.has(a) && !allow.has(a));
    let agg = "-";
    if (r.kind !== "info") {
        const cur = hit(r.current?.value), exp = hit(r.expected);
        if (r.aggAllowed) agg = cur.length || exp.length ? "allowed (by design)" : "ok";
        else agg = exp.length ? "**VIOLATION (expected)**" : cur.length ? "**VIOLATION (current)**" : "ok";
    }
    let dep = "-";
    if (r.kind === "authority" && members(t, r.expected).includes(t.identities.D)) {
        dep = !r.exception ? "**GAP (no exception text)**" : /^(GAP|VIOLATION)/.test(r.exception) ? "**GAP**" : "exception";
    }
    return { agg, dep };
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

export function render(t) {
    const L = [];
    const p = (...x) => L.push(...x);
    p("<!-- GENERATED by scripts/gen-rc8-owner-table.mjs from docs/security/rc8-owner-table.json. Do not edit by hand. -->",
        `# ${t.title}`, "",
        `Sepolia (chain ${t.readAt.chainId}), read-only, pinned block **${t.readAt.block}** \`${t.readAt.hash}\`. ` +
        `Endpoints: ${t.readAt.endpoints.join(" + ")}; ${t.readAt.rule}.`, "",
        `Operator inputs and the topic0 table come from \`${t.inventory.path}\` (sha256 \`${t.inventory.sha256}\`), ` +
        "an actual run of `script/rehearsal/inventory.mjs`.", "",
        "Regenerate: `node script/rehearsal/owner-table-read.mjs <env> <secondRpc> <inventory.json>` (network, read-only), then " +
        "`node scripts/gen-rc8-owner-table.mjs`; check: `node scripts/gen-rc8-owner-table.mjs --check`.", "",
        "**Expected** is the value after rc.8 as currently written (manifest / a3a / DeployLive on main). " +
        "**Agg** = no aggregator may be an owner, admin, proposer, executor, ProxyAdmin or role holder (wiring rows that must point at the aggregator are allow-listed). " +
        "**D** = a value left with the deployer needs a written exception, otherwise it is a GAP.", "");
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
    p("## Owner / privilege table", "",
        "| Contract | Slot | Current (Sepolia) | Expected post-rc.8 | Set by | Readback | Agg | D | Exception / notes |", "|---|---|---|---|---|---|---|---|---|");
    const issues = [];
    for (const r of t.rows) {
        const f = flags(t, r);
        if (/VIOLATION|GAP/.test(f.agg + f.dep)) issues.push(`- \`${r.id}\`: ${[f.agg, f.dep].filter((x) => /VIOLATION|GAP/.test(x)).join(", ").replace(/\*/g, "")}`);
        const where = r.address === null ? "" : `<br>${show(t, r.address)}`;
        const notes = [r.exception, r.notes].filter(Boolean).map(esc).join(" ");
        p(`| ${esc(r.contract)}${where} | ${esc(r.slot)} | ${showCurrent(t, r.current)} | ${show(t, r.expected)} | ${esc(r.step)} | ${esc(r.readback)} | ${f.agg} | ${f.dep} | ${notes} |`);
    }
    p("", `## Open items (${issues.length})`, "", ...(issues.length ? issues : ["- none"]), "");
    p("## Set enumeration (getter-less sets)", "");
    for (const r of t.rows.filter((x) => x.current?.seeds)) {
        p(`- \`${r.id}\` (deploy block ${r.current.deployBlock}, ${r.current.candidates} candidates): ` +
            r.current.seeds.map((s) => `${s.event} on ${nameOf(t, s.address)} from ${s.fromBlock}${s.filter ? " " + esc(JSON.stringify(s.filter)) : ""}: ${s.logs} logs`).join("; "));
    }
    p("", "## SuperPaymaster topic0 table (input to the DVT detector supplement)", "",
        "| topic0 | Signature | Count | First block | Class | Source |", "|---|---|---|---|---|---|");
    for (const r of t.inventory.topic0Table) p(`| \`${r.topic0}\` | ${esc(r.signature)} | ${r.count} | ${r.firstBlock} | ${r.class} | ${esc(r.source ?? "")} |`);
    return L.join("\n") + "\n";
}

export function load(root = ROOT, table = TABLE) {
    const t = JSON.parse(readFileSync(join(root, table), "utf8"));
    const ev = t.inventory?.path && existsSync(join(root, t.inventory.path)) ? readFileSync(join(root, t.inventory.path)) : null;
    const iregistrySrc = readFileSync(join(root, "contracts/src/interfaces/v3/IRegistry.sol"), "utf8");
    return { t, ctx: { iregistrySrc, evidence: ev } };
}

export function main(argv = process.argv.slice(2), root = ROOT) {
    const { t, ctx } = load(root);
    const errors = validate(t, ctx);
    if (errors.length) { console.error("owner table INVALID:\n  " + errors.join("\n  ")); return 1; }
    const md = render(t);
    const doc = join(root, DOC);
    if (argv.includes("--check")) {
        if (!existsSync(doc) || readFileSync(doc, "utf8") !== md) { console.error(`STALE: ${DOC} differs from ${TABLE}; run node scripts/gen-rc8-owner-table.mjs`); return 1; }
        console.log(`OK: ${DOC} is up to date (${t.rows.length} rows)`);
        return 0;
    }
    writeFileSync(doc, md);
    console.log(`wrote ${DOC} (${t.rows.length} rows)`);
    return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) process.exit(main());

#!/usr/bin/env node
// gen-abi-docs.mjs — Regenerate the per-contract ABI reference + selector index for the
// SuperPaymaster contract suite, straight from the compiled `out/` artifacts.
//
// WHY: upstream consumers (@aastar/sdk, integrators, debuggers) need an authoritative,
// drift-free map of every callable surface: signature, 4-byte selector, params, returns,
// NatSpec @notice/@dev, state mutability, and (best-effort) access control. Hand-written
// docs rot the moment the ABI changes; this script makes the reference a build artifact.
//
// SOURCES (all under out/, produced by `forge build`):
//   - artifact.abi              — function/event/error/constructor fragments
//   - artifact.methodIdentifiers — solc's authoritative signature -> 4-byte selector map
//   - artifact.metadata.output.userdoc / devdoc — NatSpec (@notice / @dev / @param / @return)
//   - artifact.metadata.settings.compilationTarget — source path (used to keep only src/ contracts)
// Access-control modifiers (onlyOwner / onlyEntryPoint / ...) are NOT in the ABI, so they are
// scraped best-effort from the Solidity source headers and clearly labelled as such.
//
// OUTPUTS (both carry a GENERATED marker; never hand-edit):
//   docs/abi/reference.md  — combined per-contract reference (one section per src/ contract)
//   docs/abi/selectors.md  — global 4-byte selector index (functions + errors) + event topics
//
// Usage:
//   node scripts/gen-abi-docs.mjs           # write the generated docs
//   node scripts/gen-abi-docs.mjs --check   # exit 1 if the committed docs are stale (CI gate)
//
// Idempotent: output is a pure function of out/ + src/ (no timestamps), so re-running with an
// unchanged build produces byte-identical files.

import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { keccak256, toBytes } from "viem";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const OUT_DIR = join(ROOT, "out");
const DOCS_DIR = join(ROOT, "docs", "abi");
const REFERENCE_MD = join(DOCS_DIR, "reference.md");
const SELECTORS_MD = join(DOCS_DIR, "selectors.md");
const CHECK = process.argv.includes("--check");

const GEN_MARKER =
  "<!-- GENERATED FILE — DO NOT EDIT BY HAND.\n" +
  "     Regenerate with `pnpm gen:abi-docs` (scripts/gen-abi-docs.mjs).\n" +
  "     Source of truth: out/ compiled ABIs + NatSpec. Hand edits will be overwritten. -->";

// --- selector helpers (mirror build-full-abi.mjs canonicalisation) -----------------------

// Canonical type string with tuple components expanded — matches solc's methodIdentifiers keys.
function canonicalType(input) {
  if (input.type.startsWith("tuple")) {
    const inner = "(" + (input.components || []).map(canonicalType).join(",") + ")";
    return inner + input.type.slice("tuple".length); // preserve [] / [N] suffixes
  }
  return input.type;
}
function canonicalSig(entry) {
  return `${entry.name}(${(entry.inputs || []).map(canonicalType).join(",")})`;
}
function selector4(sig) {
  return keccak256(toBytes(sig)).slice(0, 10); // 0x + 8 hex
}
function topic0(sig) {
  return keccak256(toBytes(sig)); // full 32-byte event topic
}

// --- artifact loading --------------------------------------------------------------------

// Every src/ contract we want to document, plus a couple of interface artifacts whose ABI is
// the canonical encoding surface for fallback-routed calls. Anything else (libraries pulled in
// from lib/, forge-std, OZ, account-abstraction) is filtered out via compilationTarget.
function srcPathOf(artifact) {
  try {
    const md =
      typeof artifact.rawMetadata === "string"
        ? JSON.parse(artifact.rawMetadata)
        : artifact.metadata;
    const target = md?.settings?.compilationTarget;
    if (!target) return null;
    const [path] = Object.keys(target);
    return path || null;
  } catch {
    return null;
  }
}
function natspec(artifact) {
  try {
    const md =
      typeof artifact.rawMetadata === "string"
        ? JSON.parse(artifact.rawMetadata)
        : artifact.metadata;
    return {
      user: md?.output?.userdoc ?? {},
      dev: md?.output?.devdoc ?? {},
    };
  } catch {
    return { user: {}, dev: {} };
  }
}

// Collect candidate artifacts: out/<Name>.sol/<Name>.json whose compilationTarget is under src/.
function collectContracts() {
  if (!existsSync(OUT_DIR)) {
    console.error(`Missing ${OUT_DIR} — run \`forge build\` first.`);
    process.exit(2);
  }
  const contracts = [];
  for (const dir of readdirSync(OUT_DIR)) {
    const dirPath = join(OUT_DIR, dir);
    if (!dir.endsWith(".sol") || !statSync(dirPath).isDirectory()) continue;
    if (dir.endsWith(".t.sol") || dir.endsWith(".s.sol")) continue; // tests / scripts
    for (const file of readdirSync(dirPath)) {
      if (!file.endsWith(".json")) continue;
      const artifact = JSON.parse(readFileSync(join(dirPath, file), "utf8"));
      const path = srcPathOf(artifact);
      if (!path || !path.startsWith("contracts/src/")) continue;
      const name = file.replace(/\.json$/, "");
      contracts.push({ name, file: dir, srcPath: path, artifact, ...natspec(artifact) });
    }
  }
  // Deterministic ordering: group by src subdir, then name.
  contracts.sort((a, b) =>
    a.srcPath === b.srcPath ? a.name.localeCompare(b.name) : a.srcPath.localeCompare(b.srcPath),
  );
  return contracts;
}

// --- access-control scrape (best effort, from source headers) ----------------------------

const KNOWN_MODIFIERS = [
  "onlyFactoryOrOwner",
  "onlyAuthorizedExecutor",
  "onlyEntryPoint",
  "onlyRegistry",
  "onlyOwner",
  "onlyDAO",
  "whenNotPaused",
  "whenPaused",
  "nonReentrant",
  "initializer",
  "reinitializer",
  "onlyInitializing",
];

// Returns Map<functionName, string[]> of access-relevant modifiers found on the source header.
// Overloads share a name and get their modifier sets merged (deduped).
function scrapeModifiers(srcPath) {
  const abs = join(ROOT, srcPath);
  if (!existsSync(abs)) return new Map();
  const code = readFileSync(abs, "utf8");
  const out = new Map();
  // Match `function NAME( ... )  <header up to body/decl end>`.
  // params are matched non-greedily to the first ')', then the header is captured up to '{' or ';'.
  const re = /function\s+(\w+)\s*\([^)]*\)([^{;]*)[{;]/g;
  let m;
  while ((m = re.exec(code)) !== null) {
    const name = m[1];
    const header = m[2];
    const found = KNOWN_MODIFIERS.filter((mod) => new RegExp(`\\b${mod}\\b`).test(header));
    if (found.length === 0) continue;
    const prev = out.get(name) ?? [];
    out.set(name, [...new Set([...prev, ...found])]);
  }
  return out;
}

// --- markdown rendering ------------------------------------------------------------------

function esc(s) {
  return String(s).replace(/\|/g, "\\|").replace(/\n+/g, " ").trim();
}

function paramLabel(input, i) {
  const nm = input.name && input.name.length ? input.name : `arg${i}`;
  return `${canonicalType(input)} ${nm}`;
}

function renderFunction(fn, methodIds, user, dev, modMap) {
  const sig = canonicalSig(fn);
  // Authoritative selector from solc when available; else compute. Cross-check if both exist.
  const computed = selector4(sig);
  const fromSolc = methodIds[sig] ? `0x${methodIds[sig]}` : null;
  if (fromSolc && fromSolc !== computed) {
    console.error(`Selector mismatch for ${sig}: solc=${fromSolc} computed=${computed}`);
    process.exit(1);
  }
  const sel = fromSolc ?? computed;

  const u = user.methods?.[sig] ?? {};
  const d = dev.methods?.[sig] ?? {};
  const mods = modMap.get(fn.name) ?? [];
  const access = mods.length ? mods.join(", ") : "—";

  const lines = [];
  const argList = (fn.inputs || []).map((inp, i) => paramLabel(inp, i)).join(", ");
  lines.push(`#### \`${fn.name}(${argList})\``);
  lines.push("");
  const meta = [`\`${sel}\``, fn.stateMutability, `access: ${access}`];
  lines.push(meta.join(" · "));
  lines.push("");
  if (u.notice) lines.push(`> ${esc(u.notice)}`, "");
  if (d.details) lines.push(`*@dev* ${esc(d.details)}`, "");

  // Params with @param notes.
  if ((fn.inputs || []).length) {
    lines.push("| param | type | description |", "|---|---|---|");
    for (let i = 0; i < fn.inputs.length; i++) {
      const inp = fn.inputs[i];
      const nm = inp.name && inp.name.length ? inp.name : `arg${i}`;
      const note = d.params?.[nm] ?? "";
      lines.push(`| \`${esc(nm)}\` | \`${esc(canonicalType(inp))}\` | ${esc(note)} |`);
    }
    lines.push("");
  }
  // Returns with @return notes.
  if ((fn.outputs || []).length) {
    lines.push("| returns | type | description |", "|---|---|---|");
    for (let i = 0; i < fn.outputs.length; i++) {
      const out = fn.outputs[i];
      const nm = out.name && out.name.length ? out.name : `_${i}`;
      // devdoc keys unnamed returns as _0, _1, ...
      const note = d.returns?.[nm] ?? d.returns?.[`_${i}`] ?? "";
      lines.push(`| \`${esc(nm)}\` | \`${esc(canonicalType(out))}\` | ${esc(note)} |`);
    }
    lines.push("");
  }
  return { sel, sig, mutability: fn.stateMutability, access, notice: u.notice ?? "", md: lines.join("\n") };
}

function renderContract(c) {
  const { artifact } = c;
  const abi = artifact.abi || [];
  const methodIds = artifact.methodIdentifiers || {};
  const modMap = scrapeModifiers(c.srcPath);

  const fns = abi
    .filter((e) => e.type === "function")
    .sort((a, b) => canonicalSig(a).localeCompare(canonicalSig(b)));
  const events = abi.filter((e) => e.type === "event");
  const errors = abi.filter((e) => e.type === "error");

  const lines = [];
  lines.push(`## ${c.name}`);
  lines.push("");
  lines.push(`- **Source:** \`${c.srcPath}\``);
  lines.push(`- **Functions:** ${fns.length} · **Events:** ${events.length} · **Errors:** ${errors.length}`);
  if (c.dev.title) lines.push(`- **Title:** ${esc(c.dev.title)}`);
  if (c.dev.notice || c.user.notice) lines.push(`- ${esc(c.dev.notice || c.user.notice)}`);
  lines.push("");

  const rendered = fns.map((fn) => renderFunction(fn, methodIds, c.user, c.dev, modMap));

  // Per-contract quick selector table.
  if (rendered.length) {
    lines.push("### Function selector index", "");
    lines.push("| selector | function | mutability | access | notice |", "|---|---|---|---|---|");
    for (const r of rendered) {
      lines.push(
        `| \`${r.sel}\` | \`${r.sig}\` | ${r.mutability} | ${r.access} | ${esc(r.notice)} |`,
      );
    }
    lines.push("");
    lines.push("### Functions", "");
    for (const r of rendered) lines.push(r.md);
  }

  // Events.
  if (events.length) {
    lines.push("### Events", "");
    lines.push("| topic0 | event |", "|---|---|");
    for (const ev of events.sort((a, b) => canonicalSig(a).localeCompare(canonicalSig(b)))) {
      const sig = canonicalSig(ev);
      lines.push(`| \`${topic0(sig)}\` | \`${sig}\` |`);
    }
    lines.push("");
  }
  // Errors.
  if (errors.length) {
    lines.push("### Errors", "");
    lines.push("| selector | error |", "|---|---|");
    for (const er of errors.sort((a, b) => canonicalSig(a).localeCompare(canonicalSig(b)))) {
      const sig = canonicalSig(er);
      lines.push(`| \`${selector4(sig)}\` | \`${sig}\` |`);
    }
    lines.push("");
  }

  // Collect global selector rows.
  const fnRows = rendered.map((r) => ({ sel: r.sel, sig: r.sig, contract: c.name, kind: "function" }));
  const errRows = errors.map((er) => {
    const sig = canonicalSig(er);
    return { sel: selector4(sig), sig, contract: c.name, kind: "error" };
  });
  const evRows = events.map((ev) => {
    const sig = canonicalSig(ev);
    return { sel: topic0(sig), sig, contract: c.name };
  });
  return { md: lines.join("\n"), fnRows, errRows, evRows };
}

// --- build documents ---------------------------------------------------------------------

function buildDocs() {
  const contracts = collectContracts();
  if (contracts.length === 0) {
    console.error("No src/ contracts found in out/ — did `forge build` run?");
    process.exit(2);
  }

  const sections = [];
  const allFns = [];
  const allErrs = [];
  const allEvs = [];
  for (const c of contracts) {
    const r = renderContract(c);
    sections.push(r.md);
    allFns.push(...r.fnRows);
    allErrs.push(...r.errRows);
    allEvs.push(...r.evRows);
  }

  // reference.md
  const ref = [];
  ref.push(GEN_MARKER, "");
  ref.push("# SuperPaymaster — Generated ABI Reference", "");
  ref.push(
    "Authoritative, auto-generated reference for every external/public function, event, and error " +
      "across the SuperPaymaster `src/` contracts. Generated from compiled `out/` artifacts " +
      "(ABI + solc selectors + NatSpec). See [`README.md`](./README.md) for how this is produced " +
      "and [`capabilities.md`](./capabilities.md) for a capability-grouped map.",
    "",
  );
  ref.push(
    "> **Access control** is scraped best-effort from Solidity source modifiers " +
      "(`onlyOwner`, `onlyEntryPoint`, …); `—` means no recognised access modifier was found " +
      "on the declaration (it may still be guarded inside the body — verify against source).",
    "",
  );
  ref.push("## Contracts", "");
  for (const c of contracts) ref.push(`- [${c.name}](#${c.name.toLowerCase()}) — \`${c.srcPath}\``);
  ref.push("");
  ref.push(...sections);
  const refOut = ref.join("\n").replace(/\n{3,}/g, "\n\n").trimEnd() + "\n";

  // selectors.md
  const sel = [];
  sel.push(GEN_MARKER, "");
  sel.push("# SuperPaymaster — Global Selector Index", "");
  sel.push(
    "Every 4-byte function selector and custom-error selector, plus event topic hashes, across " +
      "the SuperPaymaster `src/` contracts. Useful for decoding raw calldata / revert data / logs. " +
      "Generated by `pnpm gen:abi-docs`.",
    "",
  );

  sel.push("## Function selectors", "");
  sel.push("| selector | function | contract |", "|---|---|---|");
  for (const r of [...allFns].sort((a, b) => a.sel.localeCompare(b.sel))) {
    sel.push(`| \`${r.sel}\` | \`${r.sig}\` | ${r.contract} |`);
  }
  sel.push("");

  sel.push("## Error selectors", "");
  sel.push("| selector | error | contract |", "|---|---|---|");
  // Dedup identical (selector,sig) pairs shared across contracts via shared Errors.sol.
  const seenErr = new Set();
  for (const r of [...allErrs].sort((a, b) => a.sel.localeCompare(b.sel))) {
    const key = `${r.sel}|${r.sig}`;
    if (seenErr.has(key)) continue;
    seenErr.add(key);
    sel.push(`| \`${r.sel}\` | \`${r.sig}\` | ${r.contract} |`);
  }
  sel.push("");

  sel.push("## Event topics (topic0)", "");
  sel.push("| topic0 | event | contract |", "|---|---|---|");
  const seenEv = new Set();
  for (const r of [...allEvs].sort((a, b) => a.sel.localeCompare(b.sel))) {
    const key = `${r.sel}|${r.sig}`;
    if (seenEv.has(key)) continue;
    seenEv.add(key);
    sel.push(`| \`${r.sel}\` | \`${r.sig}\` | ${r.contract} |`);
  }
  sel.push("");
  const selOut = sel.join("\n").replace(/\n{3,}/g, "\n\n").trimEnd() + "\n";

  return {
    contracts,
    files: [
      { path: REFERENCE_MD, content: refOut },
      { path: SELECTORS_MD, content: selOut },
    ],
    counts: { contracts: contracts.length, fns: allFns.length, errs: seenErr.size, evs: seenEv.size },
  };
}

// --- main --------------------------------------------------------------------------------

const { files, counts } = buildDocs();

if (CHECK) {
  let stale = false;
  for (const f of files) {
    const current = existsSync(f.path) ? readFileSync(f.path, "utf8") : "";
    if (current !== f.content) {
      console.error(`STALE: ${f.path.replace(ROOT + "/", "")} — run \`pnpm gen:abi-docs\` and commit.`);
      stale = true;
    }
  }
  if (stale) process.exit(1);
  console.log(
    `ABI docs up to date (${counts.contracts} contracts, ${counts.fns} functions, ` +
      `${counts.errs} errors, ${counts.evs} events).`,
  );
} else {
  mkdirSync(DOCS_DIR, { recursive: true });
  for (const f of files) writeFileSync(f.path, f.content);
  console.log(
    `Wrote docs/abi/reference.md + docs/abi/selectors.md: ` +
      `${counts.contracts} contracts, ${counts.fns} functions, ${counts.errs} errors, ${counts.evs} events.`,
  );
}

#!/usr/bin/env node
// =============================================================================
// check-abi-bundle.mjs
//
// `gen-abi-docs.mjs --check` recomputes docs/abi/*.md and nothing else. It never
// reads abis/*.json — the bundle sync_to_sdk.sh copies into aastar-sdk, i.e. the
// artifact downstream actually imports. So the file with consumers sat outside
// the gate while the human-readable docs sat inside it, and abis/BLSAggregator.json
// drifted four functions behind the contract for six days with CI green. Raised
// by pr-daemon; issue #411.
//
// Names are not enough. #400 added a field to an EXISTING getter
// (guardianSlashCases, 7 outputs -> 8) without adding or removing a function, so a
// name-level diff sees nothing. This compares the full shape: inputs, outputs,
// stateMutability.
// =============================================================================
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join } from "node:path";

const ROOT = process.cwd();
const ABIS = join(ROOT, "abis");
const OUT = join(ROOT, "out");

const shape = (f) => JSON.stringify({
  t: f.type, n: f.name ?? "",
  i: (f.inputs ?? []).map((x) => x.type),
  o: (f.outputs ?? []).map((x) => x.type),
  m: f.stateMutability ?? "",
});

// Only first-party contracts are comparable. abis/ also carries EntryPoint,
// SimpleAccount and SimpleAccountFactory, which are account-abstraction v0.7
// artifacts deliberately pinned to what is DEPLOYED (EntryPoint v0.7 lives at
// 0x0000000071727De22E5E9d8BAf0edAc6f37da032). Comparing those against whatever
// `out/` happens to hold reports drift that is intentional — the first version
// of this script did exactly that and flagged all three. A gate that cries wolf
// on pinned externals gets ignored, and then it is not a gate.
const FIRST_PARTY = new Set(
  walkSol(join(ROOT, "contracts", "src")).map((f) => f.replace(/\.sol$/, ""))
);
function walkSol(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walkSol(join(dir, e.name)) : e.name.endsWith(".sol") ? [e.name] : []
  );
}

function compiledAbi(name) {
  const p = join(OUT, `${name}.sol`, `${name}.json`);
  return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")).abi : null;
}

let stale = 0, checked = 0, skipped = [], external = [];
for (const file of readdirSync(ABIS).filter((f) => f.endsWith(".json"))) {
  const name = file.replace(/\.json$/, "");
  if (name === "abi.config") continue;
  const raw = JSON.parse(readFileSync(join(ABIS, file), "utf8"));
  const committed = Array.isArray(raw) ? raw : raw.abi;
  const compiled = compiledAbi(name);
  // No artifact means this bundle has no contract to compare against. Say so
  // rather than counting it as agreement: an empty comparison and a passing one
  // are the same reading otherwise.
  if (!FIRST_PARTY.has(name)) { external.push(name); continue; }
  // A first-party bundle whose artifact is missing is NOT a pass. The first
  // version pushed it to `skipped` and exited 0, so a partial or stale `out/`
  // turned every uncompared bundle into a silent agreement — the same
  // fail-open this script exists to close, reproduced inside it.
  if (!compiled) { console.error(`FAIL: abis/${file} — no compiled artifact at out/${name}.sol/${name}.json`); stale++; continue; }
  if (!committed) { console.error(`FAIL: abis/${file} — unreadable or empty ABI`); stale++; continue; }
  checked++;
  const c = new Set(committed.map(shape));
  const o = new Set(compiled.map(shape));
  const missing = [...o].filter((x) => !c.has(x));
  const extra = [...c].filter((x) => !o.has(x));
  if (missing.length || extra.length) {
    stale++;
    console.error(`STALE: abis/${file}`);
    for (const m of missing.slice(0, 6)) console.error(`   only in compiled: ${m}`);
    for (const e of extra.slice(0, 6)) console.error(`   only in abis/   : ${e}`);
  }
}
console.log(`compared ${checked} bundles against out/`);
if (skipped.length) console.log(`no artifact, NOT compared: ${skipped.join(", ")}`);
if (external.length) console.log(`external / pinned to a deployment, NOT compared: ${external.join(", ")}`);
if (checked === 0) { console.error("FAIL: nothing was compared — run `forge build` first"); process.exit(2); }
if (stale) { console.error(`\n${stale} bundle(s) stale — run scripts/extract_v3_abis.sh and commit.`); process.exit(1); }
console.log("abis/ matches the compiled contracts (full shape, not just names)");

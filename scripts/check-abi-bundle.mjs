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
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const ROOT = process.cwd();
const ABIS = join(ROOT, "abis");
const OUT = join(ROOT, "out");

// Full entry, not just types: an event's `indexed` flags decide topic vs. data
// decoding, `anonymous` removes topic0, and tuple `components` are the struct
// layout. A shape that dropped them let `OperatorPaused.by` lose `indexed` in
// abis/ with this check green (Codex R3 on the event PR).
const param = (x) => ({
  n: x.name ?? "", t: x.type, x: !!x.indexed,
  c: (x.components ?? []).map(param),
});
const shape = (f) => JSON.stringify({
  t: f.type, n: f.name ?? "",
  i: (f.inputs ?? []).map(param),
  o: (f.outputs ?? []).map(param),
  m: f.stateMutability ?? "",
  a: !!f.anonymous,
});

// Only first-party contracts are comparable. abis/ also carries EntryPoint,
// SimpleAccount and SimpleAccountFactory, which are account-abstraction v0.7
// artifacts deliberately pinned to what is DEPLOYED (EntryPoint v0.7 lives at
// 0x0000000071727De22E5E9d8BAf0edAc6f37da032). Comparing those against whatever
// `out/` happens to hold reports drift that is intentional — the first version
// of this script did exactly that and flagged all three. A gate that cries wolf
// on pinned externals gets ignored, and then it is not a gate.
// TimelockController is an OpenZeppelin source, but this repository DEPLOYS it
// (DeployAPNTsCapped: owner of SP / APNTsCapped / Registry), so its exported bytecode
// must be the one the deploy scripts ship. A stale runs=200 copy sat in abis/ on the
// rc.8 BLS branch because it was filed under "external" here.
const DEPLOYED_EXTERNAL = ["TimelockController"];
const FIRST_PARTY = new Set([
  ...walkSol(join(ROOT, "contracts", "src")).map((f) => f.replace(/\.sol$/, "")),
  ...DEPLOYED_EXTERNAL,
]);
function walkSol(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walkSol(join(dir, e.name)) : e.name.endsWith(".sol") ? [e.name] : []
  );
}

// The artifact is the profile.default build resolved by its OWN metadata, the same
// file the deploy scripts ship (scripts/resolve_default_artifact.py mirrors
// contracts/script/v3/DefaultArtifacts.sol). `out/<C>.sol/<C>.json` is only the
// last compile of that name -- a Prague test build, or a stale runs=200 copy.
const bundleNames = readdirSync(ABIS)
  .filter((f) => f.endsWith(".json") && f !== "abi.config.json" && !f.endsWith(".full.json"))
  .map((f) => f.replace(/\.json$/, ""))
  .filter((n) => FIRST_PARTY.has(n));
const resolved = spawnSync("python3", ["scripts/resolve_default_artifact.py", "--out", OUT, "--json", ...bundleNames], { encoding: "utf8" });
let artifactPath = {}, unresolved = {};
try {
  ({ found: artifactPath, failed: unresolved } = JSON.parse(resolved.stdout));
} catch {
  // An unreadable resolver result is a failure of every bundle, never an empty pass.
  for (const n of bundleNames) unresolved[n] = `resolver did not run: ${(resolved.stderr || resolved.error || "").toString().trim()}`;
}
function compiledArtifact(name) {
  const p = artifactPath[name];
  return p && existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null;
}

// The bundle also carries creation bytecode, and a deploy from it is a deploy of
// whatever it holds: on the rc.8 event PR the ABIs were regenerated but a later
// source fix was not, so the exported SuperPaymaster/Admin/Lens bytecode silently
// predated it while the shape check stayed green. Bytecode is compared exactly.
const strip = (h) => (typeof h === "string" ? h : h?.object ?? "").replace(/^0x/, "").toLowerCase();

let stale = 0, checked = 0, skipped = [], external = [];
// A bundle that was deleted is not "nothing to compare". The required set is independent of
// what abis/ currently holds: every contract extract_v3_abis.sh exports (its CONTRACTS list),
// plus the deployed externals.
const extractSrc = readFileSync(join(ROOT, "scripts", "extract_v3_abis.sh"), "utf8");
const listMatch = extractSrc.match(/^CONTRACTS=\(([\s\S]*?)^\)/m);
const REQUIRED = new Set([
  ...(listMatch ? [...listMatch[1].matchAll(/^\s*"(\w+)"/gm)].map((m) => m[1]) : []),
  ...DEPLOYED_EXTERNAL,
]);
if (!listMatch || REQUIRED.size < 10) { console.error("FAIL: could not read the CONTRACTS list from scripts/extract_v3_abis.sh"); stale++; }
for (const n of REQUIRED) {
  if (!existsSync(join(ABIS, `${n}.json`))) { console.error(`FAIL: abis/${n}.json is missing (required bundle)`); stale++; }
}
for (const file of readdirSync(ABIS).filter((f) => f.endsWith(".json"))) {
  const name = file.replace(/\.json$/, "");
  if (name === "abi.config") continue;
  const raw = JSON.parse(readFileSync(join(ABIS, file), "utf8"));
  const committed = Array.isArray(raw) ? raw : raw.abi;
  const artifact = compiledArtifact(name);
  const compiled = artifact ? artifact.abi : null;
  // No artifact means this bundle has no contract to compare against. Say so
  // rather than counting it as agreement: an empty comparison and a passing one
  // are the same reading otherwise.
  if (name.endsWith(".full")) continue; // checked below as the merge of its halves
  if (!FIRST_PARTY.has(name)) { external.push(name); continue; }
  // A first-party bundle whose artifact is missing is NOT a pass. The first
  // version pushed it to `skipped` and exited 0, so a partial or stale `out/`
  // turned every uncompared bundle into a silent agreement — the same
  // fail-open this script exists to close, reproduced inside it.
  if (!compiled) { console.error(`FAIL: abis/${file} — ${unresolved[name] ?? "no unique profile.default build artifact"}`); stale++; continue; }
  if (!committed) { console.error(`FAIL: abis/${file} — unreadable or empty ABI`); stale++; continue; }
  checked++;
  if (!Array.isArray(raw) && raw.bytecode !== undefined && strip(raw.bytecode) !== strip(artifact.bytecode)) {
    stale++;
    console.error(`STALE: abis/${file} — bytecode differs from ${artifactPath[name]}`);
  }
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
// The merged core+extension bundles (*.full.json) have no single artifact; they
// are checked as the merge of their two (already checked) halves.
const full = spawnSync("python3", ["scripts/gen-sp-full-abi.py", "--check"], { encoding: "utf8" });
process.stdout.write(full.stdout ?? "");
if (full.status !== 0) { console.error(full.stderr || "FAIL: merged *.full.json check did not pass"); stale++; }
console.log(`compared ${checked} bundles against out/`);
if (skipped.length) console.log(`no artifact, NOT compared: ${skipped.join(", ")}`);
if (external.length) console.log(`external / pinned to a deployment, NOT compared: ${external.join(", ")}`);
if (checked === 0) { console.error("FAIL: nothing was compared — run `forge build` first"); process.exit(2); }
if (stale) { console.error(`\n${stale} bundle(s) stale — run scripts/extract_v3_abis.sh and commit.`); process.exit(1); }
console.log("abis/ matches the compiled contracts (full entries, bytecode, merged bundles)");

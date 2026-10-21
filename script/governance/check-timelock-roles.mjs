#!/usr/bin/env node
// =============================================================================
// check-timelock-roles.mjs — role-exclusivity check for the GOV-1 TimelockController (D5b, Codex
// closing review Medium; hardened after the Codex re-checks of ed2a4762 and 626b6ea8).
//
// WHAT THIS IS: an OPERATOR CHECK. It tells the person running it whether the timelock's role history,
// up to one head block, matches the committed manifest. Its attestation (--attest) is NOT signed and is
// NOT an enforcement boundary: UpgradeViaTimelock reads it as an operator preflight, but nothing binds
// what the Safe signers submit to it. Its load-bearing uses are (a) establishing the initial role sets
// ONCE at A5s / A6 (archived), and (b) letting operators and Safe signers re-check before a schedule /
// execute. The on-chain basis is a CONDITIONAL invariant (D5b-design §6.3d): WHILE DEFAULT_ADMIN_ROLE ==
// [timelock] AND minDelay == 172800, every grantRole / revokeRole / updateDelay is a public timelock
// operation delayed >= 48h. A scheduled operation can break either invariant (lower minDelay; grant
// DEFAULT_ADMIN to an outside account, which can then change roles without scheduling), but that FIRST
// weakening operation is itself publicly scheduled under the current 48h delay — it is what monitoring
// must alert on (updateDelay, grantRole(DEFAULT_ADMIN_ROLE, *), any grantRole to a non-manifest account)
// and what the Safe signers must refuse.
//
// OZ TimelockController uses AccessControl, NOT AccessControlEnumerable: nothing on-chain can list who
// holds a role, so the forge preflight (UpgradeViaTimelock.m1Preflight) is only a bounded check of the
// accounts it is told about. This script establishes exclusivity from the event history instead: it
// pulls every RoleGranted / RoleRevoked log of the timelock from its deployment block to a PINNED head
// block (chunked), replays them in (block, logIndex) order, and exits non-zero unless the resulting
// holder set of EVERY role equals the committed manifest (deployments/timelock-roles.<env>.json)
// exactly, and no `mustHoldNothing` account holds anything.
//
// Manifest (M3): every schema field is required — network, chainId, timelock, deploymentBlock,
// roles.{DEFAULT_ADMIN,PROPOSER,CANCELLER,EXECUTOR}_ROLE, mustHoldNothing, mustHoldNothingLabels — and
// must state the M1 policy (DEFAULT_ADMIN = [timelock]; PROPOSER = CANCELLER = EXECUTOR = [one Safe]),
// with a non-empty, unique, non-zero mustHoldNothing and one non-empty label per entry. A manifest that
// omits a field is rejected, never read as an empty (vacuously satisfied) set.
//
// Chain (M1): the primary endpoint's chainId — and --rpc2's — must equal the manifest chainId; both are
// recorded. UpgradeViaTimelock additionally requires manifest chainId == block.chainid.
//
// Completeness: a log scan cannot prove from its own results that no log was dropped (a missing range
// looks exactly like an empty one). What this script DOES verify, and prints:
//   1. depth probe — the endpoint serves state at the deployment block (code present at
//      deploymentBlock, absent at deploymentBlock - 1), i.e. it is an archive for that range;
//   2. positive control — the constructor's own grants (DEFAULT_ADMIN to the timelock itself, and the
//      manifest's proposer/canceller/executor) appear IN THE DEPLOYMENT BLOCK (a later grant of the
//      same role does not satisfy it: it would not prove the scan reached the constructor);
//   3. state cross-check — every reconstructed holder, and every manifest holder, is confirmed with a
//      live hasRole() call at the pinned head block;
//   4. optional second endpoint (--rpc2): it must serve the SAME head block (number AND hash — a lagging
//      or forked endpoint fails), pass its own depth probe, and return the identical log list over the
//      identical range, compared on the canonical decoded fields (event, role, account, sender,
//      blockNumber, blockHash, logIndex, transactionHash). The head hash is re-read on both endpoints
//      after the scan (a reorg during the scan fails the check).
// Without (4) the report says "completeness NOT independently verified". Keys in RPC URLs are never
// printed or written.
//
// Usage: node script/governance/check-timelock-roles.mjs --rpc <url> --manifest <path>
//            [--rpc2 <url>] [--chunk <positive integer, default 10000>] [--out <report.json>]
//            [--attest <path>|auto]
// Exit: 0 = history == manifest; 1 = mismatch / check failed / invalid manifest;
//       2 = usage / infrastructure error.
// With --attest <path>, EVERY run writes the attestation file at that path — usage errors, invalid
// manifests and infrastructure errors included — with result "PASS" only on exit 0, so a later failing
// run always replaces an earlier PASS (only `--attest` given without a value cannot be written).
// =============================================================================
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createPublicClient, http, parseAbiItem, getAddress, isAddress, keccak256, toBytes } from "viem";

const CHECKER_VERSION = "check-timelock-roles/1.5.0";
const USAGE = "usage: --rpc <url> --manifest <path> [--rpc2 <url>] [--chunk <positive integer>] [--out f] [--attest <path>|auto]\n" +
  "       --canonicalize <manifest>   (print the canonical serialization; see CANONICAL FORM)";

// ------------------------------------------------------------------ CANONICAL FORM (Codex re-check of 48cba3bd)
// The ONE place the manifest's byte-level form is enforced. A manifest is accepted only if its raw bytes
// are EXACTLY canonicalManifest(JSON.parse(bytes)):
//   - UTF-8, no BOM, LF line endings, 2-space indentation, one trailing "\n" — i.e.
//     JSON.stringify(value, null, 2) + "\n" (JSON.stringify writes non-ASCII characters literally and
//     escapes only what JSON requires);
//   - top-level keys in the order of TOP_KEYS (only those keys; `_comment` / `_placeholder` optional),
//     `roles` keys in the order of ROLE_LIST.
// Because JSON.parse -> canonical re-serialization is a function of the parsed VALUE, this rejects
// unicode-escaped keys or values, duplicate keys (the parser keeps one), nested decoys under unknown
// keys, reordered keys, alternative number / string spellings, trailing spaces, CRLF and a BOM. Forge
// (UpgradeViaTimelock) does not re-parse the bytes' form: it relies on the attestation binding the exact
// file bytes (manifestKeccak256), see requireRolesAttestation.
const TOP_KEYS = ["_comment", "_placeholder", "network", "chainId", "timelock", "deploymentBlock", "roles",
  "mustHoldNothing", "mustHoldNothingLabels"];
const ROLE_KEYS = ["DEFAULT_ADMIN_ROLE", "PROPOSER_ROLE", "CANCELLER_ROLE", "EXECUTOR_ROLE"];
function canonicalManifest(value) {
  const isObj = (o) => o !== null && typeof o === "object" && !Array.isArray(o);
  if (!isObj(value)) return JSON.stringify(value, null, 2) + "\n";
  const out = {};
  for (const k of TOP_KEYS) {
    if (!Object.prototype.hasOwnProperty.call(value, k)) continue;
    if (k === "roles" && isObj(value.roles)) {
      const r = {};
      for (const rk of ROLE_KEYS) if (Object.prototype.hasOwnProperty.call(value.roles, rk)) r[rk] = value.roles[rk];
      out.roles = r; // unknown role keys are dropped here (and reported by validateManifest)
    } else out[k] = value[k];
  }
  return JSON.stringify(out, null, 2) + "\n"; // unknown top-level keys are dropped (and reported)
}
const ATTEST_SCHEMA = "d5b-timelock-roles-attestation/2";
const args = process.argv.slice(2);
// --attest is located before anything else is validated, so that even a usage error overwrites a
// previous PASS at that path (Codex re-check of 626b6ea8, Low)
const RAW_ATTEST = (() => {
  const i = args.indexOf("--attest");
  const v = i >= 0 ? args[i + 1] : undefined;
  return v !== undefined && !v.startsWith("--") ? v : undefined;
})();
// EVERY destination the caller may have meant, in any spelling (`--attest p`, `--attest=p`,
// repeated flags): a usage error overwrites all of them, so no earlier PASS can survive.
const ALL_ATTEST = (() => {
  const out = [];
  args.forEach((a, i) => {
    if (a === "--attest" && args[i + 1] !== undefined && !args[i + 1].startsWith("--")) out.push(args[i + 1]);
    else if (a.startsWith("--attest=") && a.length > "--attest=".length) out.push(a.slice("--attest=".length));
  });
  return [...new Set(out)];
})();
function writeUsageFail(msg) {
  for (const a of ALL_ATTEST) writeUsageFailAt(a, msg);
}
function writeUsageFailAt(raw, msg) {
  // `auto` names a network/head-specific file that is unknown before the chain is read; a usage
  // error can only write the fixed placeholder below (documented limit: an earlier auto-named PASS
  // is not replaced — auto-named files are single-use and must be checked for freshness anyway)
  const path = raw === "auto" ? "deployments/attestations/timelock-roles.unknown.nohead.json" : raw;
  try {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, JSON.stringify({
      schema: ATTEST_SCHEMA, result: "FAIL", problems: [`usage error: ${msg}`],
      checker: { path: "script/governance/check-timelock-roles.mjs", version: CHECKER_VERSION },
      note: "usage error: nothing was checked; this file only replaces any earlier attestation at this path",
    }, null, 2) + "\n");
    console.error(`attestation written: ${path} (result FAIL, usage error)`);
  } catch (e) {
    console.error(`could not write the FAIL attestation at ${path}: ${e.message}`);
  }
}
const usage = (msg) => { writeUsageFail(msg); console.error(`usage error: ${msg}\n${USAGE}`); process.exit(2); };
const opt = (k, d) => {
  const i = args.indexOf(k);
  if (i < 0) return d;
  const v = args[i + 1];
  if (v === undefined || v.startsWith("--")) usage(`${k} needs a value`);
  return v;
};
// Strict argument grammar: only `--flag value` (no `--flag=value`), each flag at most once, only
// known flags. Anything else is a usage error — which overwrites every --attest destination found
// above with FAIL (Codex check of 279a7026: `--attest=path` and repeated flags bypassed that).
{
  const KNOWN = new Set(["--rpc", "--rpc2", "--manifest", "--chunk", "--out", "--attest", "--canonicalize"]);
  const seen = new Set();
  // every flag takes exactly one value; any token that is neither a flag nor the value right after
  // one (a stray positional) is a usage error too (Codex check of 2446d9d4, Low)
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (!a.startsWith("--")) usage(`unexpected argument "${a}" (every option is "--flag value")`);
    if (a.includes("=")) usage(`"${a}": the --flag=value form is not supported; use "--flag value"`);
    if (!KNOWN.has(a)) usage(`unknown option ${a}`);
    if (seen.has(a)) usage(`${a} given more than once`);
    seen.add(a);
    if (args[i + 1] === undefined || args[i + 1].startsWith("--")) usage(`${a} needs a value`);
    i++; // skip the value
  }
}
// --canonicalize <path>: print the canonical form (operators fix a file with it); no chain access
if (args.includes("--canonicalize")) {
  // A formatting helper, never a check: combined with any check option it is a usage error, so an
  // `--attest` path given alongside it is overwritten with FAIL instead of keeping an earlier PASS.
  const mixed = ["--attest", "--rpc", "--rpc2", "--manifest", "--out", "--chunk"].filter((k) => args.includes(k));
  if (mixed.length) usage(`--canonicalize cannot be combined with ${mixed.join(", ")} (it checks nothing)`);
  const p = opt("--canonicalize");
  let v;
  try { v = JSON.parse(readFileSync(p, "utf8").replace(/^\uFEFF/, "")); } catch (e) { usage(`cannot parse ${p}: ${e.message}`); }
  process.stdout.write(canonicalManifest(v));
  process.exit(0);
}
const RPC = opt("--rpc");
const RPC2 = opt("--rpc2");
const MANIFEST = opt("--manifest");
const CHUNK_RAW = opt("--chunk", "10000");
const OUT = opt("--out");
const ATTEST = opt("--attest");
if (!RPC || !MANIFEST) usage("--rpc and --manifest are required");
// L2: a zero / negative / non-integer chunk would never advance the scan loop
if (!/^[1-9][0-9]*$/.test(CHUNK_RAW)) usage(`--chunk must be a strictly positive integer, got "${CHUNK_RAW}"`);
const CHUNK = BigInt(CHUNK_RAW);
const redact = (u) => { try { const x = new URL(u); return `${x.protocol}//${x.host}`; } catch { return "<rpc>"; } };

const ROLE_NAMES = {
  ["0x" + "00".repeat(32)]: "DEFAULT_ADMIN_ROLE",
  [keccak256(toBytes("PROPOSER_ROLE"))]: "PROPOSER_ROLE",
  [keccak256(toBytes("CANCELLER_ROLE"))]: "CANCELLER_ROLE",
  [keccak256(toBytes("EXECUTOR_ROLE"))]: "EXECUTOR_ROLE",
};
const ROLE_ID = Object.fromEntries(Object.entries(ROLE_NAMES).map(([id, n]) => [n, id]));
const ROLE_LIST = Object.values(ROLE_NAMES);
const GRANTED = parseAbiItem("event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)");
const REVOKED = parseAbiItem("event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender)");
const HASROLE = parseAbiItem("function hasRole(bytes32 role, address account) view returns (bool)");

const gitCommit = (() => { try { return execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(); } catch { return "unknown"; } })();
const gitDirty = (() => { try { return execFileSync("git", ["status", "--porcelain", "--", "script/governance"], { encoding: "utf8" }).trim().length > 0; } catch { return null; } })();

// ------------------------------------------------------------------ attestation (written on every outcome)
const att = {
  schema: ATTEST_SCHEMA,
  result: "FAIL",
  chainId: null, rpc2ChainId: null, manifestChainId: null, timelock: null,
  manifestPath: MANIFEST, manifestSha256: null, manifestKeccak256: null,
  deploymentBlock: null, headBlock: null, headBlockHash: null,
  roles: {}, unknownRoles: [], mustHoldNothing: [], mustHoldNothingLabels: [], logs: null,
  depthProbe: null, rpc2DepthProbe: null, constructorControl: null, completeness: null, rpc2Used: !!RPC2,
  endpoint: redact(RPC), endpoint2: RPC2 ? redact(RPC2) : null,
  problems: [],
  checker: { path: "script/governance/check-timelock-roles.mjs", version: CHECKER_VERSION, gitCommit, gitDirty },
  note: "Operator check output, NOT signed and NOT an enforcement boundary: UpgradeViaTimelock uses it as an operator preflight (chainId, timelock, manifest hash, freshness, head hash when available, attested holders still hold their roles); it cannot bind what the Safe signs.",
};
let manifestNetwork = "unknown";
function writeAttestation() {
  if (!ATTEST) return;
  const path = ATTEST === "auto" ? `deployments/attestations/timelock-roles.${manifestNetwork}.${att.headBlock ?? "nohead"}.json` : ATTEST;
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(att, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2) + "\n");
  console.log(`attestation written: ${path} (result ${att.result})`);
}
function fail(problems, code = 1) {
  att.result = "FAIL";
  att.problems = problems;
  writeAttestation();
  console.log("TIMELOCK ROLE CHECK FAILED:");
  for (const p of problems) console.log("  - " + p);
  process.exit(code);
}

// ------------------------------------------------------------------ manifest (M3: complete schema, non-vacuous)
// Everything from reading the manifest on runs inside main() (Codex re-check of 7ca43549, L2): any
// exception — a malformed manifest included — ends in main().catch, which writes a FAIL attestation.
let TL, FROM, MANIFEST_CHAIN, expected, mustNothing, m;
const U64_MAX = 18446744073709551615n;
// chainId / deploymentBlock (Codex re-check of 7ca43549, M2): a JSON STRING of decimal digits, no leading
// zeros (except "0"), <= uint64 — checked on the parsed JSON type, so bare numbers (1, 1.0,
// 9007199254740993), hex strings, "007" and "" are all rejected; the byte-level form is the CANONICAL
// FORM check above.
const canonU64 = (v) => typeof v === "string" && /^(0|[1-9][0-9]{0,19})$/.test(v) && BigInt(v) <= U64_MAX;

function loadManifest() {
  let manifestBytes;
  try { manifestBytes = readFileSync(MANIFEST); } catch (e) { usage(`cannot read manifest ${MANIFEST}: ${e.message}`); }
  att.manifestSha256 = createHash("sha256").update(manifestBytes).digest("hex");
  att.manifestKeccak256 = keccak256(manifestBytes);
  // a leading BOM is tolerated by the PARSER only so that the canonical-bytes check below names it
  try { m = JSON.parse(manifestBytes.toString("utf8").replace(/^\uFEFF/, "")); } catch (e) { fail([`manifest is not valid JSON: ${e.message}`]); }
  const v = validateManifest(m);
  // byte-level canonical form (see CANONICAL FORM): the attested bytes are canonical or nothing passes
  const canon = Buffer.from(canonicalManifest(m), "utf8");
  if (Buffer.compare(canon, manifestBytes) !== 0) {
    let i = 0;
    while (i < canon.length && i < manifestBytes.length && canon[i] === manifestBytes[i]) ++i;
    v.problems.push(`manifest: bytes are not the canonical serialization (first difference at byte ${i}; ` +
      `run: node script/governance/check-timelock-roles.mjs --canonicalize ${MANIFEST})`);
  }
  for (const k of Object.keys(isPlainObject(m) ? m : {})) if (!TOP_KEYS.includes(k)) v.problems.push(`manifest: unknown top-level key .${k}`);
  if (typeof m?.network === "string" && /^[A-Za-z0-9._-]+$/.test(m.network)) manifestNetwork = m.network;
  att.manifestChainId = typeof m?.chainId === "string" ? m.chainId : null;
  att.timelock = v.tl;
  if (v.problems.length) fail(v.problems);
  TL = v.tl;
  FROM = BigInt(m.deploymentBlock);
  MANIFEST_CHAIN = BigInt(m.chainId);
  expected = Object.fromEntries(ROLE_LIST.map((r) => [r, new Set(v.roles[r])]));
  mustNothing = v.mhn;
  att.deploymentBlock = m.deploymentBlock;
  att.mustHoldNothing = mustNothing;
  att.mustHoldNothingLabels = m.mustHoldNothingLabels;
}

const isPlainObject = (o) => o !== null && typeof o === "object" && !Array.isArray(o);

function validateManifest(m) {
  const p = [];
  const isObj = (o) => o !== null && typeof o === "object" && !Array.isArray(o);
  const has = (o, k) => isObj(o) && Object.prototype.hasOwnProperty.call(o, k);
  if (!isObj(m)) return { problems: [`manifest: must be a JSON object (got ${Array.isArray(m) ? "array" : m === null ? "null" : typeof m})`], tl: null, roles: {}, mhn: [] };
  const addr = (v, where) => {
    if (typeof v !== "string" || !isAddress(v, { strict: false })) { p.push(`${where}: not an address (${JSON.stringify(v)})`); return null; }
    const a = getAddress(v);
    if (a === "0x0000000000000000000000000000000000000000") { p.push(`${where}: zero address`); return null; }
    return a;
  };
  if (has(m, "_placeholder")) p.push("manifest: `_placeholder` is set — this is the example schema with FAKE addresses, not a network manifest");
  for (const k of ["network", "chainId", "timelock", "deploymentBlock", "roles", "mustHoldNothing", "mustHoldNothingLabels"]) {
    if (!has(m, k)) p.push(`manifest: missing field .${k}`);
  }
  if (has(m, "network") && (typeof m.network !== "string" || m.network.length === 0)) p.push("manifest: .network must be a non-empty string");
  for (const k of ["chainId", "deploymentBlock"]) {
    if (!has(m, k)) continue;
    if (!canonU64(m[k])) p.push(`manifest: .${k} must be a decimal string (no leading zeros, <= uint64), got ${JSON.stringify(m[k])} (${typeof m[k]})`);
    else if (m[k] === "0") p.push(`manifest: .${k} must be > 0`);
  }
  const tl = has(m, "timelock") ? addr(m.timelock, "manifest .timelock") : null;
  const roles = {};
  if (has(m, "roles") && !isObj(m.roles)) {
    p.push(`manifest: .roles must be an object (got ${Array.isArray(m.roles) ? "array" : m.roles === null ? "null" : typeof m.roles})`);
  } else if (has(m, "roles")) {
    for (const r of ROLE_LIST) {
      if (!has(m.roles, r)) { p.push(`manifest: missing field .roles.${r}`); continue; }
      if (!Array.isArray(m.roles[r]) || m.roles[r].length === 0) { p.push(`manifest: .roles.${r} must be a non-empty array`); continue; }
      roles[r] = m.roles[r].map((a, i) => addr(a, `manifest .roles.${r}[${i}]`));
      if (new Set(roles[r]).size !== roles[r].length) p.push(`manifest: duplicate address in .roles.${r}`);
    }
    for (const k of Object.keys(m.roles)) if (!ROLE_LIST.includes(k)) p.push(`manifest: unknown role key .roles.${k}`);
  }
  // M1 policy: DEFAULT_ADMIN = [timelock]; PROPOSER = CANCELLER = EXECUTOR = [the same single Safe]
  const one = (r) => (roles[r]?.length === 1 ? roles[r][0] : undefined);
  const safe = one("PROPOSER_ROLE");
  if (Object.keys(roles).length === 4) {
    if (!(one("DEFAULT_ADMIN_ROLE") && tl && one("DEFAULT_ADMIN_ROLE") === tl)) p.push("manifest: not the M1 policy: DEFAULT_ADMIN_ROLE must be exactly [timelock]");
    if (!(safe && one("CANCELLER_ROLE") === safe && one("EXECUTOR_ROLE") === safe)) p.push("manifest: not the M1 policy: PROPOSER = CANCELLER = EXECUTOR must be exactly [the same Safe]");
    if (safe && tl && safe === tl) p.push("manifest: the Safe must not be the timelock");
  }
  let mhn = [];
  if (has(m, "mustHoldNothing")) {
    if (!Array.isArray(m.mustHoldNothing) || m.mustHoldNothing.length === 0) p.push("manifest: .mustHoldNothing must be a non-empty array (historical accounts: deployer, old owners)");
    else {
      mhn = m.mustHoldNothing.map((a, i) => addr(a, `manifest .mustHoldNothing[${i}]`));
      if (new Set(mhn).size !== mhn.length) p.push("manifest: duplicate address in .mustHoldNothing");
      for (const a of mhn) if (a && (a === tl || a === safe)) p.push(`manifest: .mustHoldNothing lists the timelock / Safe (${a})`);
    }
  }
  if (has(m, "mustHoldNothingLabels")) {
    const L = m.mustHoldNothingLabels;
    if (!Array.isArray(L) || L.length !== (Array.isArray(m.mustHoldNothing) ? m.mustHoldNothing.length : -1)) p.push("manifest: .mustHoldNothingLabels must have exactly one label per .mustHoldNothing entry");
    else L.forEach((l, i) => { if (typeof l !== "string" || l.trim().length === 0) p.push(`manifest: .mustHoldNothingLabels[${i}] must be a non-empty string`); });
  }
  return { problems: p, tl, roles, mhn };
}


// ------------------------------------------------------------------ scanning
const client = (url) => createPublicClient({ transport: http(url, { retryCount: 3 }) });

async function depthProbe(c) {
  const codeAt = await c.getCode({ address: TL, blockNumber: FROM });
  const codeBefore = await c.getCode({ address: TL, blockNumber: FROM - 1n });
  return !!codeAt && codeAt !== "0x" && (!codeBefore || codeBefore === "0x");
}

async function scanLogs(c, head) {
  const logs = [];
  for (let a = FROM; a <= head; a += CHUNK) {
    const b = a + CHUNK - 1n > head ? head : a + CHUNK - 1n;
    logs.push(...(await c.getLogs({ address: TL, events: [GRANTED, REVOKED], fromBlock: a, toBlock: b })));
  }
  logs.sort((x, y) => (x.blockNumber === y.blockNumber ? x.logIndex - y.logIndex : (x.blockNumber < y.blockNumber ? -1 : 1)));
  return logs;
}

// canonical decoded form used for the rpc2 comparison (M2)
const canon = (l) => ({
  event: l.eventName, role: l.args.role, account: getAddress(l.args.account), sender: getAddress(l.args.sender),
  blockNumber: l.blockNumber.toString(), blockHash: l.blockHash, logIndex: Number(l.logIndex), transactionHash: l.transactionHash,
});

function replay(logs) {
  const holders = {};
  const unknownRoles = new Set();
  for (const l of logs) {
    const role = l.args.role;
    const name = ROLE_NAMES[role] ?? role;
    if (!ROLE_NAMES[role]) unknownRoles.add(role);
    holders[name] ??= new Set();
    const acct = getAddress(l.args.account);
    if (l.eventName === "RoleGranted") holders[name].add(acct); else holders[name].delete(acct);
  }
  return { holders, unknownRoles: [...unknownRoles] };
}

const eq = (a, b) => a.size === b.size && [...a].every((x) => b.has(x));

async function main() {
  loadManifest();
  const problems = [];
  const c1 = client(RPC);
  // M1: the endpoint must be the manifest's chain — otherwise nothing below is about the right timelock
  const chain1 = BigInt(await c1.getChainId());
  att.chainId = Number(chain1);
  let c2;
  if (RPC2) {
    c2 = client(RPC2);
    const chain2 = BigInt(await c2.getChainId());
    att.rpc2ChainId = Number(chain2);
    if (chain2 !== MANIFEST_CHAIN) problems.push(`chain mismatch: --rpc2 chainId ${chain2} != manifest chainId ${MANIFEST_CHAIN}`);
  }
  if (chain1 !== MANIFEST_CHAIN) problems.push(`chain mismatch: --rpc chainId ${chain1} != manifest chainId ${MANIFEST_CHAIN}`);
  if (problems.length) fail(problems);

  // M2: pin the head (number AND hash) once; everything below is evaluated at exactly this block
  const head = await c1.getBlockNumber();
  const headHash = (await c1.getBlock({ blockNumber: head })).hash;
  att.headBlock = Number(head);
  att.headBlockHash = headHash;
  if (head < FROM) fail([`manifest deploymentBlock ${FROM} is after the endpoint head ${head}`]);

  const depth1 = await depthProbe(c1);
  att.depthProbe = depth1;
  if (!depth1) problems.push(`depth probe failed: no code at deploymentBlock ${FROM} or code already at ${FROM - 1n} (wrong block or non-archive endpoint)`);
  const logs = await scanLogs(c1, head);
  for (const l of logs) if (l.blockNumber === head && l.blockHash !== headHash) problems.push(`log ${l.transactionHash}:${l.logIndex} at the pinned head carries block hash ${l.blockHash} != ${headHash}`);
  const { holders, unknownRoles } = replay(logs);
  att.logs = logs.length;

  // positive control, restricted to the deployment block (the constructor's own grants)
  const ctor = logs.filter((l) => l.eventName === "RoleGranted" && l.blockNumber === FROM);
  const inCtor = (role, acct) => ctor.some((l) => l.args.role === ROLE_ID[role] && getAddress(l.args.account) === acct);
  const ctorMissing = [];
  if (!inCtor("DEFAULT_ADMIN_ROLE", TL)) ctorMissing.push("DEFAULT_ADMIN_ROLE -> timelock");
  for (const r of ["PROPOSER_ROLE", "CANCELLER_ROLE", "EXECUTOR_ROLE"]) for (const a of expected[r]) if (!inCtor(r, a)) ctorMissing.push(`${r} -> ${a}`);
  att.constructorControl = ctorMissing.length === 0 ? `constructor grants found in deployment block ${FROM}` : `MISSING in deployment block ${FROM}: ${ctorMissing.join("; ")}`;
  for (const x of ctorMissing) problems.push(`positive control failed: constructor grant ${x} not found in deployment block ${FROM}`);

  // exact equality per role
  for (const r of ROLE_LIST) {
    const got = holders[r] ?? new Set();
    if (!eq(got, expected[r])) problems.push(`${r}: history holders [${[...got].join(", ")}] != manifest [${[...expected[r]].join(", ")}]`);
  }
  for (const r of unknownRoles) problems.push(`unexpected role id granted: ${r} holders [${[...(holders[r] ?? [])].join(", ")}]`);
  for (const a of mustNothing) for (const r of ROLE_LIST) if ((holders[r] ?? new Set()).has(a)) problems.push(`mustHoldNothing account ${a} holds ${r}`);

  // state cross-check at the pinned head
  const live = [];
  for (const r of ROLE_LIST) {
    const acc = new Set([...(holders[r] ?? []), ...expected[r], ...mustNothing]);
    for (const a of acc) {
      const val = await c1.readContract({ address: TL, abi: [HASROLE], functionName: "hasRole", args: [ROLE_ID[r], a], blockNumber: head });
      const want = (holders[r] ?? new Set()).has(a);
      live.push({ role: r, account: a, hasRole: val });
      if (val !== want) problems.push(`state cross-check: hasRole(${r}, ${a}) = ${val} but the replayed history says ${want}`);
    }
  }

  // M2: the second endpoint must serve the SAME pinned head and return the identical canonical log list
  let second = "completeness NOT independently verified (no --rpc2)";
  if (c2) {
    let head2Hash = null;
    try { head2Hash = (await c2.getBlock({ blockNumber: head })).hash; } catch { head2Hash = null; }
    const head2 = await c2.getBlockNumber();
    if (head2Hash === null || head2 < head) {
      problems.push(`--rpc2 does not serve the pinned head block ${head} (its head is ${head2}: lagging endpoint)`);
      second = "SECOND ENDPOINT LAGGING";
    } else if (head2Hash !== headHash) {
      problems.push(`--rpc2 block ${head} hash ${head2Hash} != primary ${headHash} (different chain or fork)`);
      second = "SECOND ENDPOINT ON A DIFFERENT CHAIN / FORK";
    } else {
      const depth2 = await depthProbe(c2);
      att.rpc2DepthProbe = depth2;
      if (!depth2) problems.push("--rpc2 depth probe failed (not an archive for the deployment block)");
      const logs2 = await scanLogs(c2, head);
      const k1 = logs.map(canon);
      const k2 = logs2.map(canon);
      const firstDiff = (() => { for (let i = 0; i < Math.max(k1.length, k2.length); ++i) if (JSON.stringify(k1[i]) !== JSON.stringify(k2[i])) return i; return -1; })();
      if (firstDiff >= 0) {
        problems.push(`--rpc2 returned a different role-log list over [${FROM}, ${head}] (${k2.length} vs ${k1.length} logs; first difference at index ${firstDiff}: ${JSON.stringify(k2[firstDiff] ?? null)} vs ${JSON.stringify(k1[firstDiff] ?? null)})`);
        second = "SECOND ENDPOINT DISAGREES";
      } else {
        second = `second endpoint ${redact(RPC2)} served the same head ${head} (${headHash}), passed its depth probe and returned the identical ${k2.length} role logs (canonical fields)`;
      }
    }
    // reorg guard: the pinned head must still be canonical on both endpoints after the scan
    const again2 = await c2.getBlock({ blockNumber: head }).then((b) => b.hash).catch(() => null);
    if (head2Hash !== null && again2 !== head2Hash) problems.push(`--rpc2 head block ${head} changed during the scan (reorg)`);
  }
  const again1 = (await c1.getBlock({ blockNumber: head })).hash;
  if (again1 !== headHash) problems.push(`primary head block ${head} changed during the scan (reorg)`);

  att.roles = Object.fromEntries(ROLE_LIST.map((r) => [r, [...(holders[r] ?? [])]]));
  att.unknownRoles = unknownRoles;
  att.completeness = second;
  const report = {
    ...att, holders: Object.fromEntries(Object.entries(holders).map(([r, s]) => [r, [...s]])),
    expected: Object.fromEntries(Object.entries(expected).map(([r, s]) => [r, [...s]])),
    liveHasRole: live, problems, ok: problems.length === 0,
  };
  if (OUT) writeFileSync(OUT, JSON.stringify(report, (_, x) => (typeof x === "bigint" ? x.toString() : x), 2) + "\n");
  console.log(`timelock ${TL} (chain ${chain1}${RPC2 ? `, rpc2 chain ${att.rpc2ChainId}` : ""}): ${logs.length} role logs in [${FROM}, ${head}] from ${redact(RPC)}; depth probe ${depth1 ? "ok" : "FAILED"}; ${second}`);
  for (const [r, s] of Object.entries(holders)) console.log(`  ${r}: ${[...s].join(", ") || "(none)"}`);
  if (problems.length) fail(problems);
  att.result = "PASS";
  att.problems = [];
  writeAttestation();
  console.log("TIMELOCK ROLE CHECK OK: the event-history holder set of every role equals the manifest");
}

main().catch((e) => {
  const msg = `infrastructure or internal error: ${e.shortMessage ?? e.message}`;
  console.error(msg);
  att.result = "FAIL";
  att.problems = [msg];
  try { writeAttestation(); } catch {}
  process.exit(2);
});

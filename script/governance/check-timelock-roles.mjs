#!/usr/bin/env node
// =============================================================================
// check-timelock-roles.mjs — role-exclusivity check for the GOV-1 TimelockController (D5b, Codex
// closing review Medium).
//
// OZ TimelockController uses AccessControl, NOT AccessControlEnumerable: nothing on-chain can list who
// holds a role, so the forge preflight (UpgradeViaTimelock.m1Preflight) is only a bounded check of the
// accounts it is told about. This script establishes exclusivity from the event history instead: it
// pulls every RoleGranted / RoleRevoked log of the timelock from its deployment block to `latest`
// (chunked), replays them in (block, logIndex) order, and exits non-zero unless the resulting holder
// set of EVERY role equals the committed manifest (deployments/timelock-roles.<env>.json) exactly, and
// no `mustHoldNothing` account holds anything.
//
// Completeness: a log scan cannot prove from its own results that no log was dropped (a missing range
// looks exactly like an empty one). What this script DOES verify, and prints:
//   1. depth probe — the endpoint serves state at the deployment block (code present at
//      deploymentBlock, absent at deploymentBlock - 1), i.e. it is an archive for that range;
//   2. positive control — the constructor's own grants (DEFAULT_ADMIN to the timelock itself, and the
//      manifest's proposer/canceller/executor) appear in the history;
//   3. state cross-check — every reconstructed holder, and every manifest holder, is confirmed with a
//      live hasRole() call at the scan head block;
//   4. optional second endpoint (--rpc2): the whole scan is repeated there and must match log-for-log.
// Without (4) the report says "completeness NOT independently verified". Keys in RPC URLs are never
// printed or written.
//
// Usage: node script/governance/check-timelock-roles.mjs --rpc <url> --manifest <path>
//            [--rpc2 <url>] [--chunk 10000] [--out <report.json>] [--attest <path>|auto]
// Exit: 0 = history == manifest; 1 = mismatch / check failed; 2 = usage / infrastructure error.
// =============================================================================
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createPublicClient, http, parseAbiItem, getAddress, keccak256, toBytes } from "viem";

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const RPC = opt("--rpc");
const RPC2 = opt("--rpc2");
const MANIFEST = opt("--manifest");
const CHUNK = BigInt(opt("--chunk", "10000"));
const OUT = opt("--out");
// --attest <path>: write the attestation UpgradeViaTimelock requires (TL_ROLES_ATTESTATION) for every
// governed broadcast; default deployments/attestations/timelock-roles.<network>.<head>.json when
// --attest is given without a path value of its own ("auto").
const ATTEST = opt("--attest");
const CHECKER_VERSION = "check-timelock-roles/1.1.0";
if (!RPC || !MANIFEST) { console.error("usage: --rpc <url> --manifest <path> [--rpc2 <url>] [--chunk N] [--out f]"); process.exit(2); }
const redact = (u) => { try { const x = new URL(u); return `${x.protocol}//${x.host}`; } catch { return "<rpc>"; } };

const ROLE_NAMES = {
  ["0x" + "00".repeat(32)]: "DEFAULT_ADMIN_ROLE",
  [keccak256(toBytes("PROPOSER_ROLE"))]: "PROPOSER_ROLE",
  [keccak256(toBytes("CANCELLER_ROLE"))]: "CANCELLER_ROLE",
  [keccak256(toBytes("EXECUTOR_ROLE"))]: "EXECUTOR_ROLE",
};
const ROLE_ID = Object.fromEntries(Object.entries(ROLE_NAMES).map(([id, n]) => [n, id]));
const GRANTED = parseAbiItem("event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)");
const REVOKED = parseAbiItem("event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender)");
const HASROLE = parseAbiItem("function hasRole(bytes32 role, address account) view returns (bool)");

const manifestBytes = readFileSync(MANIFEST);
const m = JSON.parse(manifestBytes.toString("utf8"));
const manifestSha256 = createHash("sha256").update(manifestBytes).digest("hex");
const manifestKeccak256 = keccak256(manifestBytes);
const gitCommit = (() => { try { return execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(); } catch { return "unknown"; } })();
const gitDirty = (() => { try { return execFileSync("git", ["status", "--porcelain", "--", "script/governance"], { encoding: "utf8" }).trim().length > 0; } catch { return null; } })();
const TL = getAddress(m.timelock);
const FROM = BigInt(m.deploymentBlock);
const expected = {};
for (const n of Object.values(ROLE_NAMES)) expected[n] = new Set((m.roles?.[n] ?? []).map((a) => getAddress(a)));
const mustNothing = (m.mustHoldNothing ?? []).map((a) => getAddress(a));

async function scan(url) {
  const c = createPublicClient({ transport: http(url, { retryCount: 3 }) });
  const head = await c.getBlockNumber();
  const codeAt = await c.getCode({ address: TL, blockNumber: FROM });
  const codeBefore = FROM > 0n ? await c.getCode({ address: TL, blockNumber: FROM - 1n }) : undefined;
  const depthOk = !!codeAt && codeAt !== "0x" && (FROM === 0n || !codeBefore || codeBefore === "0x");
  const logs = [];
  for (let a = FROM; a <= head; a += CHUNK) {
    const b = a + CHUNK - 1n > head ? head : a + CHUNK - 1n;
    const got = await c.getLogs({ address: TL, events: [GRANTED, REVOKED], fromBlock: a, toBlock: b });
    logs.push(...got);
  }
  logs.sort((x, y) => (x.blockNumber === y.blockNumber ? x.logIndex - y.logIndex : (x.blockNumber < y.blockNumber ? -1 : 1)));
  return { c, head, depthOk, logs };
}

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
  const problems = [];
  const s1 = await scan(RPC);
  const { holders, unknownRoles } = replay(s1.logs);
  if (!s1.depthOk) problems.push(`depth probe failed: no code at deploymentBlock ${FROM} or code already at ${FROM - 1n} (wrong block or non-archive endpoint)`);
  // positive control: the constructor grants must be in the scanned history
  const grants = s1.logs.filter((l) => l.eventName === "RoleGranted");
  const has = (role, acct) => grants.some((l) => l.args.role === ROLE_ID[role] && getAddress(l.args.account) === acct);
  if (!has("DEFAULT_ADMIN_ROLE", TL)) problems.push("positive control failed: constructor grant DEFAULT_ADMIN_ROLE -> timelock not found in the scanned history");
  for (const r of ["PROPOSER_ROLE", "CANCELLER_ROLE", "EXECUTOR_ROLE"]) {
    for (const a of expected[r]) if (!has(r, a)) problems.push(`positive control failed: no RoleGranted(${r}, ${a}) in the history`);
  }
  // exact equality per role
  for (const r of Object.values(ROLE_NAMES)) {
    const got = holders[r] ?? new Set();
    if (!eq(got, expected[r])) {
      problems.push(`${r}: history holders [${[...got].join(", ")}] != manifest [${[...expected[r]].join(", ")}]`);
    }
  }
  for (const r of unknownRoles) problems.push(`unexpected role id granted: ${r} holders [${[...(holders[r] ?? [])].join(", ")}]`);
  for (const a of mustNothing) {
    for (const r of Object.values(ROLE_NAMES)) if ((holders[r] ?? new Set()).has(a)) problems.push(`mustHoldNothing account ${a} holds ${r}`);
  }
  // state cross-check at the scan head
  const live = [];
  for (const r of Object.values(ROLE_NAMES)) {
    const acc = new Set([...(holders[r] ?? []), ...expected[r], ...mustNothing]);
    for (const a of acc) {
      const v = await s1.c.readContract({ address: TL, abi: [HASROLE], functionName: "hasRole", args: [ROLE_ID[r], a], blockNumber: s1.head });
      const want = (holders[r] ?? new Set()).has(a);
      live.push({ role: r, account: a, hasRole: v });
      if (v !== want) problems.push(`state cross-check: hasRole(${r}, ${a}) = ${v} but the replayed history says ${want}`);
    }
  }
  let second = "completeness NOT independently verified (no --rpc2)";
  if (RPC2) {
    const s2 = await scan(RPC2);
    const key = (l) => `${l.blockNumber}:${l.logIndex}:${l.transactionHash}`;
    const k1 = s1.logs.filter((l) => l.blockNumber <= s2.head).map(key).join("|");
    const k2 = s2.logs.filter((l) => l.blockNumber <= s1.head).map(key).join("|");
    second = k1 === k2 ? `second endpoint ${redact(RPC2)} returned the identical ${s2.logs.length} role logs` : "SECOND ENDPOINT DISAGREES";
    if (k1 !== k2) problems.push("second endpoint returned a different role-log set");
  }
  const report = {
    timelock: TL, deploymentBlock: FROM.toString(), headBlock: s1.head.toString(), endpoint: redact(RPC),
    logs: s1.logs.length, depthProbe: s1.depthOk,
    holders: Object.fromEntries(Object.entries(holders).map(([r, s]) => [r, [...s]])),
    expected: Object.fromEntries(Object.entries(expected).map(([r, s]) => [r, [...s]])),
    mustHoldNothing: mustNothing, liveHasRole: live, completeness: second,
    note: "A log scan cannot prove completeness from its own results; see the checks above.",
    problems, ok: problems.length === 0,
  };
  if (OUT) writeFileSync(OUT, JSON.stringify(report, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2) + "\n");
  if (ATTEST) {
    const chainId = await s1.c.getChainId();
    const headBlk = await s1.c.getBlock({ blockNumber: s1.head });
    const att = {
      schema: "d5b-timelock-roles-attestation/1",
      result: problems.length === 0 ? "PASS" : "FAIL",
      chainId, timelock: TL,
      manifestPath: MANIFEST, manifestSha256, manifestKeccak256,
      deploymentBlock: Number(FROM), headBlock: Number(s1.head), headBlockHash: headBlk.hash,
      roles: Object.fromEntries(Object.values(ROLE_NAMES).map((r) => [r, [...(holders[r] ?? [])]])),
      unknownRoles, mustHoldNothing: mustNothing, logs: s1.logs.length, depthProbe: s1.depthOk,
      completeness: second, rpc2Used: !!RPC2, endpoint: redact(RPC),
      problems,
      checker: { path: "script/governance/check-timelock-roles.mjs", version: CHECKER_VERSION, gitCommit, gitDirty },
      note: "Generated by the checker, not cryptographically signed; UpgradeViaTimelock re-verifies chainId, timelock, manifest hash, freshness and every attested holder on-chain.",
    };
    const path = ATTEST === "auto" ? `deployments/attestations/timelock-roles.${m.network ?? "unknown"}.${s1.head}.json` : ATTEST;
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, JSON.stringify(att, null, 2) + "\n");
    console.log(`attestation written: ${path} (result ${att.result})`);
  }
  console.log(`timelock ${TL}: ${s1.logs.length} role logs in [${FROM}, ${s1.head}] from ${redact(RPC)}; depth probe ${s1.depthOk ? "ok" : "FAILED"}; ${second}`);
  for (const [r, s] of Object.entries(holders)) console.log(`  ${r}: ${[...s].join(", ") || "(none)"}`);
  if (problems.length) {
    console.log("TIMELOCK ROLE CHECK FAILED:");
    for (const p of problems) console.log("  - " + p);
    process.exit(1);
  }
  console.log("TIMELOCK ROLE CHECK OK: the event-history holder set of every role equals the manifest");
}

main().catch((e) => { console.error("infrastructure error:", e.shortMessage ?? e.message); process.exit(2); });

#!/usr/bin/env node
// A3a precheck v2: prove the EXACT member set of every TimelockController role.
// OZ v5 TimelockController is AccessControl (not Enumerable), so hasRole() point checks cannot show
// that nobody ELSE holds a role. This script rebuilds each role's member set from the complete
// RoleGranted/RoleRevoked history of the timelock and then cross-checks it with hasRole().
//
// Completeness argument (checked, not assumed): the timelock has NO code at (deployBlock - 1), so it
// emitted nothing before deployBlock; every block from deployBlock to latest is a LOCAL anvil block,
// so a getLogs over [deployBlock, latest] on the fork is the full history.
//
// Usage: node scripts/a3a-v2-roles.mjs <local rpc> <timelock> <deployBlock> <expected-json>
//   expected-json: {"ADMIN":["0x.."],"PROPOSER":[..],"CANCELLER":[..],"EXECUTOR":[..]}
// Exit 1 (fail-closed) on any mismatch, including an empty event scan.
import { createPublicClient, http, parseAbi, parseAbiItem, keccak256, toHex, getAddress } from 'viem';

const [rpc, tlArg, deployBlockArg, expectedArg] = process.argv.slice(2);
if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(rpc ?? '')) { console.error('refusing: rpc must be a local anvil (http://127.0.0.1:<port>)'); process.exit(3); }
const tl = getAddress(tlArg);
const deployBlock = BigInt(deployBlockArg);
const expected = JSON.parse(expectedArg);
const c = createPublicClient({ transport: http(rpc) });

const ROLES = {
  ADMIN: '0x0000000000000000000000000000000000000000000000000000000000000000',
  PROPOSER: keccak256(toHex('PROPOSER_ROLE')),
  CANCELLER: keccak256(toHex('CANCELLER_ROLE')),
  EXECUTOR: keccak256(toHex('EXECUTOR_ROLE')),
};
const abi = parseAbi([
  'function hasRole(bytes32,address) view returns (bool)',
  'function getRoleAdmin(bytes32) view returns (bytes32)',
  'function PROPOSER_ROLE() view returns (bytes32)',
  'function CANCELLER_ROLE() view returns (bytes32)',
  'function EXECUTOR_ROLE() view returns (bytes32)',
  'function DEFAULT_ADMIN_ROLE() view returns (bytes32)',
]);
const granted = parseAbiItem('event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)');
const revoked = parseAbiItem('event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender)');
const fail = (m) => { console.error('ROLE CHECK FAILED: ' + m); process.exit(1); };

// role ids: the locally computed constants must equal the contract's own getters (selector check)
for (const [k, fn] of [['ADMIN', 'DEFAULT_ADMIN_ROLE'], ['PROPOSER', 'PROPOSER_ROLE'], ['CANCELLER', 'CANCELLER_ROLE'], ['EXECUTOR', 'EXECUTOR_ROLE']]) {
  const onchain = await c.readContract({ address: tl, abi, functionName: fn });
  if (onchain !== ROLES[k]) fail(`${fn}() ${onchain} != local ${ROLES[k]}`);
}
const before = await c.getCode({ address: tl, blockNumber: deployBlock - 1n });
if (before && before !== '0x') fail(`timelock already had code at block ${deployBlock - 1n}: event history may predate the scan`);
const latest = await c.getBlockNumber();
const g = await c.getLogs({ address: tl, event: granted, fromBlock: deployBlock, toBlock: latest });
const r = await c.getLogs({ address: tl, event: revoked, fromBlock: deployBlock, toBlock: latest });
if (g.length === 0) fail('zero RoleGranted events: the scan instrument is dead (a constructor always emits >= 1)');
const all = [...g.map((l) => ({ ...l, kind: 'grant' })), ...r.map((l) => ({ ...l, kind: 'revoke' }))]
  .sort((a, b) => (a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : Number(a.blockNumber - b.blockNumber)));
const sets = Object.fromEntries(Object.keys(ROLES).map((k) => [k, new Set()]));
const unknownRoles = [];
for (const l of all) {
  const k = Object.keys(ROLES).find((x) => ROLES[x] === l.args.role);
  if (!k) { unknownRoles.push(l.args.role); continue; }
  if (l.kind === 'grant') sets[k].add(getAddress(l.args.account)); else sets[k].delete(getAddress(l.args.account));
}
if (unknownRoles.length) fail(`events for unexpected role ids: ${unknownRoles.join(',')}`);

const result = { timelock: tl, deployBlock: deployBlock.toString(), scannedTo: latest.toString(), roleGrantedEvents: g.length, roleRevokedEvents: r.length, roles: {}, roleAdmins: {}, hasRoleCrossCheck: [] };
for (const k of Object.keys(ROLES)) {
  const got = [...sets[k]].sort();
  const exp = (expected[k] ?? []).map((a) => getAddress(a)).sort();
  result.roles[k] = got;
  if (JSON.stringify(got) !== JSON.stringify(exp)) fail(`${k} member set ${JSON.stringify(got)} != expected ${JSON.stringify(exp)}`);
  // positive control: every reconstructed member must answer hasRole == true
  for (const m of got) {
    const h = await c.readContract({ address: tl, abi, functionName: 'hasRole', args: [ROLES[k], m] });
    result.hasRoleCrossCheck.push({ role: k, account: m, hasRole: h, expected: true });
    if (!h) fail(`${k}: event-derived member ${m} has hasRole == false`);
  }
  const admin = await c.readContract({ address: tl, abi, functionName: 'getRoleAdmin', args: [ROLES[k]] });
  result.roleAdmins[k] = admin;
  if (admin !== ROLES.ADMIN) fail(`${k}: getRoleAdmin != DEFAULT_ADMIN_ROLE`);
}
// negative controls: well-known addresses that must NOT hold any role
const extra = (process.env.NOT_MEMBERS ?? '').split(',').filter(Boolean).map((a) => getAddress(a));
for (const a of ['0x0000000000000000000000000000000000000000', ...extra]) {
  for (const k of Object.keys(ROLES)) {
    if (sets[k].has(getAddress(a))) continue;
    const h = await c.readContract({ address: tl, abi, functionName: 'hasRole', args: [ROLES[k], a] });
    result.hasRoleCrossCheck.push({ role: k, account: getAddress(a), hasRole: h, expected: false });
    if (h) fail(`${k}: ${a} holds the role but no RoleGranted event shows it`);
  }
}
console.log(JSON.stringify(result, null, 1));

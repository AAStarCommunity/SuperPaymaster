import { noFixture, operatorBalanceContinuity } from './gauge-lib.mjs';
// A6 per-UserOperation gauge (CC-125 a71741ed; RDR-6 ①; plan §8.4 SP-owned implementation half).
//
// Drives matched triplets of real UserOperations — one through each arm, SP (SuperPaymaster),
// VPM (eth-infinitism VerifyingPaymaster) and TPM (eth-infinitism TokenPaymaster) — under the
// SAME EntryPoint, sender account, callData, gas fields and bundler EOA, and records every attempt
// (sent, withheld, failed) as one append-only JSONL line.
//
// What makes it a gauge rather than a dry-run (vs. the previous revision of this file):
//   * the verdict of an attempt is per UserOperation, decoded from the EntryPoint's
//     UserOperationEvent / UserOperationRevertReason / PostOpRevertReason for the EXPECTED
//     userOpHash (computed locally AND via EntryPoint.getUserOpHash, which must agree) —
//     receipt.status is recorded but never taken as the op's outcome;
//   * the SP arm decodes TransactionSponsored + the xPNTs lock/credit events and checks the
//     before/after read-backs against the conservation identities in gauge-lib.mjs (cited);
//   * every read-back is made on two RPC endpoints (A/B) pinned to the same block and compared;
//   * a run Passport (chain id, blocks, runtime codehashes, config getters) is taken at the start
//     and the end and must not drift;
//   * stop conditions exit non-zero; validate.mjs re-derives every verdict from the raw JSONL.
//
// LOCAL ANVIL ONLY. This file refuses any non-loopback RPC URL. Its output is NOT A6 data: the
// sample protocol (N, B_max, scenario mix) is DSR's deliverable; --count/--b-max are validated,
// required arguments here, and a run is flagged protocolConformant only when --count is 50.
//
// Usage:
//   node script/a6-collector/collector.mjs --rpc-a http://127.0.0.1:8545 --rpc-b http://127.0.0.1:8546 \
//     --count 50 --b-max 1 --out <run.jsonl> [--max-attempts 60] [--arms SP,VPM,TPM] \
//     [--fixture exec-revert|drop-op|wrong-hash] [--config deployments/config.anvil.json] \
//     [--baselines <baselines.json>] [--expect-entrypoint 0x...]
//
// Exit codes: 0 = N matched triplets collected; 10 = attempt budget exhausted before N;
//   20 RPC_DISAGREEMENT, 21 PASSPORT_DRIFT, 22 CONSERVATION_MISMATCH, 23 HASH_SELF_CHECK,
//   24 BLOCK_NOT_ISOLATED, 25 RECEIPT_DISAGREEMENT, 26 ENTRYPOINT_MISMATCH (an arm or the account
//   is bound to another EntryPoint); 27 UNEXPECTED_USEROP_EVENT (extra op in single-op gauge); 2 = bad arguments / refused; 1 = crash.
import { readFileSync, existsSync, statSync, openSync, writeSync, fsyncSync, closeSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  concat, pad, toHex, getAddress, encodeAbiParameters, decodeErrorResult, ContractFunctionRevertedError,
  keccak256, createPublicClient, http, encodeFunctionData,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { clients, send, rpc, EP_ABI, ANVIL_KEYS } from '../b-layer/lib.mjs';
import { checkDepositFloor, opGasLimitSum, depositFloor } from './deposit-guard.mjs';
import {
  CANONICAL_EP_V07, VERDICTS, classifyAttempt, decodeLogsFrom, SP_EVENTS_ABI, TOKEN_EVENTS_ABI,
  spConservation, localUserOpHash, diffPaths, jsonable,
} from './gauge-lib.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const SCHEMA = 'a6-gauge/1';
const PROTOCOL_N = 50;

// ── arguments (validated; no silent defaults for the protocol parameters) ─────────────────
function argVal(flag) { const i = process.argv.indexOf(flag); return i === -1 ? undefined : process.argv[i + 1]; }
function die(msg) { console.error(`collector: ${msg}`); process.exit(2); }
const LOCAL = /^http:\/\/(127\.0\.0\.1|localhost):\d+$/;
const rpcA = argVal('--rpc-a') ?? argVal('--rpc');
const rpcB = argVal('--rpc-b');
if (!rpcA || !rpcB) die('--rpc-a and --rpc-b are both required (two read-back endpoints; see README)');
if (!LOCAL.test(rpcA) || !LOCAL.test(rpcB)) die('refusing: local Anvil only (http://127.0.0.1:<port>)');
const allowSameEndpointLocal = process.argv.includes('--allow-same-endpoint-local');
const distinctEndpoints = false; // Local aliases cannot establish independent host identity.
if (new URL(rpcA).port === new URL(rpcB).port) die('identical RPC endpoints: different local ports are required');
if (!distinctEndpoints && !allowSameEndpointLocal) die('local RPC ports require --allow-same-endpoint-local (disqualifies conformance)');
const countRaw = argVal('--count');
if (!countRaw || !/^[1-9]\d*$/.test(countRaw) || Number(countRaw) > 1000) die('--count is required: an integer in [1, 1000] (matched triplets to collect)');
const count = Number(countRaw);
const bMaxRaw = argVal('--b-max');
if (!bMaxRaw || !/^[1-9]\d*$/.test(bMaxRaw) || Number(bMaxRaw) > 1_000_000) die('--b-max is required: an integer in [1, 1000000]');
const bMax = BigInt(bMaxRaw);
const maxAttemptsRaw = argVal('--max-attempts') ?? String(count * 2);
if (!/^[1-9]\d*$/.test(maxAttemptsRaw) || Number(maxAttemptsRaw) < count) die('--max-attempts must be an integer >= --count (attempt budget per arm)');
const maxAttempts = Number(maxAttemptsRaw);
const ARM_NAMES = ['SP', 'VPM', 'TPM'];
const arms = (argVal('--arms') ?? ARM_NAMES.join(',')).split(',');
if (!arms.length || arms.some((a) => !ARM_NAMES.includes(a)) || new Set(arms).size !== arms.length) die(`--arms must be a subset of ${ARM_NAMES}`);
const FIXTURES = ['exec-revert', 'drop-op', 'wrong-hash'];
const fixture = argVal('--fixture') ?? null;
if (!noFixture(fixture) && !FIXTURES.includes(fixture)) die(`--fixture must be one of ${FIXTURES}`);
const outPath = argVal('--out');
if (!outPath) die('--out <run.jsonl> is required');
if (existsSync(outPath) && statSync(outPath).size > 0) die(`refusing to touch non-empty ${outPath}: raw JSONL is append-only, one file per run`);
const configPath = argVal('--config') ?? resolve(ROOT, 'deployments/config.anvil.json');
const baselinesPath = argVal('--baselines') ?? resolve(ROOT, 'script/a6-collector/dryrun-output/baselines.anvil.json');
const expectEp = argVal('--expect-entrypoint') ?? null;

const cfg = JSON.parse(readFileSync(configPath, 'utf8'));
const baselines = JSON.parse(readFileSync(baselinesPath, 'utf8'));
const EP = getAddress(cfg.entryPoint);
if (expectEp !== null && (!/^0x[0-9a-fA-F]{40}$/.test(expectEp) || getAddress(expectEp) !== EP)) {
  die(`--expect-entrypoint ${expectEp} does not match the deployment's EntryPoint ${EP}`);
}
const SPA = getAddress(cfg.superPaymaster);
if (new Set([SPA, baselines.verifyingPaymaster.address, baselines.tokenPaymaster.address].map(a => getAddress(a).toLowerCase())).size !== 3) die('SP/VPM/TPM paymasters must be distinct');
const ctx = clients(rpcA, ANVIL_KEYS[0]);        // operator + account owner (deploy-core's deployer)
const bundler = clients(rpcA, ANVIL_KEYS[1]);    // bundler EOA, identical for every arm
const pubA = ctx.pub;
const pubB = createPublicClient({ transport: http(rpcB, { timeout: 60_000 }) });
const runId = argVal('--run-id') ?? `run-${new Date().toISOString().replace(/[:.]/g, '-')}`;

function collectorHead() {
  const files = ['collector.mjs', 'gauge-lib.mjs', 'deposit-guard.mjs', 'validate.mjs', 'rpc-proxy.mjs', '../b-layer/lib.mjs'];
  const codeSha256 = Object.fromEntries(files.map((f) => [f, createHash('sha256').update(readFileSync(resolve(ROOT, 'script/a6-collector', f))).digest('hex')]));
  try {
    const head = execSync('git rev-parse HEAD', { cwd: ROOT }).toString().trim();
    const dirty = execSync('git status --porcelain -- script/a6-collector script/b-layer/lib.mjs', { cwd: ROOT }).toString().trim() !== '';
    return { head, collectorDirty: dirty, codeSha256 };
  } catch { return { head: null, collectorDirty: null, codeSha256 }; }
}

// ── append-only JSONL ─────────────────────────────────────────────────────────────────────
const fd = openSync(outPath, 'a');
function writeLine(obj) {
  writeSync(fd, JSON.stringify(jsonable({ schema: SCHEMA, runId, ...obj })) + '\n');
  fsyncSync(fd);
}

class Stop extends Error { constructor(reason, code, detail) { super(reason); this.reason = reason; this.code = code; this.detail = detail; } }

// ── A/B read-backs ────────────────────────────────────────────────────────────────────────
/** Run `fn(pub)` on A and B; stop the run on any disagreement. Returns A's value. */
async function readAB(label, fn) {
  const [a, b] = await Promise.all([fn(pubA), fn(pubB)]);
  const ja = jsonable(a), jb = jsonable(b);
  const diff = diffPaths(ja, jb);
  if (diff.length) throw new Stop('RPC_DISAGREEMENT', 20, { label, diff, A: ja, B: jb });
  return { value: a, A: ja, B: jb };
}
async function rawCall(method, params) {
  const r = await rpc(rpcA, method, params);
  if (r.error) throw new Error(`${method}: ${JSON.stringify(r.error)}`);
  return r.result;
}

// ── ABIs ──────────────────────────────────────────────────────────────────────────────────
const EP_DEPOSIT_ABI = [{ type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'getDepositInfo', stateMutability: 'view', inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ type: 'tuple', components: [{ name: 'deposit', type: 'uint256' }, { name: 'staked', type: 'bool' },
      { name: 'stake', type: 'uint112' }, { name: 'unstakeDelaySec', type: 'uint32' }, { name: 'withdrawTime', type: 'uint48' }] }] }];
const SP_ABI = [
  { type: 'function', name: 'gasParams', stateMutability: 'view', inputs: [], outputs: [
    { name: 'current', type: 'tuple', components: ['minPostOpGas', 'settleGasBound', 'cWrap', 'cPostop'].map(name => ({ name, type: 'uint32' })) },
    { name: 'pending', type: 'tuple', components: [...['minPostOpGas', 'settleGasBound', 'cWrap', 'cPostop'].map(name => ({ name, type: 'uint32' })), { name: 'eta', type: 'uint64' }] },
  ] },
  { type: 'function', name: 'updateSBTStatus', stateMutability: 'nonpayable', inputs: [{ name: 'user', type: 'address' }, { name: 'status', type: 'bool' }], outputs: [] },
  { type: 'function', name: 'operators', stateMutability: 'view', inputs: [{ name: '', type: 'address' }],
    outputs: [{ name: 'aPNTsBalance', type: 'uint128' }, { name: 'isConfigured', type: 'bool' }, { name: 'isPaused', type: 'bool' },
      { name: 'xPNTsToken', type: 'address' }, { name: 'reputation', type: 'uint32' }, { name: 'minTxInterval', type: 'uint48' },
      { name: 'treasury', type: 'address' }, { name: 'totalSpent', type: 'uint256' }, { name: 'totalTxSponsored', type: 'uint256' }] },
  { type: 'function', name: 'deposit', stateMutability: 'nonpayable', inputs: [{ name: 'amount', type: 'uint256' }], outputs: [] },
  { type: 'function', name: 'updatePrice', stateMutability: 'nonpayable', inputs: [], outputs: [] },
  { type: 'function', name: 'protocolRevenue', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'inflightOf', stateMutability: 'view', inputs: [{ name: 'opHash', type: 'bytes32' }], outputs: [{ name: 'operator', type: 'address' }, { name: 'a0', type: 'uint256' }] },
  { type: 'function', name: 'version', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
  { type: 'function', name: 'entryPoint', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'REGISTRY', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'APNTS_TOKEN', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'protocolFeeBPS', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'aPNTsPriceUSD', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'priceStalenessThreshold', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'paused', stateMutability: 'view', inputs: [], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'cachedPrice', stateMutability: 'view', inputs: [], outputs: [{ name: 'price', type: 'int256' }, { name: 'updatedAt', type: 'uint256' }, { name: 'roundId', type: 'uint80' }, { name: 'decimals', type: 'uint8' }] },
  { type: 'function', name: 'isEligibleForSponsorship', stateMutability: 'view', inputs: [{ name: 'u', type: 'address' }], outputs: [{ type: 'bool' }] },
];
const TOKEN_ABI = [
  { type: 'function', name: 'mint', stateMutability: 'nonpayable', inputs: [{ name: 'to', type: 'address' }, { name: 'amount', type: 'uint256' }], outputs: [] },
  { type: 'function', name: 'approve', stateMutability: 'nonpayable', inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'transfer', stateMutability: 'nonpayable', inputs: [{ name: 'to', type: 'address' }, { name: 'amount', type: 'uint256' }], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'totalSupply', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'lockedOf', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'debts', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'creditReservedOf', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'lockOf', stateMutability: 'view', inputs: [{ name: 'h', type: 'bytes32' }, { name: 'u', type: 'address' }],
    outputs: [{ type: 'tuple', components: [{ name: 'xLocked', type: 'uint128' }, { name: 'aReserved', type: 'uint128' }, { name: 'locker', type: 'address' }] }] },
  { type: 'function', name: 'version', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
  { type: 'function', name: 'exchangeRate', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'SUPERPAYMASTER_ADDRESS', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'maxSingleTxLimit', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'emergencyDisabled', stateMutability: 'view', inputs: [], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'setAutoAllowance', stateMutability: 'nonpayable', inputs: [{ name: 'spender', type: 'address' }, { name: 'cap', type: 'uint256' }], outputs: [] },
  { type: 'function', name: 'setUserTotalCap', stateMutability: 'nonpayable', inputs: [{ name: 'cap', type: 'uint256' }], outputs: [] },
];
const ACCOUNT_ABI = [{ type: 'function', name: 'execute', stateMutability: 'nonpayable',
  inputs: [{ name: 'dest', type: 'address' }, { name: 'value', type: 'uint256' }, { name: 'func', type: 'bytes' }], outputs: [] }];
const FACTORY_ABI = [
  { type: 'function', name: 'createAccount', stateMutability: 'nonpayable', inputs: [{ name: 'owner', type: 'address' }, { name: 'salt', type: 'uint256' }], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'getAddress', stateMutability: 'view', inputs: [{ name: 'owner', type: 'address' }, { name: 'salt', type: 'uint256' }], outputs: [{ type: 'address' }] },
];
const HANDLE_OPS_ABI = [{ type: 'function', name: 'handleOps', stateMutability: 'nonpayable',
  inputs: [{ name: 'ops', type: 'tuple[]', components: [
    { name: 'sender', type: 'address' }, { name: 'nonce', type: 'uint256' },
    { name: 'initCode', type: 'bytes' }, { name: 'callData', type: 'bytes' },
    { name: 'accountGasLimits', type: 'bytes32' }, { name: 'preVerificationGas', type: 'uint256' },
    { name: 'gasFees', type: 'bytes32' }, { name: 'paymasterAndData', type: 'bytes' },
    { name: 'signature', type: 'bytes' } ] }, { name: 'beneficiary', type: 'address' }], outputs: [] }];
const ENTRYPOINT_ERRORS_ABI = [
  { type: 'error', name: 'FailedOp', inputs: [{ name: 'opIndex', type: 'uint256' }, { name: 'reason', type: 'string' }] },
  { type: 'error', name: 'FailedOpWithRevert', inputs: [{ name: 'opIndex', type: 'uint256' }, { name: 'reason', type: 'string' }, { name: 'inner', type: 'bytes' }] },
];

// ── op building (identical gas/fees/callData across arms) ────────────────────────────────
const u128 = (v) => pad(toHex(v), { size: 16 });
const GAS = { callGasLimit: 100_000n, verificationGasLimit: 300_000n, preVerificationGas: 60_000n,
  maxFeePerGas: 20_000_000_000n, maxPriorityFeePerGas: 2_000_000_000n };
const MAX_FEE_CEILING = GAS.maxFeePerGas;
const PM_GAS = {
  SP: { ver: 400_000n, post: 200_000n },   // D7 finding: 5.5.0 validation needs >150k
  VPM: { ver: 100_000n, post: 50_000n },
  TPM: { ver: 150_000n, post: 120_000n },
};
const NOOP_TARGET = '0x000000000000000000000000000000000000dEaD';
const NONCE_KEY = 0n;
const DECOY_NONCE_KEY = 1n; // drop-op fixture: a different op from the same sender, under another nonce key

/** callData every arm sends: SimpleAccount.execute(0x…dEaD, 0, 0x) — a real, successful call. */
function defaultCallData() {
  return encodeFunctionData({ abi: ACCOUNT_ABI, functionName: 'execute', args: [NOOP_TARGET, 0n, '0x'] });
}
/** exec-revert fixture: execute(GToken, 0, transfer(dEaD, 1)) — the account holds no GToken, so the
 *  inner call reverts with ERC20InsufficientBalance and EntryPoint emits UserOperationRevertReason. */
function revertingCallData() {
  const inner = encodeFunctionData({ abi: TOKEN_ABI, functionName: 'transfer', args: [NOOP_TARGET, 1n] });
  return encodeFunctionData({ abi: ACCOUNT_ABI, functionName: 'execute', args: [getAddress(cfg.gToken), 0n, inner] });
}

async function signAndHash({ sender, nonce, callData, pmAddr, pmGas, pmData }) {
  const packed = {
    sender, nonce, initCode: '0x', callData,
    accountGasLimits: concat([u128(GAS.verificationGasLimit), u128(GAS.callGasLimit)]),
    preVerificationGas: GAS.preVerificationGas,
    gasFees: concat([u128(GAS.maxPriorityFeePerGas), u128(GAS.maxFeePerGas)]),
    paymasterAndData: concat([pmAddr, u128(pmGas.ver), u128(pmGas.post), pmData]),
    signature: '0x',
  };
  const epHash = await readAB('getUserOpHash', (p) => p.readContract({ address: EP, abi: EP_ABI, functionName: 'getUserOpHash', args: [packed] }));
  const local = localUserOpHash(packed, EP, chainId);
  if (epHash.value.toLowerCase() !== local.toLowerCase()) throw new Stop('HASH_SELF_CHECK', 23, { epHash: epHash.value, local });
  packed.signature = await privateKeyToAccount(ANVIL_KEYS[0]).signMessage({ message: { raw: epHash.value } });
  return { packed, hash: epHash.value, localHash: local };
}

async function pmDataFor(arm, { sender, nonce, callData }) {
  if (arm === 'SP') {
    return concat([getAddress(ctx.account.address), pad(toHex((1n << 256n) - 1n), { size: 32 }), getAddress(spToken), '0x00']);
  }
  if (arm === 'VPM') {
    const vpm = baselines.verifyingPaymaster;
    const validUntil = 0n, validAfter = 0n;
    const partial = { sender, nonce, initCode: '0x', callData,
      accountGasLimits: concat([u128(GAS.verificationGasLimit), u128(GAS.callGasLimit)]),
      preVerificationGas: GAS.preVerificationGas, gasFees: concat([u128(GAS.maxPriorityFeePerGas), u128(GAS.maxFeePerGas)]),
      paymasterAndData: concat([getAddress(vpm.address), u128(PM_GAS.VPM.ver), u128(PM_GAS.VPM.post)]), signature: '0x' };
    const h = await pubA.readContract({ address: vpm.address, abi: vpm.abi, functionName: 'getHash', args: [partial, validUntil, validAfter] });
    const sig = await privateKeyToAccount(vpm.signerKey).signMessage({ message: { raw: h } });
    return concat([encodeAbiParameters([{ type: 'uint48' }, { type: 'uint48' }], [validUntil, validAfter]), sig]);
  }
  return '0x'; // TPM: no paymasterData
}
const pmAddrOf = (arm) => getAddress(arm === 'SP' ? cfg.superPaymaster : arm === 'VPM' ? baselines.verifyingPaymaster.address : baselines.tokenPaymaster.address);

// ── revert classification (unchanged semantics from the previous revision: only AA31 is infra) ─
function classifyRevert(decoded, rawErrorText) {
  if (decoded && typeof decoded.reason === 'string' && decoded.reason.startsWith('AA31')) return { infraFailure: true, sponsorshipFailed: false, revertReason: decoded.reason };
  if (decoded && typeof decoded.reason === 'string') return { infraFailure: false, sponsorshipFailed: true, revertReason: decoded.reason };
  return { infraFailure: true, sponsorshipFailed: false, undecoded: true, revertReason: `UNDECODED: ${(rawErrorText || '').slice(0, 250)}` };
}
function rawRevertDataOf(err) {
  let e = err;
  for (let i = 0; i < 8 && e; i++) { if (typeof e.data === 'string' && e.data.startsWith('0x') && e.data.length > 2) return e.data; e = e.cause; }
  return null;
}
async function simulateRevert(ops) {
  try {
    await pubA.simulateContract({ address: EP, abi: [...HANDLE_OPS_ABI, ...ENTRYPOINT_ERRORS_ABI], functionName: 'handleOps',
      args: [ops, bundler.account.address], account: bundler.account.address });
    return null;
  } catch (e) {
    const reverted = typeof e.walk === 'function' ? e.walk((err) => err instanceof ContractFunctionRevertedError) : null;
    let decoded = reverted?.data ? { errorName: reverted.data.errorName, reason: reverted.data.args?.[1] } : null;
    if (!decoded) {
      const raw = rawRevertDataOf(e);
      if (raw) { try { const d = decodeErrorResult({ abi: ENTRYPOINT_ERRORS_ABI, data: raw }); decoded = { errorName: d.errorName, reason: d.args?.[1] }; } catch { /* undecoded */ } }
    }
    return classifyRevert(decoded, e.shortMessage || e.message || String(e));
  }
}

// ── read-backs (pinned to one block, on A and B) ──────────────────────────────────────────
async function readbacks(arm, blockNumber, expectedHash, sender) {
  const pm = pmAddrOf(arm);
  const r = await readAB(`readbacks@${blockNumber}`, async (p) => {
    const at = { blockNumber };
    const block = await p.getBlock({ blockNumber });
    const out = { blockNumber, blockHash: block.hash,
      epDeposit: await p.readContract({ address: EP, abi: EP_DEPOSIT_ABI, functionName: 'balanceOf', args: [pm], ...at }) };
    const op = await p.readContract({ address: SPA, abi: SP_ABI, functionName: 'operators', args: [ctx.account.address], ...at });
    out.operatorBalance = op[0]; // Passport anchor at this exact block, including baseline arms.
    if (arm === 'SP') {
      const inf = await p.readContract({ address: SPA, abi: SP_ABI, functionName: 'inflightOf', args: [expectedHash], ...at });
      const t = (functionName, args = []) => p.readContract({ address: spToken, abi: TOKEN_ABI, functionName, args, ...at });
      Object.assign(out, {
        operatorBalance: op[0], totalSpent: op[7], totalTxSponsored: op[8],
        protocolRevenue: await p.readContract({ address: SPA, abi: SP_ABI, functionName: 'protocolRevenue', ...at }),
        inflightOperator: inf[0], inflightA0: inf[1],
        userXPNTs: await t('balanceOf', [sender]), totalSupply: await t('totalSupply'),
        lockedOf: await t('lockedOf', [sender]), debts: await t('debts', [sender]),
        creditReservedOf: await t('creditReservedOf', [sender]),
        lockXLocked: (await t('lockOf', [expectedHash, sender])).xLocked,
      });
    }
    return out;
  });
  return { A: r.A, B: r.B };
}

// ── Passport ──────────────────────────────────────────────────────────────────────────────
const EIP1967_IMPL = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
async function passport(p, blockNumber) {
  const at = { blockNumber };
  const codehash = async (a) => { const c = await p.getCode({ address: a, ...at }); return { address: getAddress(a), codehash: c ? keccak256(c) : null, size: c ? (c.length - 2) / 2 : 0 }; };
  const implOf = async (a) => { const s = await p.getStorageAt({ address: a, slot: EIP1967_IMPL, ...at }); return getAddress('0x' + s.slice(26)); };
  const tokenCode = await p.getCode({ address: spToken, ...at });
  const tokenImpl = /^0x363d3d373d3d3d363d73[0-9a-f]{40}5af43d82803e903d91602b57fd5bf3$/i.test(tokenCode) ? getAddress('0x' + tokenCode.slice(22, 62)) : null;
  const block = await p.getBlock({ blockNumber });
  const spR = (functionName, args = []) => p.readContract({ address: SPA, abi: SP_ABI, functionName, args, ...at });
  const tR = (functionName, args = []) => p.readContract({ address: spToken, abi: TOKEN_ABI, functionName, args, ...at });
  const op = await spR('operators', [ctx.account.address]);
  const price = await spR('cachedPrice');
  const depInfo = async (a) => p.readContract({ address: EP, abi: EP_DEPOSIT_ABI, functionName: 'getDepositInfo', args: [a], ...at });
  const stakeOf = async (a) => { const d = await depInfo(a); return { staked: d.staked, stake: d.stake, unstakeDelaySec: d.unstakeDelaySec, withdrawTime: d.withdrawTime }; };
  return {
    allowSameEndpointLocal,
    chainId: await p.getChainId(),
    block: { number: blockNumber, hash: block.hash, timestamp: block.timestamp },
    // Everything under `invariant` must be identical at the start and the end of the run.
    invariant: {
      entryPoint: { address: EP, isCanonicalV07Address: EP.toLowerCase() === CANONICAL_EP_V07.toLowerCase() },
      code: {
        entryPoint: await codehash(EP),
        superPaymasterProxy: await codehash(SPA), superPaymasterImpl: await codehash(await implOf(SPA)),
        xPNTsClone: await codehash(spToken), xPNTsImpl: tokenImpl ? await codehash(tokenImpl) : null,
        xPNTsExt: await codehash(cfg.xPNTsTokenV2Ext),
        account: await codehash(sender), accountImpl: await codehash(await implOf(sender)),
        verifyingPaymaster: await codehash(baselines.verifyingPaymaster.address),
        tokenPaymaster: await codehash(baselines.tokenPaymaster.address),
        tokenPaymasterToken: await codehash(baselines.tokenPaymaster.token),
        priceFeed: await codehash(cfg.priceFeed),
      },
      superPaymaster: {
        version: await spR('version'), entryPoint: await spR('entryPoint'), registry: await spR('REGISTRY'),
        aPNTs: await spR('APNTS_TOKEN'), protocolFeeBPS: await spR('protocolFeeBPS'), aPNTsPriceUSD: await spR('aPNTsPriceUSD'),
        priceStalenessThreshold: await spR('priceStalenessThreshold'), paused: await spR('paused'),
        cachedPrice: { price: price[0], decimals: price[3] },
        operator: { address: ctx.account.address, isConfigured: op[1], isPaused: op[2], xPNTsToken: op[3], minTxInterval: op[5] },
        senderEligible: await spR('isEligibleForSponsorship', [sender]),
        minPostOpGas: (await spR('gasParams'))[0].minPostOpGas,
      },
      xPNTs: { address: spToken, version: await tR('version'), exchangeRate: await tR('exchangeRate'),
        superPaymaster: await tR('SUPERPAYMASTER_ADDRESS'), maxSingleTxLimit: await tR('maxSingleTxLimit'), emergencyDisabled: await tR('emergencyDisabled') },
      stakes: { SP: await stakeOf(SPA), VPM: await stakeOf(baselines.verifyingPaymaster.address), TPM: await stakeOf(baselines.tokenPaymaster.address) },
      verifyingSigner: await p.readContract({ address: baselines.verifyingPaymaster.address, abi: baselines.verifyingPaymaster.abi, functionName: 'verifyingSigner', ...at }),
      // Identical-EntryPoint condition across arms: every paymaster must be bound to EP.
      armEntryPoints: {
        SP: await spR('entryPoint'),
        VPM: await p.readContract({ address: baselines.verifyingPaymaster.address, abi: baselines.verifyingPaymaster.abi, functionName: 'entryPoint', ...at }),
        TPM: await p.readContract({ address: baselines.tokenPaymaster.address, abi: baselines.tokenPaymaster.abi, functionName: 'entryPoint', ...at }),
        account: await p.readContract({ address: sender, abi: [{ type: 'function', name: 'entryPoint', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] }], functionName: 'entryPoint', ...at }),
      },
      sender, bundler: bundler.account.address, beneficiary: bundler.account.address,
      gas: GAS, pmGas: PM_GAS, callDataHash: keccak256(defaultCallData()),
    },
    // Recorded, not drift-checked (moves with every op / with time).
    volatile: { cachedPriceUpdatedAt: price[1], operatorBalance: op[0] },
  };
}
async function passportAB(label) {
  const bn = await pubA.getBlockNumber({ cacheTime: 0 });
  const r = await readAB(`passport:${label}`, (p) => passport(p, bn));
  return r.A;
}

// ── one-time setup (each step is a real tx by its real owner, except the SBT bit — see README) ─
let sender, spToken, chainId;
async function asImpersonated(account, fn) {
  await rawCall('anvil_impersonateAccount', [account]);
  await rawCall('anvil_setBalance', [account, toHex(10n ** 18n)]);
  try { await fn(); } finally { await rawCall('anvil_stopImpersonatingAccount', [account]); }
}
async function ownerExec(to, abi, functionName, args) {
  const func = encodeFunctionData({ abi, functionName, args });
  await send(ctx, sender, ACCOUNT_ABI, 'execute', [to, 0n, func]);
}
const setupLog = [];
async function setup() {
  const salt = 9001n;
  const factory = getAddress(cfg.simpleAccountFactory);
  sender = await pubA.readContract({ address: factory, abi: FACTORY_ABI, functionName: 'getAddress', args: [ctx.account.address, salt] });
  const code = await pubA.getCode({ address: sender });
  if (!code || code === '0x') { await send(ctx, factory, FACTORY_ABI, 'createAccount', [ctx.account.address, salt]); setupLog.push('createAccount'); }
  const op = await pubA.readContract({ address: SPA, abi: SP_ABI, functionName: 'operators', args: [ctx.account.address] });
  spToken = getAddress(op[3]);
  const E18 = 10n ** 18n;
  // Sender balances sized for up to 1000 triplets at this file's gas fields (~122 aPNTs/op at 1:1).
  const userBal = await pubA.readContract({ address: spToken, abi: TOKEN_ABI, functionName: 'balanceOf', args: [sender] });
  if (userBal < 40_000n * E18) { await send(ctx, spToken, TOKEN_ABI, 'mint', [sender, 40_000n * E18 - userBal]); setupLog.push('mint xPNTs'); }
  // The sender's own xPNTs spend caps (owner path: account.execute → token). Default user total
  // is 5,000 aPNTs (xPNTsV2Base.sol:32), too small for 50 ops at these placeholder gas fields.
  await ownerExec(spToken, TOKEN_ABI, 'setUserTotalCap', [50_000n * E18]);
  await ownerExec(spToken, TOKEN_ABI, 'setAutoAllowance', [SPA, 50_000n * E18]);
  setupLog.push('setUserTotalCap/setAutoAllowance(SP) 50,000');
  // Operator collateral: top up toward 20,000 aPNTs, bounded by what the deployer holds
  // (prepare-test leaves it 15,000 aPNTs). a0 per op is ~2,000 aPNTs at these gas fields.
  const have = await pubA.readContract({ address: getAddress(cfg.aPNTs), abi: TOKEN_ABI, functionName: 'balanceOf', args: [ctx.account.address] });
  if (op[0] < 20_000n * E18 && have > 0n) {
    const want = 20_000n * E18 - op[0];
    const amt = want < have ? want : have;
    // aPNTs is itself an xPNTs-family token: one transfer may not exceed its maxSingleTxLimit
    // (5,000 on anvil), so deposit in chunks.
    await send(ctx, getAddress(cfg.aPNTs), TOKEN_ABI, 'approve', [SPA, amt]);
    for (let left = amt; left > 0n;) {
      const chunk = left > 5_000n * E18 ? 5_000n * E18 : left;
      await send(ctx, SPA, SP_ABI, 'deposit', [chunk]);
      left -= chunk;
    }
    setupLog.push('operator deposit aPNTs');
  }
  // SBT eligibility: impersonate Registry to call the exact setter Registry.safeMintForRole calls.
  await asImpersonated(cfg.registry, async () => {
    const data = encodeFunctionData({ abi: SP_ABI, functionName: 'updateSBTStatus', args: [sender, true] });
    await rawCall('eth_sendTransaction', [{ from: cfg.registry, to: SPA, data }]);
  });
  setupLog.push('updateSBTStatus via impersonated Registry');
  const tpm = baselines.tokenPaymaster;
  await send(ctx, tpm.token, TOKEN_ABI, 'mint', [sender, 40_000n * E18]);
  await ownerExec(tpm.token, TOKEN_ABI, 'approve', [tpm.address, (1n << 256n) - 1n]);
  setupLog.push('TPM token mint + approve (owner path)');
  // The anvil mock feed reports block.timestamp as updatedAt; refresh SP's cache so validUntil is
  // in the future for the whole run (priceStalenessThreshold is recorded in the Passport).
  await send(ctx, SPA, SP_ABI, 'updatePrice', []);
  setupLog.push('SP.updatePrice (keeper)');
}

// ── one attempt ───────────────────────────────────────────────────────────────────────────
let attemptIndex = 0;
/** One attempt = one UserOperation through one arm. Every attempt writes exactly one JSONL line,
 *  including one interrupted by a stop condition (then with `stoppedBy` and whatever was known). */
async function attempt(arm, tripletIndex, passportStart) {
  const idx = attemptIndex++;
  const st = { row: { kind: 'attempt', attemptIndex: idx, tripletIndex, arm, fixture }, written: false };
  try {
    return await attemptInner(arm, idx, tripletIndex, passportStart, st);
  } catch (e) {
    if (!st.written) {
      writeLine({ ...st.row, verdict: st.row.verdict ?? 'STOPPED', stoppedBy: e instanceof Stop ? { reason: e.reason, detail: e.detail } : { reason: 'CRASH', detail: String(e) },
        exclusion: 'STOPPED', collectedAtUtc: new Date().toISOString() });
      st.written = true;
    }
    throw e;
  }
}
async function attemptInner(arm, idx, tripletIndex, passportStart, st) {
  const pm = pmAddrOf(arm);
  const callData = fixture === 'exec-revert' ? revertingCallData() : defaultCallData();
  const nonceR = await readAB('getNonce', (p) => p.readContract({ address: EP, abi: EP_ABI, functionName: 'getNonce', args: [sender, NONCE_KEY] }));
  const nonce = nonceR.value;
  const ours = await signAndHash({ sender, nonce, callData, pmAddr: pm, pmGas: PM_GAS[arm], pmData: await pmDataFor(arm, { sender, nonce, callData }) });
  let bundled = [ours.packed];
  let decoy = null;
  if (fixture === 'drop-op') {
    const dNonceR = await readAB('getNonce(decoy)', (p) => p.readContract({ address: EP, abi: EP_ABI, functionName: 'getNonce', args: [sender, DECOY_NONCE_KEY] }));
    const dCall = defaultCallData();
    decoy = await signAndHash({ sender, nonce: dNonceR.value, callData: dCall, pmAddr: pm, pmGas: PM_GAS[arm], pmData: await pmDataFor(arm, { sender, nonce: dNonceR.value, callData: dCall }) });
    bundled = [decoy.packed]; // our op is NOT in the bundle
  }
  // wrong-hash fixture: the op is real and lands, but the hash the gauge expects is corrupted.
  const expectedHash = fixture === 'wrong-hash' ? ours.hash.slice(0, -2) + (ours.hash.endsWith('00') ? '01' : '00') : ours.hash;

  const row = Object.assign(st.row, {
    chainId, entryPoint: EP, sender, nonce, paymaster: pm, bundler: bundler.account.address,
    callDataHash: keccak256(callData), gas: GAS, pmGas: PM_GAS[arm],
    expectedUserOpHash: expectedHash, epUserOpHash: ours.hash, localUserOpHash: ours.localHash,
    bundledUserOpHashes: (decoy ? [decoy.hash] : [ours.hash]),
    packedOp: ours.packed, bundledOps: bundled,
  });

  // Deposit-floor guard (RDR-6 ①).
  const dep = await readAB('epDeposit', (p) => p.readContract({ address: EP, abi: EP_DEPOSIT_ABI, functionName: 'balanceOf', args: [pm] }));
  const gasSum = opGasLimitSum({ verificationGasLimit: GAS.verificationGasLimit, callGasLimit: GAS.callGasLimit,
    paymasterVerificationGasLimit: PM_GAS[arm].ver, paymasterPostOpGasLimit: PM_GAS[arm].post, preVerificationGas: GAS.preVerificationGas });
  const guard = checkDepositFloor({ deposit: dep.value, estimatedCost: gasSum * GAS.maxFeePerGas,
    floor: depositFloor({ bMax, gasLimitSum: gasSum, maxFeePerGasCeiling: MAX_FEE_CEILING }) });
  row.guard = guard;
  const finish = (extra) => { const r = { ...row, ...extra, collectedAtUtc: new Date().toISOString() }; writeLine(r); st.written = true; return r; };
  if (!guard.allowed) {
    return finish({ sent: false, tx: null, logs: [], verdict: VERDICTS.NOT_SENT, failingCheck: 'deposit_floor', exclusion: 'NOT_SENT:DEPOSIT_FLOOR' });
  }
  const pre = await simulateRevert(bundled);
  if (pre) {
    return finish({ sent: false, tx: null, logs: [], preflight: pre, verdict: VERDICTS.NOT_SENT, failingCheck: 'preflight_revert',
      exclusion: pre.infraFailure ? (pre.undecoded ? 'NOT_SENT:PREFLIGHT_UNDECODED' : 'NOT_SENT:INFRA_AA31') : null });
  }

  const headBefore = await pubA.getBlockNumber({ cacheTime: 0 });
  const txHash = await bundler.wallet.writeContract({ address: EP, abi: HANDLE_OPS_ABI, functionName: 'handleOps',
    args: [bundled, bundler.account.address], chain: null });
  const rcA = await pubA.waitForTransactionReceipt({ hash: txHash });
  const rcB = await pubB.getTransactionReceipt({ hash: txHash });
  const rcView = (rc) => ({ status: rc.status, blockNumber: rc.blockNumber, blockHash: rc.blockHash, gasUsed: rc.gasUsed,
    effectiveGasPrice: rc.effectiveGasPrice, logs: rc.logs.map((l) => ({ address: getAddress(l.address), topics: l.topics, data: l.data, logIndex: l.logIndex })) });
  row.sent = true;
  row.tx = { hash: txHash };
  const rdiff = diffPaths(jsonable(rcView(rcA)), jsonable(rcView(rcB)));
  if (rdiff.length) throw new Stop('RECEIPT_DISAGREEMENT', 25, { txHash, diff: rdiff });
  const bn = rcA.blockNumber;
  const blocks = await readAB('attempt block', async p => { const b = await p.getBlock({ blockNumber: bn }); return { hash: b.hash, timestamp: b.timestamp, transactions: b.transactions }; });
  const blk = blocks.A;
  const rawTx = await readAB('transaction', p => p.getTransaction({ hash: txHash }));
  const tx = { from: rawTx.A.from, gasLimit: rawTx.A.gas, hash: txHash, status: rcA.status, blockNumber: bn, blockTimestamp: blk.timestamp, blockHash: rcA.blockHash, gasUsed: rcA.gasUsed,
    effectiveGasPrice: rcA.effectiveGasPrice, blockTxCount: blk.transactions.length, headBefore };
  const logs = rcView(rcA).logs;
  // The verdict needs only the receipt; it is fixed (and kept on a stop) before any read-back.
  const cls = classifyAttempt({ sent: true, txStatus: rcA.status, logs, entryPoint: EP, expectedHash, sender, nonce, paymaster: pm });
  Object.assign(row, { sent: true, tx, logs, verdict: cls.verdict, failingCheck: cls.failingCheck,
    revertKind: cls.revertKind ?? null, userOpEvent: cls.event ?? null, execRevert: cls.execRevert ?? [], postOpRevert: cls.postOpRevert ?? [] });
  if (noFixture(fixture) && cls.epEvents?.some(e => e.event === 'UserOperationEvent' && e.args.userOpHash.toLowerCase() !== expectedHash.toLowerCase())) {
    // All receipt logs are already in row; never attribute another op's event to an arm.
    throw new Stop('UNEXPECTED_USEROP_EVENT', 27, { attemptIndex: idx, txHash });
  }
  const before = await readbacks(arm, bn - 1n, expectedHash, sender);
  const after = await readbacks(arm, bn, expectedHash, sender);
  const out = { readbacks: { before, after } };

  if (blk.transactions.length !== 1 || bn !== headBefore + 1n) {
    finish({ ...out, exclusion: 'BLOCK_NOT_ISOLATED' });
    throw new Stop('BLOCK_NOT_ISOLATED', 24, { bn, txCount: blk.transactions.length, headBefore });
  }

  // Conservation: D1 for every arm whose op produced its event; SP identities on top.
  const checks = [];
  const previousBlock = lastAttemptBlock ?? { blockNumber: passportStart.block.number, blockHash: passportStart.block.hash };
  checks.push({ id: 'continuity.block', ok: BigInt(before.A.blockNumber) === BigInt(previousBlock.blockNumber) && before.A.blockHash.toLowerCase() === previousBlock.blockHash.toLowerCase() });
  const prior = stateByArm.get(arm);
  if (prior) for (const f of Object.keys(prior).filter(f => !['blockNumber', 'blockHash', 'operatorBalance', 'lockXLocked', 'inflightA0', 'inflightOperator'].includes(f))) {
    checks.push({ id: `continuity.${f}`, ok: diffPaths(before.A[f], prior[f]).length === 0 });
  }
  checks.push(...operatorBalanceContinuity(arm, before.A, after.A, lastAttemptBlock?.operatorBalance ?? passportStart.volatile.operatorBalance));
  if (arm === 'SP') checks.push({ id: 'continuity.new_op_lock_empty', ok: BigInt(before.A.lockXLocked) === 0n });
  for (const [value, seen, label] of [[txHash, seenTransactions, 'tx'], [expectedHash, seenOperations, 'op'], [tx.blockHash, seenBlocks, 'block']]) {
    checks.push({ id: `unique.${label}`, ok: !seen.has(value.toLowerCase()) }); seen.add(value.toLowerCase());
  }
  stateByArm.set(arm, after.A); lastAttemptBlock = after.A;
  if (cls.event) {
    const dDep = BigInt(after.A.epDeposit) - BigInt(before.A.epDeposit);
    checks.push({ id: 'D1.ep_deposit_delta_eq_minus_actualGasCost', ok: dDep === -BigInt(cls.event.actualGasCost),
      expected: String(-BigInt(cls.event.actualGasCost)), actual: String(dDep), src: 'EP:535,744-745' });
  }
  let sp = null;
  if (arm === 'SP' && cls.event) {
    sp = spConservation({ before: before.A, after: after.A, spEvents: decodeLogsFrom(logs, SPA, SP_EVENTS_ABI),
      tokenEvents: decodeLogsFrom(logs, spToken, TOKEN_EVENTS_ABI), expectedHash, sender, paymaster: SPA, operator: ctx.account.address, cls });
    checks.push(...sp.checks);
  }
  const evaluated = !!cls.event && sp?.evaluated !== false;
  const conservationOk = evaluated ? checks.every((c) => c.ok) : null;
  const r = finish({ ...out, spMode: sp?.mode ?? null, charge: sp?.charge ?? null, conservation: { evaluated, notEvaluable: sp?.notEvaluable ?? null, ok: conservationOk, checks },
    exclusion: !noFixture(fixture) ? 'FIXTURE' : null });
  if (checks.some(c => !c.ok)) throw new Stop('CONSERVATION_MISMATCH', 22, { attemptIndex: idx, failed: checks.filter((c) => !c.ok) });

  // Passport drift (code + config) at this block vs. the start.
  const now = await readAB(`passport@${bn}`, (p) => passport(p, bn));
  const drift = diffPaths(passportStart.invariant, now.A.invariant);
  if (drift.length) throw new Stop('PASSPORT_DRIFT', 21, { attemptIndex: idx, drift });
  return r;
}

// ── main ──────────────────────────────────────────────────────────────────────────────────
let exitCode = 1;
let stop = null;
let passportStart = null;
let lastAttemptBlock = null;
const stateByArm = new Map(), seenTransactions = new Set(), seenOperations = new Set(), seenBlocks = new Set();
const tally = Object.fromEntries(arms.map((a) => [a, { attempts: 0, verdicts: {} }]));
let matched = 0;
const triplets = [];
try {
  chainId = (await readAB('chainId', (p) => p.getChainId())).value;
  await setup();
  passportStart = await passportAB('start');
  const epMismatch = Object.entries(passportStart.invariant.armEntryPoints).filter(([, a]) => getAddress(a) !== EP);
  if (epMismatch.length) throw new Stop('ENTRYPOINT_MISMATCH', 26, { EP, epMismatch });
  writeLine({ kind: 'run_start', ...collectorHead(), argv: process.argv.slice(2), rpcA, rpcB, allowSameEndpointLocal,
    abTopology: argVal('--ab-topology') ?? 'unspecified', count, bMax, maxAttempts, arms, fixture,
    protocolConformant: count === PROTOCOL_N && noFixture(fixture) && arms.length === 3 && distinctEndpoints && !allowSameEndpointLocal,
    setupLog, passport: passportStart, startedAtUtc: new Date().toISOString() });
  console.log(`A6 gauge ${runId}: N=${count} bMax=${bMax} maxAttempts/arm=${maxAttempts} arms=${arms} fixture=${fixture ?? 'none'}`);
  console.log(`EP=${EP} (canonical v0.7 address: ${passportStart.invariant.entryPoint.isCanonicalV07Address}) sender=${sender}`);
  for (let t = 0; matched < count; t++) {
    if (arms.some((a) => tally[a].attempts >= maxAttempts)) { stop = { reason: 'MAX_ATTEMPTS', code: 10 }; break; }
    const rows = [];
    for (const arm of arms) {
      const r = await attempt(arm, t, passportStart);
      tally[arm].attempts++;
      tally[arm].verdicts[r.verdict] = (tally[arm].verdicts[r.verdict] ?? 0) + 1;
      rows.push(r);
      console.log(`  t=${t} ${arm.padEnd(3)} ${r.verdict}${r.failingCheck ? ` (${r.failingCheck})` : ''} hash=${r.expectedUserOpHash.slice(0, 12)}…${r.tx ? ` tx=${r.tx.hash.slice(0, 12)}… receipt=${r.tx.status}` : ''}`);
    }
    const ok = noFixture(fixture) && rows.every((r) => r.verdict === VERDICTS.USEROP_SUCCESS && r.conservation?.evaluated && r.conservation.ok)
      && new Set(rows.map((r) => r.callDataHash)).size === 1
      && ['paymaster', 'expectedUserOpHash'].every(f => new Set(rows.map(r => r[f].toLowerCase())).size === rows.length)
      && new Set(rows.map(r => r.tx.hash.toLowerCase())).size === rows.length;
    triplets.push({ tripletIndex: t, matched: ok, attempts: rows.map((r) => r.attemptIndex) });
    if (ok) matched++;
  }
  if (!stop) stop = { reason: 'COMPLETE', code: 0 };
} catch (e) {
  if (e instanceof Stop) stop = { reason: e.reason, code: e.code, detail: e.detail };
  else { stop = { reason: 'CRASH', code: 1, detail: String(e?.stack ?? e) }; }
}
let passportEnd = null;
try {
  if (passportStart && stop.reason !== 'RPC_DISAGREEMENT') {
    // Wait for an independently read later block; never relabel the last receipt block.
    const deadline = Date.now() + 60_000;
    const finalHeight = BigInt(lastAttemptBlock?.blockNumber ?? passportStart.block.number);
    // A local anvil (automine) produces no block after the last tx; mine one explicitly. Only under
    // the local override on chain 31337, which already disqualifies conformance; real chains wait.
    if (allowSameEndpointLocal && Number(passportStart.chainId) === 31337) await pubA.request({ method: 'evm_mine', params: [] });
    while (await pubA.getBlockNumber({ cacheTime: 0 }) <= finalHeight) {
      if (Date.now() >= deadline) throw new Stop('END_BLOCK_NOT_ADVANCED', 21, { finalHeight });
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
    passportEnd = await passportAB('end');
    const last = lastAttemptBlock ?? { blockNumber: passportStart.block.number, blockHash: passportStart.block.hash };
    const endHeight = BigInt(passportEnd.block.number), lastHeight = BigInt(last.blockNumber);
    const sameHash = passportEnd.block.hash.toLowerCase() === last.blockHash.toLowerCase();
    if ((passportEnd.chainId !== passportStart.chainId || endHeight <= lastHeight || sameHash || seenBlocks.has(passportEnd.block.hash.toLowerCase()) || passportEnd.block.hash.toLowerCase() === passportStart.block.hash.toLowerCase()) && stop.code === 0) stop = { reason: 'PASSPORT_WINDOW_MISMATCH', code: 21 };
    if (lastAttemptBlock && BigInt(passportEnd.volatile.operatorBalance) !== BigInt(lastAttemptBlock.operatorBalance) && stop.code === 0) stop = { reason: 'END_BALANCE_MISMATCH', code: 21 };
    const drift = diffPaths(passportStart.invariant, passportEnd.invariant);
    if (drift.length && stop.code === 0) stop = { reason: 'PASSPORT_DRIFT', code: 21, detail: { drift } };
  }
} catch (e) {
  if (e instanceof Stop && stop.code === 0) stop = { reason: e.reason, code: e.code, detail: e.detail };
}
exitCode = stop.code;
writeLine({ kind: 'run_end', stop, exitCode, matchedTriplets: matched, targetTriplets: count, tally, triplets,
  passport: passportEnd, endedAtUtc: new Date().toISOString() });
closeSync(fd);
console.log(`stop=${stop.reason} exit=${exitCode} matched=${matched}/${count} ${JSON.stringify(tally)}`);
if (stop.detail) console.log(`detail: ${JSON.stringify(jsonable(stop.detail)).slice(0, 2000)}`);
process.exit(exitCode);

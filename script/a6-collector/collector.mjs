import { accumulateSlotWait, createWindow, runSlots, waitForSlot, windowRecord, TARGET_TRIPLETS, WINDOW_SLOTS, WINDOWS } from './window-schedule.mjs';
import { finalizePVG, recordPVG } from './pvg.mjs';
import { persistSettlement } from './frozen-plan.mjs';
import { settlementBranch, settlementSignatures } from '../rq3op/branch.mjs';
import { rehearsalTpmRefresh } from './rehearsal-refresh.mjs';
import { traceTPM } from './trace-policy.mjs';
import { revalidateAnchors, requireDecodedPreflight, waitAfterInclusion } from './formal.mjs';
import { loadPins, loadRegistry, sha256, evidenceIndex, writeArtifact, appendIndex, writeTrailer, armCounts, exclusionReason } from './evidence.mjs';
import { decomposeGas } from './gas-decomposition.mjs';
import { noFixture, operatorBalanceContinuity } from './gauge-lib.mjs';
import { READ_CAP, readPool, readPassport, readReadbacks, waitForHead, EP_DEPOSIT_ABI, SP_ABI, TOKEN_ABI } from './window-reads.mjs';
// A6 per-UserOperation gauge (CC-125 a71741ed; RDR-6 ①; plan §8.4 SP-owned implementation half).
//
// Drives matched triplets of real UserOperations — one through each arm, SP (SuperPaymaster),
// VPM (eth-infinitism VerifyingPaymaster) and TPM (eth-infinitism TokenPaymaster) — under the
// SAME EntryPoint, sender account, callData, gas fields and bundler EOA, and records every attempt
// (sent, withheld, failed) as one append-only JSONL line. Formal mode uses the
// per-arm frozen gas limits and common task/fees specified by G3-MATRIX.
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
// Local Anvil by default; --formal selects the separate keystore/archived RPC runtime. Its output is NOT A6 data: the
// sample protocol (N, B_max, scenario mix) is DSR's deliverable; --count/--b-max are validated,
// required arguments here, and a run is flagged protocolConformant only when --count is 50.
//
// Usage:
//   node script/a6-collector/collector.mjs --rpc-a http://127.0.0.1:8545 --rpc-b http://127.0.0.1:8546 \
//     --count 50 --b-max 1 --out <run.jsonl> [--max-attempts 60] [--arms SP,VPM,TPM] \
//     [--fixture exec-revert|drop-op|wrong-hash] [--config deployments/config.anvil.json] \
//     [--baselines <baselines.json>] [--expect-entrypoint 0x...] [--trace]
//
// Exit codes: 0 = N matched triplets collected or a frozen slice exhausted with passing end checks;
//   10 = attempt budget exhausted before N;
//   20 RPC_DISAGREEMENT, 21 PASSPORT_DRIFT, 22 CONSERVATION_MISMATCH, 23 HASH_SELF_CHECK,
//   24 BLOCK_NOT_ISOLATED, 25 RECEIPT_DISAGREEMENT or RECEIPT_B_HEAD_BEHIND, 26 ENTRYPOINT_MISMATCH (an arm or the account
//   is bound to another EntryPoint); 27 UNEXPECTED_USEROP_EVENT (extra op in single-op gauge); 28 EVIDENCE_CONTINUITY_MISMATCH; 29 END_PASSPORT_ERROR; 2 = bad arguments / refused; 1 = crash.
import { readFileSync, existsSync, statSync, openSync, writeSync, fsyncSync, closeSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  concat, pad, toHex, getAddress, encodeAbiParameters, decodeErrorResult, ContractFunctionRevertedError,
  keccak256, createPublicClient, http, encodeFunctionData, decodeFunctionData,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { EP_ABI, DEFAULT_FACTORY, formalConfig, formalRuntime, castSigner, withPasswordSource, acquireBundlerLock, armOrder, taskCallData, requirePostGas, feePause, prepareSimpleAccount } from './formal.mjs';
const rehearsal = process.argv.includes('--rehearsal');
const scheduled = process.argv.includes('--frozen-plan');
const formal = process.argv.includes('--formal') || rehearsal || scheduled;
// Do not even load the development key module in formal mode.
const { clients, send, rpc, ANVIL_KEYS } = formal ? {} : await import('../b-layer/lib.mjs');
import { checkDepositFloor, opGasLimitSum, depositFloor } from './deposit-guard.mjs';
import {
  CANONICAL_EP_V07, VERDICTS, classifyAttempt, decodeLogsFrom, SP_EVENTS_ABI, TOKEN_EVENTS_ABI,
  spConservation, conservationStop, localUserOpHash, diffPaths, jsonable,
} from './gauge-lib.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const SCHEMA = 'a6-gauge/2'; // /2 adds invariant.credit and the on-chain extension / price-feed bindings
const PROTOCOL_N = 50;

// ── arguments (validated; no silent defaults for the protocol parameters) ─────────────────
function argVal(flag) { const i = process.argv.indexOf(flag); return i === -1 ? undefined : process.argv[i + 1]; }
function die(msg) { console.error(`collector: ${msg}`); process.exit(2); }
if (formal && !rehearsal && (!argVal('--frozen-plan') || argVal('--frozen-plan').startsWith('--') || !/^[0-9a-f]{64}$/.test(argVal('--bundle-sha256') ?? ''))) die('non-rehearsal formal requires --frozen-plan and --bundle-sha256');
const LOCAL = /^http:\/\/(127\.0\.0\.1|localhost):\d+$/;
const rpcA = argVal('--rpc-a') ?? argVal('--rpc');
const rpcB = argVal('--rpc-b');
if (!formal && (!rpcA || !rpcB)) die('--rpc-a and --rpc-b are both required (two read-back endpoints; see README)');
if (!formal && (!LOCAL.test(rpcA) || !LOCAL.test(rpcB))) die('refusing: local Anvil only (http://127.0.0.1:<port>)');
const traceEnabled = process.argv.includes('--trace');
const allowSameEndpointLocal = process.argv.includes('--allow-same-endpoint-local');
const distinctEndpoints = false; // Local aliases cannot establish independent host identity.
if (!formal && new URL(rpcA).port === new URL(rpcB).port) die('identical RPC endpoints: different local ports are required');
if (!formal && !distinctEndpoints && !allowSameEndpointLocal) die('local RPC ports require --allow-same-endpoint-local (disqualifies conformance)');
const countRaw = argVal('--count');
if (!countRaw || !/^[1-9]\d*$/.test(countRaw) || Number(countRaw) > 1000) die('--count is required: an integer in [1, 1000] (matched triplets to collect)');
const count = Number(countRaw);
const bMaxRaw = argVal('--b-max');
if (!bMaxRaw || !/^[1-9]\d*$/.test(bMaxRaw) || Number(bMaxRaw) > 1_000_000) die('--b-max is required: an integer in [1, 1000000]');
const bMax = BigInt(bMaxRaw);
const maxAttemptsRaw = argVal('--max-attempts') ?? (scheduled ? '' : String(count * 2));
const maxAttempts = Number(maxAttemptsRaw);
const windowIndexRaw = argVal('--window-index');
const windowIndex = Number(windowIndexRaw);
const seed = argVal('--seed');
if (scheduled) {
  if (!seed || seed.startsWith('--') || count !== TARGET_TRIPLETS || maxAttemptsRaw !== String(WINDOW_SLOTS)) die(`frozen window requires --seed, --count ${TARGET_TRIPLETS} and --max-attempts ${WINDOW_SLOTS}`);
  if (String(windowIndex) !== windowIndexRaw || !Number.isInteger(windowIndex) || windowIndex < 1 || windowIndex > WINDOWS) die(`frozen window requires --window-index in 1..${WINDOWS}`);
} else if (!/^[1-9]\d*$/.test(maxAttemptsRaw) || maxAttempts < count) die('--max-attempts must be an integer >= --count (attempt budget per arm)');
const ARM_NAMES = ['SP', 'VPM', 'TPM'];
const arms = (argVal('--arms') ?? ARM_NAMES.join(',')).split(',');
if (!arms.length || arms.some((a) => !ARM_NAMES.includes(a)) || new Set(arms).size !== arms.length) die(`--arms must be a subset of ${ARM_NAMES}`);
const FIXTURES = ['exec-revert', 'drop-op', 'wrong-hash'];
const fixture = argVal('--fixture') ?? null;
if (!noFixture(fixture) && !FIXTURES.includes(fixture)) die(`--fixture must be one of ${FIXTURES}`);
const outPath = argVal('--out');
if (!outPath) die('--out <run.jsonl> is required');
if (existsSync(outPath) && statSync(outPath).size > 0) die(`refusing to touch non-empty ${outPath}: raw JSONL is append-only, one file per run`);
const windowPath = dirname(resolve(outPath));
if (formal && (rpcA || rpcB || allowSameEndpointLocal || fixture || arms.join(',') !== 'SP,VPM,TPM')) die('formal mode requires URL files, all arms and no local override/fixtures');
if (formal && (!argVal('--formal-config') || !argVal('--rpc-a-file') || !argVal('--rpc-b-file') || !argVal('--config') || !argVal('--baselines'))) die('formal mode requires --formal-config, --rpc-a-file, --rpc-b-file, --config and --baselines');
const formalInput = formal ? JSON.parse(readFileSync(argVal('--formal-config'), 'utf8')) : null;
if (formal && (!argVal('--rpc-registry') || !argVal('--pins'))) die('formal mode requires --rpc-registry and --pins');
const evidencePins = formal ? loadPins(argVal('--pins')) : null;
const registry = formal ? loadRegistry(argVal('--rpc-registry')) : null;
if (formal && (existsSync(resolve(windowPath, 'raw')) || existsSync(resolve(windowPath, 'index.ndjson')) || existsSync(resolve(windowPath, 'manifest.json')))) die('formal window already exists');
if (formal) formalInput.factory ??= DEFAULT_FACTORY;
if (scheduled && (!Array.isArray(formalInput.senders) || formalInput.senders.length !== 3)) die('formal config requires three senders: {sender,salt,owner:{name,address}}');
const senderConfigs = scheduled ? formalInput.senders.map(s => ({...formalInput,sender:getAddress(s.sender),salt:s.salt,accounts:{...formalInput.accounts,owner:s.owner}})) : [];
// Refuse conflicts across all rotating owners before runtime can start a signer process.
for (const config of senderConfigs) withPasswordSource(config.accounts.owner, argVal('--keystore-password-source'));
const window = scheduled ? createWindow({readBundle:()=>readFileSync(argVal('--frozen-plan')),bundleSha256:argVal('--bundle-sha256'),seed,chainId:formalInput.chainId,accounts:senderConfigs.map(c=>c.sender),windowIndex}) : null;
let adapter = window ? window.adapters.get(senderConfigs[0].sender) : null;
if (window) Object.assign(formalInput,senderConfigs[0]);
if (adapter && rehearsal) die('frozen plan requires formal transport');
let frozen = adapter ? adapter.frozen : formal ? formalConfig(formalInput, bMax) : null;
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
if (window) for (const config of senderConfigs) window.adapters.get(config.sender).bind(config,cfg,baselines,bMax,20);
if (adapter) adapter.bind(formalInput,cfg,baselines,bMax,20);
if (adapter) {
  const release=acquireBundlerLock(resolve(ROOT,'cache/3arm/collector-locks'),formalInput.chainId,formalInput.accounts.bundler.address);
  process.once('exit',release);
}
// --keystore-password-source keychain: opt-in Keychain+pty password delivery (see README); default prompts on /dev/tty.
const runtime = formal ? await formalRuntime({ config: formalInput, rehearsal, frozenPlan: Boolean(adapter), rpcAFile: argVal('--rpc-a-file'), rpcBFile: argVal('--rpc-b-file'), outPath, keystorePasswordSource: argVal('--keystore-password-source') }) : null;
let frozenArm, activeSlot, activeRow, windowStart;
const owners = new Map();
const senderPassports = new Map();
const senderPassportRefs = new Map();
if (adapter) {
  const write = runtime.writeContract;
  runtime.writeContract = async args => {
    return adapter.send({...runtime,writeContract: async checked => {
      formalInput.bundlerGasLimit = checked.gas;
      return write({...checked, beforeSubmit: async () => {
        const result = await slotGate(frozenArm,activeRow);
        if (!result.allowed) throw Object.assign(Error('SLOT_DEADLINE'),{slotResult:result});
      }});
    }},frozenArm,args,poolOf);
  };
}
const ctx = formal ? { account: { address: getAddress(formalInput.operator) }, pub: runtime.pubA } : clients(rpcA, ANVIL_KEYS[0]);
const bundler = formal ? { account: runtime.accounts.bundler, wallet: { writeContract: runtime.writeContract } } : clients(rpcA, ANVIL_KEYS[1]);
const pubA = ctx.pub;
const pubB = formal ? runtime.pubB : createPublicClient({ transport: http(rpcB, { timeout: 60_000 }) });
const runId = argVal('--run-id') ?? `run-${new Date().toISOString().replace(/[:.]/g, '-')}`;

function collectorHead() {
  const python = window ? {pythonVersion:window.manifest.pythonVersion} : {};
  const files = ['collector.mjs', 'window-reads.mjs', ...(adapter ? ['window-schedule.mjs','schedule.py','chain-params.json','frozen-plan.mjs','pvg.mjs','../rq3op/pvg-rule.json','../rq3op/branch.mjs'] : []), 'formal.mjs', 'gas-decomposition.mjs', 'gauge-lib.mjs', 'deposit-guard.mjs', 'validate.mjs', 'rpc-proxy.mjs', ...(formal ? [] : ['../b-layer/lib.mjs'])];
  const codeSha256 = Object.fromEntries(files.map((f) => [f, createHash('sha256').update(readFileSync(resolve(ROOT, 'script/a6-collector', f))).digest('hex')]));
  try {
    const head = execSync('git rev-parse HEAD', { cwd: ROOT }).toString().trim();
    const dirty = execSync('git status --porcelain -- script/a6-collector script/b-layer/lib.mjs', { cwd: ROOT }).toString().trim() !== '';
    return { head, collectorDirty: dirty, codeSha256, ...python };
  } catch { return { head: null, collectorDirty: null, codeSha256, ...python }; }
}

// ── append-only JSONL ─────────────────────────────────────────────────────────────────────
const fd = openSync(outPath, 'a');
const archiveCursor = [0, 0];
const evidenceRows = [];
const replacements = [];
let pendingReplacement = null;
let pendingReplacementReason = null;
const passportRefs = {};
if (formal) writeArtifact(windowPath, 'rpc-identity.json', registry);
const rpcIdentityPin = formal ? { path:'rpc-identity.json', sha256:sha256(readFileSync(resolve(windowPath,'rpc-identity.json'))) } : null;
function savePassport(name, passport) {
  const path = `passports/${name}.json`;
  writeArtifact(windowPath, path, passport);
  return { path, raw:Object.fromEntries(runtime.archives.map((a,i) => [i?'B':'A', a.records.filter(r=>r.method==='eth_chainId' || r.blockAnchor?.number===String(passport.block.number) && r.blockAnchor?.hash===passport.block.hash && ['eth_call','eth_getCode','eth_getStorageAt','eth_getBlockByNumber'].includes(r.method)).map(r => ({path:r.path,id:r.id}))])) };
}
function writeLine(obj) {
  if (formal && obj.kind === 'attempt') {
    obj.evidenceEnd = runtime.archives.map(a => a.ids.length);
    const index = evidenceIndex(obj, {schedule:Boolean(window),windowId:runId, archives:runtime.archives, pins:evidencePins, rpcIdentity:rpcIdentityPin,
      passports:{start:passportRefs.start, attempt:passportRefs[obj.attemptIndex]},
      stopReason:obj.stoppedBy?.reason ?? null, replaces:pendingReplacement});
    if (window) Object.assign(index,{block_slot:obj.block_slot,pair_id:obj.pair_id,seed:obj.seed,schedule_sha256:obj.schedule_sha256,warmup:false,spWait:obj.spWait,slotChecks:obj.slotChecks,scheduleDisposition:obj.scheduleDisposition});
    appendIndex(windowPath, index);
    evidenceRows.push(index);
  }
  if (formal) obj = { ...obj, rpcArchiveRefs: Object.fromEntries(runtime.archives.map((a, i) => {
    const ids = a.ids.slice(archiveCursor[i]); archiveCursor[i] = a.ids.length;
    return [i ? 'B' : 'A', ids];
  })) };
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
  if (formal) return pubA.request({ method, params });
  const r = await rpc(rpcA, method, params);
  if (r.error) throw new Error(`${method}: ${JSON.stringify(r.error)}`);
  return r.result;
}

// ── ABIs ──────────────────────────────────────────────────────────────────────────────────
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
// Fees follow G3-MATRIX §3a (5 gwei / 1 gwei). At the old 20 gwei the SP reservation (~5,712 aPNTs) exceeds the
// xPNTs V2 default maxSingleTxLimit (5000e18) and validation fails with AA34.
const LOCAL_GAS = { callGasLimit: 100_000n, verificationGasLimit: 300_000n, preVerificationGas: 60_000n,
  maxFeePerGas: 5_000_000_000n, maxPriorityFeePerGas: 1_000_000_000n };
let MAX_FEE_CEILING = formal ? frozen.fees.maxFeePerGas : LOCAL_GAS.maxFeePerGas;
const gasFor = arm => formal ? frozen.gas[arm] : LOCAL_GAS;
let PM_GAS = frozen?.pmGas ?? {
  SP: { ver: 400_000n, post: 200_000n },   // D7 finding: 5.5.0 validation needs >150k
  VPM: { ver: 100_000n, post: 50_000n },
  TPM: { ver: 150_000n, post: 120_000n },
};
const NOOP_TARGET = '0x000000000000000000000000000000000000dEaD';
const NONCE_KEY = 0n;
const DECOY_NONCE_KEY = 1n; // drop-op fixture: a different op from the same sender, under another nonce key

/** callData every arm sends: SimpleAccount.execute(0x…dEaD, 0, 0x) — a real, successful call. */
function defaultCallData() {
  if (formal) return frozen.callData;
  return encodeFunctionData({ abi: ACCOUNT_ABI, functionName: 'execute', args: [NOOP_TARGET, 0n, '0x'] });
}
/** exec-revert fixture: execute(GToken, 0, transfer(dEaD, 1)) — the account holds no GToken, so the
 *  inner call reverts with ERC20InsufficientBalance and EntryPoint emits UserOperationRevertReason. */
function revertingCallData() {
  const inner = encodeFunctionData({ abi: TOKEN_ABI, functionName: 'transfer', args: [NOOP_TARGET, 1n] });
  return encodeFunctionData({ abi: ACCOUNT_ABI, functionName: 'execute', args: [getAddress(cfg.gToken), 0n, inner] });
}

async function signAndHash({ sender, nonce, callData, pmAddr, pmGas, pmData, gas = LOCAL_GAS }) {
  const GAS = gas;
  if (formal) taskCallData(formalInput.task, callData);
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
  packed.signature = await (formal ? runtime.accounts.owner : privateKeyToAccount(ANVIL_KEYS[0])).signMessage({ message: { raw: epHash.value } });
  return { packed, hash: epHash.value, localHash: local };
}

async function pmDataFor(arm, { sender, nonce, callData }, GAS = gasFor(arm)) {
  if (arm === 'SP') {
    return concat([getAddress(ctx.account.address), pad(toHex((1n << 256n) - 1n), { size: 32 }), getAddress(spToken), '0x00']);
  }
  if (arm === 'VPM') {
    const vpm = baselines.verifyingPaymaster;
    const validUntil = rehearsal && formalInput.rehearsalExpiredVpm && attemptIndex === 2 ? 1n : 0n, validAfter = 0n;
    const partial = { sender, nonce, initCode: '0x', callData,
      accountGasLimits: concat([u128(GAS.verificationGasLimit), u128(GAS.callGasLimit)]),
      preVerificationGas: GAS.preVerificationGas, gasFees: concat([u128(GAS.maxPriorityFeePerGas), u128(GAS.maxFeePerGas)]),
      paymasterAndData: concat([getAddress(vpm.address), u128(PM_GAS.VPM.ver), u128(PM_GAS.VPM.post)]), signature: '0x' };
    const h = await pubA.readContract({ address: vpm.address, abi: vpm.abi, functionName: 'getHash', args: [partial, validUntil, validAfter] });
    const sig = await (formal ? runtime.accounts.verifyingSigner : privateKeyToAccount(vpm.signerKey)).signMessage({ message: { raw: h } });
    return concat([encodeAbiParameters([{ type: 'uint48' }, { type: 'uint48' }], [validUntil, validAfter]), sig]);
  }
  return '0x'; // TPM: no paymasterData
}
const pmAddrOf = (arm) => getAddress(arm === 'SP' ? cfg.superPaymaster : arm === 'VPM' ? baselines.verifyingPaymaster.address : baselines.tokenPaymaster.address);

// ── revert classification (unchanged semantics from the previous revision: only AA31 is infra) ─
function classifyRevert(decoded, rawErrorText) {
  if (decoded && typeof decoded.reason === 'string' && decoded.reason.startsWith('AA31')) return { infraFailure: true, sponsorshipFailed: false, revertReason: decoded.reason, ...(decoded.inner!=null?{inner:decoded.inner}:{}) };
  if (decoded && typeof decoded.reason === 'string') return { infraFailure: false, sponsorshipFailed: true, revertReason: decoded.reason, ...(decoded.inner!=null?{inner:decoded.inner}:{}) };
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
    let decoded = reverted?.data ? { errorName: reverted.data.errorName, reason: reverted.data.args?.[1], ...(reverted.data.errorName==='FailedOpWithRevert'?{inner:reverted.data.args[2]}:{}) } : null;
    if (!decoded || typeof decoded.reason!=='string') {
      const raw = rawRevertDataOf(e);
      if (raw) { try { const d = decodeErrorResult({ abi: ENTRYPOINT_ERRORS_ABI, data: raw }); decoded = { errorName: d.errorName, reason: d.errorName==='Panic'?raw:d.args?.[1], ...(d.errorName==='FailedOpWithRevert'?{inner:d.args[2]}:{}) }; } catch { /* undecoded */ } }
    }
    if (formal) requireDecodedPreflight(e,decoded);
    return classifyRevert(decoded, e.shortMessage || e.message || String(e));
  }
}

// ── read-backs (pinned to one block, on A and B) ──────────────────────────────────────────
async function readbacks(arm, blockNumber, expectedHash, sender) {
  const r = await readAB(`readbacks@${blockNumber}`, (p) => readReadbacks(p, arm, blockNumber, expectedHash, sender, readEnv(), poolOf(p)));
  return { A: r.A, B: r.B };
}

// ── Passport ──────────────────────────────────────────────────────────────────────────────
// Pools are per endpoint and shared by every fixed-block read round on that endpoint.
const readPools = new Map([[pubA, readPool(READ_CAP.A)], [pubB, readPool(READ_CAP.B)]]);
function poolOf(p) { const pool = readPools.get(p); if (!pool) throw new Error('read pool: unknown client'); return pool; }
function readEnv() {
  return { EP, SPA, spToken, sender, operator: ctx.account.address, baselines, formal, allowSameEndpointLocal, pmAddrOf,
    bundler: bundler.account.address, gas: formal ? frozen.gas : LOCAL_GAS, pmGas: PM_GAS, callDataHash: keccak256(defaultCallData()) };
}
const passport = (p, blockNumber) => readPassport(p, blockNumber, readEnv(), poolOf(p));
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
  if (formal) {
    const prepared = await prepareSimpleAccount({ config: formalInput, runtime, readAB });
    sender = prepared.sender;
    if (prepared.created) setupLog.push('factory createAccount');
    const op = await readAB('operator', p => p.readContract({ address: SPA, abi: SP_ABI, functionName: 'operators', args: [ctx.account.address] }));
    spToken = getAddress(op.value[3]);
    if ([spToken, cfg.aPNTs, baselines.tokenPaymaster.token].some(a => a?.toLowerCase() === formalInput.task.token.toLowerCase())) throw new Error('task must use a separate plain ERC20 token');
    const minimumSenderBalance = window ? 1n + BigInt(window.manifest.schedule.payload.slots.slice(window.manifest.slice.firstSlot)
      .filter(slot => Object.values(slot.senders).includes(sender)).length) : 300n;
    for (const who of [sender, formalInput.task.recipient]) {
      const balance = await readAB('task balance', p => p.readContract({ address: formalInput.task.token, abi: TOKEN_ABI, functionName: 'balanceOf', args: [who] }));
      if (balance.value < (who === sender ? minimumSenderBalance : 1n)) throw new Error('task requires warmed, funded token balances');
    }
    return;
  }

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
let previousInclusion = null;
/** One attempt = one UserOperation through one arm. Every attempt writes exactly one JSONL line,
 *  including one interrupted by a stop condition (then with `stoppedBy` and whatever was known). */
async function attempt(arm, tripletIndex, passportStart) {
  const idx = attemptIndex++;
  const st = { row: { ...(adapter ? adapter.row(arm,activeSlot.allocationIndex) : {}), ...(window ? {block_slot:activeSlot.block_slot,pair_id:activeSlot.pair_id,seed:window.manifest.schedule.payload.seed,schedule_sha256:window.manifest.schedule.sha256,sender,warmup:false} : {}), kind: 'attempt', spBranch: arm === 'SP' ? {planned:'balance', observed:null, event:null} : null, ...(formal ? {stateTargets:{superPaymaster:SPA,token:spToken,tpmToken:baselines.tokenPaymaster.token,operator:ctx.account.address}} : {}), attemptIndex: idx, tripletIndex, arm, fixture, ...(formal ? { evidenceStart:runtime.archives.map(a => a.ids.length) } : {}), ...(formal ? { armOrder: window ? activeSlot.order.map(a=>({SP:"SP",VerifyingPaymaster:"VPM",TokenPaymaster:"TPM"}[a])) : armOrder(tripletIndex) } : {}) }, written: false };
  try {
    return await attemptInner(arm, idx, tripletIndex, passportStart, st);
  } catch (e) {
    if (!st.written) {
      writeLine(Object.assign(st.row, { verdict: st.row.verdict ?? 'STOPPED', stoppedBy: e instanceof Stop ? { reason: e.reason, detail: e.detail } : { reason: 'CRASH', detail: String(e) },
        exclusion: 'STOPPED', collectedAtUtc: new Date().toISOString() }));
      st.written = true;
    }
    e.attemptRow=st.row;
    throw e;
  }
}
async function attemptInner(arm, idx, tripletIndex, passportStart, st) {
  frozenArm = arm;
  activeRow = st.row;
  const GAS = {...gasFor(arm)};
  if (formal && previousInclusion) st.row.priorInclusionHeads = await waitAfterInclusion([pubA,pubB], previousInclusion);
  if (formal) {
    const control = await rehearsalTpmRefresh({rehearsal,config:formalInput,arm,attemptIndex:idx,client:pubA,paymaster:baselines.tokenPaymaster.address,abi:baselines.tokenPaymaster.abi});
    if (control) st.row.rehearsalControl = control;
    const block = await runtime.refreshPin();
    const p = await readAB(`passport attempt ${idx}`, client => passport(client, block.number));
    st.row.passport = p.A;
    passportRefs[idx] = savePassport(`attempt-${idx}`, p.A);
    if (diffPaths(passportStart.invariant, p.A.invariant).length) throw new Stop('PASSPORT_DRIFT',21,{attemptIndex:idx});
  }
  if (window) {
    const result = await slotGate(arm,st.row);
    if (!result.allowed) {
      const row = {...st.row,sent:false,tx:null,verdict:VERDICTS.NOT_SENT,failingCheck:result.reason,scheduleDisposition:result.reason,collectedAtUtc:new Date().toISOString()};
      writeLine(row);st.written=true;return row;
    }
  }
  const pm = pmAddrOf(arm);
  const callData = fixture === 'exec-revert' ? revertingCallData() : defaultCallData();
  const nonceR = await readAB('getNonce', (p) => p.readContract({ address: EP, abi: EP_ABI, functionName: 'getNonce', args: [sender, NONCE_KEY] }));
  const nonce = nonceR.value;
  const sign = async value => {
    GAS.preVerificationGas=value;
    return signAndHash({ sender, nonce, callData, pmAddr: pm, gas: GAS, pmGas: PM_GAS[arm], pmData: await pmDataFor(arm, { sender, nonce, callData }, GAS) });
  };
  let ours;
  try { ours = adapter ? await finalizePVG(sign,bundler.account.address,{lengths:adapter.plan.phaseC.pvgLengths[arm],reserve:adapter.plan.phaseC.pvgReserve[arm]}) : await sign(GAS.preVerificationGas); }
  catch (error) {
    if (error.message.startsWith('PVG_')) throw new Stop(error.message,23,{});
    throw error;
  }
  if (adapter) {
    recordPVG(st.row,ours.pvg);
    if (ours.pvg.value>BigInt(adapter.plan.phaseC.pvgReserve[arm])) throw new Stop('PVG_RESERVE',23,{});
  }
  let bundled = [ours.packed];
  let decoy = null;
  if (fixture === 'drop-op') {
    const dNonceR = await readAB('getNonce(decoy)', (p) => p.readContract({ address: EP, abi: EP_ABI, functionName: 'getNonce', args: [sender, DECOY_NONCE_KEY] }));
    const dCall = defaultCallData();
    decoy = await signAndHash({ sender, nonce: dNonceR.value, callData: dCall, pmAddr: pm, gas: GAS, pmGas: PM_GAS[arm], pmData: await pmDataFor(arm, { sender, nonce: dNonceR.value, callData: dCall }) });
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
  if (formal) {
    if (adapter) await adapter.beforeSend(runtime, poolOf);
    const pause = feePause(await runtime.refreshPin(), GAS.maxFeePerGas);
    if (pause) return finish(pause);
  }
  const pre = await simulateRevert(bundled);
  if (pre) {
    return finish({ sent: false, tx: null, logs: [], preflight: pre, verdict: VERDICTS.NOT_SENT, failingCheck: 'preflight_revert',
      exclusion: 'NOT_SENT:preflight_revert' });
  }

  const headBefore = await pubA.getBlockNumber({ cacheTime: 0 });
  if (formal) {
    if (adapter) await adapter.beforeSend(runtime, poolOf);
    const pause = feePause(await runtime.refreshPin(), GAS.maxFeePerGas);
    if (pause) return finish(pause);
  }
  let txHash;
  try { txHash = await bundler.wallet.writeContract({ address: EP, abi: HANDLE_OPS_ABI, functionName: 'handleOps',
    args: [bundled, bundler.account.address], chain: null });
  } catch (e) {
    if (window && e.slotResult) return finish({sent:false,tx:null,verdict:VERDICTS.NOT_SENT,failingCheck:e.slotResult.reason,scheduleDisposition:e.slotResult.reason});
    if (formal && e.message === 'basefee_above_cap') return finish(e.pause);
    if (formal) { row.reason = 'bundler_error'; const raw=runtime.archives[0].records.findLast(r=>r.method==='eth_sendRawTransaction' && r.response); const error=raw && JSON.parse(Buffer.from(raw.response,'base64')).error; if (error) row.submissionException = { message: error.message }; }
    throw e;
  }
  if (formal) { row.sent = true; row.tx = { hash: txHash }; }
  // 1 s polling: with no chain set viem polls every 4 s, about two OP blocks per poll.
  const rcA = await pubA.waitForTransactionReceipt({ hash: txHash, pollingInterval: 1_000 });
  // B's receipt is read once. A can see it about a second after inclusion, so first wait until B's
  // head reaches A's receipt block (60 s, then stop); a null receipt at that head still fails closed.
  try { await waitForHead(pubB, rcA.blockNumber); }
  catch (e) { if (e.head === undefined) throw e; throw new Stop('RECEIPT_B_HEAD_BEHIND', 25, { txHash, receiptBlock: rcA.blockNumber, headB: e.head }); }
  const rcB = await pubB.getTransactionReceipt({ hash: txHash });
  const rcView = (rc) => ({ status: rc.status, blockNumber: rc.blockNumber, blockHash: rc.blockHash, gasUsed: rc.gasUsed,
    effectiveGasPrice: rc.effectiveGasPrice, l1Fee: rc.l1Fee??null, logs: rc.logs.map((l) => ({ address: getAddress(l.address), topics: l.topics, data: l.data, logIndex: l.logIndex, ...(formal ? {transactionHash:l.transactionHash} : {}) })) });
  row.sent = true;
  row.tx = { hash: txHash };
  const rdiff = diffPaths(jsonable(rcView(rcA)), jsonable(rcView(rcB)));
  if (rdiff.length) throw new Stop('RECEIPT_DISAGREEMENT', 25, { txHash, diff: rdiff });
  previousInclusion = rcA;
  const bn = rcA.blockNumber;
  const blocks = await readAB('attempt block', async p => { const b = await p.getBlock({ blockNumber: bn }); return { hash: b.hash, timestamp: b.timestamp, transactions: b.transactions }; });
  const blk = blocks.A;
  const rawTx = await readAB('transaction', p => p.getTransaction({ hash: txHash }));
  function recordMeasuredPVG(event=null) {
    if (!adapter) return;
    try { recordPVG(row,ours.pvg,rawTx.A.input,rcA,event); }
    catch (error) {
      if (error.message.startsWith('PVG_')) throw new Stop(error.message,23,{});
      throw error;
    }
  }
  recordMeasuredPVG();

  if (formal) {
    const decoded = decodeFunctionData({abi:HANDLE_OPS_ABI,data:rawTx.A.input});
    if (decoded.functionName !== 'handleOps' || diffPaths(jsonable(decoded.args[0]),jsonable(bundled)).length) throw new Stop('TRANSACTION_BUNDLE_MISMATCH',27,{txHash});
  }
  const tx = { raw: rawTx.A, input: rawTx.A.input, handleOpsIndex: bundled.includes(ours.packed) ? bundled.indexOf(ours.packed) : null, maxFeePerGas:rawTx.A.maxFeePerGas, maxPriorityFeePerGas:rawTx.A.maxPriorityFeePerGas, from: rawTx.A.from, gasLimit: rawTx.A.gas, hash: txHash, status: rcA.status, blockNumber: bn, blockTimestamp: blk.timestamp, blockHash: rcA.blockHash, gasUsed: rcA.gasUsed,
    effectiveGasPrice: rcA.effectiveGasPrice, blockTxCount: blk.transactions.length, headBefore };
  const logs = rcView(rcA).logs;
  // The verdict needs only the receipt; it is fixed (and kept on a stop) before any read-back.
  const cls = classifyAttempt({ sent: true, txStatus: rcA.status, logs, entryPoint: EP, expectedHash, sender, nonce, paymaster: pm });
  const observedUoe = cls.epEvents?.find(e => e.event === 'UserOperationEvent' && e.args.sender.toLowerCase() === sender.toLowerCase() && BigInt(e.args.nonce) === nonce);
  row.observedUserOpEvent = observedUoe ? {...observedUoe.args, logIndex:observedUoe.logIndex, txHash:rcA.logs.find(l => l.logIndex === observedUoe.logIndex)?.transactionHash} : null;
  Object.assign(row, { sent: true, tx, logs, verdict: cls.verdict, failingCheck: cls.failingCheck,
    revertKind: cls.revertKind ?? null, userOpEvent: cls.event ? { ...cls.event, logIndex: cls.epEvents.find(e => e.event === 'UserOperationEvent' && e.args.userOpHash === cls.event.userOpHash)?.logIndex } : null, execRevert: cls.execRevert ?? [], postOpRevert: cls.postOpRevert ?? [], prefundTooLow: cls.prefundTooLow ?? [] });
  recordMeasuredPVG(cls.event);
  if (adapter) {
    try {
      persistSettlement(row,rcA,{arm,token:spToken,user:sender,hash:expectedHash,planned:adapter.plan.phaseC.spBranch},()=>{});
    } catch { throw new Stop('SP_BRANCH_MISMATCH',22,{branch:row.spBranch}); }
  } else if (arm === 'SP') {
    try {
      row.spBranch = settlementBranch(logs, {token:spToken, user:sender, hash:expectedHash,
        planned:'balance', topics:Object.fromEntries(Object.entries(settlementSignatures).map(([k,v])=>[k,keccak256(toHex(v))]))});
    } catch (error) {
      row.spBranch = error.branch;
      throw new Stop('SP_BRANCH_MISMATCH', 22, {branch:row.spBranch});
    }
  } else row.spBranch = null;
  if (formal && arm === 'TPM') Object.assign(row, await traceTPM([pubA,pubB],txHash,pm,baselines.tokenPaymaster.oracle));
  if (traceEnabled) {
    try {
      row.gasTrace = { transactionHash: txHash, blockHash: rcA.blockHash,
        tracer: 'callTracer', result: await pubA.request({ method: 'debug_traceTransaction',
          params: [txHash, { tracer: 'callTracer' }] }) };
    } catch {
      row.gasTrace = { reason: 'debug_traceTransaction callTracer unavailable' };
    }
  }
  row.gasDecomposition = decomposeGas(row, cls.event);
  recordMeasuredPVG(cls.event);

  if (noFixture(fixture) && cls.epEvents?.some(e => e.event === 'UserOperationEvent' && e.args.userOpHash.toLowerCase() !== expectedHash.toLowerCase())) {
    // All receipt logs are already in row; never attribute another op's event to an arm.
    throw new Stop('UNEXPECTED_USEROP_EVENT', 27, { attemptIndex: idx, txHash });
  }
  const before = await readbacks(arm, bn - 1n, expectedHash, sender);
  const after = await readbacks(arm, bn, expectedHash, sender);
  const out = { readbacks: { before, after } };

  if (formal ? bn <= headBefore : blk.transactions.length !== 1 || bn !== headBefore + 1n) {
    finish({ ...out, stoppedBy: { reason: 'BLOCK_NOT_ISOLATED', detail: { bn, txCount: blk.transactions.length, headBefore } }, exclusion: 'BLOCK_NOT_ISOLATED' });
    throw new Stop('BLOCK_NOT_ISOLATED', 24, { bn, txCount: blk.transactions.length, headBefore });
  }

  // Conservation: D1 for every arm whose op produced its event; SP identities on top.
  const checks = [];
  const previousBlock = lastAttemptBlock ?? { blockNumber: passportStart.block.number, blockHash: passportStart.block.hash };
  checks.push({ id: 'continuity.block', ok: formal ? BigInt(before.A.blockNumber) >= BigInt(previousBlock.blockNumber) : BigInt(before.A.blockNumber) === BigInt(previousBlock.blockNumber) && before.A.blockHash.toLowerCase() === previousBlock.blockHash.toLowerCase() });
  const prior = stateByArm.get(arm);
  const senderPrior = stateByArm.get(arm+':'+sender);
  const senderFields = ['userXPNTs','lockedOf','debts','creditReservedOf'];
  // A declared rehearsal cache-aging control (rehearsal-refresh.mjs) changes only the TPM cache timestamp between attempts.
  const aged = rehearsal && st.row.rehearsalControl?.kind === 'tpmCacheAged' && arm === 'TPM' ? ['tpmCachedPriceTimestamp'] : [];
  if (prior) for (const f of Object.keys(prior).filter(f => ![...aged, 'blockNumber', 'blockHash', 'operatorBalance', 'lockXLocked', 'inflightA0', 'inflightOperator'].includes(f))) {
    checks.push({ id: `continuity.${f}`, ok: diffPaths(before.A[f], window && senderFields.includes(f) ? (senderPrior?.[f] ?? before.A[f]) : window && f==='tpmTokenBalances' ? {...prior[f],sender:senderPrior?.[f]?.sender ?? before.A[f].sender} : prior[f]).length === 0 });
  }
  checks.push(...operatorBalanceContinuity(arm, before.A, after.A, lastAttemptBlock?.operatorBalance ?? passportStart.volatile.operatorBalance));
  if (arm === 'SP') checks.push({ id: 'continuity.new_op_lock_empty', ok: BigInt(before.A.lockXLocked) === 0n });
  for (const [value, seen, label] of [[txHash, seenTransactions, 'tx'], [expectedHash, seenOperations, 'op'], [tx.blockHash, seenBlocks, 'block']]) {
    checks.push({ id: `unique.${label}`, ok: !seen.has(value.toLowerCase()) }); seen.add(value.toLowerCase());
  }
  stateByArm.set(arm, after.A); stateByArm.set(arm+':'+sender, after.A); lastAttemptBlock = after.A;
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
  const failure = conservationStop(checks);
  const r = finish({ ...out, ...(failure ? { stoppedBy: { reason: failure.reason, detail: { attemptIndex: idx, failed: failure.failed } } } : {}), spMode: sp?.mode ?? null, charge: sp?.charge ?? null, conservation: { evaluated, notEvaluable: sp?.notEvaluable ?? null, ok: conservationOk, checks },
    exclusion: !noFixture(fixture) ? 'FIXTURE' : failure?.reason ?? (cls.verdict !== VERDICTS.USEROP_SUCCESS ? cls.failingCheck ?? cls.verdict : null) });
  if (failure) throw new Stop(failure.reason, failure.code, { attemptIndex: idx, failed: failure.failed });

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
let windowOutcome = null;
try {
  chainId = (await readAB('chainId', (p) => p.getChainId())).value;
  if (formal && chainId !== formalInput.chainId) throw new Error('formal target chainId mismatch');
  if (window) {
    for (const config of senderConfigs) {
      const owner = await castSigner(withPasswordSource(config.accounts.owner, argVal('--keystore-password-source')), 'owner');
      if (owner.type !== 'local' || getAddress(owner.address) !== getAddress(config.accounts.owner.address)) throw new Error('injected signer identity mismatch');
      owners.set(config.sender,owner);
      selectSender(config.sender);
      await setup();
      await adapter.beforeSend(runtime, poolOf);
      const start = await passportAB('start');
      senderPassports.set(sender,start);
      senderPassportRefs.set(sender,savePassport('start-'+sender,start));
    }
    selectSender(senderConfigs[0].sender);
    windowStart = (await runtime.refreshPin()).timestamp;
    writeArtifact(windowPath,'manifest.json',{...window.manifest,windowId:runId,startTimestamp:windowStart});
  } else await setup();
  passportStart = window ? senderPassports.get(sender) : await passportAB('start');
  if (formal) passportRefs.start = savePassport('start', passportStart);
  if (formal) {
    requirePostGas(frozen.pmGas.SP.post, passportStart.invariant.superPaymaster.minPostOpGas);
    if (BigInt(passportStart.invariant.credit.policy) !== 0n || BigInt(passportStart.invariant.credit.pendingPolicyEta) !== 0n) throw new Error('formal SP requires credit OFF and no pending policy');
    if (getAddress(passportStart.invariant.verifyingSigner) !== getAddress(runtime.accounts.verifyingSigner.address)) throw new Error('VPM keystore signer mismatch');
  }
  const epMismatch = Object.entries(passportStart.invariant.armEntryPoints).filter(([, a]) => getAddress(a) !== EP);
  if (epMismatch.length) throw new Stop('ENTRYPOINT_MISMATCH', 26, { EP, epMismatch });
  writeLine({ kind: 'run_start', ...collectorHead(), argv: formal ? ['--formal', '(URL files redacted)'] : process.argv.slice(2), rpcA: formal ? 'https://rpc-a.invalid' : rpcA, rpcB: formal ? 'https://rpc-b.invalid' : rpcB, allowSameEndpointLocal,
    ...(formal ? { formal: true, rehearsal, formalSlice: 5, frozenConfig: formalInput, configSha256: createHash('sha256').update(readFileSync(argVal('--formal-config'))).digest('hex'),
      deploymentConfigSha256: createHash('sha256').update(readFileSync(configPath)).digest('hex'), baselineConfigSha256: createHash('sha256').update(readFileSync(baselinesPath)).digest('hex'), rpcIdentity:rpcIdentityPin, pins:evidencePins, archiveLayout:'raw/{A|B}/YYYYMMDD.ndjson', sopPending:['DSR independent re-fetch and acceptance'] } : {}),
    abTopology: argVal('--ab-topology') ?? 'unspecified', count, bMax, maxAttempts, arms, fixture,
    protocolConformant: !rehearsal && (formal || distinctEndpoints) && count === PROTOCOL_N && noFixture(fixture) && arms.length === 3 && !allowSameEndpointLocal,
    setupLog, passport: passportStart, startedAtUtc: new Date().toISOString() });
  console.log(`A6 gauge ${runId}: N=${count} bMax=${bMax} maxAttempts/arm=${maxAttempts} arms=${arms} fixture=${fixture ?? 'none'}`);
  console.log(`EP=${EP} (canonical v0.7 address: ${passportStart.invariant.entryPoint.isCanonicalV07Address}) sender=${sender}`);
  if (window) {
    const result = await runSlots(window.manifest,async (slot,arm,account,allocationIndex) => {
      activeSlot={...slot,allocationIndex};
      selectSender(account);
      passportRefs.start=senderPassportRefs.get(sender);
      tally[arm].attempts++;
      const row=await attempt(arm,slot.block_slot,senderPassports.get(sender));
      tally[arm].verdicts[row.verdict]=(tally[arm].verdicts[row.verdict]??0)+1;
      return row;
    },rows=>rows.length===3 && rows.every(r=>r.verdict===VERDICTS.USEROP_SUCCESS && r.postOpRefreshed!==true && r.conservation?.evaluated && r.conservation.ok)
      && new Set(rows.map(r=>r.callDataHash)).size===1
      && ['paymaster','expectedUserOpHash'].every(f=>new Set(rows.map(r=>r[f].toLowerCase())).size===3)
      && new Set(rows.map(r=>r.tx.hash.toLowerCase())).size===3);
    matched=result.complete;
    triplets.push(...result.slots.map(s=>({...s,tripletIndex:s.block_slot})));
    windowOutcome=windowRecord(window.manifest,result);
    stop={reason:result.status,code:0};
    selectSender(senderConfigs[0].sender);
  } else for (let t = 0; matched < count; t++) {
    if (arms.some((a) => tally[a].attempts >= maxAttempts)) { stop = { reason: 'MAX_ATTEMPTS', code: 10 }; break; }
    if (formal && pendingReplacement) replacements.push({abandoned:pendingReplacement,
      replacement:{windowId:runId,tripleIndex:t}, reason:pendingReplacementReason});
    const rows = [];
    for (const arm of (formal ? armOrder(t) : arms)) {
      const r = await attempt(arm, t, passportStart);
      tally[arm].attempts++;
      tally[arm].verdicts[r.verdict] = (tally[arm].verdicts[r.verdict] ?? 0) + 1;
      rows.push(r);
      if (formal && r.reason === 'basefee_above_cap') break;
      console.log(`  t=${t} ${arm.padEnd(3)} ${r.verdict}${r.failingCheck ? ` (${r.failingCheck})` : ''} hash=${r.expectedUserOpHash?.slice(0, 12)}…${r.tx ? ` tx=${r.tx.hash.slice(0, 12)}… receipt=${r.tx.status}` : ''}`);
    }
    const ok = noFixture(fixture) && rows.every((r) => r.verdict === VERDICTS.USEROP_SUCCESS && r.postOpRefreshed !== true && r.conservation?.evaluated && r.conservation.ok)
      && new Set(rows.map((r) => r.callDataHash)).size === 1
      && ['paymaster', 'expectedUserOpHash'].every(f => new Set(rows.map(r => r[f].toLowerCase())).size === rows.length)
      && new Set(rows.map(r => r.tx.hash.toLowerCase())).size === rows.length;
    triplets.push({ tripletIndex: t, ...(formal ? { armOrder: armOrder(t) } : {}), matched: ok, attempts: rows.map((r) => r.attemptIndex) });
    if (ok) matched++;
    if (formal) {
      pendingReplacement = null;
      if (!ok && !rows.some(r => r.reason === 'basefee_above_cap')) {
        const failures = rows.filter(r => r.verdict !== VERDICTS.USEROP_SUCCESS || r.postOpRefreshed === true);
        // Only explicitly classified, non-gas failures permit replacement.
        if (!failures.length || failures.some(r => !r.postOpRefreshed && exclusionReason(r,formal ? runtime.archives : undefined) === 'not_included')) throw new Stop('UNAPPROVED_ABANDONMENT', 29);
        pendingReplacement = {windowId:runId,tripleIndex:t};
        pendingReplacementReason = failures[0].postOpRefreshed ? 'tpm_postop_refresh' : exclusionReason(failures[0],formal ? runtime.archives : undefined);
      }
    }
    if (formal && rows.some(r => r.reason === 'basefee_above_cap')) { stop = { reason: 'BASEFEE_PAUSED', code: 10 }; break; }
  }
  if (!stop) stop = { reason: 'COMPLETE', code: 0 };
} catch (e) {
  if (window && e.windowProgress) {
    matched=e.windowProgress.complete;
    triplets.push(...e.windowProgress.slots.map(s=>({...s,tripletIndex:s.block_slot})));
  }
  if (window && !windowOutcome) windowOutcome=windowRecord(window.manifest,e.windowProgress);
  if (e instanceof Stop) stop = { reason: e.reason, code: e.code, detail: e.detail };
  else { stop = { reason: 'CRASH', code: 1, detail: String(e?.stack ?? e) }; }
}
let passportEnd = null;
let finalBlockCheck = null;
// End checks run on every in-process exit (not on SIGINT/SIGTERM/SIGKILL).
const endCheckScope = 'on every in-process exit (not on SIGINT/SIGTERM/SIGKILL)';
const endChecks = [];
async function endCheck(check, action) {
  try {
    const result = await action();
    endChecks.push({check, status:'PASS', ...result});
  } catch (e) {
    const failure = e instanceof Stop
      ? {reason:e.reason, code:e.code, detail:e.detail}
      : {reason:'END_PASSPORT_ERROR', code:29, detail:String(e)};
    endChecks.push({check, status:'FAIL', ...failure});
    if (stop.code === 0) {
      stop = failure;
      if (windowOutcome) windowOutcome.status = 'STOPPED';
    }
  }
}
await endCheck('endBlock', async () => {
  if (passportStart) {
    // Wait for an independently read later block; never relabel the last receipt block.
    const deadline = Date.now() + 60_000;
    const finalHeight = BigInt(lastAttemptBlock?.blockNumber ?? passportStart.block.number);
    // A local anvil (automine) produces no block after the last tx; mine one explicitly. Only under
    // the local override on chain 31337, which already disqualifies conformance; real chains wait.
    if (!formal && allowSameEndpointLocal && Number(passportStart.chainId) === 31337) await pubA.request({ method: 'evm_mine', params: [] });
    while (await pubA.getBlockNumber({ cacheTime: 0 }) <= finalHeight) {
      if (Date.now() >= deadline) throw new Stop('END_BLOCK_NOT_ADVANCED', 21, { finalHeight });
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
  } else return {status:'UNAVAILABLE',reason:'NO_START_PASSPORT'};
});
if (window) {
  for (const config of senderConfigs) {
    await endCheck('senderPassport:'+config.sender, async () => {
      const start = senderPassports.get(config.sender);
      if (!start) {
        return {status:'UNAVAILABLE',reason:'NO_START_PASSPORT'};
      }
      selectSender(config.sender);
      const end = await passportAB('end');
      savePassport('end-'+sender,end);
      const drift = diffPaths(start.invariant,end.invariant);
      if (drift.length) throw new Stop('PASSPORT_DRIFT',21,{sender,drift});
    });
  }
}
await endCheck('finalPassport', async () => {
  if (!passportStart) return {status:'UNAVAILABLE',reason:'NO_START_PASSPORT'};
  if (passportStart) {
    if (window) selectSender(senderConfigs[0].sender);
    passportEnd = await passportAB('end');
    if (formal) passportRefs.end = savePassport('end',passportEnd);
    const last = lastAttemptBlock ?? { blockNumber: passportStart.block.number, blockHash: passportStart.block.hash };
    const endHeight = BigInt(passportEnd.block.number), lastHeight = BigInt(last.blockNumber);
    const sameHash = passportEnd.block.hash.toLowerCase() === last.blockHash.toLowerCase();
    if ((passportEnd.chainId !== passportStart.chainId || endHeight <= lastHeight || sameHash || seenBlocks.has(passportEnd.block.hash.toLowerCase()) || passportEnd.block.hash.toLowerCase() === passportStart.block.hash.toLowerCase())) throw new Stop('PASSPORT_WINDOW_MISMATCH',21);
    if (lastAttemptBlock && BigInt(passportEnd.volatile.operatorBalance) !== BigInt(lastAttemptBlock.operatorBalance)) throw new Stop('END_BALANCE_MISMATCH',21);
    const drift = diffPaths(passportStart.invariant, passportEnd.invariant);
    if (drift.length) throw new Stop('PASSPORT_DRIFT',21,{drift});
  }
});
if (formal) await endCheck('anchors', async () => { finalBlockCheck = await revalidateAnchors(runtime.archives); });
exitCode = stop.code;
writeLine({ kind: 'run_end', stop, exitCode, endCheckScope, endChecks, matchedTriplets: matched, targetTriplets: count, tally, triplets,
  ...(formal ? {finalBlockCheck, rehearsal} : {}), ...(window ? {scheduledSlots:windowOutcome.scheduledSlots,attemptedSlots:windowOutcome.usedSlots,window:windowOutcome,warmupAttempts:0} : {}), passport: passportEnd, endedAtUtc: new Date().toISOString() });
closeSync(fd);
if (formal) {
  const triples = [...new Set(evidenceRows.map(r => r.tripleIndex))].map(tripleIndex => ({tripleIndex,
    attempts:evidenceRows.filter(r => r.tripleIndex === tripleIndex).map(r => r.attempt),
    included:stop.code === 0 && triplets.some(t => t.tripletIndex === tripleIndex && t.matched)}));
  writeTrailer(windowPath, {schemaVersion:'a6-evidence-trailer/1', rehearsal, windowId:runId, void:stop.code !== 0,
    stopReason:stop.reason, stopAttempt:evidenceRows.at(-1)?.attempt ?? null, endPassport:passportRefs.end ?? null,
    finalBlockCheck, endCheckScope, endChecks, triples, replacements, counts:armCounts(evidenceRows, triples, replacements), ...(window ? {window:windowOutcome} : {})});
}
console.log(`stop=${stop.reason} exit=${exitCode} matched=${matched}/${count} ${JSON.stringify(tally)}`);
if (stop.detail) console.log(`detail: ${JSON.stringify(jsonable(stop.detail)).slice(0, 2000)}`);
process.exit(exitCode);

function selectSender(account) {
  const config=senderConfigs.find(c=>c.sender===account);
  Object.assign(formalInput,config);
  adapter=window.adapters.get(account);frozen=adapter.frozen;
  adapter.bind(formalInput,cfg,baselines,bMax,20);
  PM_GAS=frozen.pmGas;MAX_FEE_CEILING=frozen.fees.maxFeePerGas;
  sender=account;runtime.accounts.owner=owners.get(account);
}
async function slotGate(arm,row) {
  const firstSliceSlot=window.manifest.schedule.payload.slots[window.manifest.slice.firstSlot];
  const result=await waitForSlot({runtime,arm,operator:ctx.account.address,sender,paymaster:SPA,
    start:windowStart+BigInt(activeSlot.start_seconds-firstSliceSlot.start_seconds),
    deadline:windowStart+BigInt(activeSlot.deadline_seconds-firstSliceSlot.start_seconds)});
  (row.slotChecks??=[]).push(result);
  if(arm==='SP') row.spWait=accumulateSlotWait(row.spWait,result.wait);
  return result;
}

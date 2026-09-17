// A6 collector mechanism (RDR-6 ①; plan §8.4 SP-owned implementation half — see README.md).
// Drives a small, CLI-configurable number of real gasless UserOps through SP 5.5.0 and the two
// baseline comparator paymasters (VerifyingPaymaster, TokenPaymaster) on a local anvil, guarding
// every send with the deposit-floor check, and writes one JSONL row per op (sent or withheld).
//
// THIS IS A MECHANISM DRY-RUN, NOT ACCEPTED EVIDENCE. The sample protocol (how many ops, what
// scenario/failure mix, B_max) is DSR's deliverable (plan §8.4) and is not implemented here —
// --count and --b-max are placeholders you pass explicitly, not defaults this file chooses.
//
// Usage: node script/a6-collector/collector.mjs --rpc http://127.0.0.1:8545 --count 2 --b-max 1 \
//          --config deployments/config.anvil.json --baselines script/a6-collector/dryrun-output/baselines.anvil.json \
//          --out script/a6-collector/dryrun-output/collector-run.jsonl
import { readFileSync, writeFileSync, appendFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { concat, pad, toHex, getAddress, encodeAbiParameters, decodeErrorResult, ContractFunctionRevertedError } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { clients, send, rpc, EP_ABI, ANVIL_KEYS, encodeFunctionData } from '../b-layer/lib.mjs';
import { checkDepositFloor, opGasLimitSum, depositFloor } from './deposit-guard.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

function argVal(flag, def) {
  const i = process.argv.indexOf(flag);
  return i === -1 ? def : process.argv[i + 1];
}
const rpcUrl = argVal('--rpc', 'http://127.0.0.1:8545');
const count = BigInt(argVal('--count', '2'));
const bMax = BigInt(argVal('--b-max', '1')); // placeholder — see file header
const configPath = argVal('--config', resolve(ROOT, 'deployments/config.anvil.json'));
const baselinesPath = argVal('--baselines', resolve(ROOT, 'script/a6-collector/dryrun-output/baselines.anvil.json'));
const outPath = argVal('--out', resolve(ROOT, 'script/a6-collector/dryrun-output/collector-run.jsonl'));

if (!/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(rpcUrl)) {
  console.error('refusing: collector dry-run only talks to a local node (http://127.0.0.1:<port>)');
  process.exit(2);
}

const cfg = JSON.parse(readFileSync(configPath, 'utf8'));
const baselines = JSON.parse(readFileSync(baselinesPath, 'utf8'));
const EP = getAddress(cfg.entryPoint);
const ctx = clients(rpcUrl, ANVIL_KEYS[0]); // deployer key, matches deploy-core anvil's default signer

// script/b-layer/lib.mjs's buildOp() closes over ITS OWN module-scope EP constant (the canonical
// singleton address, 0x0000...7da032) rather than taking one as a parameter — that constant is
// correct for b-layer's own fixtures (which etch the canonical EntryPoint at genesis) but NOT for
// a plain `deploy-core anvil` run, which deploys its own EntryPoint at whatever address CREATE
// gives it (see deploy-baselines.mjs's comment). Rather than edit lib.mjs (other reproduction
// records under docs/design/aoa-balance-mode/b-layer/ depend on its exact current behavior),
// this is a local copy of the same logic parameterized by the real EP for this deployment.
const u128local = (v) => pad(toHex(v), { size: 16 });
async function buildOp(ctxArg, { sender, nonce, callData = '0x', factory, factoryData,
  callGasLimit = 100_000n, verificationGasLimit = 300_000n, preVerificationGas = 100_000n,
  maxFeePerGas = 20_000_000_000n, maxPriorityFeePerGas = 2_000_000_000n, pm, ownerKey }) {
  const initCode = factory ? concat([factory, factoryData]) : '0x';
  const paymasterAndData = pm
    ? concat([pm.address, u128local(pm.verificationGasLimit), u128local(pm.postOpGasLimit), pm.data ?? '0x'])
    : '0x';
  const packed = {
    sender, nonce, initCode, callData,
    accountGasLimits: concat([u128local(verificationGasLimit), u128local(callGasLimit)]),
    preVerificationGas,
    gasFees: concat([u128local(maxPriorityFeePerGas), u128local(maxFeePerGas)]),
    paymasterAndData, signature: '0x',
  };
  const hash = await ctxArg.pub.readContract({ address: EP, abi: EP_ABI, functionName: 'getUserOpHash', args: [packed] });
  const owner = privateKeyToAccount(ownerKey);
  const signature = await owner.signMessage({ message: { raw: hash } });
  packed.signature = signature;
  return { packed, hash };
}

const GAS = { callGasLimit: 100_000n, verificationGasLimit: 300_000n, preVerificationGas: 60_000n,
  maxFeePerGas: 20_000_000_000n, maxPriorityFeePerGas: 2_000_000_000n };
const MAX_FEE_CEILING = GAS.maxFeePerGas; // dry-run: same fixed fee every op, so "ceiling" == the fee used
const SP_PM_VER_GAS = 400_000n; // D7 finding: 5.5.0 validation needs >150k (test-case-2-superpaymaster-xpnts1-fixed.js)
const SP_PM_POSTOP_GAS = 200_000n;
const VPM_PM_VER_GAS = 100_000n;
const VPM_PM_POSTOP_GAS = 50_000n;
const TPM_PM_VER_GAS = 150_000n;
const TPM_PM_POSTOP_GAS = 120_000n;

writeFileSync(outPath, '');
function writeRow(row) { appendFileSync(outPath, JSON.stringify(row) + '\n'); }

async function rawCall(method, params) {
  const r = await rpc(rpcUrl, method, params);
  if (r.error) throw new Error(`${method}: ${JSON.stringify(r.error)}`);
  return r.result;
}

async function paymasterDeposit(paymaster) {
  const info = await ctx.pub.readContract({
    address: EP,
    abi: [{ type: 'function', name: 'getDepositInfo', stateMutability: 'view',
      inputs: [{ name: 'account', type: 'address' }],
      outputs: [{ type: 'tuple', components: [
        { name: 'deposit', type: 'uint256' }, { name: 'staked', type: 'bool' },
        { name: 'stake', type: 'uint112' }, { name: 'unstakeDelaySec', type: 'uint32' },
        { name: 'withdrawTime', type: 'uint48' },
      ] }] }],
    functionName: 'getDepositInfo',
    args: [paymaster],
  });
  return info.deposit;
}

// ── one-time sender setup (SimpleAccount + xPNTs balance + SP eligibility) ──────────────────
// prepare-test anvil provisions SP operators, NOT a sender smart account — same gap D7's
// phase-2 fork hit. Built here rather than depending on script/gasless-tests/ (kept untouched
// per directive) so this collector has no dependency on D7's test-only fixtures.
const SIMPLE_ACCOUNT_FACTORY_ABI = [
  { type: 'function', name: 'createAccount', stateMutability: 'nonpayable',
    inputs: [{ name: 'owner', type: 'address' }, { name: 'salt', type: 'uint256' }],
    outputs: [{ type: 'address' }] },
  { type: 'function', name: 'getAddress', stateMutability: 'view',
    inputs: [{ name: 'owner', type: 'address' }, { name: 'salt', type: 'uint256' }],
    outputs: [{ type: 'address' }] },
];
const XPNTS_ABI = [
  { type: 'function', name: 'mint', stateMutability: 'nonpayable', inputs: [{ name: 'to', type: 'address' }, { name: 'amount', type: 'uint256' }], outputs: [] },
  { type: 'function', name: 'approve', stateMutability: 'nonpayable', inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }], outputs: [{ type: 'bool' }] },
];
const SP_ABI = [
  { type: 'function', name: 'updateSBTStatus', stateMutability: 'nonpayable', inputs: [{ name: 'user', type: 'address' }, { name: 'status', type: 'bool' }], outputs: [] },
  { type: 'function', name: 'operators', stateMutability: 'view', inputs: [{ name: '', type: 'address' }],
    outputs: [{ name: 'aPNTsBalance', type: 'uint128' }, { type: 'bool' }, { type: 'bool' }, { name: 'xPNTsToken', type: 'address' }, { type: 'uint32' }, { type: 'uint48' }, { type: 'address' }, { type: 'uint256' }, { type: 'uint256' }] },
  { type: 'function', name: 'deposit', stateMutability: 'nonpayable', inputs: [{ name: 'amount', type: 'uint256' }], outputs: [] },
];
async function asImpersonated(fn) {
  await rawCall('anvil_impersonateAccount', [cfg.registry]);
  await rawCall('anvil_setBalance', [cfg.registry, toHex(10n ** 18n)]);
  try {
    await fn();
  } finally {
    await rawCall('anvil_stopImpersonatingAccount', [cfg.registry]);
  }
}

async function setupSpSender() {
  const salt = 9001n;
  const factory = { address: getAddress(cfg.simpleAccountFactory), abi: SIMPLE_ACCOUNT_FACTORY_ABI };
  const addr = await ctx.pub.readContract({ ...factory, functionName: 'getAddress', args: [ctx.account.address, salt] });
  const code = await ctx.pub.getCode({ address: addr });
  if (!code || code === '0x') {
    await send(ctx, factory.address, factory.abi, 'createAccount', [ctx.account.address, salt]);
  }
  // SP.operators(deployer).xPNTsToken — D7 finding: NOT config.aPNTs (that's SP's own collateral asset).
  const opInfo = await ctx.pub.readContract({ address: getAddress(cfg.superPaymaster), abi: SP_ABI, functionName: 'operators', args: [ctx.account.address] });
  const token = opInfo[3];
  await send(ctx, token, XPNTS_ABI, 'mint', [addr, 10_000n * 10n ** 18n]);

  // Top up the deployer operator's aPNTsBalance inside SP (its own solvency collateral, distinct
  // from the sender's xPNTs above) — TestAccountPrepare only deposits 1,000 aPNTs, not enough to
  // cover this dry-run's deliberately generous gas limits (INSUFFICIENT_BALANCE observed at the
  // default deposit; confirmed via SuperPaymasterLens.dryRunValidation before this fix).
  if (opInfo[0] < 5_000n * 10n ** 18n) {
    await send(ctx, getAddress(cfg.aPNTs), XPNTS_ABI, 'approve', [getAddress(cfg.superPaymaster), 5_000n * 10n ** 18n]);
    await send(ctx, getAddress(cfg.superPaymaster), SP_ABI, 'deposit', [5_000n * 10n ** 18n]);
  }
  // sbtHolders[user] is set by Registry via SuperPaymaster.updateSBTStatus (onlyRegistry). The
  // real path is Registry.safeMintForRole, which needs a configured community + role + stake —
  // out of proportion for a mechanism dry-run, so impersonate Registry to call the same setter
  // the real path calls (not fabricating a storage slot blindly).
  await asImpersonated(async () => {
    const data = encodeFunctionData({ abi: SP_ABI, functionName: 'updateSBTStatus', args: [addr, true] });
    await rawCall('eth_sendTransaction', [{ from: cfg.registry, to: cfg.superPaymaster, data }]);
  });

  // TokenPaymaster path: fund + approve its own test ERC-20 (F1TestToken, 1:1 test oracle —
  // same fixture script/b-layer/f1-setup.mjs uses), independent of SP's xPNTs.
  const tpmToken = baselines.tokenPaymaster.token;
  await send(ctx, tpmToken, XPNTS_ABI, 'mint', [addr, 10_000n * 10n ** 18n]);
  await asImpersonated0(addr, async () => {
    const data = encodeFunctionData({ abi: XPNTS_ABI, functionName: 'approve', args: [baselines.tokenPaymaster.address, (1n << 256n) - 1n] });
    await rawCall('eth_sendTransaction', [{ from: addr, to: tpmToken, data }]);
  });

  return { address: addr, token };
}

async function asImpersonated0(account, fn) {
  await rawCall('anvil_impersonateAccount', [account]);
  await rawCall('anvil_setBalance', [account, toHex(10n ** 18n)]);
  try { await fn(); } finally { await rawCall('anvil_stopImpersonatingAccount', [account]); }
}

// ── op builders ──────────────────────────────────────────────────────────────────────────────
const u128 = (v) => pad(toHex(v), { size: 16 });

async function buildSpOp({ sender, nonce, token, maxRate }) {
  const pmData = concat([
    pad(getAddress(cfg.superPaymaster), { size: 20 }), // wasted first 20B is overwritten by buildOp's pm.address prefix; keep pmData = suffix only
  ]);
  // suffix after [paymaster(20)][pmVerGas(16)][pmPostGas(16)]: operator(20) + maxRate(32) + token(20) + flags(1)
  const suffix = concat([
    getAddress(ctx.account.address), // operator == deployer, matches TestAccountPrepare
    pad(toHex(maxRate), { size: 32 }),
    getAddress(token),
    '0x00',
  ]);
  return buildOp(ctx, {
    sender, nonce, ...GAS, ownerKey: ANVIL_KEYS[0],
    pm: { address: getAddress(cfg.superPaymaster), verificationGasLimit: SP_PM_VER_GAS, postOpGasLimit: SP_PM_POSTOP_GAS, data: suffix },
  });
}

async function buildVerifyingOp({ sender, nonce }) {
  const vpm = baselines.verifyingPaymaster;
  const validUntil = 0n, validAfter = 0n; // 0 = no expiry, standard sample convention for this contract
  // getHash only needs paymasterAndData[20:52] filled (the two v0.7 gas-limit words) — build a
  // minimal partial op for the view call, matching what the contract itself slices.
  const partialPmd = concat([getAddress(vpm.address), u128(VPM_PM_VER_GAS), u128(VPM_PM_POSTOP_GAS)]);
  const nonceArg = nonce;
  const { packed: partialPacked } = await buildOp(ctx, {
    sender, nonce: nonceArg, ...GAS, ownerKey: ANVIL_KEYS[0],
    pm: { address: getAddress(vpm.address), verificationGasLimit: VPM_PM_VER_GAS, postOpGasLimit: VPM_PM_POSTOP_GAS, data: '0x' },
  });
  const hash = await ctx.pub.readContract({
    address: vpm.address, abi: vpm.abi, functionName: 'getHash', args: [partialPacked, validUntil, validAfter],
  });
  const signer = privateKeyToAccount(vpm.signerKey);
  const signature = await signer.signMessage({ message: { raw: hash } });
  const suffix = concat([encodeAbiParameters([{ type: 'uint48' }, { type: 'uint48' }], [validUntil, validAfter]), signature]);
  return buildOp(ctx, {
    sender, nonce: nonceArg, ...GAS, ownerKey: ANVIL_KEYS[0],
    pm: { address: getAddress(vpm.address), verificationGasLimit: VPM_PM_VER_GAS, postOpGasLimit: VPM_PM_POSTOP_GAS, data: suffix },
  });
}

async function buildTokenPaymasterOp({ sender, nonce }) {
  const tpm = baselines.tokenPaymaster;
  return buildOp(ctx, {
    sender, nonce, ...GAS, ownerKey: ANVIL_KEYS[0],
    pm: { address: getAddress(tpm.address), verificationGasLimit: TPM_PM_VER_GAS, postOpGasLimit: TPM_PM_POSTOP_GAS, data: '0x' },
  });
}

const HANDLE_OPS_ABI = [{ type: 'function', name: 'handleOps', stateMutability: 'nonpayable',
  inputs: [{ name: 'ops', type: 'tuple[]', components: [
    { name: 'sender', type: 'address' }, { name: 'nonce', type: 'uint256' },
    { name: 'initCode', type: 'bytes' }, { name: 'callData', type: 'bytes' },
    { name: 'accountGasLimits', type: 'bytes32' }, { name: 'preVerificationGas', type: 'uint256' },
    { name: 'gasFees', type: 'bytes32' }, { name: 'paymasterAndData', type: 'bytes' },
    { name: 'signature', type: 'bytes' } ] }, { name: 'beneficiary', type: 'address' }], outputs: [] }];

// ── revert decoding + classification (RDR-6: only AA31 is "infrastructure") ────────────────
// EntryPoint v0.7 reverts the WHOLE handleOps tx (this collector always sends 1-op batches) for
// several distinct reasons (confirmed from source, account-abstraction-v7/contracts/core/EntryPoint.sol):
//   line 533  revert FailedOp(opIndex, "AA31 paymaster deposit too low")          — infra: the
//             collector's own deposit-floor guard failed to keep this from happening.
//   line 547  revert FailedOpWithRevert(opIndex, "AA33 reverted", innerReturnData) — the
//             paymaster's OWN validatePaymasterUserOp reverted (e.g. TokenPaymaster's
//             safeTransferFrom failing on insufficient sender balance/allowance) — this IS the
//             paymaster declining to sponsor, must count toward ITS sponsorship failure rate.
//   line 584  revert FailedOp(opIndex, "AA34 signature error")                    — same: the
//             paymaster's own validation decision, not an infra problem.
// Only "AA31" is infra per RDR-6 (plan line ~406); everything else FailedOp/FailedOpWithRevert
// decodes to is the paymaster's own outcome.
const ENTRYPOINT_ERRORS_ABI = [
  { type: 'error', name: 'FailedOp', inputs: [{ name: 'opIndex', type: 'uint256' }, { name: 'reason', type: 'string' }] },
  { type: 'error', name: 'FailedOpWithRevert', inputs: [{ name: 'opIndex', type: 'uint256' }, { name: 'reason', type: 'string' }, { name: 'inner', type: 'bytes' }] },
];

/** reason -> { infraFailure, sponsorshipFailed, revertReason }. `decoded` is {errorName, reason} or null. */
function classifyRevert(decoded, rawErrorText) {
  if (decoded && typeof decoded.reason === 'string' && decoded.reason.startsWith('AA31')) {
    return { infraFailure: true, sponsorshipFailed: false, revertReason: decoded.reason };
  }
  if (decoded && typeof decoded.reason === 'string') {
    return { infraFailure: false, sponsorshipFailed: true, revertReason: decoded.reason };
  }
  // Couldn't decode a FailedOp/FailedOpWithRevert shape at all — an unrecognized failure mode.
  // Default toward infra/unclassified rather than silently letting an undecoded revert count as
  // "the paymaster just said no" (that would be the same over/under-classification bug, inverted).
  return { infraFailure: true, sponsorshipFailed: false, revertReason: `UNDECODED: ${(rawErrorText || '').slice(0, 250)}` };
}

/** Best-effort extraction of raw revert calldata from a thrown viem error, when `.walk` for
 *  ContractFunctionRevertedError doesn't find one (e.g. a plain eth_call/estimateGas failure that
 *  never went through simulateContract's own ABI-aware decoding). */
function rawRevertDataOf(err) {
  let e = err;
  for (let i = 0; i < 8 && e; i++) {
    if (typeof e.data === 'string' && e.data.startsWith('0x') && e.data.length > 2) return e.data;
    e = e.cause;
  }
  return null;
}

/** Simulate handleOps read-only (optionally pinned to a historical block) and classify the
 *  result. Returns null if it would succeed, else a classifyRevert() result. Used both as the
 *  pre-broadcast preflight AND, pinned to receipt.blockNumber, to recover the revert reason of a
 *  tx that got mined-but-reverted (viem's waitForTransactionReceipt does not throw on that and
 *  carries no revert data — see the call site below). */
async function simulateRevert(packed, blockNumber) {
  try {
    await ctx.pub.simulateContract({
      address: EP, abi: [...HANDLE_OPS_ABI, ...ENTRYPOINT_ERRORS_ABI], functionName: 'handleOps',
      args: [[packed], ctx.account.address], account: ctx.account.address,
      ...(blockNumber !== undefined ? { blockNumber } : {}),
    });
    return null;
  } catch (e) {
    const reverted = typeof e.walk === 'function' ? e.walk((err) => err instanceof ContractFunctionRevertedError) : null;
    let decoded = reverted?.data ? { errorName: reverted.data.errorName, reason: reverted.data.args?.[1] } : null;
    if (!decoded) {
      const raw = rawRevertDataOf(e);
      if (raw) {
        try {
          const d = decodeErrorResult({ abi: ENTRYPOINT_ERRORS_ABI, data: raw });
          decoded = { errorName: d.errorName, reason: d.args?.[1] };
        } catch { /* not a FailedOp/FailedOpWithRevert shape — leave decoded null, classifyRevert defaults to infra */ }
      }
    }
    return classifyRevert(decoded, e.shortMessage || e.message || String(e));
  }
}

// ── send + record one op, guarded by the deposit floor ──────────────────────────────────────
async function sendGuarded({ paymasterKind, paymasterAddr, build, senderAddr, pmVerGas = 0n, pmPostOpGas = 0n }) {
  const deposit = await paymasterDeposit(paymasterAddr);
  const gasSum = opGasLimitSum({
    verificationGasLimit: GAS.verificationGasLimit, callGasLimit: GAS.callGasLimit,
    paymasterVerificationGasLimit: pmVerGas, paymasterPostOpGasLimit: pmPostOpGas,
    preVerificationGas: GAS.preVerificationGas,
  });
  const estimatedCost = gasSum * GAS.maxFeePerGas;
  const floor = depositFloor({ bMax, gasLimitSum: gasSum, maxFeePerGasCeiling: MAX_FEE_CEILING });
  const guard = checkDepositFloor({ deposit, estimatedCost, floor });
  if (!guard.allowed) {
    writeRow({ paymasterKind, paymaster: paymasterAddr, skipped: true, ...guard, collectedAtUtc: new Date().toISOString() });
    console.log(`${paymasterKind}: WITHHELD (${guard.reason}) deposit=${guard.deposit} floor=${guard.floor}`);
    return { sent: false };
  }

  const nonce = await ctx.pub.readContract({ address: EP, abi: EP_ABI, functionName: 'getNonce', args: [senderAddr, 0n] });
  const { packed, hash } = await build({ sender: senderAddr, nonce });

  function recordFailure(cls, extra) {
    writeRow({
      paymasterKind, paymaster: paymasterAddr, userOpHash: hash,
      skipped: false, ...cls, ...extra,
      collectedAtUtc: new Date().toISOString(),
    });
    console.log(`${paymasterKind}: ${cls.infraFailure ? 'INFRA FAILURE' : 'SPONSORSHIP FAILED'} ${cls.revertReason}`);
    return { sent: extra.txHash != null, ...cls };
  }

  // Preflight via simulateContract (read-only, no tx broadcast, no gas spent): decodes any
  // FailedOp/FailedOpWithRevert using the real EntryPoint error ABI and classifies AA31 (infra)
  // vs everything else (the paymaster's own sponsorship decision, e.g. AA33/AA34) — see
  // simulateRevert()/classifyRevert() above. This is also strictly better than the old
  // "broadcast then hope writeContract throws with a useful message" approach: nothing that
  // would revert ever gets broadcast at all.
  const preflight = await simulateRevert(packed, undefined);
  if (preflight) {
    return recordFailure(preflight, { txHash: null, status: 'reverted (pre-broadcast simulate)' });
  }

  let receipt, txHash;
  try {
    txHash = await ctx.wallet.writeContract({
      address: EP, abi: HANDLE_OPS_ABI, functionName: 'handleOps', args: [[packed], ctx.account.address], chain: null,
    });
    receipt = await ctx.pub.waitForTransactionReceipt({ hash: txHash });
  } catch (e) {
    // Broadcast/mining failed for a reason simulateContract's preflight didn't catch (RPC-level
    // rejection, not a decodable EntryPoint revert) — no paymaster-attributable reason available,
    // so this is infra by default (same "don't silently call it sponsorship" rule as classifyRevert).
    return recordFailure(
      { infraFailure: true, sponsorshipFailed: false, revertReason: (e.shortMessage || e.message || String(e)).slice(0, 250) },
      { txHash: txHash ?? null, status: null },
    );
  }
  if (receipt.status !== 'success') {
    // Rare race: state changed between the preflight simulate and the tx actually mining.
    // waitForTransactionReceipt does NOT throw on this and carries no revert reason — recover it
    // by replaying the exact same call pinned to the failing block.
    const cls = (await simulateRevert(packed, receipt.blockNumber)) ??
      { infraFailure: true, sponsorshipFailed: false, revertReason: `handleOps mined with status=${receipt.status}; replay at its own block did not reproduce a decodable revert` };
    return recordFailure(cls, { txHash: receipt.transactionHash, status: receipt.status });
  }

  const block = await ctx.pub.getBlock({ blockNumber: receipt.blockNumber });
  const row = {
    paymasterKind,
    paymaster: paymasterAddr,
    userOpHash: hash,
    txHash,
    chainId: await ctx.pub.getChainId(),
    blockNumber: Number(receipt.blockNumber),
    blockHash: receipt.blockHash,
    blockTimestamp: Number(block.timestamp),
    status: receipt.status, // handleOps itself succeeded; a paymaster sigFailure (not a revert) would
                             // still show status 'success' here with no UserOperationEvent for this op
    gasUsed: Number(receipt.gasUsed),
    effectiveGasPriceWei: receipt.effectiveGasPrice.toString(),
    postOpGasLimit: Number(pmPostOpGas),
    callGasLimit: Number(GAS.callGasLimit),
    feePerGasWei: GAS.maxFeePerGas.toString(),
    skipped: false,
    infraFailure: false,
    sponsorshipFailed: false,
    collectedAtUtc: new Date().toISOString(),
  };
  writeRow(row);
  console.log(`${paymasterKind}: SENT tx=${txHash} status=${receipt.status} gasUsed=${receipt.gasUsed}`);
  return { sent: true, infraFailure: false, sponsorshipFailed: false, receipt };
}

// ── main ─────────────────────────────────────────────────────────────────────────────────────
console.log(`A6 collector dry-run: count=${count} bMax=${bMax} (placeholder — DSR to set the real value) rpc=${rpcUrl}`);
console.log(`SP=${cfg.superPaymaster}  VerifyingPaymaster=${baselines.verifyingPaymaster.address}  TokenPaymaster=${baselines.tokenPaymaster.address}`);

const sp = await setupSpSender();
console.log(`SP sender ready: ${sp.address}  token=${sp.token}`);

for (let i = 0n; i < count; i++) {
  await sendGuarded({
    paymasterKind: 'SP', paymasterAddr: getAddress(cfg.superPaymaster), senderAddr: sp.address,
    pmVerGas: SP_PM_VER_GAS, pmPostOpGas: SP_PM_POSTOP_GAS, build: (o) => buildSpOp({ ...o, token: sp.token, maxRate: (1n << 256n) - 1n }),
  });
}
for (let i = 0n; i < count; i++) {
  await sendGuarded({
    paymasterKind: 'VerifyingPaymaster', paymasterAddr: getAddress(baselines.verifyingPaymaster.address), senderAddr: sp.address,
    pmVerGas: VPM_PM_VER_GAS, pmPostOpGas: VPM_PM_POSTOP_GAS, build: buildVerifyingOp,
  });
}
for (let i = 0n; i < count; i++) {
  await sendGuarded({
    paymasterKind: 'TokenPaymaster', paymasterAddr: getAddress(baselines.tokenPaymaster.address), senderAddr: sp.address,
    pmVerGas: TPM_PM_VER_GAS, pmPostOpGas: TPM_PM_POSTOP_GAS, build: buildTokenPaymasterOp,
  });
}

console.log(`wrote ${outPath}`);

#!/usr/bin/env node

/**
 * Gasless Transfer Test Case 4 - Credit/Debt Path
 *
 * Demonstrates the balance/credit fallback path in SuperPaymaster's 5.5.0 postOp
 * (spec 03 §1, §2.2):
 *   - Balance path: SP.validatePaymasterUserOp -> token.tryLockForGas OK -> postOp
 *     settles via token.settleLocked — burns xPNTs.
 *   - Credit path: tryLockForGas INSUFFICIENT -> token.tryReserveCredit OK -> postOp
 *     settles via token.settleCredit — adds to token.debts(user), no burn.
 *
 * When Account A has zero xPNTs balance, postOp falls back to the credit path
 * and xPNTs.debts(Account_A) increases after the UserOp.
 *
 * PRECONDITION (5.5.0): the credit path additionally requires the token's
 * creditPolicy != OFF (default at deploy) AND Account A to have an active
 * requestCredit() for the current policyEpoch (effectiveCreditCap, spec C-0).
 * creditPolicy changes go through a 48h TIMELOCK (queueCreditPolicy ->
 * executeCreditPolicy, xPNTsTokenV2Ext.sol:161-176) gated by the token's
 * communityOwner — this script queues/executes it if authorized and the
 * window has elapsed, and SKIPs with a clear reason otherwise (there is no
 * way to fast-forward a real network's clock from here).
 *
 * EXIT CODES — LESSON LEARNED (2026-05-13):
 *   0 = PASS  — UserOp submitted and confirmed on-chain
 *   1 = FAIL  — Script ran but test failed (TX reverted, assertion failed)
 *   2 = SKIP  — Precondition not met (no credit available, network error, etc.)
 *
 * Root cause of the old bug: zero-balance path used `return` inside main(), which
 * caused main().then(() => process.exit(0)) to execute — giving the test runner
 * exit 0 (PASS) even though no UserOp was submitted. Fix: always use process.exit(2)
 * for skipped / precondition-not-met cases, NEVER bare `return` from main().
 */

const { ethers } = require('ethers');
const path = require('path');
const { loadConfig } = require('./load-config');
const { makeProvider } = require('./tx-utils');
require('dotenv').config({ path: process.env.ENV_FILE || path.join(__dirname, '../../.env.sepolia') });

// ============================================================
// ABI Definitions (inline — standalone file, no test-helpers import)
// ============================================================

const XPNTS_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function debts(address user) view returns (uint256)",
  "function repayDebt(uint256 amountXPNTs)",
  "function exchangeRate() view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  // Balance-mode credit (spec 03 §2.2, §2.3 C-0)
  "function effectiveCreditCap(address user) view returns (uint256)",
  "function creditReservedOf(address user) view returns (uint256)",
  "function creditPolicy() view returns (uint8)",
  "function policyEpoch() view returns (uint32)",
  "function pendingPolicy() view returns (uint8)",
  "function pendingPolicyEta() view returns (uint64)",
  "function creditReq(address user) view returns (uint112 requestedCap, uint112 approvedCap, uint32 epoch)",
  "function communityOwner() view returns (address)",
  "function queueCreditPolicy(uint8 p)",
  "function executeCreditPolicy()",
  "function requestCredit(uint256 maxCapAPNTs)",
];

const SP_ABI = [
  "function operators(address) view returns (uint128 aPNTsBalance, bool isConfigured, bool isPaused, address xPNTsToken, uint32 reputation, uint48 minTxInterval, address treasury, uint256 totalSpent, uint256 totalTxSponsored)",
  // getAvailableCredit(user, token) is GONE in 5.5.0 — the credit cap moved to the token
  // itself (xPNTs.effectiveCreditCap, above).
  "function sbtHolders(address user) view returns (bool)",
  "function updatePrice()",
  "function priceValidUntil() view returns (uint256)",
];

// dryRunValidation moved OUT of SuperPaymaster into SuperPaymasterLens in 5.5.0 (EIP-170
// headroom, spec F1/§5) — note the extra leading `sp` address param.
const LENS_ABI = [
  "function dryRunValidation(address sp, tuple(address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp, uint256 maxCost) view returns (bool ok, bytes32 reasonCode)",
];

const REGISTRY_ABI = [
  "function owner() view returns (address)",
  "function creditTierConfig(uint256 level) view returns (uint256)",
  "function setCreditTier(uint256 level, uint256 limit)",
  "function getCreditLimit(address user) view returns (uint256)",
];

const ENTRYPOINT_ABI = [
  "function handleOps((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature)[] calldata ops, address payable beneficiary) external",
  "function getUserOpHash((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) calldata userOp) view returns (bytes32)"
];

const SIMPLE_ACCOUNT_ABI = [
  "function execute(address dest, uint256 value, bytes calldata func) external",
  "function getNonce() view returns (uint256)"
];

const ERC20_ABI = [
  "function transfer(address to, uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
];

// ============================================================
// Network error detection
// ============================================================

function isNetworkError(err) {
  const msg = (err.message || '').toLowerCase();
  return msg.includes('timeout') || msg.includes('econnreset') ||
    msg.includes('socket hang up') || msg.includes('etimedout') ||
    msg.includes('request timeout') || msg.includes('read timeout');
}

function isNonceConflict(err) {
  const msg = (err.message || '').toLowerCase();
  const code = (err.code || '').toLowerCase();
  return msg.includes('replacement transaction underpriced') ||
    msg.includes('replacement underpriced') ||
    code === 'replacement_underpriced' ||
    msg.includes('nonce too low') ||
    msg.includes('already known') ||
    msg.includes('in-flight transaction limit') ||
    msg.includes('nonce has already been used');
}

// True for any EntryPoint validation rejection (FailedOp "AAxx ..." / paymaster /
// signature / expired). These must NOT be blindly skipped — classifyValidationFailure
// runs the contract's own dryRunValidation to decide precondition-SKIP vs real-FAIL.
function isValidationRejection(err) {
  const msg = (err.message || '').toLowerCase();
  const data = (err.data || (err.info && err.info.error && err.info.error.data) || '').toLowerCase();
  return /aa2[0-9]|aa3[0-9]|failedop|paymaster|signature error|expired or not due/.test(msg) ||
    data.includes('220266b6') ||                 // FailedOp(uint256,string) selector
    /414132|414133/.test(data);                  // "AA2"/"AA3" hex prefixes
}

// bytes32 reason code → ascii (e.g. 0x494e53554646...→ "INSUFFICIENT_BALANCE")
function decodeReason(code) {
  try {
    if (!code || code === ethers.ZeroHash) return 'OK';
    return ethers.decodeBytes32String(code) || code; // handles null-termination correctly
  } catch (_) { return code; }
}

// Compute the EntryPoint-style maxCost (required prefund) from this userOp,
// INCLUDING the paymaster gas limits packed into paymasterAndData, so the
// dryRunValidation solvency check mirrors what handleOps actually requires.
function computeMaxCost(userOp) {
  const verGas  = BigInt(ethers.dataSlice(userOp.accountGasLimits, 0, 16));
  const callGas = BigInt(ethers.dataSlice(userOp.accountGasLimits, 16, 32));
  const maxFeePerGas = BigInt(ethers.dataSlice(userOp.gasFees, 16, 32));
  let pmVerGas = 0n, pmPostGas = 0n;
  // paymasterAndData layout: [paymaster(20)][pmVerGas(16)][pmPostGas(16)][...]
  if (userOp.paymasterAndData && ethers.dataLength(userOp.paymasterAndData) >= 52) {
    pmVerGas  = BigInt(ethers.dataSlice(userOp.paymasterAndData, 20, 36));
    pmPostGas = BigInt(ethers.dataSlice(userOp.paymasterAndData, 36, 52));
  }
  return (verGas + callGas + pmVerGas + pmPostGas + BigInt(userOp.preVerificationGas)) * maxFeePerGas;
}

// Classify a validation rejection using the contract's OWN diagnostic
// (dryRunValidation), so we never guess:
//   ok=false → split by reasonCode: RECOVERABLE preconditions (env not ready) →
//              SKIP; HARD failures that mean the UserOp/test is wrong → FAIL.
//   ok=true  → on-chain validation passes. If the bundler still rejected with AA32
//              (time-window) it is a simulation artifact → SKIP; any other code is a
//              genuine contradiction (validation OK yet EntryPoint rejects) → FAIL.
// Returns { action: 'SKIP'|'FAIL', proceed: bool, reason: string }.
//
// Recoverable preconditions → SKIP (re-run after fixing the environment):
const DRYRUN_SKIP_REASONS = new Set([
  'OPERATOR_NOT_CONFIGURED', 'OPERATOR_PAUSED', 'USER_NOT_ELIGIBLE',
  'INSUFFICIENT_BALANCE', 'STALE_PRICE', 'RATE_LIMITED',
]);
// Everything else (RATE_COMMITMENT_VIOLATED, USER_BLOCKED, unknown) means the
// UserOp/test was constructed wrong or hit an unexpected state → FAIL, never hide.

// Detect AA32 in BOTH message and revert data (the bundler sometimes only puts it
// in data) — passing just the message would miss it and mislabel an artifact as a bug.
function errIsAA32(err) {
  const msg = (err && err.message || '').toLowerCase();
  const data = (err && (err.data || (err.info && err.info.error && err.info.error.data)) || '').toLowerCase();
  return msg.includes('aa32') || msg.includes('expired or not due') || data.includes('41413332');
}

async function classifyValidationFailure(lens, spAddr, userOp, err) {
  try {
    const maxCost = computeMaxCost(userOp);
    const [ok, reasonCode] = await lens.dryRunValidation(spAddr, userOp, maxCost);
    if (!ok) {
      const reason = decodeReason(reasonCode);
      if (DRYRUN_SKIP_REASONS.has(reason)) {
        return { action: 'SKIP', proceed: false, reason: `precondition ${reason} (dryRunValidation, maxCost=${maxCost})` };
      }
      // Hard failure — the test/UserOp is wrong, not the environment.
      return { action: 'FAIL', proceed: false, reason: `dryRunValidation rejected: ${reason} — NOT a recoverable precondition (real/test bug)` };
    }
    if (errIsAA32(err)) {
      // Validation is sound; only the bundler's time-window simulation glitched.
      // proceed=true so an estimateGas-only AA32 doesn't abort the real submit.
      return { action: 'SKIP', proceed: true, reason: 'AA32 but dryRunValidation OK — bundler simulation artifact' };
    }
    return { action: 'FAIL', proceed: false, reason: `validation passes on-chain yet EntryPoint rejected — real/unexpected bug` };
  } catch (e) {
    // Cannot verify → conservative FAIL so we never hide a bug.
    return { action: 'FAIL', proceed: false, reason: `classification failed: ${(e.message || '').substring(0, 80)}` };
  }
}

// Same-operator UserOps are gated by the operator's minTxInterval (60s on
// Sepolia). When earlier gasless tests just sponsored this operator+user, the
// credit-path submit hits RATE_LIMITED — the test is valid, only too soon. So we
// wait out the window and retry instead of SKIPping, making the suite order-
// independent and robust to timing. dryRunValidation re-checks every cycle.
async function waitOutRateLimit(lens, spAddr, userOp, maxAttempts = 3) {
  for (let i = 0; i < maxAttempts; i++) {
    let ok, reasonCode;
    try {
      [ok, reasonCode] = await lens.dryRunValidation(spAddr, userOp, computeMaxCost(userOp));
    } catch (_) {
      return; // cannot pre-check (network) — let the normal submit path decide
    }
    if (ok) return;                                       // validation passes now → submit
    if (decodeReason(reasonCode) !== 'RATE_LIMITED') return; // other precondition → submit will classify
    const waitMs = 65000;                                 // minTxInterval 60s + 5s margin
    console.log(`  ⏳ RATE_LIMITED — waiting ${waitMs / 1000}s for the minTxInterval window (attempt ${i + 1}/${maxAttempts})...`);
    await new Promise((r) => setTimeout(r, waitMs));
  }
  console.log('  ⚠️  Still RATE_LIMITED after waiting — submit will SKIP if it persists.');
}

// ============================================================
// Main
// ============================================================

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║  Gasless Transfer Test Case 4 - Credit/Debt Path         ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  // ── Config & env ────────────────────────────────────────────
  let config;
  try {
    config = loadConfig();
  } catch (err) {
    console.error('❌ Failed to load deployment config:', err.message);
    process.exit(2);
  }

  const SUPER_PAYMASTER_ADDRESS = config.superPaymaster;
  // SP 5.5.0: the deployer operator's configured xPNTsToken is the v2 token
  // (config.aastarXPNTsV2) — config.aPNTs is now only SP's operator-deposit collateral
  // asset (APNTS_TOKEN), a different address. See test-case-2-fixed.js for the same note.
  const XPNTS_TOKEN_ADDRESS     = config.aastarXPNTsV2;
  const ENTRYPOINT_ADDRESS      = config.entryPoint;
  const LENS_ADDRESS            = config.superPaymasterLens;

  if (!LENS_ADDRESS) {
    console.error('❌ config.superPaymasterLens missing — dryRunValidation moved there in 5.5.0');
    process.exit(2);
  }

  const rpcUrl          = process.env.SEPOLIA_RPC_URL;
  const senderPrivateKey = process.env.OWNER_PRIVATE_KEY || process.env.DEPLOYER_PRIVATE_KEY;
  const recipientAddress = process.env.OWNER2_ADDRESS || process.env.TEST_EOA_ADDRESS;

  if (!rpcUrl || !senderPrivateKey || !recipientAddress) {
    console.error('❌ Required env variables not found (SEPOLIA_RPC_URL, OWNER_PRIVATE_KEY/DEPLOYER_PRIVATE_KEY, OWNER2_ADDRESS/TEST_EOA_ADDRESS)');
    process.exit(2);
  }

  const deployerWallet  = new ethers.Wallet(senderPrivateKey);
  const operatorAddress = process.env.OPERATOR_ADDRESS_APNTS || deployerWallet.address;

  // Account A: the AA smart account whose credit path we're exercising.
  // Fall back to B if A is not set (same as TC2).
  const senderAAAccount =
    process.env.TEST_AA_ACCOUNT_ADDRESS_A ||
    process.env.TEST_AA_ACCOUNT_ADDRESS_B ||
    process.env.TEST_AA_ACCOUNT_ADDRESS_1;

  if (!senderAAAccount) {
    console.error('❌ TEST_AA_ACCOUNT_ADDRESS_A (or _B) not found in env');
    process.exit(2);
  }

  console.log('📌 Configuration:');
  console.log(`  SuperPaymaster:  ${SUPER_PAYMASTER_ADDRESS}`);
  console.log(`  aPNTs Token:     ${XPNTS_TOKEN_ADDRESS}`);
  console.log(`  EntryPoint:      ${ENTRYPOINT_ADDRESS}`);
  console.log(`  Operator:        ${operatorAddress}`);
  console.log(`  Sender AA:       ${senderAAAccount}`);
  console.log(`  Recipient:       ${recipientAddress}\n`);

  // ── Provider / signers ────────────────────────────────────────
  let provider;
  try {
    // CHAIN_ID override: makeProvider's staticNetwork default (11155111) makes anvil (31337)
    // reject every signed tx at the mempool unless overridden.
    provider = makeProvider(rpcUrl, Number(process.env.CHAIN_ID) || 11155111); // 20s/request timeout + read retry → survives RPC hiccups
  } catch (err) {
    console.warn('\n⚠️  SKIP: Cannot connect to RPC:', err.message);
    process.exit(2);
  }

  const wallet = new ethers.Wallet(senderPrivateKey, provider);

  // ── Contract instances ──────────────────────────────────────
  const xPNTs         = new ethers.Contract(XPNTS_TOKEN_ADDRESS, XPNTS_ABI, provider);
  const xPNTsAsWallet = new ethers.Contract(XPNTS_TOKEN_ADDRESS, XPNTS_ABI, wallet);
  const sp            = new ethers.Contract(SUPER_PAYMASTER_ADDRESS, SP_ABI, provider);
  const lens          = new ethers.Contract(LENS_ADDRESS, LENS_ABI, provider);
  const simpleAccount = new ethers.Contract(senderAAAccount, SIMPLE_ACCOUNT_ABI, provider);
  const entryPoint    = new ethers.Contract(ENTRYPOINT_ADDRESS, ENTRYPOINT_ABI, wallet);
  const xPNTsAsERC20  = new ethers.Contract(XPNTS_TOKEN_ADDRESS, ERC20_ABI, provider);
  const registry      = new ethers.Contract(config.registry, REGISTRY_ABI, wallet);

  // effectiveCreditCap is the CEILING (spec C-0); tryReserveCredit gates on
  // debts + creditReservedOf + amount <= cap (C-1), so headroom is the cap net of both.
  async function recomputeAvailableCredit() {
    const [cap, debt, reserved] = await Promise.all([
      xPNTs.effectiveCreditCap(senderAAAccount),
      xPNTs.debts(senderAAAccount),
      xPNTs.creditReservedOf(senderAAAccount),
    ]);
    const spent = debt + reserved;
    return cap > spent ? cap - spent : 0n;
  }

  // Hoisted so cleanup can run from any early-exit path
  let creditSetupRestoreValue = null;
  async function restoreCreditTier() {
    if (creditSetupRestoreValue !== null) {
      try {
        const tx = await registry.setCreditTier(1n, creditSetupRestoreValue);
        await tx.wait();
        console.log(`\n  ✅ Registry.setCreditTier(1, ${ethers.formatEther(creditSetupRestoreValue)}) restored`);
      } catch (restoreErr) {
        console.warn(`\n  ⚠️  Could not restore creditTierConfig[1]: ${restoreErr.message.substring(0, 80)}`);
      }
    }
  }

  try {
    // ── Step 1: Read current state ──────────────────────────────
    console.log('📊 Step 1: Read current credit/debt state');

    let xPNTsBalance, debtBefore, creditBefore, opConfig, symbol, decimals;
    try {
      [xPNTsBalance, debtBefore, creditBefore, opConfig, symbol, decimals] = await Promise.all([
        xPNTs.balanceOf(senderAAAccount),
        xPNTs.debts(senderAAAccount),
        recomputeAvailableCredit(),
        sp.operators(operatorAddress),
        xPNTs.symbol(),
        xPNTs.decimals(),
      ]);
    } catch (err) {
      if (isNetworkError(err)) {
        console.warn('\n⚠️  SKIP: Network error reading state:', err.message);
        process.exit(2);
      }
      throw err;
    }

    console.log(`  xPNTs balance:        ${ethers.formatUnits(xPNTsBalance, decimals)} ${symbol}`);
    console.log(`  Debt (aPNTs):         ${ethers.formatEther(debtBefore)} aPNTs`);
    console.log(`  Available credit:     ${ethers.formatEther(creditBefore)} aPNTs`);
    console.log(`  Operator configured:  ${opConfig[1]}`);
    console.log(`  Operator aPNTs bal:   ${ethers.formatEther(opConfig[0])} aPNTs`);

    // ── Step 2: Credit precondition — ensure Account A has available credit ──
    // 5.5.0 adds two gates ahead of the Registry credit-tier one this test already did
    // (spec 03 §2.2, §2.3 C-0): the token's creditPolicy must not be OFF, and the account
    // must hold an active requestCredit() for the CURRENT policyEpoch.
    console.log('\n📊 Step 2: Credit precondition check');

    // Step 2a: creditPolicy — 48h TIMELOCK, communityOwner-gated. Cannot be fast-forwarded
    // on a real network from here, so this queues/executes only when the window has already
    // elapsed and SKIPs (never fails) when it hasn't or the wallet isn't authorized.
    const CREDIT_POLICY_AUTO = 2;
    let creditPolicy = await xPNTs.creditPolicy();
    if (creditPolicy === 0n) { // OFF — ethers v6 decodes every uintN (incl. uint8) as bigint
      const owner = await xPNTs.communityOwner();
      if (owner.toLowerCase() !== wallet.address.toLowerCase()) {
        console.log(`  ❌ SKIP: token.creditPolicy() is OFF and this wallet (${wallet.address}) is not communityOwner (${owner}) — cannot queue AUTO.`);
        process.exit(2);
      }
      const [pending, eta] = await Promise.all([xPNTs.pendingPolicy(), xPNTs.pendingPolicyEta()]);
      // Chain time, not local Date.now(): the ETA is measured against block.timestamp, and
      // comparing against the test runner's wall clock is wrong wherever the two can drift
      // (clock skew, or a time-warped local anvil).
      const now = BigInt((await provider.getBlock('latest')).timestamp);
      if (pending === 0n || eta === 0n) {
        const tx = await xPNTsAsWallet.queueCreditPolicy(CREDIT_POLICY_AUTO);
        await tx.wait();
        const newEta = await xPNTs.pendingPolicyEta();
        console.log(`  ❌ SKIP: creditPolicy was OFF — queued AUTO, executable at ${new Date(Number(newEta) * 1000).toISOString()} (48h TIMELOCK). Re-run this test after that time.`);
        process.exit(2);
      }
      if (now < eta) {
        console.log(`  ❌ SKIP: creditPolicy AUTO already queued, executable at ${new Date(Number(eta) * 1000).toISOString()}. Re-run after that time.`);
        process.exit(2);
      }
      const tx = await xPNTsAsWallet.executeCreditPolicy();
      await tx.wait();
      creditPolicy = await xPNTs.creditPolicy();
      console.log(`  ✅ executeCreditPolicy() succeeded — creditPolicy is now ${creditPolicy} (2 = AUTO)`);
    }

    // Step 2b: requestCredit — must come from senderAAAccount itself (msg.sender-gated) and
    // match the CURRENT policyEpoch (C-0: a stale epoch reads as 0 cap even with requestedCap set).
    const [policyEpoch, req] = await Promise.all([xPNTs.policyEpoch(), xPNTs.creditReq(senderAAAccount)]);
    const REQUEST_CREDIT_CAP = ethers.parseEther('1000');
    if (req.epoch !== policyEpoch || req.requestedCap === 0n) {
      console.log(`  ⚠️  No active credit request for this epoch (req.epoch=${req.epoch}, policyEpoch=${policyEpoch}) — requesting ${ethers.formatEther(REQUEST_CREDIT_CAP)} aPNTs via the AA account...`);
      const requestCalldata = xPNTs.interface.encodeFunctionData('requestCredit', [REQUEST_CREDIT_CAP]);
      const tx = await simpleAccount.connect(wallet).execute(XPNTS_TOKEN_ADDRESS, 0, requestCalldata);
      await tx.wait();
      console.log('  ✅ requestCredit() submitted from the AA account');
    }

    // Step 2c: Registry credit-tier headroom (unchanged from pre-5.5.0 — the token's
    // GlobalTierSource reads Registry.getCreditLimit, spec C-5).
    creditBefore = await recomputeAvailableCredit();
    if (creditBefore === 0n) {
      console.log('  ⚠️  Available credit is still 0 — attempting to set up credit via Registry.setCreditTier(1, 1000 ether)...');
      try {
        const tier1Before = await registry.creditTierConfig(1n);
        const TEMP_CREDIT = ethers.parseEther('1000');

        const tx = await registry.setCreditTier(1n, TEMP_CREDIT);
        await tx.wait();
        console.log(`  ✅ setCreditTier(1, 1000 ether) succeeded — original was ${ethers.formatEther(tier1Before)}`);
        creditSetupRestoreValue = tier1Before; // save for restoration (outer scope)

        // Re-read credit after tier boost
        creditBefore = await recomputeAvailableCredit();
        console.log(`  ✅ Available credit after tier boost: ${ethers.formatEther(creditBefore)} aPNTs`);
      } catch (setupErr) {
        console.log(`  ❌ SKIP: Could not set up credit tier (not Registry owner? err: ${setupErr.message.substring(0, 80)})`);
        await restoreCreditTier();
        process.exit(2);
      }
    }

    if (creditBefore === 0n) {
      console.log('  ❌ SKIP: Available credit still 0 after tier setup. Cannot test credit path.');
      await restoreCreditTier();
      process.exit(2);
    }
    console.log(`  ✅ Available credit: ${ethers.formatEther(creditBefore)} aPNTs — proceeding`);

    // ── Step 3: Determine test path ─────────────────────────────
    console.log('\n📊 Step 3: Determine test path');
    const pureCreditPath = xPNTsBalance === 0n;

    if (pureCreditPath) {
      console.log('  Account A has 0 xPNTs balance — will use PURE CREDIT PATH');
      console.log('  (validate: tryLockForGas INSUFFICIENT → tryReserveCredit OK; postOp: settleCredit)');
    } else {
      console.log(`  Account A has ${ethers.formatUnits(xPNTsBalance, decimals)} ${symbol} — will use BALANCE PATH`);
      console.log('  (validate: tryLockForGas OK; postOp: settleLocked burns xPNTs, no debt)');
      console.log('  Note: run again after balance reaches 0 to exercise pure credit path');
    }

    // ── Step 4: Build UserOp ────────────────────────────────────
    console.log('\n📝 Step 4: Prepare Transfer CallData');
    const transferAmount   = ethers.parseUnits('1', decimals);
    const transferCalldata = xPNTsAsERC20.interface.encodeFunctionData('transfer', [recipientAddress, transferAmount]);
    const executeCalldata  = simpleAccount.interface.encodeFunctionData('execute', [XPNTS_TOKEN_ADDRESS, 0, transferCalldata]);
    console.log(`  Transfer Amount: 1 ${symbol} to ${recipientAddress}`);

    console.log('\n🔨 Step 5: Build UserOperation');
    let nonce;
    try {
      nonce = await simpleAccount.getNonce();
    } catch (err) {
      if (isNetworkError(err)) {
        console.warn('\n⚠️  SKIP: Network error fetching nonce:', err.message);
        await restoreCreditTier();
        process.exit(2);
      }
      throw err;
    }
    console.log(`  Nonce: ${nonce}`);

    // Paymaster gas limits — same values as TC2 (tested on anvil, D7):
    // pmVerificationGasLimit: 400K (5.5.0 validatePaymasterUserOp does more work than 3.x —
    //                          exchangeRate low-level call + tryLockForGas/tryReserveCredit
    //                          external call; 150K measured AA36 on a cold-storage account)
    // pmPostOpGasLimit: 200K  (postOp runs settleLocked/settleCredit on the v2 token,
    //                          ~120K with xPNTsToken._update + event emits; 100K was OOG)
    const pmVerificationGasLimit = 400000n;
    const pmPostOpGasLimit       = 200000n;
    // 5.5.0 paymasterAndData layout (SuperPaymasterStorage.sol:177-180):
    // [paymaster(20)][pmVerGas(16)][pmPostGas(16)][operator(20)][maxRate(32)][token(20)][flags(1)]
    const maxRate = ethers.MaxUint256;
    const flags = 0; // no SP_RENEW / ACCOUNT_RENEW
    const paymasterAndData       = ethers.solidityPacked(
      ['address', 'uint128', 'uint128', 'address', 'uint256', 'address', 'uint8'],
      [SUPER_PAYMASTER_ADDRESS, pmVerificationGasLimit, pmPostOpGasLimit, operatorAddress, maxRate, XPNTS_TOKEN_ADDRESS, flags]
    );

    const userOp = {
      sender:               senderAAAccount,
      nonce:                nonce,
      initCode:             '0x',
      callData:             executeCalldata,
      accountGasLimits:     ethers.solidityPacked(['uint128', 'uint128'], [200000, 200000]),
      preVerificationGas:   100000n,
      gasFees:              ethers.solidityPacked(['uint128', 'uint128'], [2000000000, 2000000000]),
      paymasterAndData:     paymasterAndData,
      signature:            '0x',
    };

    console.log('\n✍️  Step 6: Sign UserOperation');
    const userOpHash = await entryPoint.getUserOpHash(userOp);
    console.log(`  UserOp Hash: ${userOpHash.substring(0, 20)}...`);
    const signature = await wallet.signMessage(ethers.getBytes(userOpHash));
    userOp.signature = signature;

    console.log('\n🚀 Step 7: Submit UserOp to EntryPoint');
    const beneficiary = wallet.address;

    // Wait out the operator's minTxInterval if a prior same-operator UserOp just
    // ran (keeps the credit-path test order-independent instead of SKIPping).
    await waitOutRateLimit(lens, SUPER_PAYMASTER_ADDRESS, userOp);

    try {
      const gasEstimate = await entryPoint.handleOps.estimateGas([userOp], beneficiary);
      console.log(`  Estimated gas: ${gasEstimate}`);
    } catch (estimateErr) {
      if (isNetworkError(estimateErr)) {
        console.warn('\n⚠️  SKIP: Network error during gas estimation:', estimateErr.message);
        await restoreCreditTier();
        process.exit(2);
      }
      if (isNonceConflict(estimateErr)) {
        console.warn('\n⚠️  SKIP: In-flight/nonce limit during gas estimation — too many pending TXs.');
        await restoreCreditTier();
        process.exit(2);
      }
      if (isValidationRejection(estimateErr)) {
        const verdict = await classifyValidationFailure(lens, SUPER_PAYMASTER_ADDRESS, userOp, estimateErr);
        if (verdict.action === 'FAIL') {
          console.error(`\n❌ FAIL: validation rejected on gas estimation — ${verdict.reason}`);
          await restoreCreditTier();
          process.exit(1);
        }
        if (!verdict.proceed) {
          console.warn(`\n⚠️  SKIP: ${verdict.reason}`);
          await restoreCreditTier();
          process.exit(2);
        }
        console.log(`  Gas estimation hit a simulation artifact (${verdict.reason}) — proceeding to real submit...`);
      } else {
        console.log(`  Gas estimation: ${estimateErr.message.substring(0, 100)}...`);
        console.log('  Proceeding with transaction anyway...');
      }
    }

    console.log('  Sending transaction...');
    let tx;
    try {
      tx = await entryPoint.handleOps([userOp], beneficiary);
    } catch (txErr) {
      if (isNetworkError(txErr)) {
        console.warn('\n⚠️  SKIP: Network error sending TX:', txErr.message);
        await restoreCreditTier();
        process.exit(2);
      }
      if (isNonceConflict(txErr)) {
        console.warn('\n⚠️  SKIP: Nonce conflict (REPLACEMENT_UNDERPRICED / nonce too low).');
        console.warn('  A previous TX from this account is still pending in the mempool.');
        console.warn('  Wait for the pending TX to confirm and re-run this test.');
        await restoreCreditTier();
        process.exit(2);
      }
      if (isValidationRejection(txErr)) {
        // handleOps already failed, so even an AA32 artifact is terminal here.
        const verdict = await classifyValidationFailure(lens, SUPER_PAYMASTER_ADDRESS, userOp, txErr);
        await restoreCreditTier();
        if (verdict.action === 'FAIL') {
          console.error(`\n❌ FAIL: validation rejected on handleOps — ${verdict.reason}`);
          process.exit(1);
        }
        console.warn(`\n⚠️  SKIP: ${verdict.reason}`);
        process.exit(2);
      }
      throw txErr;
    }

    console.log(`\n⬛ TX Hash: ${tx.hash}`);
    console.log(`🔗 Etherscan: https://sepolia.etherscan.io/tx/${tx.hash}`);

    const receipt = await tx.wait();
    if (receipt.status !== 1) {
      console.log('\n❌ Transaction failed (status=0)');
      process.exit(1);
    }
    console.log('  ✅ Transaction confirmed!\n');

    // ── Step 8: Read post-TX state ──────────────────────────────
    console.log('📊 Step 8: Read post-TX credit/debt state');

    let xPNTsBalanceAfter, debtAfter, creditAfter;
    // FALSE-GREEN FIX: the TX confirmed, but the accounting assertions (Step 9) have
    // NOT run yet. Previously a network hiccup here exited 0 (PASS) before any
    // verification — a green run that proved nothing. The post-state reads are
    // idempotent views, so retry transient errors; if they still fail, report
    // INCONCLUSIVE (exit 2 = SKIP), never exit 0 with the assertions unrun.
    {
      const POST_READ_RETRIES = 4;
      let postReadErr = null;
      for (let attempt = 1; attempt <= POST_READ_RETRIES; attempt++) {
        try {
          [xPNTsBalanceAfter, debtAfter, creditAfter] = await Promise.all([
            xPNTs.balanceOf(senderAAAccount),
            xPNTs.debts(senderAAAccount),
            recomputeAvailableCredit(),
          ]);
          postReadErr = null;
          break;
        } catch (err) {
          postReadErr = err;
          if (isNetworkError(err) && attempt < POST_READ_RETRIES) {
            console.warn(`  ⚠️  Network error reading post-TX state (attempt ${attempt}/${POST_READ_RETRIES - 1}) — retrying in ${attempt * 3}s...`);
            await new Promise(r => setTimeout(r, attempt * 3000));
            continue;
          }
          break;
        }
      }
      if (postReadErr) {
        if (isNetworkError(postReadErr)) {
          // TX confirmed but post-state could not be read after retries → accounting
          // NOT verified. Inconclusive (exit 2), NOT a green PASS.
          console.warn('\n⚠️  SKIP (inconclusive): TX confirmed but post-TX state read failed after retries — accounting NOT verified. Re-run to confirm.');
          await restoreCreditTier();
          process.exit(2);
        }
        throw postReadErr;
      }
    }

    const balanceDelta = xPNTsBalance - xPNTsBalanceAfter;
    const debtDelta    = debtAfter - debtBefore;
    const creditDelta  = creditBefore - creditAfter;

    console.log('\n  ┌─────────────────────────────────────────────┐');
    console.log('  │         Before / After Comparison          │');
    console.log('  ├─────────────────────────────────────────────┤');
    console.log(`  │ xPNTs balance: ${ethers.formatUnits(xPNTsBalance, decimals).padEnd(10)} → ${ethers.formatUnits(xPNTsBalanceAfter, decimals).padEnd(10)} ${symbol}`);
    console.log(`  │ Debt (aPNTs):  ${ethers.formatEther(debtBefore).padEnd(10)} → ${ethers.formatEther(debtAfter).padEnd(10)} aPNTs`);
    console.log(`  │ Credit (aPNTs):${ethers.formatEther(creditBefore).padEnd(10)} → ${ethers.formatEther(creditAfter).padEnd(10)} aPNTs`);
    console.log('  └─────────────────────────────────────────────┘');

    // ── Step 9: Assertions ──────────────────────────────────────
    console.log('\n📊 Step 9: Verify accounting');

    if (pureCreditPath) {
      // Pure credit path: xPNTs balance unchanged, debt increased, credit decreased
      if (xPNTsBalanceAfter === xPNTsBalance) {
        console.log('  ✅ PASS: xPNTs balance unchanged (no burn)');
      } else {
        console.log(`  ❌ FAIL: Expected xPNTs balance unchanged, got delta ${ethers.formatUnits(balanceDelta, decimals)}`);
        process.exit(1);
      }

      if (debtDelta > 0n) {
        console.log(`  ✅ PASS: DEBT_INCREASED — debt grew by ${ethers.formatEther(debtDelta)} aPNTs (credit/debt path taken)`);
      } else {
        console.log(`  ❌ FAIL: Expected debt to increase on credit path (debtDelta=${debtDelta})`);
        console.log('  Possible causes: SuperPaymaster postOp had enough credit but used burn somehow, or revert');
        process.exit(1);
      }

      if (creditDelta > 0n) {
        console.log(`  ✅ PASS: Available credit decreased by ${ethers.formatEther(creditDelta)} aPNTs (debt consumed credit)`);
      } else {
        console.log(`  ℹ️  Note: Credit unchanged (creditDelta=${creditDelta}) — debt may exceed tier limit already`);
      }

    } else {
      // Burn path: xPNTs balance should have decreased, debt unchanged or zero
      if (balanceDelta > 0n) {
        console.log(`  ✅ PASS: xPNTs burned — balance decreased by ${ethers.formatUnits(balanceDelta, decimals)} ${symbol}`);
      } else {
        // If balance didn't change, it might have taken credit path anyway (balance was < charge)
        console.log(`  ℹ️  Note: xPNTs balance unchanged (may have been < charge amount, credit path used)`);
      }

      if (debtDelta === 0n) {
        console.log('  ✅ PASS: Debt unchanged (burn path succeeded)');
      } else {
        console.log(`  ℹ️  Note: Debt changed by ${ethers.formatEther(debtDelta)} aPNTs (partial credit path — balance was < charge)`);
      }

      console.log('\n  💡 To test pure credit path: run again after Account A xPNTs balance reaches 0');
    }

  } catch (error) {
    if (isNetworkError(error)) {
      console.warn('\n⚠️  SKIP: Network error (transient RPC issue):', error.message);
      console.warn('  Not a contract logic failure — re-run manually.\n');
      await restoreCreditTier();
      process.exit(2);
    }
    console.error('\n❌ Error:', error.message);
    if (error.data)  console.error('  Error data:', error.data);
    if (error.error) console.error('  Error reason:', error.error);
    await restoreCreditTier();
    process.exit(1);
  }

  // Always restore credit tier on normal completion
  await restoreCreditTier();

  console.log('\n╔═══════════════════════════════════════════════════════════╗');
  console.log('║               Test Case 4 Completed — PASS               ║');
  console.log('╚═══════════════════════════════════════════════════════════╝');
}

main().then(() => process.exit(0)).catch((error) => { console.error(error); process.exit(1); });

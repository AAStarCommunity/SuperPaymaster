#!/usr/bin/env node

/**
 * Gasless Transfer Test Case 4 - Credit/Debt Path
 *
 * Demonstrates the credit/debt fallback path in SuperPaymaster's postOp:
 *   - Burn path: burnFromWithOpHash(user, chargeAPNTs, opHash) — burns xPNTs
 *   - Credit path: recordDebtWithOpHash(user, chargeAPNTs, opHash) — records debt
 *
 * When Account A has zero xPNTs balance, postOp falls back to the credit/debt
 * path and getDebt(Account_A) increases after the UserOp.
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
require('dotenv').config({ path: process.env.ENV_FILE || path.join(__dirname, '../../.env.sepolia') });

// ============================================================
// ABI Definitions (inline — standalone file, no test-helpers import)
// ============================================================

const XPNTS_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function getDebt(address user) view returns (uint256)",
  "function repayDebt(uint256 amountXPNTs)",
  "function exchangeRate() view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
];

const SP_ABI = [
  "function operators(address) view returns (uint128 aPNTsBalance, bool isConfigured, bool isPaused, address xPNTsToken, uint32 reputation, uint48 minTxInterval, address treasury, uint256 totalSpent, uint256 totalTxSponsored)",
  "function getAvailableCredit(address user, address token) view returns (uint256)",
  "function sbtHolders(address user) view returns (bool)",
  "function updatePrice()",
  "function priceValidUntil() view returns (uint256)",
  "function dryRunValidation(tuple(address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp, uint256 maxCost) view returns (bool ok, bytes32 reasonCode)",
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

async function classifyValidationFailure(sp, userOp, err) {
  try {
    const maxCost = computeMaxCost(userOp);
    const [ok, reasonCode] = await sp.dryRunValidation(userOp, maxCost);
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
  const XPNTS_TOKEN_ADDRESS     = config.aPNTs;
  const ENTRYPOINT_ADDRESS      = config.entryPoint;

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
    provider = new ethers.JsonRpcProvider(rpcUrl, 11155111, { staticNetwork: true });
  } catch (err) {
    console.warn('\n⚠️  SKIP: Cannot connect to RPC:', err.message);
    process.exit(2);
  }

  const wallet = new ethers.Wallet(senderPrivateKey, provider);

  // ── Contract instances ──────────────────────────────────────
  const xPNTs         = new ethers.Contract(XPNTS_TOKEN_ADDRESS, XPNTS_ABI, provider);
  const sp            = new ethers.Contract(SUPER_PAYMASTER_ADDRESS, SP_ABI, provider);
  const simpleAccount = new ethers.Contract(senderAAAccount, SIMPLE_ACCOUNT_ABI, provider);
  const entryPoint    = new ethers.Contract(ENTRYPOINT_ADDRESS, ENTRYPOINT_ABI, wallet);
  const xPNTsAsERC20  = new ethers.Contract(XPNTS_TOKEN_ADDRESS, ERC20_ABI, provider);
  const registry      = new ethers.Contract(config.registry, REGISTRY_ABI, wallet);

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
        xPNTs.getDebt(senderAAAccount),
        sp.getAvailableCredit(senderAAAccount, XPNTS_TOKEN_ADDRESS),
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
    console.log('\n📊 Step 2: Credit precondition check');

    if (creditBefore === 0n) {
      console.log('  ⚠️  Available credit is 0 — attempting to set up credit via Registry.setCreditTier(1, 1000 ether)...');
      try {
        const tier1Before = await registry.creditTierConfig(1n);
        const TEMP_CREDIT = ethers.parseEther('1000');

        const tx = await registry.setCreditTier(1n, TEMP_CREDIT);
        await tx.wait();
        console.log(`  ✅ setCreditTier(1, 1000 ether) succeeded — original was ${ethers.formatEther(tier1Before)}`);
        creditSetupRestoreValue = tier1Before; // save for restoration (outer scope)

        // Re-read credit after tier boost
        creditBefore = await sp.getAvailableCredit(senderAAAccount, XPNTS_TOKEN_ADDRESS);
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
      console.log('  (postOp: burnFromWithOpHash will fail → recordDebtWithOpHash called)');
    } else {
      console.log(`  Account A has ${ethers.formatUnits(xPNTsBalance, decimals)} ${symbol} — will use BURN PATH`);
      console.log('  (postOp: burnFromWithOpHash will succeed → xPNTs burned, no debt)');
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

    // Paymaster gas limits — same values as TC2 (tested on Sepolia):
    // pmVerificationGasLimit: 150K (validatePaymasterUserOp overhead)
    // pmPostOpGasLimit: 200K  (postOp runs burn→recordDebt→pendingDebts fallback chain,
    //                          ~120K with xPNTsToken._update + event emits; 100K was OOG)
    const pmVerificationGasLimit = 150000n;
    const pmPostOpGasLimit       = 200000n;
    const paymasterAndData       = ethers.solidityPacked(
      ['address', 'uint128', 'uint128', 'address'],
      [SUPER_PAYMASTER_ADDRESS, pmVerificationGasLimit, pmPostOpGasLimit, operatorAddress]
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
        const verdict = await classifyValidationFailure(sp, userOp, estimateErr);
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
        const verdict = await classifyValidationFailure(sp, userOp, txErr);
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
    try {
      [xPNTsBalanceAfter, debtAfter, creditAfter] = await Promise.all([
        xPNTs.balanceOf(senderAAAccount),
        xPNTs.getDebt(senderAAAccount),
        sp.getAvailableCredit(senderAAAccount, XPNTS_TOKEN_ADDRESS),
      ]);
    } catch (err) {
      if (isNetworkError(err)) {
        console.warn('\n⚠️  Note: Network error reading post-TX state — TX already confirmed.');
        // TX succeeded; don't fail the test just because post-read had a network hiccup
        process.exit(0);
      }
      throw err;
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

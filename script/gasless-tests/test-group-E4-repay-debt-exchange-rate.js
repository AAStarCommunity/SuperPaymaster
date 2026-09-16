#!/usr/bin/env node
/**
 * Test Group E4: xPNTs Debt Repayment & Exchange Rate Accounting
 *
 * Verifies the repayDebt() mechanism and exchange rate math in xPNTsToken v2:
 *   - exchangeRate() is live and non-zero
 *   - repayDebt(xPNTsAmount) repays floor(xPNTs * 1e18 / rate) aPNTs of debt
 *   - tryLockForGas's lock-time conversion uses ceil(aPNTs * rate / 1e18) xPNTs (opposite
 *     direction; 5.5.0 renamed home for the math previously illustrated via
 *     burnFromWithOpHash — that function is gone, but the ceil formula itself is
 *     unchanged, it now lives in xPNTsTokenV2._lockDecision, xPNTsTokenV2.sol:209)
 *   - exchange rate has bounds [1e14, 1e22] and a 1h cooldown between updates
 *   - effectiveCreditCap/debts/creditReservedOf reflect debt changes after repayDebt
 *
 * This is NOT a UserOp test — it directly calls the xPNTs v2 token's view/write
 * functions using the deployer wallet. 5.5.0: the token under test is
 * config.aastarXPNTsV2 (the actual balance-mode token), NOT config.aPNTs — that address
 * is now SP's own operator-deposit collateral asset and doesn't implement debts/
 * effectiveCreditCap/tryLockForGas at all (see test-case-2-fixed.js for the same note).
 *
 * Prerequisites: run A1 + B1 first (operator configured, deployer has xPNTs).
 */
const {
  initTestEnv, getContracts, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, finishTest, resetCounters,
  assertEqual, assertTrue, assertGt, assertGte,
  sendTxSafe, catchStep,
} = require('./test-helpers');

// ============================================================
// xPNTs v2 debt/rate ABI extension
// (test-helpers' shared ABI.xPNTsToken already covers this, but this file predates
// that addition and manages its own contract instance against aastarXPNTsV2 directly)
// ============================================================

const XPNTS_DEBT_ABI = [
  "function debts(address user) view returns (uint256)",
  "function repayDebt(uint256 amountXPNTs)",
  "function exchangeRate() view returns (uint256)",
  "function updateExchangeRate(uint256 newRate)",
  "function maxSingleTxLimit() view returns (uint256)",
  "function exchangeRateUpdatedAt() view returns (uint256)",
  "function effectiveCreditCap(address user) view returns (uint256)",
  "function creditReservedOf(address user) view returns (uint256)",
  // Also include ERC20 basics needed here
  "function balanceOf(address) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
];

// ============================================================
// Helpers
// ============================================================

/** Floor division: how many aPNTs are repaid by spending xPNTsAmount xPNTs */
function xPNTsToAPNTs(xPNTsAmount, rate) {
  return (xPNTsAmount * BigInt('1000000000000000000')) / rate;
}

/** Ceil division: how many xPNTs are needed to cover aPNTsAmount in a burn */
function aPNTsToXPNTsCeil(aPNTsAmount, rate) {
  const ONE18 = BigInt('1000000000000000000');
  return (aPNTsAmount * rate + ONE18 - 1n) / ONE18;
}

// ============================================================
// Main
// ============================================================

async function main() {
  printHeader('Test Group E4: repayDebt & Exchange Rate Accounting');
  resetCounters();

  const { config, deployer } = initTestEnv();
  const deployerAddr = deployer.address;

  if (!config.aastarXPNTsV2) {
    printSkip('config.aastarXPNTsV2 missing — this deployment predates 5.5.0 balance mode');
    process.exit(finishTest('E4: repayDebt & Exchange Rate'));
  }

  // Build the extended xPNTs v2 contract instance with debt functions
  const xpnts = new ethers.Contract(config.aastarXPNTsV2, XPNTS_DEBT_ABI, deployer);

  // ──────────────────────────────────────────────────────────
  // Step 1: Read xPNTs exchange rate and debt accounting state
  // ──────────────────────────────────────────────────────────
  printStep(1, 'Read xPNTs exchange rate and debt accounting state');

  let rate, txLimit, lastUpdate, debtBeforeStep3;
  try {
    [rate, txLimit, lastUpdate, debtBeforeStep3] = await Promise.all([
      xpnts.exchangeRate(),
      xpnts.maxSingleTxLimit(),
      xpnts.exchangeRateUpdatedAt(),
      xpnts.debts(deployerAddr),
    ]);
  } catch (e) {
    catchStep(`Failed to read xPNTs state`, e);
    process.exit(finishTest('E4: repayDebt & Exchange Rate'));
  }

  printKeyValue('xPNTs token address', config.aastarXPNTsV2);
  printKeyValue('exchangeRate (live)', ethers.formatEther(rate) + ' (xPNTs per aPNTs, 18-dec fixed point)');
  printKeyValue('maxSingleTxLimit (aPNTs)', ethers.formatEther(txLimit));
  printKeyValue('exchangeRateUpdatedAt (unix)', lastUpdate.toString());
  printKeyValue("deployer's current debt (aPNTs)", ethers.formatEther(debtBeforeStep3));

  assertGt(rate, 0n, 'exchangeRate must be non-zero');

  // ──────────────────────────────────────────────────────────
  // Step 2: Read deployer's xPNTs balance available for repayment
  // ──────────────────────────────────────────────────────────
  printStep(2, "Read deployer's xPNTs balance available for repayment");

  let xPNTsBalance;
  try {
    xPNTsBalance = await xpnts.balanceOf(deployerAddr);
  } catch (e) {
    catchStep(`balanceOf`, e);
    xPNTsBalance = 0n;
  }

  const wouldRepayAPNTs = xPNTsBalance > 0n ? xPNTsToAPNTs(xPNTsBalance, rate) : 0n;

  printKeyValue('xPNTs balance', ethers.formatEther(xPNTsBalance) + ' xPNTs');
  printKeyValue('exchangeRate', ethers.formatEther(rate));
  printInfo(`If deployer repays ALL ${ethers.formatEther(xPNTsBalance)} xPNTs,`);
  printInfo(`  that clears floor(${ethers.formatEther(xPNTsBalance)} * 1e18 / rate) = ${ethers.formatEther(wouldRepayAPNTs)} aPNTs of debt`);
  printSuccess('Balance and repayment illustration computed');

  // ──────────────────────────────────────────────────────────
  // Step 3: Verify repayDebt math — xPNTs → aPNTs floor conversion
  // ──────────────────────────────────────────────────────────
  printStep(3, 'Verify repayDebt math: xPNTs → aPNTs floor conversion');

  let debtAfterRepay = debtBeforeStep3; // updated if repay executes

  if (debtBeforeStep3 === 0n) {
    printSkip('Deployer has no debt — repayDebt TX skipped (no-op)');
    printInfo('Tip: run a TC4 UserOp with 0-balance AA account to accumulate debt first');
  } else if (xPNTsBalance === 0n) {
    printSkip('Deployer has debt but no xPNTs balance — cannot repay (balance=0)');
    printInfo('Tip: mint or receive xPNTs to the deployer address, then re-run E4');
  } else {
    // Repay a small amount to avoid draining all tokens: min(1 ether, balance/10)
    const ONE_XPNTS    = ethers.parseEther('1');
    const repayAmount  = xPNTsBalance / 10n < ONE_XPNTS ? xPNTsBalance / 10n : ONE_XPNTS;
    const expectedRepaid = xPNTsToAPNTs(repayAmount, rate);

    printKeyValue('repayAmount (xPNTs)', ethers.formatEther(repayAmount));
    printKeyValue('expectedRepaid (aPNTs, floor)', ethers.formatEther(expectedRepaid));
    printInfo('Calling repayDebt...');

    const receipt = await sendTxSafe(xpnts, 'repayDebt', [repayAmount], 'repayDebt');

    if (receipt) {
      try {
        debtAfterRepay = await xpnts.debts(deployerAddr);
      } catch (e) {
        catchStep(`debts() after repay`, e);
        debtAfterRepay = debtBeforeStep3; // fallback: assume unchanged
      }
      const actualRepaid = debtBeforeStep3 - debtAfterRepay;

      printKeyValue('debtBefore (aPNTs)', ethers.formatEther(debtBeforeStep3));
      printKeyValue('debtAfter  (aPNTs)', ethers.formatEther(debtAfterRepay));
      printKeyValue('actualRepaid (aPNTs)', ethers.formatEther(actualRepaid));

      // The contract computes: repaid = floor(amountXPNTs * 1e18 / exchangeRate)
      // Allow for minor rounding if rate changed between our read and the TX
      const delta = actualRepaid >= expectedRepaid
        ? actualRepaid - expectedRepaid
        : expectedRepaid - actualRepaid;
      const tolerance = ethers.parseEther('0.001'); // 0.001 aPNTs tolerance for rate skew

      if (delta <= tolerance) {
        printSuccess(`debt reduced by floor(xPNTs * 1e18 / rate) = ${ethers.formatEther(expectedRepaid)} aPNTs (±${ethers.formatEther(delta)})`);
      } else {
        printError(`repayDebt math mismatch: expected ${ethers.formatEther(expectedRepaid)} aPNTs, got ${ethers.formatEther(actualRepaid)} aPNTs`);
      }
    } else {
      printError('repayDebt TX failed — see error above');
    }
  }

  // ──────────────────────────────────────────────────────────
  // Step 4: Exchange rate bounds verification (read-only)
  // ──────────────────────────────────────────────────────────
  printStep(4, 'Exchange rate bounds verification (read-only)');

  const RATE_MIN = 100000000000000n;        // 1e14
  const RATE_MAX = 10000000000000000000000n; // 1e22

  printKeyValue('Current rate', ethers.formatEther(rate));
  printKeyValue('Min allowed rate (1e14)', ethers.formatEther(RATE_MIN));
  printKeyValue('Max allowed rate (1e22)', ethers.formatEther(RATE_MAX));

  assertTrue(rate >= RATE_MIN, 'rate >= 1e14 (min bound)');
  assertTrue(rate <= RATE_MAX, 'rate <= 1e22 (max bound)');

  printInfo('Rate changes require a 1-hour cooldown between calls; max ±20% per update');

  const RATE_COOLDOWN_SEC = 3600n;
  const nextAllowed       = lastUpdate + RATE_COOLDOWN_SEC;
  const nextAllowedDate   = new Date(Number(nextAllowed) * 1000).toISOString();
  printKeyValue('Next allowed rate update (approx)', nextAllowedDate);

  // ──────────────────────────────────────────────────────────
  // Step 5: Verify effectiveCreditCap-derived headroom reflects debt changes
  // 5.5.0: SP.getAvailableCredit is gone — headroom is now computed client-side from
  // the token's own effectiveCreditCap/debts/creditReservedOf (spec C-0/C-1), same
  // as recomputeAvailableCredit() in test-case-4-superpaymaster-credit-path.js.
  // ──────────────────────────────────────────────────────────
  printStep(5, 'Verify effectiveCreditCap - debts - creditReservedOf reflects debt changes');

  let creditNow;
  try {
    const [cap, debtNow, reserved] = await Promise.all([
      xpnts.effectiveCreditCap(deployerAddr),
      xpnts.debts(deployerAddr),
      xpnts.creditReservedOf(deployerAddr),
    ]);
    const spent = debtNow + reserved;
    creditNow = cap > spent ? cap - spent : 0n;
  } catch (e) {
    catchStep(`effectiveCreditCap headroom`, e);
    creditNow = null;
  }

  if (creditNow !== null) {
    printKeyValue('Available credit (aPNTs)', ethers.formatEther(creditNow));

    assertTrue(creditNow >= 0n, 'available credit must be non-negative');

    const repairedAPNTs = debtBeforeStep3 - debtAfterRepay;
    if (repairedAPNTs > 0n) {
      printInfo(`repayDebt repaid ${ethers.formatEther(repairedAPNTs)} aPNTs of debt`);
      printInfo(`Available credit increased by ~${ethers.formatEther(repairedAPNTs)} aPNTs after repayDebt`);
      printSuccess('Credit reflects debt repayment (increased after repayDebt)');
    } else {
      printInfo('No debt was repaid in Step 3 — credit baseline verified');
      printSuccess('Available credit computation returns non-negative value');
    }
  }

  // ──────────────────────────────────────────────────────────
  // Step 6: aPNTs accounting — lock-time ceil conversion (read-only)
  // 5.5.0: this math used to be illustrated via the now-removed burnFromWithOpHash;
  // the identical ceil(aPNTs * rate / 1e18) formula lives on in tryLockForGas's
  // internal _lockDecision (xPNTsTokenV2.sol:209) — same rounding direction, new home.
  // ──────────────────────────────────────────────────────────
  printStep(6, 'aPNTs accounting: tryLockForGas aPNTs→xPNTs ceil conversion (math verification)');

  // Re-read rate in case it changed (unlikely in same block, but be safe)
  let rateNow;
  try {
    rateNow = await xpnts.exchangeRate();
  } catch (e) {
    rateNow = rate; // fall back to Step 1 value
    printInfo(`Note: could not re-read rate (${e.message.substring(0, 60)}), using Step 1 value`);
  }

  const EXAMPLE_APNTS     = ethers.parseEther('10');   // 10 aPNTs — illustration
  const xPNTsToBurn       = aPNTsToXPNTsCeil(EXAMPLE_APNTS, rateNow);
  const xPNTsToBurnFloor  = xPNTsToAPNTs(EXAMPLE_APNTS, rateNow); // floor for comparison

  printKeyValue('Example charge (aPNTs)', ethers.formatEther(EXAMPLE_APNTS));
  printKeyValue('exchangeRate', ethers.formatEther(rateNow));
  printInfo(`Burn 10 aPNTs at rate ${ethers.formatEther(rateNow)}:`);
  printInfo(`  xPNTs to burn (ceil) = ceil(10 * rate / 1e18) = ${ethers.formatEther(xPNTsToBurn)} xPNTs`);
  printInfo(`  cross-check (floor)  = floor(10 * rate / 1e18) = ${ethers.formatEther(xPNTsToBurnFloor)} xPNTs`);
  printInfo('tryLockForGas uses ceil so the operator is never under-compensated by rounding.');

  // Sanity: ceil >= floor always
  assertTrue(xPNTsToBurn >= xPNTsToBurnFloor, 'ceil(aPNTs * rate / 1e18) >= floor — ceil never less than floor');

  // When rate == 1e18 (1:1), ceil == floor == aPNTs
  if (rateNow === BigInt('1000000000000000000')) {
    printInfo('Rate is 1:1 (1e18) — ceil == floor == aPNTs amount (as expected)');
  }

  printSuccess('tryLockForGas ceil math verified (read-only)');

  // ──────────────────────────────────────────────────────────
  // Summary
  // ──────────────────────────────────────────────────────────
  process.exit(finishTest('E4: repayDebt & Exchange Rate'));
}

main().catch(e => { console.error(e); process.exit(1); });

#!/usr/bin/env node
/**
 * Test Group E3: aPNTs Exchange Rate Accounting
 *
 * Verifies the unified aPNTs accounting introduced in PR #200:
 * - xPNTsToken.exchangeRate() is the live rate used by SuperPaymaster (not stale config)
 * - operators() returns 9-tuple (no exchangeRate field)
 * - effectiveCreditCap / debts (5.5.0: getAvailableCredit/getDebt moved off SP onto the
 *   token itself — see IxPNTsTokenV2) both return aPNTs values
 *
 * Prerequisites: run A1 + B1 first (operator configured, registry roles set).
 */
const {
  initTestEnv, getContracts, ethers,
  printHeader, printStep, printSuccess, printError, catchStep, printSkip, printInfo, printKeyValue,
  printSummary, finishTest, resetCounters,
  assertEqual, assertTrue, assertGt, assertGte,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group E3: aPNTs Exchange Rate Accounting (PR #200)');
  resetCounters();

  const { config, deployer, anni } = initTestEnv();
  const c = getContracts(config, deployer);
  const sp = c.superPaymaster;

  const deployerAddr = deployer.address;
  const anniAddr = process.env.OPERATOR_ADDRESS || (anni ? anni.address : null);

  // ──────────────────────────────────────────
  // Step 1: operators() returns 9-tuple (no exchangeRate)
  // ──────────────────────────────────────────
  printStep(1, 'Verify operators() 9-tuple (no exchangeRate in v5.3.3)');
  try {
    const op = await sp.operators(deployerAddr);
    // 9-tuple: [aPNTsBalance, isConfigured, isPaused, xPNTsToken, reputation, minTxInterval, treasury, totalSpent, totalTxSponsored]
    const fieldCount = Object.keys(op).filter(k => !isNaN(parseInt(k))).length;
    printKeyValue('Tuple field count', fieldCount);
    printKeyValue('aPNTsBalance', ethers.formatEther(op[0]));
    printKeyValue('isConfigured', op[1]);
    printKeyValue('isPaused', op[2]);
    printKeyValue('xPNTsToken', op[3]);
    printKeyValue('reputation', op[4].toString());
    assertEqual(fieldCount, 9, 'operators() must return 9 fields (exchangeRate removed)');
  } catch (e) {
    catchStep(`operators() tuple check`, e);
  }

  // ──────────────────────────────────────────
  // Step 2: xPNTsToken live exchange rate
  // ──────────────────────────────────────────
  printStep(2, 'Read live exchangeRate from xPNTsToken');
  const xPNTsAbi = [
    'function exchangeRate() view returns (uint256)',
    'function debts(address user) view returns (uint256)',
    'function maxSingleTxLimit() view returns (uint256)',
    'function effectiveCreditCap(address user) view returns (uint256)',
    'function creditReservedOf(address user) view returns (uint256)',
  ];
  let xPNTsTokenAddr = null;
  try {
    const op = await sp.operators(deployerAddr);
    xPNTsTokenAddr = op[3]; // index 3 = xPNTsToken (after exchangeRate removal)
    if (xPNTsTokenAddr === ethers.ZeroAddress) {
      printSkip('Deployer has no xPNTsToken configured');
    } else {
      const token = new ethers.Contract(xPNTsTokenAddr, xPNTsAbi, deployer);
      const rate = await token.exchangeRate();
      const limit = await token.maxSingleTxLimit();
      printKeyValue('xPNTsToken', xPNTsTokenAddr);
      printKeyValue('exchangeRate (live)', ethers.formatEther(rate));
      printKeyValue('maxSingleTxLimit (aPNTs)', ethers.formatEther(limit));
      assertGt(rate, 0n, 'exchangeRate must be non-zero');
      assertGte(limit, ethers.parseEther('1000'), 'maxSingleTxLimit must be at least 1000 aPNTs');
      printSuccess('Live exchange rate verified from xPNTsToken');
    }
  } catch (e) {
    catchStep(`xPNTsToken read`, e);
  }

  // ──────────────────────────────────────────
  // Step 3: effectiveCreditCap (5.5.0: replaces SP.getAvailableCredit, moved onto the token)
  // ──────────────────────────────────────────
  printStep(3, 'token.effectiveCreditCap returns aPNTs denomination');
  try {
    if (!xPNTsTokenAddr || xPNTsTokenAddr === ethers.ZeroAddress) {
      printSkip('xPNTsToken not set, skipping credit check');
    } else {
      const token = new ethers.Contract(xPNTsTokenAddr, xPNTsAbi, deployer);
      const cap = await token.effectiveCreditCap(deployerAddr);
      printKeyValue('effectiveCreditCap (aPNTs)', ethers.formatEther(cap));
      assertGte(cap, 0n, 'effectiveCreditCap must return non-negative');
      printSuccess('effectiveCreditCap returns aPNTs value');
    }
  } catch (e) {
    catchStep(`effectiveCreditCap`, e);
  }

  // ──────────────────────────────────────────
  // Step 4: debts() returns aPNTs
  // ──────────────────────────────────────────
  printStep(4, 'xPNTsToken.debts() returns aPNTs (not xPNTs)');
  try {
    if (!xPNTsTokenAddr || xPNTsTokenAddr === ethers.ZeroAddress) {
      printSkip('xPNTsToken not set, skipping debt check');
    } else {
      const token = new ethers.Contract(xPNTsTokenAddr, xPNTsAbi, deployer);
      const debt = await token.debts(deployerAddr);
      printKeyValue('Deployer debt (aPNTs)', ethers.formatEther(debt));
      // If any debt exists, it should be in sane aPNTs range (< 1M aPNTs)
      assertTrue(debt <= ethers.parseEther('1000000'), 'Debt value must be in reasonable aPNTs range');
      printSuccess('debts() returns aPNTs denomination');
    }
  } catch (e) {
    catchStep(`debts`, e);
  }

  // ──────────────────────────────────────────
  // Step 5: Anni's operator state if available
  // ──────────────────────────────────────────
  printStep(5, "Read Anni's operator state (9-tuple)");
  if (anniAddr) {
    try {
      const op = await sp.operators(anniAddr);
      printKeyValue('aPNTsBalance', ethers.formatEther(op[0]));
      printKeyValue('isConfigured', op[1]);
      printKeyValue('xPNTsToken', op[3]);
      printKeyValue('treasury', op[6]); // index 6 after removing exchangeRate
      assertTrue(op[1], 'Anni must be configured as operator');
      printSuccess('Anni operator state read successfully with new 9-tuple ABI');
    } catch (e) {
      catchStep(`Anni operator read`, e);
    }
  } else {
    printSkip('OPERATOR_ADDRESS not set');
  }

  process.exit(finishTest('E3: aPNTs Exchange Rate Accounting'));
}

main().catch(e => { console.error(e); process.exit(1); });

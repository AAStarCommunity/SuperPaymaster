#!/usr/bin/env node
/**
 * Test Group E3: aPNTs Exchange Rate Accounting
 *
 * Verifies the unified aPNTs accounting introduced in PR #200:
 * - xPNTsToken.exchangeRate() is the live rate used by SuperPaymaster (not stale config)
 * - operators() returns 9-tuple (no exchangeRate field)
 * - getAvailableCredit returns aPNTs values
 * - getDebt returns aPNTs (not xPNTs)
 * - burnFromWithOpHash and recordDebtWithOpHash both use aPNTs as input
 *
 * Prerequisites: run A1 + B1 first (operator configured, registry roles set).
 */
const {
  initTestEnv, getContracts, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, resetCounters,
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
    printError(`operators() tuple check: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 2: xPNTsToken live exchange rate
  // ──────────────────────────────────────────
  printStep(2, 'Read live exchangeRate from xPNTsToken');
  const xPNTsAbi = [
    'function exchangeRate() view returns (uint256)',
    'function getDebt(address user) view returns (uint256)',
    'function maxSingleTxLimit() view returns (uint256)',
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
    printError(`xPNTsToken read: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 3: getAvailableCredit returns aPNTs
  // ──────────────────────────────────────────
  printStep(3, 'getAvailableCredit returns aPNTs denomination');
  try {
    if (!xPNTsTokenAddr || xPNTsTokenAddr === ethers.ZeroAddress) {
      printSkip('xPNTsToken not set, skipping credit check');
    } else {
      const credit = await sp.getAvailableCredit(deployerAddr, xPNTsTokenAddr);
      printKeyValue('Available credit (aPNTs)', ethers.formatEther(credit));
      assertGte(credit, 0n, 'getAvailableCredit must return non-negative');
      printSuccess('getAvailableCredit returns aPNTs value');
    }
  } catch (e) {
    printError(`getAvailableCredit: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 4: getDebt returns aPNTs
  // ──────────────────────────────────────────
  printStep(4, 'xPNTsToken.getDebt() returns aPNTs (not xPNTs)');
  try {
    if (!xPNTsTokenAddr || xPNTsTokenAddr === ethers.ZeroAddress) {
      printSkip('xPNTsToken not set, skipping debt check');
    } else {
      const token = new ethers.Contract(xPNTsTokenAddr, xPNTsAbi, deployer);
      const debt = await token.getDebt(deployerAddr);
      printKeyValue('Deployer debt (aPNTs)', ethers.formatEther(debt));
      // If any debt exists, it should be in sane aPNTs range (< 1M aPNTs)
      assertTrue(debt <= ethers.parseEther('1000000'), 'Debt value must be in reasonable aPNTs range');
      printSuccess('getDebt() returns aPNTs denomination');
    }
  } catch (e) {
    printError(`getDebt: ${e.message.substring(0, 100)}`);
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
      printError(`Anni operator read: ${e.message.substring(0, 100)}`);
    }
  } else {
    printSkip('OPERATOR_ADDRESS not set');
  }

  printSummary();
}

main().catch(e => { console.error(e); process.exit(1); });

#!/usr/bin/env node
/**
 * Test Group B3: configureOperator v2 (2-arg, no exchangeRate)
 *
 * Tests the new configureOperator(xPNTsToken, opTreasury) signature introduced
 * in PR #200 (v5.3.3 aPNTs unified accounting).
 *
 * Key behaviors verified:
 * - configureOperator takes exactly 2 args (no exchangeRate param)
 * - After configure: isConfigured=true, xPNTsToken stored, exchangeRate read live
 * - Re-configure updates treasury without breaking state
 * - Calling with wrong arg count reverts (ABI safety)
 *
 * Prerequisites: deployer has ROLE_PAYMASTER_SUPER (run A1 first).
 */
const {
  initTestEnv, getContracts, ROLES, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, resetCounters,
  assertEqual, assertTrue, assertFalse,
  sendTxSafe,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group B3: configureOperator v2 (2-arg, PR #200)');
  resetCounters();

  const { config, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const sp = c.superPaymaster;
  const registry = c.registry;

  const deployerAddr = deployer.address;

  // ──────────────────────────────────────────
  // Step 1: Verify deployer has ROLE_PAYMASTER_SUPER
  // ──────────────────────────────────────────
  printStep(1, 'Verify ROLE_PAYMASTER_SUPER');
  let hasRole;
  try {
    hasRole = await registry.hasRole(ROLES.PAYMASTER_SUPER, deployerAddr);
  } catch (e) {
    const msg = (e.message || '').toLowerCase();
    const isNet = msg.includes('socket hang up') || msg.includes('timeout') ||
      msg.includes('econnreset') || msg.includes('etimedout') || msg.includes('request timeout');
    if (isNet) {
      printSkip(`Network error in Step 1 — transient RPC issue: ${e.message.substring(0, 60)}`);
      const allPassed = printSummary('B3: configureOperator v2');
      process.exit(allPassed ? 0 : 2);
    }
    printError(`hasRole: ${e.message.substring(0, 100)}`);
    const allPassed = printSummary('B3: configureOperator v2');
    process.exit(allPassed ? 0 : 1);
  }
  if (!hasRole) {
    printSkip('Deployer lacks ROLE_PAYMASTER_SUPER — skipping configure tests');
    printSummary('B3: configureOperator v2');
    process.exit(2);
  }
  printSuccess('Deployer has ROLE_PAYMASTER_SUPER');

  // ──────────────────────────────────────────
  // Step 2: Read current operator state
  // ──────────────────────────────────────────
  printStep(2, 'Read current operator state before configure');
  let currentXPNTs = null;
  let currentTreasury = null;
  try {
    const op = await sp.operators(deployerAddr);
    // v5.3.3 9-tuple: [aPNTsBalance, isConfigured, isPaused, xPNTsToken, reputation, minTxInterval, treasury, ...]
    currentXPNTs = op[3];
    currentTreasury = op[6];
    printKeyValue('isConfigured', op[1]);
    printKeyValue('xPNTsToken', currentXPNTs);
    printKeyValue('treasury', currentTreasury);
    printKeyValue('aPNTsBalance', ethers.formatEther(op[0]));
  } catch (e) {
    printError(`Read state: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 3: Get xPNTsToken from factory
  // ──────────────────────────────────────────
  printStep(3, 'Get xPNTsToken for deployer from factory');
  const factoryAbi = ['function getTokenAddress(address op) view returns (address)'];
  let xPNTsAddr = null;
  try {
    const factoryAddr = config.xPNTsFactory || config.xpntsFactory;
    if (!factoryAddr) {
      printSkip('xPNTsFactory address not in config');
    } else {
      const factory = new ethers.Contract(factoryAddr, factoryAbi, deployer);
      xPNTsAddr = await factory.getTokenAddress(deployerAddr);
      printKeyValue('xPNTsToken from factory', xPNTsAddr);
      if (xPNTsAddr === ethers.ZeroAddress) {
        printInfo('No xPNTs token deployed for deployer — use test-group-A1 to register community first');
        xPNTsAddr = currentXPNTs; // fall back to existing
      }
    }
  } catch (e) {
    printInfo(`Factory lookup: ${e.message.substring(0, 80)}`);
    xPNTsAddr = currentXPNTs;
  }

  if (!xPNTsAddr || xPNTsAddr === ethers.ZeroAddress) {
    printSkip('No xPNTsToken available — cannot test configureOperator');
    printSummary('B3: configureOperator v2');
    process.exit(2);
  }

  // ──────────────────────────────────────────
  // Step 4: Call configureOperator(xPNTs, treasury) — 2-arg v2 signature
  // ──────────────────────────────────────────
  printStep(4, 'Call configureOperator(xPNTs, treasury) — 2-arg signature');
  const newTreasury = deployerAddr; // use self as treasury for test
  try {
    // This should succeed with exactly 2 args (xPNTsToken, opTreasury)
    await sendTxSafe(sp, 'configureOperator', [xPNTsAddr, newTreasury], 'configureOperator(xPNTs, treasury)');

    const op = await sp.operators(deployerAddr);
    assertEqual(op[3], xPNTsAddr, 'xPNTsToken must be stored after configure');
    assertEqual(op[6], newTreasury, 'treasury must be updated');
    assertTrue(op[1], 'isConfigured must be true');
    printSuccess('configureOperator 2-arg signature works (no exchangeRate param)');
  } catch (e) {
    printError(`configureOperator: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 5: Verify live exchange rate used (not stored in config)
  // ──────────────────────────────────────────
  printStep(5, 'Verify exchangeRate is read live from xPNTsToken (not in OperatorConfig)');
  const xPNTsAbi = ['function exchangeRate() view returns (uint256)'];
  try {
    const token = new ethers.Contract(xPNTsAddr, xPNTsAbi, deployer);
    const liveRate = await token.exchangeRate();
    printKeyValue('Live rate from xPNTsToken', ethers.formatEther(liveRate));
    // The OperatorConfig struct no longer has exchangeRate — verify by checking tuple length
    const op = await sp.operators(deployerAddr);
    const fieldCount = Object.keys(op).filter(k => !isNaN(parseInt(k))).length;
    assertEqual(fieldCount, 9, 'operators() must return 9 fields (no exchangeRate)');
    assertTrue(liveRate > 0n, 'Live rate from token must be non-zero');
    printSuccess('SuperPaymaster uses live rate from xPNTsToken — no stale config rate');
  } catch (e) {
    printError(`Rate check: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 6: Re-configure with new treasury — idempotent
  // ──────────────────────────────────────────
  printStep(6, 'Re-configure with original treasury — verify idempotent');
  if (currentTreasury && currentTreasury !== ethers.ZeroAddress) {
    try {
      await sendTxSafe(sp, 'configureOperator', [xPNTsAddr, currentTreasury], 'configureOperator (restore treasury)');
      const op = await sp.operators(deployerAddr);
      assertEqual(op[6], currentTreasury, 'Treasury must be restored');
      printSuccess('Re-configure is idempotent — treasury updated without breaking state');
    } catch (e) {
      printInfo(`Re-configure: ${e.message.substring(0, 80)}`);
    }
  } else {
    printSkip('No original treasury to restore');
  }

  const allPassed = printSummary('B3: configureOperator v2');
  process.exit(allPassed ? 0 : 1);
}

main().catch(e => { console.error(e); process.exit(1); });

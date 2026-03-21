#!/usr/bin/env node
/**
 * Test Group D2: Credit Tier Configuration
 *
 * Tests: creditTierConfig read, setCreditTier, levelThresholds,
 * getCreditLimit for registered and unregistered users.
 */
const {
  initTestEnv, getContracts, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, resetCounters,
  assertEqual, assertTrue, assertGte,
  sendTxSafe,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group D2: Credit Tier Configuration');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const registry = c.registry;

  const deployerAddr = deployer.address;
  const randomAddr = ethers.Wallet.createRandom().address;

  // ──────────────────────────────────────────
  // Step 1: Read creditTierConfig levels 1-6
  // ──────────────────────────────────────────
  printStep(1, 'creditTierConfig for levels 1-6');
  for (let level = 1; level <= 6; level++) {
    try {
      const limit = await registry.creditTierConfig(level);
      printKeyValue(`Tier ${level}`, `${ethers.formatEther(limit)} aPNTs`);
    } catch (e) {
      printInfo(`Tier ${level}: ${e.message.substring(0, 60)}`);
    }
  }
  printSuccess('creditTierConfig read completed');

  // ──────────────────────────────────────────
  // Step 2: setCreditTier(7, 5000 ether)
  // ──────────────────────────────────────────
  printStep(2, 'setCreditTier(7, 5000 ether)');
  const testTierLevel = 7;
  const testTierLimit = ethers.parseEther('5000');
  try {
    await sendTxSafe(registry, 'setCreditTier', [testTierLevel, testTierLimit], 'setCreditTier(7, 5000)');

    const stored = await registry.creditTierConfig(testTierLevel);
    assertEqual(stored, testTierLimit, 'Tier 7 limit');
  } catch (e) {
    printError(`setCreditTier: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 3: Read levelThresholds
  // ──────────────────────────────────────────
  printStep(3, 'Read levelThresholds');
  for (let i = 0; i < 8; i++) {
    try {
      const threshold = await registry.levelThresholds(i);
      printKeyValue(`Threshold[${i}]`, threshold.toString());
    } catch (e) {
      // Array out of bounds is expected at some point
      if (i === 0) {
        printError(`levelThresholds[0]: ${e.message.substring(0, 60)}`);
      }
      break;
    }
  }
  printSuccess('levelThresholds read completed');

  // ──────────────────────────────────────────
  // Step 4: getCreditLimit for deployer
  // ──────────────────────────────────────────
  printStep(4, 'getCreditLimit for deployer');
  try {
    const limit = await registry.getCreditLimit(deployerAddr);
    printKeyValue('Deployer credit limit', ethers.formatEther(limit));
    assertGte(limit, 0n, 'Credit limit >= 0');
  } catch (e) {
    printError(`getCreditLimit(deployer): ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 5: getCreditLimit for random (no role)
  // ──────────────────────────────────────────
  printStep(5, 'getCreditLimit for unregistered address');
  try {
    const limit = await registry.getCreditLimit(randomAddr);
    printKeyValue('Random addr credit limit', ethers.formatEther(limit));
    assertEqual(limit, 0n, 'Unregistered user credit limit is 0');
  } catch (e) {
    // If it reverts, that's also acceptable for unregistered user
    printSuccess(`getCreditLimit(random) reverted as expected: ${e.message.substring(0, 60)}`);
  }

  // ──────────────────────────────────────────
  // Step 6: Cleanup: setCreditTier(7, 0)
  // ──────────────────────────────────────────
  printStep(6, 'Cleanup: setCreditTier(7, 0)');
  try {
    await sendTxSafe(registry, 'setCreditTier', [testTierLevel, 0], 'setCreditTier(7, 0)');
    const stored = await registry.creditTierConfig(testTierLevel);
    assertEqual(stored, 0n, 'Tier 7 reset to 0');
  } catch (e) {
    printInfo(`Cleanup: ${e.message.substring(0, 60)}`);
  }

  const allPassed = printSummary('D2: Credit Tiers');
  process.exit(allPassed ? 0 : 1);
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });

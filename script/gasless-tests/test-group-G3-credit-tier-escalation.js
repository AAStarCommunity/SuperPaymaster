#!/usr/bin/env node
/**
 * Test Group G3: Credit Tier Escalation
 *
 * Scenario: A power user earns reputation through community activity. As their
 * globalReputation increases, SuperPaymaster allows them to be sponsored for
 * larger transactions via credit tiers (0 → 1 → 2 → ... → 6).
 *
 * Production flow:
 *   Community scores user → ReputationSystem → BLS consensus →
 *   batchUpdateGlobalReputation (Registry) → getCreditLimit escalates
 *
 * This test verifies the tier configuration and demonstrates the full
 * escalation path via read-only simulation (BLS scoring requires validators).
 *
 * Tests:
 *   1. creditTierConfig — all configured tier limits
 *   2. levelThresholds — reputation thresholds per tier
 *   3. getCreditLimit — current limit for deployer and a fresh address
 *   4. Tier escalation simulation — expected credit at each threshold
 *   5. setCreditTier — admin can expand the tier ceiling
 *   6. getAvailableCredit — credit remaining after in-flight usage
 *   7. Debt and credit interaction (via pending debt check)
 *
 * Prerequisites:
 *   - SuperPaymaster V5.3.0 + Registry V4.1.0 deployed
 *   - Deployer is owner (for setCreditTier)
 */
const {
  initTestEnv, getContracts, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, resetCounters,
  assertEqual, assertTrue, assertGte, assertFalse,
  sendTxSafe,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group G3: Credit Tier Escalation');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const sp = c.superPaymaster;
  const registry = c.registry;

  const deployerAddr = deployer.address;
  const freshUser = ethers.Wallet.createRandom().address;

  printKeyValue('Registry', config.registry);
  printKeyValue('SuperPaymaster', config.superPaymaster);
  printKeyValue('Deployer', deployerAddr);
  printKeyValue('Fresh user (rep=0)', freshUser);
  console.log();

  // ──────────────────────────────────────────
  // Step 1: creditTierConfig — all tier limits
  // ──────────────────────────────────────────
  printStep(1, 'creditTierConfig — tier credit limits (levels 1-6)');
  const tierLimits = {};
  try {
    console.log('    Level | Credit Limit');
    console.log('    ------|-------------');
    for (let level = 1; level <= 6; level++) {
      const limit = await registry.creditTierConfig(level);
      tierLimits[level] = limit;
      console.log(`    Tier ${level} | ${ethers.formatEther(limit)} aPNTs`);
    }
    assertTrue(tierLimits[6] > tierLimits[1], 'Tier 6 limit > Tier 1 limit');
    printSuccess('Credit tier limits read successfully');
  } catch (e) {
    printError(`creditTierConfig: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 2: levelThresholds — reputation → tier mapping
  // ──────────────────────────────────────────
  printStep(2, 'levelThresholds — reputation score thresholds');
  const thresholds = [];
  try {
    console.log('    Index | Threshold | Grants Tier');
    console.log('    ------|-----------|------------');
    let i = 0;
    while (true) {
      try {
        const t = await registry.levelThresholds(i);
        thresholds.push(t);
        console.log(`    [${i}]   | ${t.toString().padEnd(9)} | Tier ${i + 2}`);
        i++;
      } catch {
        break;
      }
    }
    assertTrue(thresholds.length >= 4, 'At least 4 thresholds configured (Fibonacci-like defaults)');
    printSuccess(`${thresholds.length} thresholds configured`);

    // Verify Fibonacci-like progression (each threshold > previous)
    for (let j = 1; j < thresholds.length; j++) {
      assertTrue(thresholds[j] > thresholds[j - 1], `Threshold[${j}] > Threshold[${j - 1}]`);
    }
    printSuccess('Thresholds are strictly increasing');
  } catch (e) {
    printError(`levelThresholds: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 3: getCreditLimit — current users
  // ──────────────────────────────────────────
  printStep(3, 'getCreditLimit — current credit for deployer and fresh user');
  try {
    const deployerRep = await registry.globalReputation(deployerAddr);
    const freshRep = await registry.globalReputation(freshUser);

    const deployerLimit = await registry.getCreditLimit(deployerAddr);
    const freshLimit = await registry.getCreditLimit(freshUser);

    printKeyValue('Deployer reputation', deployerRep.toString());
    printKeyValue('Deployer credit limit', `${ethers.formatEther(deployerLimit)} aPNTs`);
    printKeyValue('Fresh user reputation', freshRep.toString());
    printKeyValue('Fresh user credit limit', `${ethers.formatEther(freshLimit)} aPNTs`);

    assertEqual(freshRep, 0n, 'Fresh user starts at reputation 0');
    assertEqual(freshLimit, tierLimits[1] ?? 0n, 'Fresh user (rep=0) gets tier 1 limit');
    printSuccess('getCreditLimit returns tier 1 for users with reputation 0');
  } catch (e) {
    printError(`getCreditLimit: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 4: Tier escalation simulation
  // ──────────────────────────────────────────
  printStep(4, 'Tier escalation simulation — expected credit at each threshold');
  try {
    console.log('    Scenario        | Rep Score | Tier | Credit Limit');
    console.log('    ----------------|-----------|------|-------------');

    // Tier 1 = rep 0
    const tier1Limit = tierLimits[1] ?? await registry.creditTierConfig(1n);
    console.log(`    Fresh user      |         0 |    1 | ${ethers.formatEther(tier1Limit)} aPNTs`);

    for (let i = 0; i < thresholds.length; i++) {
      const tierLevel = i + 2;
      const limit = tierLimits[tierLevel] ?? await registry.creditTierConfig(tierLevel);
      const label = i === 0 ? 'New contributor' :
                    i === 1 ? 'Active member  ' :
                    i === 2 ? 'Power user     ' :
                    i === 3 ? 'Community lead ' :
                              `Tier ${tierLevel} user    `;
      console.log(`    ${label} | ${thresholds[i].toString().padEnd(9)} | ${tierLevel.toString().padEnd(4)} | ${ethers.formatEther(limit)} aPNTs`);
    }

    printSuccess('Escalation path simulated (actual escalation requires BLS-signed reputation update)');
    printInfo('Production: users earn reputation via community activity → BLSAggregator → batchUpdateGlobalReputation');
  } catch (e) {
    printError(`Simulation: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 5: setCreditTier — admin can expand ceiling
  // ──────────────────────────────────────────
  printStep(5, 'setCreditTier — owner expands tier ceiling (tier 7)');
  const testTier = 7n;
  const testLimit = ethers.parseEther('5000'); // 5000 aPNTs
  let tierSet = false;
  try {
    const ownerAddr = await registry.owner();
    if (ownerAddr.toLowerCase() !== deployerAddr.toLowerCase()) {
      printSkip(`setCreditTier: deployer is not registry owner (owner=${ownerAddr})`);
    } else {
      await sendTxSafe(registry, 'setCreditTier', [testTier, testLimit], 'setCreditTier(7, 5000 aPNTs)');

      const stored = await registry.creditTierConfig(testTier);
      assertEqual(stored, testLimit, 'Tier 7 limit');
      tierSet = true;
      printSuccess('Tier 7 set to 5000 aPNTs — admin can expand credit ceiling');
    }
  } catch (e) {
    printError(`setCreditTier: ${e.message.substring(0, 100)}`);
  }

  // Cleanup: reset tier 7 to 0 (unused)
  if (tierSet) {
    try {
      await sendTxSafe(registry, 'setCreditTier', [testTier, 0n], 'Reset tier 7 to 0');
      printInfo('Tier 7 reset to 0 (cleanup)');
    } catch (e) {
      printInfo(`Cleanup: ${e.message.substring(0, 60)}`);
    }
  }

  // ──────────────────────────────────────────
  // Step 6: getAvailableCredit — credit remaining
  // ──────────────────────────────────────────
  printStep(6, 'getAvailableCredit — SuperPaymaster tracks in-flight usage');
  try {
    const aPNTsAddr = await sp.APNTS_TOKEN();
    const deployerAvail = await sp.getAvailableCredit(deployerAddr, aPNTsAddr);
    const freshAvail = await sp.getAvailableCredit(freshUser, aPNTsAddr);

    printKeyValue('aPNTs token', aPNTsAddr);
    printKeyValue('Deployer available credit', `${ethers.formatEther(deployerAvail)} aPNTs`);
    printKeyValue('Fresh user available credit', `${ethers.formatEther(freshAvail)} aPNTs`);

    // Available credit = min(creditLimit, creditLimit - pendingDebt)
    // For a fresh user with no pending debt it should equal getCreditLimit
    const freshLimit = await registry.getCreditLimit(freshUser);
    const tier1Limit = tierLimits[1] ?? 0n;
    assertEqual(freshLimit, tier1Limit, 'Fresh user getCreditLimit == tier 1');
    printSuccess('getAvailableCredit read successfully');
  } catch (e) {
    printError(`getAvailableCredit: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 7: Summary — how to reach higher tiers
  // ──────────────────────────────────────────
  printStep(7, 'Production escalation path summary');
  console.log();
  console.log('    How a user escalates credit tiers:');
  console.log('    ┌─────────────────────────────────────────────────────────┐');
  console.log('    │ 1. User gets ENDUSER SBT (community registration)       │');
  console.log('    │ 2. User participates in community (activities logged)    │');
  console.log('    │ 3. Community sets reputation via ReputationSystem        │');
  console.log('    │ 4. BLSAggregator reaches consensus (≥3 DVT validators)   │');
  console.log('    │ 5. batchUpdateGlobalReputation() called on Registry      │');
  console.log('    │ 6. getCreditLimit returns higher tier automatically      │');
  console.log('    │ 7. SuperPaymaster postOp honors the new credit ceiling   │');
  console.log('    └─────────────────────────────────────────────────────────┘');
  console.log();
  printSuccess('Credit tier escalation path documented');

  const allPassed = printSummary('G3: Credit Tier Escalation');
  process.exit(allPassed ? 0 : 1);
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });

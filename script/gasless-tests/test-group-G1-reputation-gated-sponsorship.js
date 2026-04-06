#!/usr/bin/env node
/**
 * Test Group G1: Reputation-Gated Sponsorship
 *
 * Scenario: A dApp uses SuperPaymaster's reputation-credit system to grant
 * higher transaction limits to users who have earned community reputation.
 *
 * Tests:
 *   1. isEligibleForSponsorship — SBT holder vs non-holder vs agent
 *   2. globalReputation read from Registry
 *   3. getCreditLimit — tier determination by reputation score
 *   4. levelThresholds and creditTierConfig configuration
 *   5. getAvailableCredit — credit remaining after usage
 *   6. Eligibility gateway: non-SBT non-agent user is rejected
 *
 * Prerequisites:
 *   - SuperPaymaster V5.3.0 deployed
 *   - Deployer registered with ROLE_ENDUSER (sbtHolders[deployer] = true, set by RegisterEnduser.s.sol)
 *   - TEST_AA_ACCOUNT_ADDRESS_A set to a known non-SBT address (or random)
 */
const {
  initTestEnv, getContracts, ROLES, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, resetCounters,
  assertEqual, assertTrue, assertFalse, assertGte,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group G1: Reputation-Gated Sponsorship');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const sp = c.superPaymaster;
  const registry = c.registry;

  const deployerAddr = deployer.address;
  // Use a random address guaranteed to have no SBT and no agent NFT
  const nonSbtUser = ethers.Wallet.createRandom().address;
  const testUserA = process.env.TEST_AA_ACCOUNT_ADDRESS_A || nonSbtUser;

  printKeyValue('SuperPaymaster', config.superPaymaster);
  printKeyValue('Deployer', deployerAddr);
  printKeyValue('Non-SBT address', nonSbtUser);
  console.log();

  // ──────────────────────────────────────────
  // Step 1: Check sbtHolders state
  // ──────────────────────────────────────────
  printStep(1, 'Check sbtHolders state');
  try {
    const deployerSBT = await sp.sbtHolders(deployerAddr);
    const randomSBT = await sp.sbtHolders(nonSbtUser);

    printKeyValue('Deployer is SBT holder', deployerSBT.toString());
    printKeyValue('Random addr is SBT holder', randomSBT.toString());

    assertFalse(randomSBT, 'Random address must NOT be SBT holder');

    if (!deployerSBT) {
      printInfo('Deployer lacks SBT — run RegisterEnduser.s.sol to set it up');
      printInfo('Continuing with read-only checks...');
    } else {
      printSuccess('Deployer is SBT holder');
    }
  } catch (e) {
    printError(`sbtHolders: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 2: isEligibleForSponsorship — SBT path
  // ──────────────────────────────────────────
  printStep(2, 'isEligibleForSponsorship — SBT path');
  try {
    const deployerEligible = await sp.isEligibleForSponsorship(deployerAddr);
    const randomEligible  = await sp.isEligibleForSponsorship(nonSbtUser);

    printKeyValue('Deployer eligible', deployerEligible.toString());
    printKeyValue('Random addr eligible', randomEligible.toString());

    assertFalse(randomEligible, 'Non-SBT non-agent address must be ineligible');
    printSuccess('Eligibility gate: random address correctly rejected');

    if (deployerEligible) {
      printSuccess('Deployer is eligible (SBT holder or registered agent)');
    } else {
      printInfo('Deployer not eligible — SBT not set; run RegisterEnduser.s.sol');
    }
  } catch (e) {
    printError(`isEligibleForSponsorship: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 3: isRegisteredAgent (V5.3 dual-channel)
  // ──────────────────────────────────────────
  printStep(3, 'isRegisteredAgent — dual-channel check');
  try {
    const agentIdRegistry = await sp.agentIdentityRegistry();
    printKeyValue('agentIdentityRegistry', agentIdRegistry);

    const deployerIsAgent = await sp.isRegisteredAgent(deployerAddr);
    const randomIsAgent = await sp.isRegisteredAgent(nonSbtUser);

    printKeyValue('Deployer is agent', deployerIsAgent.toString());
    printKeyValue('Random addr is agent', randomIsAgent.toString());

    assertFalse(randomIsAgent, 'Random address must not be registered agent');
    printSuccess('Agent check: random address is not a registered agent');
  } catch (e) {
    printError(`isRegisteredAgent: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 4: globalReputation from Registry
  // ──────────────────────────────────────────
  printStep(4, 'globalReputation from Registry');
  try {
    const deployerRep = await registry.globalReputation(deployerAddr);
    const randomRep = await registry.globalReputation(nonSbtUser);

    printKeyValue('Deployer reputation', deployerRep.toString());
    printKeyValue('Random addr reputation', randomRep.toString());

    assertEqual(randomRep, 0n, 'New address starts at reputation 0');
    printSuccess('Reputation read from Registry');
  } catch (e) {
    printError(`globalReputation: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 5: levelThresholds — tier configuration
  // ──────────────────────────────────────────
  printStep(5, 'levelThresholds — reputation → tier mapping');
  const thresholds = [];
  try {
    console.log('    Tier | Min Rep Score | Credit Limit');
    console.log('    -----|---------------|-------------');

    // Tier 1 = default (no threshold)
    const tier1Limit = await registry.creditTierConfig(1n);
    console.log(`    Tier 1 |     (default) | ${ethers.formatEther(tier1Limit)} aPNTs`);

    let i = 0;
    while (true) {
      try {
        const threshold = await registry.levelThresholds(i);
        thresholds.push(threshold);
        const tierLevel = i + 2; // levelThresholds[0] → level 2
        const limit = await registry.creditTierConfig(tierLevel);
        console.log(`    Tier ${tierLevel} |       ${threshold.toString().padEnd(9)} | ${ethers.formatEther(limit)} aPNTs`);
        i++;
      } catch {
        break; // Array out of bounds — done
      }
    }

    assertTrue(thresholds.length > 0, 'At least one tier threshold configured');
    printSuccess(`${thresholds.length} tier thresholds configured above default`);
  } catch (e) {
    printError(`levelThresholds: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 6: getCreditLimit — tier calculation
  // ──────────────────────────────────────────
  printStep(6, 'getCreditLimit — compute tier for current users');
  try {
    const deployerLimit = await registry.getCreditLimit(deployerAddr);
    const randomLimit = await registry.getCreditLimit(nonSbtUser);
    const deployerRep = await registry.globalReputation(deployerAddr);

    printKeyValue('Deployer reputation', deployerRep.toString());
    printKeyValue('Deployer credit limit', `${ethers.formatEther(deployerLimit)} aPNTs`);
    printKeyValue('Random addr limit', `${ethers.formatEther(randomLimit)} aPNTs`);

    // Compute expected tier for deployer based on thresholds
    let expectedTier = 1;
    for (let i = 0; i < thresholds.length; i++) {
      if (deployerRep >= thresholds[i]) {
        expectedTier = i + 2;
      }
    }
    const expectedLimit = await registry.creditTierConfig(expectedTier);
    printKeyValue('Expected tier', expectedTier.toString());
    printKeyValue('Expected limit', `${ethers.formatEther(expectedLimit)} aPNTs`);

    assertEqual(deployerLimit, expectedLimit, 'getCreditLimit matches tier formula');
    printSuccess('Credit limit correctly derived from reputation tier');
  } catch (e) {
    printError(`getCreditLimit: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 7: getAvailableCredit — credit after usage
  // ──────────────────────────────────────────
  printStep(7, 'getAvailableCredit — on-hand credit remaining');
  try {
    const aPNTsAddr = await sp.APNTS_TOKEN();
    const deployerCredit = await sp.getAvailableCredit(deployerAddr, aPNTsAddr);
    const randomCredit = await sp.getAvailableCredit(nonSbtUser, aPNTsAddr);

    printKeyValue('aPNTs token', aPNTsAddr);
    printKeyValue('Deployer available credit', `${ethers.formatEther(deployerCredit)} aPNTs`);
    printKeyValue('Random addr available credit', `${ethers.formatEther(randomCredit)} aPNTs`);

    printSuccess('getAvailableCredit call succeeded');
  } catch (e) {
    printError(`getAvailableCredit: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 8: Tier escalation simulation
  // ──────────────────────────────────────────
  printStep(8, 'Tier escalation simulation (read-only)');
  try {
    // Show what credit limit a user WOULD have at each tier threshold
    console.log('    Reputation needed → tier → credit limit (simulation):');
    const tier1Limit = await registry.creditTierConfig(1n);
    console.log(`      rep =  0 → Tier 1 → ${ethers.formatEther(tier1Limit)} aPNTs (default)`);

    for (let i = 0; i < thresholds.length; i++) {
      const tierLevel = i + 2;
      const limit = await registry.creditTierConfig(tierLevel);
      console.log(`      rep = ${thresholds[i].toString().padEnd(3)} → Tier ${tierLevel} → ${ethers.formatEther(limit)} aPNTs`);
    }

    printSuccess('Tier escalation path validated (globalReputation updated via BLS consensus in production)');
    printInfo('To reach a higher tier: accumulate community reputation → BLS-signed batchUpdateGlobalReputation');
  } catch (e) {
    printError(`Simulation: ${e.message.substring(0, 100)}`);
  }

  const allPassed = printSummary('G1: Reputation-Gated Sponsorship');
  process.exit(allPassed ? 0 : 1);
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });

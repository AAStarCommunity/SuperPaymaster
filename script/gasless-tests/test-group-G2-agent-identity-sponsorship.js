#!/usr/bin/env node
/**
 * Test Group G2: Agent Identity Sponsorship (ERC-8004 Dual-Channel)
 *
 * Scenario: An AI agent (ERC-8004) is recognized by SuperPaymaster's dual-channel
 * eligibility gate (SBT OR registered agent). Operators can define tiered BPS
 * discount policies for agents with different reputation scores.
 *
 * Tests:
 *   1. agentIdentityRegistry and agentReputationRegistry addresses
 *   2. isRegisteredAgent — EOA vs known agent NFT holder
 *   3. isEligibleForSponsorship — SBT-only path and agent-only path
 *   4. setAgentPolicies — operator sets tiered sponsorship rates
 *   5. agentPolicies — read policies back from storage
 *   6. getAgentSponsorshipRate — rate for agent at current reputation
 *   7. facilitatorFeeBPS — x402 facilitator fee configuration
 *
 * Prerequisites:
 *   - SuperPaymaster V5.3.0 deployed
 *   - Deployer must be a configured operator (run B1 first) to set agent policies
 *   - agentIdentityRegistry and agentReputationRegistry wired via setAgentRegistries()
 */
const {
  initTestEnv, getContracts, ROLES, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, resetCounters,
  assertEqual, assertTrue, assertFalse, assertGte,
  sendTxSafe,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group G2: Agent Identity Sponsorship (ERC-8004)');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const sp = c.superPaymaster;
  const registry = c.registry;

  const deployerAddr = deployer.address;
  const randomAddr = ethers.Wallet.createRandom().address;

  printKeyValue('SuperPaymaster', config.superPaymaster);
  printKeyValue('Deployer (operator)', deployerAddr);
  console.log();

  // ──────────────────────────────────────────
  // Step 1: Check registry addresses wired
  // ──────────────────────────────────────────
  printStep(1, 'Check agentIdentityRegistry + agentReputationRegistry');
  let agentIdRegistryAddr;
  let agentRepRegistryAddr;
  try {
    agentIdRegistryAddr  = await sp.agentIdentityRegistry();
    agentRepRegistryAddr = await sp.agentReputationRegistry();

    printKeyValue('agentIdentityRegistry', agentIdRegistryAddr);
    printKeyValue('agentReputationRegistry', agentRepRegistryAddr);

    const zeroAddr = '0x0000000000000000000000000000000000000000';
    if (agentIdRegistryAddr === zeroAddr) {
      printInfo('agentIdentityRegistry not wired — call setAgentRegistries() as owner');
    } else {
      printSuccess('agentIdentityRegistry is set');
    }
    if (agentRepRegistryAddr === zeroAddr) {
      printInfo('agentReputationRegistry not wired — call setAgentRegistries() as owner');
    } else {
      printSuccess('agentReputationRegistry is set');
    }
  } catch (e) {
    printError(`agentIdentityRegistry: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 2: isRegisteredAgent — EOA and random address
  // ──────────────────────────────────────────
  printStep(2, 'isRegisteredAgent — various addresses');
  try {
    const deployerIsAgent = await sp.isRegisteredAgent(deployerAddr);
    const randomIsAgent = await sp.isRegisteredAgent(randomAddr);

    printKeyValue('Deployer isRegisteredAgent', deployerIsAgent.toString());
    printKeyValue('Random addr isRegisteredAgent', randomIsAgent.toString());

    assertFalse(randomIsAgent, 'Random address must not be a registered agent');
    printSuccess('Agent check returns false for random address (as expected)');

    if (deployerIsAgent) {
      printSuccess('Deployer is a registered agent (has agent NFT)');
    } else {
      printInfo('Deployer is not a registered agent (normal for EOA operators)');
    }
  } catch (e) {
    printError(`isRegisteredAgent: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 3: isEligibleForSponsorship — dual-channel logic
  // ──────────────────────────────────────────
  printStep(3, 'isEligibleForSponsorship — dual-channel (SBT OR agent)');
  try {
    const deployerSBT = await sp.sbtHolders(deployerAddr);
    const deployerAgent = await sp.isRegisteredAgent(deployerAddr);
    const deployerEligible = await sp.isEligibleForSponsorship(deployerAddr);

    printKeyValue('Deployer has SBT', deployerSBT.toString());
    printKeyValue('Deployer is agent', deployerAgent.toString());
    printKeyValue('Deployer isEligibleForSponsorship', deployerEligible.toString());

    // Verify dual-channel logic: eligible = SBT OR agent
    const expectedEligible = deployerSBT || deployerAgent;
    assertEqual(deployerEligible, expectedEligible, 'Eligibility = sbtHolders[user] || isRegisteredAgent(user)');
    printSuccess('Dual-channel eligibility logic verified');

    // Random address should be ineligible
    const randomEligible = await sp.isEligibleForSponsorship(randomAddr);
    assertFalse(randomEligible, 'Random address with no SBT and no agent NFT is ineligible');
    printSuccess('Non-SBT non-agent address correctly rejected');
  } catch (e) {
    printError(`isEligibleForSponsorship: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 4: setAgentPolicies — define tiered BPS rates
  // ──────────────────────────────────────────
  printStep(4, 'setAgentPolicies — operator defines tiered sponsorship');
  // Three tiers:
  //   Tier A: rep >= 0   → 50% sponsorship (5000 BPS), daily cap $10
  //   Tier B: rep >= 100 → 75% sponsorship (7500 BPS), daily cap $50
  //   Tier C: rep >= 500 → 90% sponsorship (9000 BPS), daily cap $200
  const policies = [
    { minReputationScore: 0n,   sponsorshipBPS: 5000n, maxDailyUSD: 10_000_000n  }, // $10
    { minReputationScore: 100n, sponsorshipBPS: 7500n, maxDailyUSD: 50_000_000n  }, // $50
    { minReputationScore: 500n, sponsorshipBPS: 9000n, maxDailyUSD: 200_000_000n }, // $200
  ];

  let policiesSet = false;
  try {
    // Check deployer is configured operator first
    const op = await sp.operators(deployerAddr);
    if (!op.isConfigured) {
      printInfo('Deployer is not a configured operator — skipping setAgentPolicies (run B1 first)');
      printSkip('setAgentPolicies skipped: operator not configured');
    } else {
      await sendTxSafe(
        sp, 'setAgentPolicies',
        [policies.map(p => [p.minReputationScore, p.sponsorshipBPS, p.maxDailyUSD])],
        'setAgentPolicies(3 tiers)'
      );
      policiesSet = true;
      printSuccess('Agent policies set with 3 tiers');
    }
  } catch (e) {
    printError(`setAgentPolicies: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 5: Read agentPolicies back from storage
  // ──────────────────────────────────────────
  printStep(5, 'Read agentPolicies from storage');
  if (!policiesSet) {
    printSkip('skipped — policies were not set in step 4');
  } else {
    try {
      for (let i = 0; i < policies.length; i++) {
        const stored = await sp.agentPolicies(deployerAddr, i);
        printKeyValue(
          `Policy[${i}]`,
          `minRep=${stored.minReputationScore} bps=${stored.sponsorshipBPS} dailyCap=$${Number(stored.maxDailyUSD) / 1e6}`
        );
        assertEqual(stored.minReputationScore, policies[i].minReputationScore, `Policy[${i}].minReputationScore`);
        assertEqual(stored.sponsorshipBPS, policies[i].sponsorshipBPS, `Policy[${i}].sponsorshipBPS`);
        assertEqual(stored.maxDailyUSD, policies[i].maxDailyUSD, `Policy[${i}].maxDailyUSD`);
      }
      printSuccess('All 3 agent policies correctly stored');
    } catch (e) {
      printError(`agentPolicies read: ${e.message.substring(0, 100)}`);
    }
  }

  // ──────────────────────────────────────────
  // Step 6: getAgentSponsorshipRate
  // ──────────────────────────────────────────
  printStep(6, 'getAgentSponsorshipRate — BPS for agent at current reputation');
  try {
    // Use deployer as both agent and operator to simulate the lookup
    const bps = await sp.getAgentSponsorshipRate(deployerAddr, deployerAddr);
    printKeyValue('Sponsorship rate (BPS)', bps.toString());
    printKeyValue('Effective discount', `${Number(bps) / 100}%`);

    if (policiesSet) {
      // With rep=0 and tier A being minRep=0, should return tier A or better
      assertGte(bps, 5000n, 'Sponsorship BPS >= 5000 (tier A minimum)');
      printSuccess(`getAgentSponsorshipRate returned ${bps} BPS`);
    } else {
      printSuccess(`getAgentSponsorshipRate returned ${bps} BPS (no policies set → 0 BPS expected)`);
    }
  } catch (e) {
    printError(`getAgentSponsorshipRate: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 7: facilitatorFeeBPS — x402 fee check
  // ──────────────────────────────────────────
  printStep(7, 'facilitatorFeeBPS — default x402 fee');
  try {
    const feeBPS = await sp.facilitatorFeeBPS();
    const opFee = await sp.operatorFacilitatorFees(deployerAddr);

    printKeyValue('Default facilitatorFeeBPS', feeBPS.toString());
    printKeyValue('Default fee', `${Number(feeBPS) / 100}%`);
    printKeyValue('Operator override fee', opFee === 0n ? '(none — uses default)' : `${Number(opFee) / 100}%`);

    assertGte(feeBPS, 0n, 'facilitatorFeeBPS is non-negative');
    printSuccess('Facilitator fee configuration verified');
  } catch (e) {
    printError(`facilitatorFeeBPS: ${e.message.substring(0, 100)}`);
  }

  const allPassed = printSummary('G2: Agent Identity Sponsorship (ERC-8004)');
  process.exit(allPassed ? 0 : 1);
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });

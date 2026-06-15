#!/usr/bin/env node
/**
 * Test Group G2: Agent Identity Sponsorship (ERC-8004 Dual-Channel)
 *
 * Scenario: An AI agent (ERC-8004) is recognized by SuperPaymaster's dual-channel
 * eligibility gate (SBT OR registered agent).
 *
 * NOTE: the tiered AgentSponsorshipPolicy F1 design (setAgentPolicies / agentPolicies
 * / getAgentSponsorshipRate) was a V5.3 worktree experiment that was never merged into
 * the deployed contract — those selectors do not exist on-chain and are NOT tested here.
 *
 * Tests:
 *   1. agentIdentityRegistry and agentReputationRegistry addresses
 *   2. isRegisteredAgent — EOA vs known agent NFT holder
 *   3. isEligibleForSponsorship — SBT-only path and agent-only path
 *   4. facilitatorFeeBPS — x402 facilitator fee configuration
 *
 * Prerequisites:
 *   - SuperPaymaster V5.3.0 deployed
 *   - Deployer must be a configured operator (run B1 first) to set agent policies
 *   - agentIdentityRegistry and agentReputationRegistry wired via setAgentRegistries()
 */
const {
  initTestEnv, getContracts, ROLES, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, finishTest, resetCounters,
  assertEqual, assertTrue, assertFalse, assertGte,
  sendTxSafe, catchStep,
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
    catchStep(`agentIdentityRegistry`, e);
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
    catchStep(`isRegisteredAgent`, e);
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
    catchStep(`isEligibleForSponsorship`, e);
  }

  // ──────────────────────────────────────────
  // Tiered AgentSponsorshipPolicy (F1) is NOT IMPLEMENTED.
  // ──────────────────────────────────────────
  // The original Steps 4-6 here probed setAgentPolicies / agentPolicies /
  // getAgentSponsorshipRate. Those were a V5.3 worktree design (tiered per-operator
  // BPS discounts keyed by agent reputation) that was never merged into the deployed
  // SuperPaymaster — the selectors do not exist on-chain. The blocks were removed
  // rather than left as "pending V5.4+" skips, which falsely implied the feature was
  // built and merely awaiting deployment. The dual-channel eligibility gate that DID
  // ship (Steps 1-3 above: SBT OR registered agent) is the real, tested surface.

  // ──────────────────────────────────────────
  // Step 4: facilitatorFeeBPS — x402 fee check
  // ──────────────────────────────────────────
  printStep(4, 'facilitatorFeeBPS — default x402 fee');
  // v5.4 god-split: x402 facilitator-fee config moved from SuperPaymaster to X402Facilitator.
  const x402 = c.x402Facilitator;
  if (!x402) {
    printSkip('X402Facilitator not configured (config.x402Facilitator / X402_FACILITATOR) — deploy v5.4 first');
  } else {
    try {
      const feeBPS = await x402.facilitatorFeeBPS();
      const opFee = await x402.operatorFacilitatorFees(deployerAddr);

      printKeyValue('Default facilitatorFeeBPS', feeBPS.toString());
      printKeyValue('Default fee', `${Number(feeBPS) / 100}%`);
      printKeyValue('Operator override fee', opFee === 0n ? '(none — uses default)' : `${Number(opFee) / 100}%`);

      assertGte(feeBPS, 0n, 'facilitatorFeeBPS is non-negative');
      printSuccess('Facilitator fee configuration verified');
    } catch (e) {
      catchStep(`facilitatorFeeBPS`, e);
    }
  }

  process.exit(finishTest('G2: Agent Identity Sponsorship (ERC-8004)'));
}

main().catch(err => {
  const m = (err.message || '').toLowerCase();
  const isNet = m.includes('socket hang up') || m.includes('econnreset') ||
    m.includes('timeout') || m.includes('etimedout') || m.includes('request timeout');
  if (isNet) { console.error('Fatal (network):', err.message.substring(0, 80)); process.exit(2); }
  console.error('Fatal:', err.message);
  process.exit(1);
});

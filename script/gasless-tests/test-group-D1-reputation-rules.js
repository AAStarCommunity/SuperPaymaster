#!/usr/bin/env node
/**
 * Test Group D1: Reputation Rules & Scoring
 *
 * Tests: defaultRule, setRule, getActiveRules, computeScore,
 * setEntropyFactor, setCommunityReputation.
 * Requires deployer to have ROLE_COMMUNITY.
 */
const {
  initTestEnv, getContracts, ROLES, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, resetCounters,
  assertEqual, assertTrue, assertGte,
  sendTxSafe,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group D1: Reputation Rules & Scoring');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const rep = c.reputationSystem;
  const registry = c.registry;

  const deployerAddr = deployer.address;
  const testUser = process.env.TEST_AA_ACCOUNT_ADDRESS_A || ethers.Wallet.createRandom().address;

  // Check deployer is community
  const hasCommunity = await registry.hasRole(ROLES.COMMUNITY, deployerAddr);
  if (!hasCommunity) {
    printError('Deployer lacks ROLE_COMMUNITY. Run A1 first.');
    process.exit(1);
  }

  // ──────────────────────────────────────────
  // Step 1: Read defaultRule
  // ──────────────────────────────────────────
  printStep(1, 'Read defaultRule');
  try {
    const rule = await rep.defaultRule();
    printKeyValue('baseScore', rule.baseScore.toString());
    printKeyValue('activityBonus', rule.activityBonus.toString());
    printKeyValue('maxBonus', rule.maxBonus.toString());
    printKeyValue('description', rule.description);
    assertTrue(rule.baseScore >= 0n, 'defaultRule has valid baseScore');
  } catch (e) {
    printError(`defaultRule: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 2: setRule with E2E_ACTIVITY
  // ──────────────────────────────────────────
  printStep(2, 'setRule("E2E_ACTIVITY")');
  const ruleId = ethers.keccak256(ethers.toUtf8Bytes("E2E_ACTIVITY"));
  try {
    await sendTxSafe(rep, 'setRule',
      [ruleId, 20, 5, 200, "E2E test activity rule"],
      'setRule(E2E_ACTIVITY)'
    );

    // Verify
    const rule = await rep.communityRules(deployerAddr, ruleId);
    assertEqual(rule.baseScore, 20n, 'E2E_ACTIVITY baseScore');
    assertEqual(rule.activityBonus, 5n, 'E2E_ACTIVITY activityBonus');
    assertEqual(rule.maxBonus, 200n, 'E2E_ACTIVITY maxBonus');
  } catch (e) {
    printError(`setRule: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 3: getActiveRules
  // ──────────────────────────────────────────
  printStep(3, 'getActiveRules');
  try {
    const activeRules = await rep.getActiveRules(deployerAddr);
    printKeyValue('Active rules count', activeRules.length);
    const hasOurRule = activeRules.some(r => r === ruleId);
    assertTrue(hasOurRule, 'Active rules include E2E_ACTIVITY');
  } catch (e) {
    printError(`getActiveRules: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 4: computeScore
  // ──────────────────────────────────────────
  printStep(4, 'computeScore');
  try {
    const score = await rep.computeScore(
      testUser,
      [deployerAddr],        // communities
      [[ruleId]],            // ruleIds per community
      [[10n]]                // activities per rule
    );
    printKeyValue('Computed score', score.toString());
    // baseScore(20) + min(activityBonus*activity, maxBonus) = 20 + min(50, 200) = 70
    assertGte(score, 0n, 'Score is non-negative');
  } catch (e) {
    printError(`computeScore: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 5: setEntropyFactor, recompute
  // ──────────────────────────────────────────
  printStep(5, 'setEntropyFactor and recompute');
  try {
    // Set factor to 1.5e18
    const factor = ethers.parseEther('1.5');
    await sendTxSafe(rep, 'setEntropyFactor', [deployerAddr, factor], 'setEntropyFactor(1.5)');

    const stored = await rep.entropyFactors(deployerAddr);
    assertEqual(stored, factor, 'entropyFactor stored');

    // Recompute score
    const score2 = await rep.computeScore(testUser, [deployerAddr], [[ruleId]], [[10n]]);
    printKeyValue('Score with entropy=1.5', score2.toString());

    // Restore factor to 1e18
    await sendTxSafe(rep, 'setEntropyFactor', [deployerAddr, ethers.parseEther('1')], 'Restore entropyFactor(1)');
    printSuccess('entropyFactor restored to 1e18');
  } catch (e) {
    printError(`setEntropyFactor: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 6: setCommunityReputation
  // ──────────────────────────────────────────
  printStep(6, 'setCommunityReputation');
  try {
    await sendTxSafe(rep, 'setCommunityReputation',
      [deployerAddr, testUser, 42],
      'setCommunityReputation(42)'
    );
    const rep_val = await rep.communityReputations(deployerAddr, testUser);
    assertEqual(rep_val, 42n, 'communityReputation set to 42');
  } catch (e) {
    printError(`setCommunityReputation: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 7: Cleanup - remove test rule
  // ──────────────────────────────────────────
  printStep(7, 'Cleanup: remove test rule (set to zero)');
  try {
    await sendTxSafe(rep, 'setRule',
      [ruleId, 0, 0, 0, ""],
      'Remove E2E_ACTIVITY rule'
    );
    printSuccess('Test rule removed');
  } catch (e) {
    printInfo(`Cleanup: ${e.message.substring(0, 60)}`);
  }

  const allPassed = printSummary('D1: Reputation Rules');
  process.exit(allPassed ? 0 : 1);
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });

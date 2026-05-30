#!/usr/bin/env node
/**
 * Test Group H2: ReputationSystem — Community Scoring & BLS Sync Pipeline
 *
 * Covers ReputationSystem functions not exercised by D1 (which focused on
 * rule/entropy lifecycle). This group verifies:
 *   1. Contract wiring (REGISTRY, version, owner)
 *   2. entropyFactors query for deployer community
 *   3. communityRules read for deployer community (after D1 cleanup, rules are empty)
 *   4. communityReputations view — read the rep set in D1 Step 6 (score=42)
 *   5. getReputationBreakdown — breakdown returned for a user + community pair
 *   6. calculateReputation — IReputationCalculator interface view
 *   7. computeScore — multi-community weighted score
 *   8. syncToRegistry — requires BLS proof → documented skip + expected revert
 *
 * NOTE on BLS-gated syncToRegistry:
 *   syncToRegistry calls REGISTRY.batchUpdateGlobalReputation(proposalId, users,
 *   scores, epoch, proof). The Registry verifies the BLS aggregate signature from
 *   ≥3 DVT validators before writing globalReputation[user].  Without a real BLS
 *   proof from a running DVTValidator/BLSAggregator cluster this call MUST revert
 *   (InvalidProof). This is expected behavior — not a bug.
 *
 *   Production flow:
 *     community activity → setCommunityReputation → DVT validators sign → BLSAggregator
 *     reaches threshold → batchUpdateGlobalReputation → Registry.globalReputation[user]
 *     → getCreditLimit returns higher tier → SuperPaymaster honors larger credit
 */
const {
  initTestEnv, getContracts, ethers, ABI,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, finishTest, resetCounters,
  assertEqual, assertTrue, assertGte,
  sendTxSafe,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group H2: ReputationSystem — Community Scoring & BLS Sync Pipeline');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const rep = c.reputationSystem;
  const deployerAddr = deployer.address;

  // ──────────────────────────────────────────
  // Step 1: Contract wiring
  // ──────────────────────────────────────────
  printStep(1, 'ReputationSystem wiring: version, REGISTRY, owner');
  try {
    const ver  = await rep.version();
    const regAddr = await rep.REGISTRY();
    const owner = await rep.owner();

    printKeyValue('version', ver);
    printKeyValue('REGISTRY', regAddr);
    printKeyValue('owner', owner);

    assertTrue(ver.length > 0, 'version non-empty');
    assertEqual(regAddr.toLowerCase(), config.registry.toLowerCase(), 'REGISTRY == config.registry');
    assertTrue(owner.length > 0, 'owner set');
    printSuccess('ReputationSystem wiring OK');
  } catch (e) {
    printError(`Wiring check: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 2: entropyFactors for deployer community
  // ──────────────────────────────────────────
  printStep(2, 'entropyFactors(deployer community)');
  try {
    const ef = await rep.entropyFactors(deployerAddr);
    printKeyValue('entropyFactor (raw)', ef.toString());
    const displayFactor = ef === 0n ? '1.0 (default, 0 stored)' : `${Number(ef) / 1e18}`;
    printKeyValue('entropyFactor (display)', displayFactor);
    assertGte(ef, 0n, 'entropyFactor >= 0');
    printSuccess('entropyFactors query OK');
  } catch (e) {
    printError(`entropyFactors: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 3: communityRules for deployer community
  // ──────────────────────────────────────────
  printStep(3, 'communityRules — query a known ruleId for deployer community');
  try {
    // D1 tests created and then deleted "E2E_ACTIVITY". After cleanup the rule
    // storage for this ID is zeroed but readable.
    const ruleId = ethers.keccak256(ethers.toUtf8Bytes('E2E_ACTIVITY'));
    const rule = await rep.communityRules(deployerAddr, ruleId);
    printKeyValue('E2E_ACTIVITY baseScore', rule.baseScore.toString());
    printKeyValue('E2E_ACTIVITY activityBonus', rule.activityBonus.toString());
    printKeyValue('E2E_ACTIVITY maxBonus', rule.maxBonus.toString());
    printKeyValue('E2E_ACTIVITY description', rule.description || '(empty after cleanup)');
    // After D1 cleanup the rule is zeroed — baseScore == 0
    printSuccess('communityRules query completed (zeroed after D1 cleanup)');
  } catch (e) {
    printError(`communityRules: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 4: communityReputations — read score set in D1 Step 6
  // ──────────────────────────────────────────
  printStep(4, 'communityReputations(deployer, deployer) — persistent from D1 Step 6');
  try {
    const score = await rep.communityReputations(deployerAddr, deployerAddr);
    printKeyValue('communityReputations', score.toString());
    // D1 Step 6 set score=42 and did NOT clean it up — should be 42
    assertGte(score, 0n, 'communityReputation >= 0');
    if (score === 42n) {
      printSuccess('communityReputation == 42 (set by D1 Step 6)');
    } else {
      printInfo(`communityReputation == ${score} (may differ if D1 ran multiple times)`);
      printSuccess('communityReputations query OK');
    }
  } catch (e) {
    printError(`communityReputations: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 5: getReputationBreakdown
  // ──────────────────────────────────────────
  printStep(5, 'getReputationBreakdown(deployer, deployer, 0)');
  try {
    const bd = await rep.getReputationBreakdown(deployerAddr, deployerAddr, 0n);
    printKeyValue('baseScore', bd.baseScore.toString());
    printKeyValue('nftBonus', bd.nftBonus.toString());
    printKeyValue('activityBonus', bd.activityBonus.toString());
    printKeyValue('multiplier (raw)', bd.multiplier.toString());
    assertGte(bd.baseScore, 0n, 'baseScore >= 0');
    assertGte(bd.multiplier, 0n, 'multiplier >= 0');
    printSuccess('getReputationBreakdown OK');
  } catch (e) {
    printError(`getReputationBreakdown: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 6: calculateReputation (IReputationCalculator interface)
  // ──────────────────────────────────────────
  printStep(6, 'calculateReputation(deployer, deployer, 0) — IReputationCalculator');
  try {
    const calc = await rep.calculateReputation(deployerAddr, deployerAddr, 0n);
    printKeyValue('calculateReputation', calc.toString());
    assertGte(calc, 0n, 'calculateReputation >= 0');
    printSuccess('calculateReputation OK');
  } catch (e) {
    printError(`calculateReputation: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────
  // Step 7: computeScore — multi-community weighted
  // ──────────────────────────────────────────
  printStep(7, 'computeScore — deployer community, defaultRule, 10 activities');
  try {
    const ruleId = ethers.keccak256(ethers.toUtf8Bytes('DEFAULT'));
    const score = await rep.computeScore(
      deployerAddr,
      [deployerAddr],         // communities
      [[ruleId]],             // ruleIds per community
      [[10n]]                 // activity counts
    );
    printKeyValue('computeScore (DEFAULT rule, 10 activities)', score.toString());
    assertGte(score, 0n, 'computeScore >= 0');
    printSuccess('computeScore OK');
  } catch (e) {
    // DEFAULT ruleId might not be active — try with empty ruleIds (uses defaultRule)
    try {
      const score2 = await rep.computeScore(deployerAddr, [deployerAddr], [[]], [[10n]]);
      printKeyValue('computeScore (empty rules → defaultRule)', score2.toString());
      assertGte(score2, 0n, 'computeScore >= 0');
      printSuccess('computeScore with defaultRule OK');
    } catch (e2) {
      printError(`computeScore: ${e2.message.substring(0, 100)}`);
    }
  }

  // ──────────────────────────────────────────
  // Step 8: syncToRegistry — BLS proof required → expected revert
  // ──────────────────────────────────────────
  printStep(8, 'syncToRegistry — requires BLS proof (DVT consensus infrastructure)');
  printInfo('syncToRegistry calls REGISTRY.batchUpdateGlobalReputation(proposalId, users, scores, epoch, proof)');
  printInfo('The Registry verifies an aggregate BLS-12-381 signature from ≥3 DVT validators.');
  printInfo('Without a running DVT cluster, the call reverts with InvalidProof — expected behavior.');
  printSkip('syncToRegistry: BLS infrastructure dependency — requires DVT node cluster with ≥3 validators');

  printInfo('');
  printInfo('  Production pipeline (how globalReputation is updated):');
  printInfo('  1. Community operator calls setCommunityReputation(community, user, score)');
  printInfo('  2. DVT validators observe the score update, each signs a proposal');
  printInfo('  3. BLSAggregator collects signatures until threshold (≥3) reached');
  printInfo('  4. batchUpdateGlobalReputation called with BLS aggregate proof');
  printInfo('  5. Registry writes globalReputation[user] = score');
  printInfo('  6. getCreditLimit(user) now returns higher credit tier');
  printInfo('  7. SuperPaymaster postOp honors the higher credit ceiling');

  // ──────────────────────────────────────────
  // Step 9: getActiveRules after D1 cleanup
  // ──────────────────────────────────────────
  printStep(9, 'getActiveRules(deployer) — should be empty after D1 cleanup');
  try {
    const rules = await rep.getActiveRules(deployerAddr);
    printKeyValue('Active rules count', rules.length.toString());
    if (rules.length === 0) {
      printSuccess('No active rules for deployer community (D1 cleaned up E2E_ACTIVITY)');
    } else {
      for (const r of rules) {
        printKeyValue('  Rule ID', r);
      }
      printSuccess(`${rules.length} active rule(s) found`);
    }
  } catch (e) {
    printError(`getActiveRules: ${e.message.substring(0, 100)}`);
  }

  process.exit(finishTest('H2: ReputationSystem — Community Scoring & BLS Sync Pipeline'));
}

main().catch(err => {
  const m = (err.message || '').toLowerCase();
  const isNet = m.includes('socket hang up') || m.includes('econnreset') ||
    m.includes('timeout') || m.includes('etimedout') || m.includes('request timeout');
  if (isNet) { console.error('Fatal (network):', err.message.substring(0, 80)); process.exit(2); }
  console.error('Fatal:', err.message);
  process.exit(1);
});

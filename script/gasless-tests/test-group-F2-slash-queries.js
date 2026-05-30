#!/usr/bin/env node
/**
 * Test Group F2: Slash History & WARNING-level Test
 *
 * Tests: getSlashCount, getSlashHistory, slashOperator (WARNING, 0 penalty),
 * updateReputation to restore.
 * Requires deployer to be an operator.
 */
const {
  initTestEnv, getContracts, SLASH_LEVEL, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, finishTest, resetCounters,
  assertEqual, assertTrue, assertGte,
  sendTxSafe, catchStep, retryView,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group F2: Slash History & WARNING Test');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const sp = c.superPaymaster;

  const deployerAddr = deployer.address;
  const operatorAddr = process.env.OPERATOR_ADDRESS || deployerAddr;
  const anniAddr = process.env.OPERATOR_ADDRESS;

  // ──────────────────────────────────────────
  // Step 1: getSlashCount for deployer & operator
  // ──────────────────────────────────────────
  printStep(1, 'getSlashCount');
  let deployerSlashCount = 0n;
  try {
    deployerSlashCount = await retryView(() => sp.getSlashCount(deployerAddr), 'getSlashCount(deployer)');
    printKeyValue('Deployer slash count', deployerSlashCount.toString());
    assertGte(deployerSlashCount, 0n, 'Deployer slash count >= 0');
  } catch (e) {
    catchStep(`getSlashCount(deployer)`, e);
  }

  if (anniAddr && anniAddr.toLowerCase() !== deployerAddr.toLowerCase()) {
    try {
      const anniCount = await sp.getSlashCount(anniAddr);
      printKeyValue('Anni slash count', anniCount.toString());
    } catch (e) {
      printInfo(`getSlashCount(Anni): ${e.message.substring(0, 60)}`);
    }
  }

  // ──────────────────────────────────────────
  // Step 2: getSlashHistory if any exists
  // ──────────────────────────────────────────
  printStep(2, 'getSlashHistory');
  try {
    const history = await sp.getSlashHistory(deployerAddr);
    printKeyValue('History entries', history.length);
    if (history.length > 0) {
      const latest = history[history.length - 1];
      printKeyValue('Latest timestamp', new Date(Number(latest.timestamp) * 1000).toISOString());
      printKeyValue('Latest amount', ethers.formatEther(latest.amount));
      printKeyValue('Latest level', latest.level.toString());
      printKeyValue('Latest reason', latest.reason);
    }
    printSuccess('getSlashHistory read completed');
  } catch (e) {
    catchStep(`getSlashHistory`, e);
  }

  // ──────────────────────────────────────────
  // Step 3: slashOperator (WARNING, 0 penalty)
  // ──────────────────────────────────────────
  printStep(3, 'slashOperator (WARNING level, 0 penalty)');

  // Check if deployer is configured as operator
  const op = await sp.operators(deployerAddr);
  if (!op.isConfigured) {
    printSkip('Deployer not configured as operator; skipping slash test');
  } else {
    // Save reputation before
    const repBefore = op.reputation;
    printKeyValue('Reputation before', repBefore.toString());

    // Check 24h cooldown: if last slash was within 24h, skip (SlashCooldown guard)
    const history = await sp.getSlashHistory(deployerAddr);
    const SLASH_COOLDOWN = 86400n; // 24 hours in seconds
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const lastSlashTs = history.length > 0 ? BigInt(history[history.length - 1].timestamp) : 0n;
    const cooldownEnds = lastSlashTs + SLASH_COOLDOWN;
    if (lastSlashTs > 0n && nowSec < cooldownEnds) {
      const remaining = Number(cooldownEnds - nowSec);
      printSkip(`Slash cooldown active — ${Math.floor(remaining / 3600)}h ${Math.floor((remaining % 3600) / 60)}m remaining (resets at ${new Date(Number(cooldownEnds) * 1000).toISOString()})`);
    } else {
      try {
        await sendTxSafe(sp, 'slashOperator',
          [deployerAddr, SLASH_LEVEL.WARNING, 0, "E2E test warning slash"],
          'slashOperator(WARNING, 0)'
        );

        const newCount = await sp.getSlashCount(deployerAddr);
        assertEqual(newCount, deployerSlashCount + 1n, 'Slash count incremented');
      } catch (e) {
        catchStep(`slashOperator`, e);
      }
    }
  }

  // ──────────────────────────────────────────
  // Step 4: Verify latest slash record
  // ──────────────────────────────────────────
  printStep(4, 'Verify latest slash record');
  if (!op.isConfigured) {
    printSkip('Skipped (no operator)');
  } else {
    try {
      const history = await sp.getSlashHistory(deployerAddr);
      if (history.length > 0) {
        const latest = history[history.length - 1];
        assertEqual(latest.level, BigInt(SLASH_LEVEL.WARNING), 'Latest slash level = WARNING');
        assertEqual(latest.amount, 0n, 'Latest slash amount = 0');
        assertTrue(latest.reason.includes('E2E'), 'Reason contains E2E');
      } else {
        printError('No slash history after slashOperator');
      }
    } catch (e) {
      catchStep(`Verify slash`, e);
    }
  }

  // ──────────────────────────────────────────
  // Step 5: updateReputation to restore
  // ──────────────────────────────────────────
  printStep(5, 'updateReputation to restore');
  if (!op.isConfigured) {
    printSkip('Skipped (no operator)');
  } else {
    try {
      await sendTxSafe(sp, 'updateReputation', [deployerAddr, 100], 'updateReputation(100)');
      const opAfter = await sp.operators(deployerAddr);
      assertEqual(opAfter.reputation, 100n, 'Reputation restored to 100');
    } catch (e) {
      catchStep(`updateReputation`, e);
    }
  }

  // ──────────────────────────────────────────
  // Step 6: Query userOpState
  // ──────────────────────────────────────────
  printStep(6, 'Query userOpState(operator, user)');
  const testUser = process.env.TEST_AA_ACCOUNT_ADDRESS_A || ethers.Wallet.createRandom().address;
  try {
    const state = await sp.userOpState(operatorAddr, testUser);
    printKeyValue('lastTimestamp', state.lastTimestamp.toString());
    printKeyValue('isBlocked', state.isBlocked);
    printSuccess('userOpState query completed');
  } catch (e) {
    catchStep(`userOpState`, e);
  }

  process.exit(finishTest('F2: Slash History'));
}

main().catch(err => {
  const m = (err.message || '').toLowerCase();
  const isNet = m.includes('socket hang up') || m.includes('econnreset') ||
    m.includes('timeout') || m.includes('etimedout') || m.includes('request timeout');
  if (isNet) { console.error('Fatal (network):', err.message.substring(0, 80)); process.exit(2); }
  console.error('Fatal:', err.message);
  process.exit(1);
});

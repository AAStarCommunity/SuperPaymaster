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
  printSummary, resetCounters,
  assertEqual, assertTrue, assertGte,
  sendTxSafe,
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
    deployerSlashCount = await sp.getSlashCount(deployerAddr);
    printKeyValue('Deployer slash count', deployerSlashCount.toString());
    assertGte(deployerSlashCount, 0n, 'Deployer slash count >= 0');
  } catch (e) {
    printError(`getSlashCount(deployer): ${e.message.substring(0, 80)}`);
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
    printError(`getSlashHistory: ${e.message.substring(0, 80)}`);
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

    try {
      await sendTxSafe(sp, 'slashOperator',
        [deployerAddr, SLASH_LEVEL.WARNING, 0, "E2E test warning slash"],
        'slashOperator(WARNING, 0)'
      );

      const newCount = await sp.getSlashCount(deployerAddr);
      assertEqual(newCount, deployerSlashCount + 1n, 'Slash count incremented');
    } catch (e) {
      printError(`slashOperator: ${e.message.substring(0, 80)}`);
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
      printError(`Verify slash: ${e.message.substring(0, 80)}`);
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
      printError(`updateReputation: ${e.message.substring(0, 80)}`);
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
    printError(`userOpState: ${e.message.substring(0, 80)}`);
  }

  const allPassed = printSummary('F2: Slash History');
  process.exit(allPassed ? 0 : 1);
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });

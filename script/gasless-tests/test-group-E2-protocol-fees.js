#!/usr/bin/env node
/**
 * Test Group E2: Protocol Fee Configuration
 *
 * Tests: protocolFeeBPS read, setProtocolFee cycle, setProtocolFee
 * over max -> revert, protocolRevenue, totalTrackedBalance.
 */
const {
  initTestEnv, getContracts, ethers,
  printHeader, printStep, printSuccess, printError, printInfo, printKeyValue,
  printSummary, resetCounters,
  assertEqual, assertTrue, assertGte,
  sendTxSafe, expectRevert,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group E2: Protocol Fee Configuration');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const sp = c.superPaymaster;

  // ──────────────────────────────────────────
  // Step 1: Read protocolFeeBPS
  // ──────────────────────────────────────────
  printStep(1, 'Read protocolFeeBPS');
  let originalFee = 0n;
  try {
    originalFee = await sp.protocolFeeBPS();
    printKeyValue('protocolFeeBPS', originalFee.toString());
    printKeyValue('Protocol fee %', `${Number(originalFee) / 100}%`);
    assertTrue(originalFee >= 0n, 'Fee is non-negative');
  } catch (e) {
    printError(`protocolFeeBPS: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 2: setProtocolFee cycle (set -> verify -> restore)
  // ──────────────────────────────────────────
  printStep(2, 'setProtocolFee (500 -> verify -> restore)');
  const testFee = 500n; // 5%
  try {
    await sendTxSafe(sp, 'setProtocolFee', [testFee], 'setProtocolFee(500)');
    const newFee = await sp.protocolFeeBPS();
    assertEqual(newFee, testFee, 'protocolFeeBPS set to 500');

    // Restore
    await sendTxSafe(sp, 'setProtocolFee', [originalFee], `Restore protocolFeeBPS(${originalFee})`);
    const restoredFee = await sp.protocolFeeBPS();
    assertEqual(restoredFee, originalFee, 'protocolFeeBPS restored');
  } catch (e) {
    printError(`setProtocolFee cycle: ${e.message.substring(0, 80)}`);
    // Try to restore
    try { await sp.setProtocolFee(originalFee); } catch (_) {}
  }

  // ──────────────────────────────────────────
  // Step 3: setProtocolFee over MAX -> revert
  // ──────────────────────────────────────────
  printStep(3, 'setProtocolFee(2001) -> expect revert');
  try {
    const maxFee = await sp.MAX_PROTOCOL_FEE();
    printKeyValue('MAX_PROTOCOL_FEE', maxFee.toString());
    await expectRevert(
      () => sp.setProtocolFee(maxFee + 1n),
      'setProtocolFee exceeding max'
    );
  } catch (e) {
    printError(`MAX_PROTOCOL_FEE: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 4: Read protocolRevenue, totalTrackedBalance
  // ──────────────────────────────────────────
  printStep(4, 'Read protocolRevenue and totalTrackedBalance');
  try {
    const revenue = await sp.protocolRevenue();
    printKeyValue('protocolRevenue', ethers.formatEther(revenue));
    assertGte(revenue, 0n, 'protocolRevenue >= 0');
  } catch (e) {
    printError(`protocolRevenue: ${e.message.substring(0, 80)}`);
  }

  try {
    const tracked = await sp.totalTrackedBalance();
    printKeyValue('totalTrackedBalance', ethers.formatEther(tracked));
    assertGte(tracked, 0n, 'totalTrackedBalance >= 0');
  } catch (e) {
    printError(`totalTrackedBalance: ${e.message.substring(0, 80)}`);
  }

  const allPassed = printSummary('E2: Protocol Fees');
  process.exit(allPassed ? 0 : 1);
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });

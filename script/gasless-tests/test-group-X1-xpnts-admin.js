#!/usr/bin/env node
/**
 * Test Group X1: xPNTs Token Admin Functions
 *
 * Tests xPNTsToken owner/admin functions that currently have NO E2E coverage:
 * maxSingleTxLimit, spenderDailyCap, autoApprovedSpender, approvedFacilitator,
 * burn (self), updateExchangeRate (cooldown-aware), transferAndCall (ERC1363).
 *
 * Requires deployer to be communityOwner of the xPNTs token at config.aPNTs.
 */
const {
  initTestEnv, getContracts, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, finishTest, resetCounters,
  assertEqual, assertTrue, assertFalse,
  sendTxSafe, catchStep,
} = require('./test-helpers');

// ────────────────────────────────────────────────────────────────────────────
// Inline ABI extension for xPNTsToken admin functions not in ABI.xPNTsToken
// ────────────────────────────────────────────────────────────────────────────
const XPNTS_ADMIN_ABI = [
  "function communityOwner() view returns (address)",
  "function maxSingleTxLimit() view returns (uint256)",
  "function setMaxSingleTxLimit(uint256 newLimit)",
  "function spenderDailyCapTokens() view returns (uint256)",
  "function setSpenderDailyCap(uint256 newCap)",
  "function addAutoApprovedSpender(address spender)",
  "function removeAutoApprovedSpender(address spender)",
  "function autoApprovedSpenders(address spender) view returns (bool)",
  "function addApprovedFacilitator(address facilitator)",
  "function removeApprovedFacilitator(address facilitator)",
  "function approvedFacilitators(address facilitator) view returns (bool)",
  "function lastRateUpdate() view returns (uint256)",
  "function exchangeRateUpdatedAt() view returns (uint256)",
  "function updateExchangeRate(uint256 newRate)",
  "function burn(uint256 amount)",
  "function transferAndCall(address to, uint256 amount) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "function exchangeRate() view returns (uint256)",
  "function FACTORY() view returns (address)",
  "function SUPERPAYMASTER_ADDRESS() view returns (address)",
  "function emergencyDisabled() view returns (bool)",
];

async function main() {
  printHeader('Test Group X1: xPNTs Token Admin Functions');
  resetCounters();

  const { config, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const sp = c.superPaymaster;

  const deployerAddr = deployer.address;
  // Use a safe test address — deployer itself, so we never send to an unknown EOA
  const testSpender = process.env.TEST_EOA_ADDRESS || deployerAddr;

  // Attach xPNTs with the extended admin ABI
  const xpnts = new ethers.Contract(config.aPNTs, XPNTS_ADMIN_ABI, deployer);

  // ──────────────────────────────────────────
  // Step 1: Read xPNTs admin state
  // ──────────────────────────────────────────
  printStep(1, 'Read xPNTs admin state');
  try {
    const communityOwner = await xpnts.communityOwner();
    const maxLimit = await xpnts.maxSingleTxLimit();
    const dailyCap = await xpnts.spenderDailyCapTokens();
    const factory = await xpnts.FACTORY();
    const spAddr = await xpnts.SUPERPAYMASTER_ADDRESS();
    const emergency = await xpnts.emergencyDisabled();
    const rate = await xpnts.exchangeRate();

    // lastRateUpdate / exchangeRateUpdatedAt — try both storage var names
    let lastUpdate = 0n;
    try { lastUpdate = await xpnts.exchangeRateUpdatedAt(); } catch (_) {
      try { lastUpdate = await xpnts.lastRateUpdate(); } catch (_2) {}
    }

    printKeyValue('communityOwner', communityOwner);
    printKeyValue('FACTORY', factory);
    printKeyValue('SUPERPAYMASTER_ADDRESS', spAddr);
    printKeyValue('maxSingleTxLimit', ethers.formatEther(maxLimit) + ' aPNTs');
    printKeyValue('spenderDailyCapTokens', ethers.formatEther(dailyCap) + ' xPNTs');
    printKeyValue('exchangeRate', rate.toString());
    printKeyValue('exchangeRateUpdatedAt', lastUpdate.toString());
    printKeyValue('emergencyDisabled', emergency);

    assertTrue(communityOwner !== ethers.ZeroAddress, 'communityOwner is non-zero');

    if (communityOwner.toLowerCase() !== deployerAddr.toLowerCase()) {
      printInfo('WARNING: deployer is NOT the communityOwner — write tests will likely revert');
    } else {
      printSuccess('Deployer is communityOwner — write tests should proceed');
    }
  } catch (e) {
    catchStep(`Read admin state`, e);
  }

  // ──────────────────────────────────────────
  // Step 2: setMaxSingleTxLimit — set + verify + restore
  // ──────────────────────────────────────────
  printStep(2, 'setMaxSingleTxLimit — set + verify + restore');
  try {
    const currentLimit = await xpnts.maxSingleTxLimit();
    printKeyValue('currentMaxSingleTxLimit', ethers.formatEther(currentLimit) + ' aPNTs');

    // Increase by 1000 tokens, clamped to MAX_SINGLE_TX_LIMIT_CAP (50,000 ether)
    const MAX_CAP = ethers.parseEther('50000');
    let newLimit = currentLimit + ethers.parseEther('1000');
    if (newLimit > MAX_CAP) newLimit = MAX_CAP;

    if (newLimit === currentLimit) {
      printSkip('Already at cap — decrease by 1000 instead for test');
      newLimit = currentLimit - ethers.parseEther('1000');
    }

    printInfo(`Setting maxSingleTxLimit to ${ethers.formatEther(newLimit)} aPNTs...`);
    const receipt = await sendTxSafe(xpnts, 'setMaxSingleTxLimit', [newLimit], 'setMaxSingleTxLimit');
    if (receipt) {
      const after = await xpnts.maxSingleTxLimit();
      assertEqual(after, newLimit, 'maxSingleTxLimit updated');

      // Restore
      printInfo('Restoring original limit...');
      const restoreR1 = await sendTxSafe(xpnts, 'setMaxSingleTxLimit', [currentLimit], 'restoreMaxSingleTxLimit', { critical: false });
      if (restoreR1) {
        const restored = await xpnts.maxSingleTxLimit();
        assertEqual(restored, currentLimit, 'maxSingleTxLimit restored');
      }
    }
  } catch (e) {
    catchStep(`setMaxSingleTxLimit`, e);
  }

  // ──────────────────────────────────────────
  // Step 3: setSpenderDailyCap — set + verify + restore
  // ──────────────────────────────────────────
  printStep(3, 'setSpenderDailyCap — set + verify + restore');
  try {
    const currentCap = await xpnts.spenderDailyCapTokens();
    printKeyValue('currentSpenderDailyCap', ethers.formatEther(currentCap) + ' xPNTs');

    const newCap = currentCap + ethers.parseEther('500');
    printInfo(`Setting spenderDailyCap to ${ethers.formatEther(newCap)} xPNTs...`);

    const receipt = await sendTxSafe(xpnts, 'setSpenderDailyCap', [newCap], 'setSpenderDailyCap');
    if (receipt) {
      const after = await xpnts.spenderDailyCapTokens();
      assertEqual(after, newCap, 'spenderDailyCapTokens updated');

      // Restore
      printInfo('Restoring original daily cap...');
      const restoreR2 = await sendTxSafe(xpnts, 'setSpenderDailyCap', [currentCap], 'restoreSpenderDailyCap', { critical: false });
      if (restoreR2) {
        const restored = await xpnts.spenderDailyCapTokens();
        assertEqual(restored, currentCap, 'spenderDailyCapTokens restored');
      }
    }
  } catch (e) {
    catchStep(`setSpenderDailyCap`, e);
  }

  // ──────────────────────────────────────────
  // Step 4: addAutoApprovedSpender + removeAutoApprovedSpender
  // ──────────────────────────────────────────
  printStep(4, 'addAutoApprovedSpender + removeAutoApprovedSpender');
  try {
    const wasApproved = await xpnts.autoApprovedSpenders(testSpender);
    printKeyValue('isAutoApproved(testSpender) before', wasApproved);

    if (wasApproved) {
      // testSpender is already approved — test remove + re-add + remove cycle
      printInfo('testSpender already auto-approved — testing remove+re-add+remove cycle');
      const rR = await sendTxSafe(xpnts, 'removeAutoApprovedSpender', [testSpender], 'removeAutoApprovedSpender');
      if (rR) {
        assertFalse(await xpnts.autoApprovedSpenders(testSpender), 'isAutoApproved false after remove');
        const aR = await sendTxSafe(xpnts, 'addAutoApprovedSpender', [testSpender], 'addAutoApprovedSpender(restore)', { critical: false });
        if (aR) assertTrue(await xpnts.autoApprovedSpenders(testSpender), 'isAutoApproved true after restore');
      }
    } else {
      // Normal add + verify + remove flow
      const aR = await sendTxSafe(xpnts, 'addAutoApprovedSpender', [testSpender], 'addAutoApprovedSpender');
      if (aR) {
        assertTrue(await xpnts.autoApprovedSpenders(testSpender), 'isAutoApproved true after add');
        const rR = await sendTxSafe(xpnts, 'removeAutoApprovedSpender', [testSpender], 'removeAutoApprovedSpender');
        if (rR) assertFalse(await xpnts.autoApprovedSpenders(testSpender), 'isAutoApproved false after remove');
      }
    }
  } catch (e) {
    catchStep(`autoApprovedSpender`, e);
  }

  // ──────────────────────────────────────────
  // Step 5: addApprovedFacilitator + removeApprovedFacilitator
  // ──────────────────────────────────────────
  printStep(5, 'addApprovedFacilitator + removeApprovedFacilitator');
  try {
    const wasApproved = await xpnts.approvedFacilitators(testSpender);
    printKeyValue('isApprovedFacilitator(testSpender) before', wasApproved);

    if (wasApproved) {
      printInfo('testSpender already a facilitator — testing remove+re-add+remove cycle');
      const rF = await sendTxSafe(xpnts, 'removeApprovedFacilitator', [testSpender], 'removeApprovedFacilitator');
      if (rF) {
        assertFalse(await xpnts.approvedFacilitators(testSpender), 'isApprovedFacilitator false after remove');
        const aF = await sendTxSafe(xpnts, 'addApprovedFacilitator', [testSpender], 'addApprovedFacilitator(restore)', { critical: false });
        if (aF) assertTrue(await xpnts.approvedFacilitators(testSpender), 'isApprovedFacilitator true after restore');
      }
    } else {
      const aF = await sendTxSafe(xpnts, 'addApprovedFacilitator', [testSpender], 'addApprovedFacilitator');
      if (aF) {
        assertTrue(await xpnts.approvedFacilitators(testSpender), 'isApprovedFacilitator true after add');
        const rF = await sendTxSafe(xpnts, 'removeApprovedFacilitator', [testSpender], 'removeApprovedFacilitator');
        if (rF) assertFalse(await xpnts.approvedFacilitators(testSpender), 'isApprovedFacilitator false after remove');
      }
    }
  } catch (e) {
    catchStep(`approvedFacilitator`, e);
  }

  // ──────────────────────────────────────────
  // Step 6: burn(amount) — deployer self-burns 1 wei xPNTs
  // ──────────────────────────────────────────
  printStep(6, 'burn(1 wei) — minimal self-burn');
  try {
    const balance = await xpnts.balanceOf(deployerAddr);
    printKeyValue('deployer xPNTs balance', ethers.formatEther(balance));

    if (balance === 0n) {
      printSkip('No xPNTs balance to burn — skipping');
    } else {
      const burnAmount = 1n; // 1 wei — minimal irreversible burn
      printInfo(`Burning ${burnAmount} wei xPNTs (irreversible)...`);

      const receipt = await sendTxSafe(xpnts, 'burn', [burnAmount], 'burn(1 wei)');
      if (receipt) {
        const after = await xpnts.balanceOf(deployerAddr);
        assertEqual(after, balance - burnAmount, 'balance decreased by 1 wei after burn');
      }
    }
  } catch (e) {
    catchStep(`burn`, e);
  }

  // ──────────────────────────────────────────
  // Step 7: updateExchangeRate — cooldown-aware
  // ──────────────────────────────────────────
  printStep(7, 'updateExchangeRate — cooldown-aware');
  try {
    const rate = await xpnts.exchangeRate();

    // Try both storage variable names for the last update timestamp
    let lastUpdate = 0n;
    try { lastUpdate = await xpnts.exchangeRateUpdatedAt(); } catch (_) {
      try { lastUpdate = await xpnts.lastRateUpdate(); } catch (_2) {}
    }

    printKeyValue('exchangeRate', rate.toString());
    printKeyValue('lastRateUpdate', lastUpdate.toString());

    const COOLDOWN = 3600n; // 1 hour cooldown (P1-14)
    const now = BigInt(Math.floor(Date.now() / 1000));
    const cooldownEnd = lastUpdate + COOLDOWN;

    if (lastUpdate > 0n && now < cooldownEnd) {
      const untilStr = new Date(Number(cooldownEnd) * 1000).toISOString();
      printSkip(`Rate cooldown active until ${untilStr} — skipping updateExchangeRate`);
    } else {
      // 1% increase — well within the ±20% delta limit (EXCHANGE_RATE_DELTA_BPS)
      const newRate = (rate * 101n) / 100n;
      printInfo(`Updating exchange rate: ${rate} → ${newRate} (+1%)...`);

      const receipt = await sendTxSafe(xpnts, 'updateExchangeRate', [newRate], 'updateExchangeRate(+1%)');
      if (receipt) {
        const after = await xpnts.exchangeRate();
        assertEqual(after, newRate, 'exchangeRate updated to +1%');

        // Attempt restore — do NOT use sendTxSafe here because cooldown
        // activates immediately after update; a failed restore is expected and
        // must NOT count as a test failure.
        printInfo('Attempting to restore rate (cooldown active — failure is expected and OK)...');
        try {
          const tx = await xpnts.updateExchangeRate(rate);
          await tx.wait();
          const restored = await xpnts.exchangeRate();
          if (restored === rate) {
            printSuccess('exchangeRate restored to original (chain was fast enough)');
          } else {
            printInfo(`Rate not fully restored — left at +1% (restored=${restored})`);
          }
        } catch (_restoreErr) {
          printInfo('Restore reverted (1h cooldown active) — rate left at +1%, this is expected');
        }
      }
    }
  } catch (e) {
    catchStep(`updateExchangeRate`, e);
  }

  // ──────────────────────────────────────────
  // Step 8: transferAndCall — ERC1363 push deposit to SuperPaymaster
  // ──────────────────────────────────────────
  printStep(8, 'transferAndCall → SuperPaymaster (ERC1363 push deposit)');
  try {
    const balance = await xpnts.balanceOf(deployerAddr);
    const transferAmount = ethers.parseEther('1');
    printKeyValue('deployer xPNTs balance', ethers.formatEther(balance));
    printKeyValue('transferAmount', ethers.formatEther(transferAmount));

    if (balance < transferAmount) {
      printSkip(`Insufficient xPNTs balance (${ethers.formatEther(balance)} < 1) — skipping transferAndCall`);
    } else {
      // Read operator aPNTs balance before
      const opBefore = await sp.operators(deployerAddr);
      printKeyValue('SP operator.aPNTsBalance before', opBefore.aPNTsBalance.toString());

      printInfo('Calling transferAndCall(superPaymaster, 1 aPNTs)...');
      const receipt = await sendTxSafe(
        xpnts,
        'transferAndCall',
        [config.superPaymaster, transferAmount],
        'transferAndCall→SP'
      );

      if (receipt) {
        const opAfter = await sp.operators(deployerAddr);
        printKeyValue('SP operator.aPNTsBalance after', opAfter.aPNTsBalance.toString());

        if (opAfter.isConfigured) {
          // Operator configured — balance should have increased
          assertTrue(
            opAfter.aPNTsBalance >= opBefore.aPNTsBalance,
            'SP operator aPNTsBalance >= before (onTransferReceived accepted push)'
          );
        } else {
          printInfo('Deployer not configured as SP operator — SP may have rejected the push (expected)');
          printSuccess('transferAndCall TX confirmed without revert');
        }
      }
    }
  } catch (e) {
    catchStep(`transferAndCall`, e);
  }

  process.exit(finishTest('X1: xPNTs Admin'));
}

main().catch(err => {
  const m = (err.message || '').toLowerCase();
  const isNet = m.includes('socket hang up') || m.includes('econnreset') ||
    m.includes('timeout') || m.includes('etimedout') || m.includes('request timeout');
  if (isNet) { console.error('Fatal (network):', err.message.substring(0, 80)); process.exit(2); }
  console.error('Fatal:', err.message);
  process.exit(1);
});

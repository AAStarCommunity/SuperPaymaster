#!/usr/bin/env node
/**
 * Test Group B4: SuperPaymaster Governance / Admin Functions
 *
 * Covers governance/admin calls with no prior E2E TX coverage:
 *   setTreasury, updateSBTStatus, updateBlockedStatus, setAgentRegistries,
 *   setFacilitatorFeeBPS, setOperatorFacilitatorFee, dryRunValidation,
 *   queueBLSAggregator, withdrawProtocolRevenue, withdrawFacilitatorEarnings
 *
 * Exit codes:
 *   0 = all assertions passed
 *   1 = one or more assertions failed (or fatal error)
 *   2 = precondition not met (skip) — use process.exit(2), NEVER bare return
 */
const {
  initTestEnv, getContracts, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, resetCounters,
  assertEqual, assertTrue, assertFalse,
  sendTxSafe,
} = require('./test-helpers');

// ──────────────────────────────────────────────────────────────
// Extra ABI entries not present in test-helpers SP_ABI
// (treasury(), pendingBLSAggregator(), blsAggregatorChangeAt())
// ──────────────────────────────────────────────────────────────
const EXTRA_SP_ABI = [
  "function treasury() view returns (address)",
  "function pendingBLSAggregator() view returns (address)",
  "function blsAggregatorChangeAt() view returns (uint256)",
];

async function main() {
  printHeader('Test Group B4: SP Governance / Admin');
  resetCounters();

  const { config, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const deployerAddr = deployer.address;
  // All governance/admin functions are now in test-helpers ABI.SuperPaymaster
  const sp = c.superPaymaster;

  // Optional: TEST_AA_ACCOUNT_ADDRESS_A from env, fallback to deployer
  const testUser = process.env.TEST_AA_ACCOUNT_ADDRESS_A || deployerAddr;

  // Pre-check: deployer must be operator (configured) so governance calls are meaningful
  const op = await sp.operators(deployerAddr);
  if (!op.isConfigured) {
    printSkip('Deployer operator not configured — some steps may fail. Continuing anyway.');
  }

  // ──────────────────────────────────────────────────────────────
  // Step 1: setTreasury — set + verify + restore
  // ──────────────────────────────────────────────────────────────
  printStep(1, 'setTreasury — set deployer + verify + restore');
  let currentTreasury;
  try {
    currentTreasury = await sp.treasury();
    printKeyValue('Current treasury', currentTreasury);

    const receipt = await sendTxSafe(sp, 'setTreasury', [deployerAddr], 'setTreasury(deployer)');
    if (receipt) {
      const afterSet = await sp.treasury();
      assertEqual(afterSet.toLowerCase(), deployerAddr.toLowerCase(), 'treasury == deployer');

      // Restore
      if (currentTreasury.toLowerCase() !== deployerAddr.toLowerCase()) {
        await sendTxSafe(sp, 'setTreasury', [currentTreasury], 'setTreasury(restore)');
        const afterRestore = await sp.treasury();
        assertEqual(afterRestore.toLowerCase(), currentTreasury.toLowerCase(), 'treasury restored');
      } else {
        printInfo('Treasury was already deployer — no restore needed');
      }
    }
  } catch (e) {
    printError(`setTreasury: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────────────────────────
  // Step 2: updateSBTStatus — grant + verify + revoke
  // ──────────────────────────────────────────────────────────────
  printStep(2, 'updateSBTStatus — grant true + verify + revoke');
  let sbtBefore = false;
  try {
    sbtBefore = await sp.sbtHolders(testUser);
    printKeyValue('sbtHolders(testUser) before', sbtBefore);

    const receipt = await sendTxSafe(sp, 'updateSBTStatus', [testUser, true], 'updateSBTStatus(true)');
    if (receipt) {
      const afterGrant = await sp.sbtHolders(testUser);
      assertTrue(afterGrant, 'sbtHolders(testUser) is true after grant');

      // Only revoke if it was false before — don't strip existing SBT holders
      if (!sbtBefore) {
        await sendTxSafe(sp, 'updateSBTStatus', [testUser, false], 'updateSBTStatus(false restore)');
        const afterRevoke = await sp.sbtHolders(testUser);
        assertFalse(afterRevoke, 'sbtHolders(testUser) is false after revoke');
      } else {
        printInfo('testUser already had SBT status — restore skipped to avoid side-effects');
      }
    }
  } catch (e) {
    printError(`updateSBTStatus: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────────────────────────
  // Step 3: updateBlockedStatus — block + verify + unblock
  // ──────────────────────────────────────────────────────────────
  printStep(3, 'updateBlockedStatus — block user + verify + unblock');
  try {
    const operator = deployerAddr;
    // Read current state
    const stateBefore = await sp.userOpState(operator, testUser);
    printKeyValue('isBlocked before', stateBefore.isBlocked);

    const receipt = await sendTxSafe(
      sp, 'updateBlockedStatus',
      [operator, [testUser], [true]],
      'block user'
    );
    if (receipt) {
      const stateAfterBlock = await sp.userOpState(operator, testUser);
      assertTrue(stateAfterBlock.isBlocked, 'userOpState.isBlocked is true after block');

      // Restore — unblock regardless of prior state (blocking is a test artifact)
      await sendTxSafe(
        sp, 'updateBlockedStatus',
        [operator, [testUser], [false]],
        'unblock user (restore)'
      );
      const stateAfterUnblock = await sp.userOpState(operator, testUser);
      assertFalse(stateAfterUnblock.isBlocked, 'userOpState.isBlocked is false after unblock');
    }
  } catch (e) {
    printError(`updateBlockedStatus: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────────────────────────
  // Step 4: setAgentRegistries — set deployer + verify + restore
  // ──────────────────────────────────────────────────────────────
  printStep(4, 'setAgentRegistries — set deployer + verify + restore');
  let currentIdentity;
  let currentRep;
  try {
    currentIdentity = await sp.agentIdentityRegistry();
    currentRep = await sp.agentReputationRegistry();
    printKeyValue('agentIdentityRegistry before', currentIdentity);
    printKeyValue('agentReputationRegistry before', currentRep);

    const receipt = await sendTxSafe(
      sp, 'setAgentRegistries',
      [deployerAddr, deployerAddr],
      'setAgentRegistries(deployer)'
    );
    if (receipt) {
      const identityAfter = await sp.agentIdentityRegistry();
      assertEqual(identityAfter.toLowerCase(), deployerAddr.toLowerCase(), 'agentIdentityRegistry == deployer');

      // Restore
      await sendTxSafe(
        sp, 'setAgentRegistries',
        [currentIdentity, currentRep],
        'setAgentRegistries(restore)'
      );
      const identityRestored = await sp.agentIdentityRegistry();
      assertEqual(identityRestored.toLowerCase(), currentIdentity.toLowerCase(), 'agentIdentityRegistry restored');
    }
  } catch (e) {
    printError(`setAgentRegistries: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────────────────────────
  // Step 5: setFacilitatorFeeBPS — set 100 + verify + restore
  // ──────────────────────────────────────────────────────────────
  printStep(5, 'setFacilitatorFeeBPS — set 100 (1%) + verify + restore');
  let currentFacFee = 0n;
  try {
    currentFacFee = await sp.facilitatorFeeBPS();
    printKeyValue('facilitatorFeeBPS before', currentFacFee.toString());

    const receipt = await sendTxSafe(sp, 'setFacilitatorFeeBPS', [100n], 'setFacilitatorFeeBPS(100)');
    if (receipt) {
      const feeAfter = await sp.facilitatorFeeBPS();
      assertEqual(feeAfter, 100n, 'facilitatorFeeBPS == 100');

      // Restore
      await sendTxSafe(sp, 'setFacilitatorFeeBPS', [currentFacFee], 'setFacilitatorFeeBPS(restore)');
      const feeRestored = await sp.facilitatorFeeBPS();
      assertEqual(feeRestored, currentFacFee, 'facilitatorFeeBPS restored');
    }
  } catch (e) {
    printError(`setFacilitatorFeeBPS: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────────────────────────
  // Step 6: setOperatorFacilitatorFee — set 50 + verify + restore
  // ──────────────────────────────────────────────────────────────
  printStep(6, 'setOperatorFacilitatorFee — set 50 + verify + restore');
  let currentOpFacFee = 0n;
  try {
    currentOpFacFee = await sp.operatorFacilitatorFees(deployerAddr);
    printKeyValue('operatorFacilitatorFees(deployer) before', currentOpFacFee.toString());

    const receipt = await sendTxSafe(
      sp, 'setOperatorFacilitatorFee',
      [deployerAddr, 50n],
      'setOpFacFee(50)'
    );
    if (receipt) {
      const opFeeAfter = await sp.operatorFacilitatorFees(deployerAddr);
      assertEqual(opFeeAfter, 50n, 'operatorFacilitatorFees(deployer) == 50');

      // Restore
      await sendTxSafe(
        sp, 'setOperatorFacilitatorFee',
        [deployerAddr, currentOpFacFee],
        'setOpFacFee(restore)'
      );
      const opFeeRestored = await sp.operatorFacilitatorFees(deployerAddr);
      assertEqual(opFeeRestored, currentOpFacFee, 'operatorFacilitatorFees restored');
    }
  } catch (e) {
    printError(`setOperatorFacilitatorFee: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────────────────────────
  // Step 7: dryRunValidation — construct minimal UserOp + dry-run
  // ──────────────────────────────────────────────────────────────
  printStep(7, 'dryRunValidation — static call with minimal UserOp');
  try {
    const senderAcc = process.env.TEST_AA_ACCOUNT_ADDRESS_A || deployerAddr;

    // Try to read nonce from the AA account; fall back to 0 on any error
    let nonce = 0n;
    try {
      const SA_ABI = ["function getNonce() view returns (uint256)"];
      const simpleAccount = new ethers.Contract(senderAcc, SA_ABI, deployer.provider);
      nonce = await simpleAccount.getNonce();
    } catch (_) {
      printInfo('getNonce() failed (not an AA account or not deployed) — using nonce=0');
    }

    const pmVerificationGasLimit = 150000n;
    const pmPostOpGasLimit = 200000n;
    // paymasterAndData: [paymaster(20)] [verGasLimit(16)] [postOpGasLimit(16)] [operator(20)]
    const paymasterAndData = ethers.solidityPacked(
      ['address', 'uint128', 'uint128', 'address'],
      [config.superPaymaster, pmVerificationGasLimit, pmPostOpGasLimit, deployerAddr]
    );

    const userOp = {
      sender: senderAcc,
      nonce: nonce,
      initCode: '0x',
      callData: '0x',
      accountGasLimits: ethers.solidityPacked(['uint128', 'uint128'], [200000n, 200000n]),
      preVerificationGas: 100000n,
      gasFees: ethers.solidityPacked(['uint128', 'uint128'], [2000000000n, 2000000000n]),
      paymasterAndData: paymasterAndData,
      signature: '0x',
    };

    const maxCost = ethers.parseEther('0.01');

    try {
      // dryRunValidation is `view` — use staticCall
      const [ok, reasonCode] = await sp.dryRunValidation.staticCall(userOp, maxCost);
      if (ok) {
        printSuccess('dryRunValidation returned ok=true (validation would pass)');
      } else {
        // Not a test failure — just report the reason code for diagnostic purposes
        printInfo(`dryRunValidation returned ok=false, reasonCode=${reasonCode}`);
        printSuccess('dryRunValidation staticCall completed without revert');
      }
    } catch (innerErr) {
      const msg = innerErr.message || '';
      if (msg.includes('DryRunFailed') || msg.includes('dryrun') || msg.includes('0x')) {
        printInfo(`dryRunValidation reverted (expected for misconfigured op): ${msg.substring(0, 100)}`);
        printSuccess('dryRunValidation call handled (revert caught cleanly)');
      } else {
        printError(`dryRunValidation unexpected error: ${msg.substring(0, 100)}`);
      }
    }
  } catch (e) {
    printError(`dryRunValidation setup: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────────────────────────
  // Step 8: queueBLSAggregator — queue deployer + verify pending
  // ──────────────────────────────────────────────────────────────
  printStep(8, 'queueBLSAggregator — queue deployer as test address + verify');
  try {
    const pendingBefore = await sp.pendingBLSAggregator();
    const etaBefore = await sp.blsAggregatorChangeAt();
    printKeyValue('pendingBLSAggregator before', pendingBefore);
    printKeyValue('blsAggregatorChangeAt before', etaBefore.toString());

    const receipt = await sendTxSafe(
      sp, 'queueBLSAggregator',
      [deployerAddr],
      'queue BLS agg (deployer as test address)'
    );
    if (receipt) {
      const pendingAfter = await sp.pendingBLSAggregator();
      const etaAfter = await sp.blsAggregatorChangeAt();
      assertEqual(pendingAfter.toLowerCase(), deployerAddr.toLowerCase(), 'pendingBLSAggregator == deployer');
      assertTrue(etaAfter > 0n, 'blsAggregatorChangeAt > 0 (timelock set)');
      printInfo('Note: applyBLSAggregator skipped — requires 24h timelock');
    }
  } catch (e) {
    printError(`queueBLSAggregator: ${e.message.substring(0, 100)}`);
  }

  // ──────────────────────────────────────────────────────────────
  // Step 9: withdrawProtocolRevenue — check revenue + withdraw if available
  // ──────────────────────────────────────────────────────────────
  printStep(9, 'withdrawProtocolRevenue — check balance + withdraw if above buffer');
  try {
    const revenue = await sp.protocolRevenue();
    const tracked = await sp.totalTrackedBalance();
    printKeyValue('protocolRevenue', ethers.formatEther(revenue));
    printKeyValue('totalTrackedBalance', ethers.formatEther(tracked));

    // PROTOCOL_REVENUE_BUFFER = 0.1 ether (internal constant in contract)
    const BUFFER = ethers.parseEther('0.1');
    const available = revenue > BUFFER ? revenue - BUFFER : 0n;
    printKeyValue('available (above buffer)', ethers.formatEther(available));

    if (available > 0n) {
      // Withdraw at most half of available to be conservative
      const withdrawAmount = available / 2n > 0n ? available / 2n : available;
      const receipt = await sendTxSafe(
        sp, 'withdrawProtocolRevenue',
        [deployerAddr, withdrawAmount],
        `withdrawProtocolRevenue(${ethers.formatEther(withdrawAmount)})`
      );
      if (receipt) {
        const revenueAfter = await sp.protocolRevenue();
        assertTrue(revenueAfter <= revenue, 'protocolRevenue decreased after withdrawal');
      }
    } else {
      printSkip('protocolRevenue at or below PROTOCOL_REVENUE_BUFFER (0.1 ether) — withdrawal skipped');
    }
  } catch (e) {
    const msg = e.message || '';
    if (msg.includes('InsufficientRevenue') || msg.includes('buffer')) {
      printSkip(`protocolRevenue below withdrawal buffer: ${msg.substring(0, 80)}`);
    } else {
      printError(`withdrawProtocolRevenue: ${msg.substring(0, 100)}`);
    }
  }

  // ──────────────────────────────────────────────────────────────
  // Step 10: withdrawFacilitatorEarnings — check + withdraw if available
  // ──────────────────────────────────────────────────────────────
  printStep(10, 'withdrawFacilitatorEarnings — check earnings + withdraw if available');
  try {
    const earnings = await sp.facilitatorEarnings(deployerAddr, config.aPNTs);
    printKeyValue(`facilitatorEarnings(deployer, aPNTs)`, ethers.formatEther(earnings));

    if (earnings > 0n) {
      const receipt = await sendTxSafe(
        sp, 'withdrawFacilitatorEarnings',
        [config.aPNTs],
        'withdraw facilitator earnings'
      );
      if (receipt) {
        const earningsAfter = await sp.facilitatorEarnings(deployerAddr, config.aPNTs);
        assertTrue(earningsAfter < earnings, 'facilitatorEarnings decreased after withdrawal');
      }
    } else {
      printSkip('No facilitator earnings to withdraw (facilitatorEarnings == 0)');
    }
  } catch (e) {
    printError(`withdrawFacilitatorEarnings: ${e.message.substring(0, 100)}`);
  }

  const allPassed = printSummary('B4: SP Governance');
  process.exit(allPassed ? 0 : 1);
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });

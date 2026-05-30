#!/usr/bin/env node
/**
 * Test Group B5: dryRunValidation and Pending Debt Recovery
 *
 * Tests:
 * - dryRunValidation: construct a minimal UserOp and call staticCall,
 *   parse the ok/reasonCode response or catch a revert gracefully.
 * - pendingDebts query: check current pending debt for deployer.
 * - retryPendingDebt / clearPendingDebt: exercised only when debt > 0.
 */
const {
  initTestEnv, getContracts, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printCriticalSkip, printInfo, printKeyValue,
  printSummary, finishTest, resetCounters,
  sendTxSafe, isInfraError, catchStep,
} = require('./test-helpers');

// SuperPaymaster extensions needed for this test group
const SP_DRY_ABI = [
  // dryRunValidation — returns (bool ok, bytes32 reasonCode); may also revert
  "function dryRunValidation((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp, uint256 maxCost) view returns (bool ok, bytes32 reasonCode)",
  // Pending debt tracking
  "function pendingDebts(address token, address user) view returns (uint256)",
  // Owner-only recovery functions
  "function retryPendingDebt(address token, address user) external",
  "function clearPendingDebt(address token, address user) external",
];

// Minimal ABIs needed to build the UserOp callData inline
const SIMPLE_ACCOUNT_ABI = [
  "function execute(address dest, uint256 value, bytes func)",
  "function getNonce() view returns (uint256)",
];

const ERC20_TRANSFER_ABI = [
  "function transfer(address to, uint256 amount) returns (bool)",
];

async function main() {
  printHeader('Test Group B5: dryRunValidation and Pending Debt Recovery');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const deployerAddr = deployer.address;

  // Augment superPaymaster contract with dry-run / debt ABI
  const sp = new ethers.Contract(config.superPaymaster, SP_DRY_ABI, deployer);

  // ──────────────────────────────────────────
  // Step 1: dryRunValidation — construct UserOp and staticCall
  // ──────────────────────────────────────────
  printStep(1, 'dryRunValidation — construct minimal UserOp and call');

  const senderAcc = process.env.TEST_AA_ACCOUNT_ADDRESS_A;
  if (!senderAcc) {
    printSkip('TEST_AA_ACCOUNT_ADDRESS_A not configured — set this env var to run dryRunValidation');
    // Continue to pending-debt steps which don't need a sender AA account
  } else {
    try {
      const operatorAddr = process.env.OPERATOR_ADDRESS || deployerAddr;

      // Build transfer(recipient, 1 ether) calldata and wrap in execute()
      const xPNTsIface = new ethers.Interface(ERC20_TRANSFER_ABI);
      const recipient = process.env.TEST_EOA_ADDRESS || deployerAddr;
      const transferCalldata = xPNTsIface.encodeFunctionData('transfer', [recipient, ethers.parseEther('1')]);

      const saIface = new ethers.Interface(SIMPLE_ACCOUNT_ABI);
      const callData = saIface.encodeFunctionData('execute', [config.aPNTs, 0n, transferCalldata]);

      // Fetch current nonce for the AA account
      const simpleAccount = new ethers.Contract(senderAcc, SIMPLE_ACCOUNT_ABI, provider);
      let nonce = 0n;
      try {
        nonce = await simpleAccount.getNonce();
        printKeyValue('AA account nonce', nonce.toString());
      } catch (_) {
        printInfo('Could not fetch AA nonce (account may not be deployed) — using 0');
      }

      // paymasterAndData: [superPaymaster (20B)] [pmVerifGas uint128 (16B)] [pmPostOpGas uint128 (16B)] [operator (20B)]
      const pmVerificationGasLimit = 150000n;
      const pmPostOpGasLimit = 200000n;
      const paymasterAndData = ethers.solidityPacked(
        ['address', 'uint128', 'uint128', 'address'],
        [config.superPaymaster, pmVerificationGasLimit, pmPostOpGasLimit, operatorAddr]
      );

      const userOp = {
        sender: senderAcc,
        nonce: nonce,
        initCode: '0x',
        callData: callData,
        accountGasLimits: ethers.solidityPacked(['uint128', 'uint128'], [200000n, 200000n]),
        preVerificationGas: 100000n,
        gasFees: ethers.solidityPacked(['uint128', 'uint128'], [2000000000n, 2000000000n]),
        paymasterAndData: paymasterAndData,
        signature: '0x' + '00'.repeat(65),
      };

      const maxCost = ethers.parseEther('0.01');

      printInfo(`sender: ${senderAcc}`);
      printInfo(`operator: ${operatorAddr}`);

      try {
        const [ok, reasonCode] = await sp.dryRunValidation(userOp, maxCost);
        printKeyValue('dryRunValidation ok', ok);
        printKeyValue('reasonCode (bytes32)', reasonCode);
        if (ok) {
          printSuccess('dryRunValidation returned ok=true (UserOp would pass validation)');
        } else {
          // A non-ok result is a valid outcome — we just surface the reason code
          printInfo(`dryRunValidation returned ok=false — reasonCode: ${reasonCode}`);
          printSuccess(`dryRunValidation call succeeded (returned false with reason code)`);
        }
      } catch (callErr) {
        // A transient RPC error must not be read as a contract revert.
        if (isInfraError(callErr)) {
          printCriticalSkip(`dryRunValidation: transient RPC error — ${(callErr.message || '').substring(0, 50)}`);
        } else {
          const reason = callErr.reason || callErr.shortMessage || (callErr.message || '').substring(0, 120);
          printInfo(`dryRunValidation reverted: ${reason}`);
          // SPECIFIC expected-precondition signatures only — NOT the generic
          // 'execution reverted' / '0x' (those match almost any revert and would
          // mask a real failure).
          const knownFailures = [
            'not configured', 'not eligible', 'paused', 'blocked', 'rate',
            'operatornotconfigured', 'usernoteligible', 'pricetoostale', 'stale_price',
            'insufficient_balance', 'dryrun_',
          ];
          const isExpected = knownFailures.some(kw => reason.toLowerCase().includes(kw));
          if (isExpected) {
            printSuccess(`dryRunValidation reverted with expected precondition reason`);
          } else {
            printError(`dryRunValidation reverted unexpectedly: ${reason}`);
          }
        }
      }
    } catch (e) {
      catchStep('B5 Step 1 setup', e);
    }
  }

  // ──────────────────────────────────────────
  // Step 2: Check for pending debts
  // ──────────────────────────────────────────
  printStep(2, 'Check for pending debts (pendingDebts[aPNTs][deployer])');

  let pendingDebt = 0n;
  try {
    pendingDebt = await sp.pendingDebts(config.aPNTs, deployerAddr);
    printKeyValue('pendingDebts[aPNTs][deployer]', ethers.formatEther(pendingDebt));

    if (pendingDebt === 0n) {
      printSuccess('pendingDebts query succeeded — returned 0 (no pending debt)');
    } else {
      printSuccess(`pendingDebts query succeeded — ${ethers.formatEther(pendingDebt)} aPNTs pending`);
    }
  } catch (e) {
    catchStep(`pendingDebts query failed`, e);
    // Cannot proceed with retry/clear if query itself failed
    process.exit(finishTest('B5: dryRunValidation and Pending Debt Recovery'));
  }

  // ──────────────────────────────────────────
  // Step 3: retryPendingDebt — attempt to convert pending debt to recorded debt
  // ──────────────────────────────────────────
  printStep(3, 'retryPendingDebt — retry converting pending debt to xPNTs recorded debt');

  if (pendingDebt === 0n) {
    printSkip('No pending debts — retryPendingDebt not applicable');
  } else {
    try {
      const r = await sendTxSafe(sp, 'retryPendingDebt', [config.aPNTs, deployerAddr], 'retryPendingDebt');
      if (r) {
        const debtAfter = await sp.pendingDebts(config.aPNTs, deployerAddr);
        printKeyValue('pendingDebt after retry', ethers.formatEther(debtAfter));
        if (debtAfter < pendingDebt) {
          printSuccess(`pendingDebt decreased after retryPendingDebt (${ethers.formatEther(pendingDebt)} → ${ethers.formatEther(debtAfter)})`);
          pendingDebt = debtAfter;
        } else {
          // retryPendingDebt deletes the mapping then calls xPNTs.recordDebt.
          // If recordDebt succeeds, pendingDebts[token][user] is now 0.
          // If recordDebt reverts, retryPendingDebt itself reverts (no partial state).
          printInfo(`pendingDebt unchanged after retry — xPNTs.recordDebt may have also reverted`);
        }
      }
    } catch (e) {
      catchStep(`retryPendingDebt failed`, e);
    }
  }

  // ──────────────────────────────────────────
  // Step 4: clearPendingDebt — emergency debt forgiveness
  // ──────────────────────────────────────────
  printStep(4, 'clearPendingDebt — emergency escape-hatch debt forgiveness');

  // Re-read in case step 3 changed the value
  let debtForClear = 0n;
  try {
    debtForClear = await sp.pendingDebts(config.aPNTs, deployerAddr);
  } catch (_) {}

  if (debtForClear === 0n) {
    printSkip('No pending debts — clearPendingDebt not applicable');
    printInfo('clearPendingDebt forgives debt irrecoverably — only use in emergency');
  } else {
    printInfo('clearPendingDebt forgives debt — only use in emergency');
    try {
      const r = await sendTxSafe(sp, 'clearPendingDebt', [config.aPNTs, deployerAddr], 'clearPendingDebt');
      if (r) {
        const debtAfter = await sp.pendingDebts(config.aPNTs, deployerAddr);
        printKeyValue('pendingDebt after clear', ethers.formatEther(debtAfter));
        if (debtAfter === 0n) {
          printSuccess('clearPendingDebt succeeded — pendingDebt is now 0');
        } else {
          printError(`pendingDebt still non-zero after clearPendingDebt: ${ethers.formatEther(debtAfter)}`);
        }
      }
    } catch (e) {
      catchStep(`clearPendingDebt failed`, e);
    }
  }

  process.exit(finishTest('B5: dryRunValidation and Pending Debt Recovery'));
}

main().catch(err => {
  const m = (err.message || '').toLowerCase();
  const isNet = m.includes('socket hang up') || m.includes('econnreset') ||
    m.includes('timeout') || m.includes('etimedout') || m.includes('request timeout');
  if (isNet) { console.error('Fatal (network):', err.message.substring(0, 80)); process.exit(2); }
  console.error('Fatal:', err.message);
  process.exit(1);
});

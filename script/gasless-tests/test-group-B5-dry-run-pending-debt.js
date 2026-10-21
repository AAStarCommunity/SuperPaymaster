#!/usr/bin/env node
/**
 * Test Group B5: dryRunValidation and Debt Accounting (5.5.0 rewrite)
 *
 * 3.x this test exercised SP's pendingDebts[token][user] mapping plus the owner-only
 * retryPendingDebt/clearPendingDebt recovery functions. All three are GONE in 5.5.0
 * (spec 03 §1: "3.x 的 burnFromWithOpHash、recordDebt、recordDebtWithOpHash 在 v2 模板里
 * 全部删除... 新的信用路径只通过预留→结算产生债务") — `pendingDebts` is still a storage
 * slot on SP (SuperPaymasterStorage.sol:95) but is now `internal` with no writer, a dead
 * leftover, not a public mapping with recovery functions. There is no owner-side debt
 * forgiveness escape hatch anymore: debt only shrinks via the user's own token.repayDebt()
 * or automatically on mint (xPNTsV2Base.sol A-1). This rewrite verifies debt accounting
 * through the actual 5.5.0 surface instead of the retired one:
 *
 * Tests:
 * - dryRunValidation (now on SuperPaymasterLens): construct a minimal UserOp and call
 *   staticCall, parse the ok/reasonCode response or catch a revert gracefully.
 * - token.debts(user): the single source of truth for aPNTs debt (replaces the old
 *   two-stage pendingDebts→recordDebt split).
 * - token.repayDebt(): the only way debt decreases (besides auto-offset on mint) — this
 *   was formerly reachable indirectly via retryPendingDebt/clearPendingDebt; there is no
 *   replacement for admin-side forgiveness, so this test does not attempt one.
 */
const {
  initTestEnv, getContracts, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printCriticalSkip, printInfo, printKeyValue,
  printSummary, finishTest, resetCounters,
  sendTxSafe, isInfraError, catchStep,
} = require('./test-helpers');

// Minimal ABIs needed to build the UserOp callData inline
const SIMPLE_ACCOUNT_ABI = [
  "function execute(address dest, uint256 value, bytes func)",
  "function getNonce() view returns (uint256)",
];

const ERC20_TRANSFER_ABI = [
  "function transfer(address to, uint256 amount) returns (bool)",
];

async function main() {
  printHeader('Test Group B5: dryRunValidation and Debt Accounting (5.5.0)');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const sp = c.superPaymaster;
  const lens = c.superPaymasterLens;
  const deployerAddr = deployer.address;

  // ──────────────────────────────────────────
  // Step 1: dryRunValidation (via SuperPaymasterLens) — construct UserOp and staticCall
  // ──────────────────────────────────────────
  printStep(1, 'dryRunValidation (via SuperPaymasterLens) — construct minimal UserOp and call');

  const senderAcc = process.env.TEST_AA_ACCOUNT_ADDRESS_A;
  if (!lens) {
    printSkip('config.superPaymasterLens missing — dryRunValidation moved there in 5.5.0');
  } else if (!senderAcc) {
    printSkip('TEST_AA_ACCOUNT_ADDRESS_A not configured — set this env var to run dryRunValidation');
    // Continue to debt-accounting steps which don't need a sender AA account
  } else {
    try {
      const operatorAddr = process.env.OPERATOR_ADDRESS || deployerAddr;
      const opConfig = await sp.operators(operatorAddr);
      const xToken = opConfig.xPNTsToken;

      // Build transfer(recipient, 1 ether) calldata and wrap in execute()
      const xPNTsIface = new ethers.Interface(ERC20_TRANSFER_ABI);
      const recipient = process.env.TEST_EOA_ADDRESS || deployerAddr;
      const transferCalldata = xPNTsIface.encodeFunctionData('transfer', [recipient, ethers.parseEther('1')]);

      const saIface = new ethers.Interface(SIMPLE_ACCOUNT_ABI);
      const callData = saIface.encodeFunctionData('execute', [xToken, 0n, transferCalldata]);

      // Fetch current nonce for the AA account
      const simpleAccount = new ethers.Contract(senderAcc, SIMPLE_ACCOUNT_ABI, provider);
      let nonce = 0n;
      try {
        nonce = await simpleAccount.getNonce();
        printKeyValue('AA account nonce', nonce.toString());
      } catch (_) {
        printInfo('Could not fetch AA nonce (account may not be deployed) — using 0');
      }

      // 5.5.0 validation does more external-call work than 3.x (exchangeRate + tryLockForGas),
      // 150K measured AA36 on a cold account — see test-case-2-fixed.js for the same bump.
      const pmVerificationGasLimit = 400000n;
      const pmPostOpGasLimit = 200000n;
      // paymasterAndData (SuperPaymasterStorage.sol:177-180):
      // [paymaster(20)][pmVerGas(16)][pmPostGas(16)][operator(20)][maxRate(32)][token(20)][flags(1)]
      const paymasterAndData = ethers.solidityPacked(
        ['address', 'uint128', 'uint128', 'address', 'uint256', 'address', 'uint8'],
        [config.superPaymaster, pmVerificationGasLimit, pmPostOpGasLimit, operatorAddr,
         ethers.MaxUint256, xToken, 0]
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
      printInfo(`token: ${xToken}`);

      try {
        const [ok, reasonCode] = await lens.dryRunValidation(config.superPaymaster, userOp, maxCost);
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
            'insufficient_balance', 'dryrun_', 'version_mismatch',
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
  // Step 2: token.debts(deployer) — 5.5.0's single source of truth for aPNTs debt
  // ──────────────────────────────────────────
  printStep(2, "token.debts(deployer) — 5.5.0's unified debt accounting");

  const xpnts = c.aastarXPNTsV2;
  let debt = 0n;
  if (!xpnts) {
    printSkip('config.aastarXPNTsV2 missing — cannot read v2 debt accounting');
  } else {
    try {
      debt = await xpnts.debts(deployerAddr);
      printKeyValue('token.debts(deployer)', ethers.formatEther(debt));

      if (debt === 0n) {
        printSuccess('debts() query succeeded — returned 0 (no outstanding debt)');
      } else {
        printSuccess(`debts() query succeeded — ${ethers.formatEther(debt)} aPNTs owed`);
      }
    } catch (e) {
      catchStep(`token.debts() query failed`, e);
    }
  }

  // ──────────────────────────────────────────
  // Step 3: token.repayDebt() — the only way debt shrinks besides auto-offset on mint.
  // 5.5.0 removed SP's owner-only retryPendingDebt/clearPendingDebt recovery path
  // entirely (see file header) — there is no admin-side equivalent to exercise here.
  // ──────────────────────────────────────────
  printStep(3, 'token.repayDebt() — user self-service debt repayment (only path left)');

  if (!xpnts) {
    printSkip('config.aastarXPNTsV2 missing — cannot attempt repayDebt');
  } else if (debt === 0n) {
    printSkip('No outstanding debt — repayDebt not applicable');
  } else {
    try {
      const balance = await xpnts.balanceOf(deployerAddr);
      if (balance === 0n) {
        printSkip('Deployer has debt but zero xPNTs balance — cannot repay');
      } else {
        const rate = await xpnts.exchangeRate();
        // repayDebt computes repaid = floor(amountXPNTs * 1e18 / rate) and REVERTS
        // (RepayExceedsDebt) if repaid > currentDebt (xPNTsTokenV2Ext.sol repayDebt) — so the
        // xPNTs amount we send must itself be floor-rounded, not ceil: x = floor(debt*rate/1e18)
        // guarantees x*1e18 <= debt*rate, hence floor(x*1e18/rate) <= debt always (no
        // double-rounding overshoot). Ceil here could push repaid 1 wei past debt and revert.
        // This floor rounding can leave a few wei of dust debt unrepaid — that's expected,
        // not a bug, so we only assert the debt decreased, not that it reaches exactly 0.
        const ONE18 = 1000000000000000000n;
        const neededXPNTs = (debt * rate) / ONE18; // floor
        const repayAmount = balance < neededXPNTs ? balance : neededXPNTs;
        if (repayAmount === 0n) {
          printSkip('Computed repay amount rounds to 0 xPNTs (debt smaller than 1 wei at this rate) — nothing to repay');
        } else {
          const r = await sendTxSafe(xpnts, 'repayDebt', [repayAmount], 'repayDebt');
          if (r) {
            const debtAfter = await xpnts.debts(deployerAddr);
            printKeyValue('debt after repayDebt', ethers.formatEther(debtAfter));
            if (debtAfter < debt) {
              printSuccess(`debt decreased after repayDebt (${ethers.formatEther(debt)} → ${ethers.formatEther(debtAfter)}, floor rounding may leave dust)`);
            } else {
              printError('debt did not decrease after a successful repayDebt TX');
            }
          }
        }
      }
    } catch (e) {
      catchStep('repayDebt failed', e);
    }
  }

  // ──────────────────────────────────────────
  // Step 4: no owner-side debt-forgiveness escape hatch exists in 5.5.0 (documented, not tested)
  // ──────────────────────────────────────────
  printStep(4, 'Owner debt forgiveness — retired in 5.5.0, nothing to exercise');
  printInfo('3.x clearPendingDebt (owner-only emergency forgiveness) has no 5.5.0 replacement.');
  printInfo('Debt only shrinks via repayDebt (Step 3) or automatic offset on mint (xPNTsV2Base A-1).');
  printSkip('No admin recovery function to test — intentional 5.5.0 design change, not a gap');

  process.exit(finishTest('B5: dryRunValidation and Debt Accounting'));
}

main().catch(err => {
  const m = (err.message || '').toLowerCase();
  const isNet = m.includes('socket hang up') || m.includes('econnreset') ||
    m.includes('timeout') || m.includes('etimedout') || m.includes('request timeout');
  if (isNet) { console.error('Fatal (network):', err.message.substring(0, 80)); process.exit(2); }
  console.error('Fatal:', err.message);
  process.exit(1);
});

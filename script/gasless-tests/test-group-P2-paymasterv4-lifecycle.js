#!/usr/bin/env node
/**
 * Test Group P2: PaymasterV4 Lifecycle
 *
 * Tests PaymasterV4 lifecycle functions that have no current E2E coverage:
 * - deactivateFromRegistry / activateInRegistry (pause toggle)
 * - depositFor / withdraw (token balance management)
 * - updatePrice / cachedPrice (price cache refresh)
 */
const {
  initTestEnv, getContracts, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, finishTest, resetCounters,
  assertTrue, assertFalse,
  sendTxSafe, catchStep,
} = require('./test-helpers');

// Extended ABI covering Paymaster.sol + PaymasterBase.sol lifecycle surface
const PMV4_ABI = [
  "function version() view returns (string)",
  "function owner() view returns (address)",
  "function registry() view returns (address)",
  "function isActiveInRegistry() view returns (bool)",
  "function deactivateFromRegistry() external",
  "function activateInRegistry() external",
  "function paused() view returns (bool)",
  "function balances(address user, address token) view returns (uint256)",
  "function depositFor(address user, address token, uint256 amount) external",
  "function withdraw(address token, uint256 amount) external",
  "function getSupportedTokens() view returns (address[])",
  "function isTokenSupported(address token) view returns (bool)",
  "function updatePrice() external",
  "function cachedPrice() view returns (uint208 price, uint48 updatedAt)",
];

// PaymasterFactory ABI extension (getPaymasterByOperator not in test-helpers PaymasterFactory ABI)
const FACTORY_EXTRA_ABI = [
  "function getPaymasterByOperator(address operator) view returns (address)",
];

// ERC20 approve ABI (for depositFor pre-approval)
const ERC20_APPROVE_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
];

async function main() {
  printHeader('Test Group P2: PaymasterV4 Lifecycle');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const deployerAddr = deployer.address;

  // Augment pmFactory with getPaymasterByOperator
  const pmFactory = new ethers.Contract(config.paymasterFactory, FACTORY_EXTRA_ABI, deployer);

  // ──────────────────────────────────────────
  // Step 1: Read deployer's PaymasterV4 state
  // ──────────────────────────────────────────
  printStep(1, "Read deployer's PaymasterV4 state");

  let pmAddr = null;
  let pm = null;

  try {
    pmAddr = await pmFactory.getPaymasterByOperator(deployerAddr);
    printKeyValue('PaymasterV4 address', pmAddr);
  } catch (e) {
    catchStep(`getPaymasterByOperator failed`, e);
    printSummary('P2: PaymasterV4 Lifecycle');
    process.exit(1);
  }

  if (pmAddr === ethers.ZeroAddress) {
    printSkip('deployer has no PaymasterV4 — run prepare-test first');
    printSummary('P2: PaymasterV4 Lifecycle');
    process.exit(2);
  }

  pm = new ethers.Contract(pmAddr, PMV4_ABI, deployer);

  try {
    const ver = await pm.version();
    const owner = await pm.owner();
    const isActive = await pm.isActiveInRegistry();
    const tokens = await pm.getSupportedTokens();
    printKeyValue('version', ver);
    printKeyValue('owner', owner);
    printKeyValue('isActiveInRegistry', isActive);
    printKeyValue('supported tokens count', tokens.length);
    for (const t of tokens) {
      printKeyValue('  token', t);
    }
    printSuccess('Read PaymasterV4 state');
  } catch (e) {
    catchStep(`Read state failed`, e);
    printSummary('P2: PaymasterV4 Lifecycle');
    process.exit(1);
  }

  // ──────────────────────────────────────────
  // Step 2: deactivateFromRegistry + activateInRegistry (lifecycle toggle)
  // ──────────────────────────────────────────
  printStep(2, 'deactivateFromRegistry + activateInRegistry (lifecycle toggle)');

  try {
    const wasPaused = await pm.paused();
    printKeyValue('paused before', wasPaused);

    if (!wasPaused) {
      // Deactivate (sets paused=true)
      const r1 = await sendTxSafe(pm, 'deactivateFromRegistry', [], 'deactivate');
      if (r1) {
        const pausedAfterDeactivate = await pm.paused();
        printKeyValue('paused after deactivateFromRegistry', pausedAfterDeactivate);
        assertTrue(pausedAfterDeactivate, 'paused == true after deactivate');
      }
    } else {
      printInfo('Already paused — skipping deactivate, going straight to activate');
    }

    // Re-activate (sets paused=false)
    const r2 = await sendTxSafe(pm, 'activateInRegistry', [], 'activate');
    if (r2) {
      const pausedAfterActivate = await pm.paused();
      printKeyValue('paused after activateInRegistry', pausedAfterActivate);
      assertFalse(pausedAfterActivate, 'paused == false after activate');
    }

    // Confirm isActiveInRegistry reflects the restored state
    const isActiveNow = await pm.isActiveInRegistry();
    printKeyValue('isActiveInRegistry after full toggle', isActiveNow);
    // isActiveInRegistry also checks registry role — it may be false if operator
    // lacks PAYMASTER_AOA role, which is OK for this test; we just print it.
    printSuccess('Lifecycle toggle completed without error');
  } catch (e) {
    catchStep(`Lifecycle toggle failed`, e);
  }

  // ──────────────────────────────────────────
  // Step 3: depositFor — deposit tokens for a user
  // ──────────────────────────────────────────
  printStep(3, 'depositFor — deposit tokens for a user');

  const tokenAddr = config.aPNTs;
  const user = process.env.TEST_AA_ACCOUNT_ADDRESS_A || deployerAddr;
  const depositAmount = ethers.parseEther('1'); // 1 aPNTs

  try {
    // Check whether the token is supported by this PaymasterV4
    const tokenSupported = await pm.isTokenSupported(tokenAddr);
    printKeyValue('aPNTs supported by this PMV4', tokenSupported);

    if (!tokenSupported) {
      printSkip('aPNTs token not supported by this PaymasterV4 — depositFor not applicable');
    } else {
      // Check deployer's aPNTs balance
      const aPNTsToken = new ethers.Contract(tokenAddr, ERC20_APPROVE_ABI, deployer);
      const balance = await aPNTsToken.balanceOf(deployerAddr);
      printKeyValue('deployer aPNTs balance', ethers.formatEther(balance));

      if (balance < depositAmount) {
        printSkip(`insufficient aPNTs for depositFor test (have ${ethers.formatEther(balance)}, need 1)`);
      } else {
        // Approve PM to pull tokens
        const currentAllowance = await aPNTsToken.allowance(deployerAddr, pmAddr);
        if (currentAllowance < depositAmount) {
          const ra = await sendTxSafe(aPNTsToken, 'approve', [pmAddr, depositAmount], 'approve PM for aPNTs');
          if (!ra) {
            printSkip('approve failed — skipping depositFor');
          }
        } else {
          printInfo('Allowance already sufficient, skipping approve');
        }

        // Record balance before
        const balBefore = await pm.balances(user, tokenAddr);
        printKeyValue('user PM balance before', ethers.formatEther(balBefore));

        // Deposit
        const rd = await sendTxSafe(pm, 'depositFor', [user, tokenAddr, depositAmount], 'depositFor(user, aPNTs, 1)');
        if (rd) {
          const balAfter = await pm.balances(user, tokenAddr);
          printKeyValue('user PM balance after', ethers.formatEther(balAfter));
          const increased = balAfter >= balBefore + depositAmount;
          assertTrue(increased, 'balance increased by depositAmount after depositFor');
        }
      }
    }
  } catch (e) {
    catchStep(`depositFor step failed`, e);
  }

  // ──────────────────────────────────────────
  // Step 4: withdraw — withdraw tokens back (deployer withdraws own balance)
  // ──────────────────────────────────────────
  printStep(4, 'withdraw — withdraw tokens back');

  try {
    const tokenSupported = await pm.isTokenSupported(tokenAddr);
    if (!tokenSupported) {
      printSkip('aPNTs token not supported — skipping withdraw');
    } else {
      // Deployer's own balance in the PMV4
      const deployerBal = await pm.balances(deployerAddr, tokenAddr);
      printKeyValue('deployer PMV4 balance', ethers.formatEther(deployerBal));

      // If step 3 deposited to user == deployerAddr, withdrawAmount is available;
      // otherwise we use whatever deployer balance already exists.
      const withdrawAmount = deployerBal < depositAmount ? deployerBal : depositAmount;

      if (withdrawAmount === 0n) {
        printSkip('no deployer balance to withdraw — depositFor may have used a different user address');
      } else {
        const balBefore = await pm.balances(deployerAddr, tokenAddr);
        const rw = await sendTxSafe(pm, 'withdraw', [tokenAddr, withdrawAmount], 'withdraw(aPNTs, amount)');
        if (rw) {
          const balAfter = await pm.balances(deployerAddr, tokenAddr);
          printKeyValue('deployer PMV4 balance after withdraw', ethers.formatEther(balAfter));
          const decreased = balAfter <= balBefore - withdrawAmount;
          assertTrue(decreased, 'balance decreased after withdraw');
        }
      }
    }
  } catch (e) {
    catchStep(`withdraw step failed`, e);
  }

  // ──────────────────────────────────────────
  // Step 5: updatePrice — refresh PaymasterV4 price cache
  // ──────────────────────────────────────────
  printStep(5, 'updatePrice — refresh PaymasterV4 price cache');

  try {
    const before = await pm.cachedPrice();
    printKeyValue('cachedPrice.updatedAt before', before.updatedAt.toString());
    printKeyValue('cachedPrice.price before', before.price.toString());

    const ru = await sendTxSafe(pm, 'updatePrice', [], 'updatePrice');
    if (ru) {
      const after = await pm.cachedPrice();
      printKeyValue('cachedPrice.updatedAt after', after.updatedAt.toString());
      printKeyValue('cachedPrice.price after', after.price.toString());
      const freshened = after.updatedAt >= before.updatedAt;
      assertTrue(freshened, 'cachedPrice.updatedAt >= before.updatedAt after updatePrice');
    }
  } catch (e) {
    catchStep(`updatePrice step failed`, e);
  }

  process.exit(finishTest('P2: PaymasterV4 Lifecycle'));
}

main().catch(err => {
  const m = (err.message || '').toLowerCase();
  const isNet = m.includes('socket hang up') || m.includes('econnreset') ||
    m.includes('timeout') || m.includes('etimedout') || m.includes('request timeout');
  if (isNet) { console.error('Fatal (network):', err.message.substring(0, 80)); process.exit(2); }
  console.error('Fatal:', err.message);
  process.exit(1);
});

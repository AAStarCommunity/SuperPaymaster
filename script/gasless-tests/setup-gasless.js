#!/usr/bin/env node
/**
 * Pre-flight Setup for Gasless Tests
 *
 * Checks and fixes ALL prerequisites for test-case-1/2/3 before running them.
 * Safe to run repeatedly (idempotent checks, only acts when needed).
 *
 * Prerequisites managed:
 *   Test 1 (PaymasterV4 + aPNTs):
 *     - PaymasterV4 deployed for deployer ✓ check
 *     - AA_A token deposit in PaymasterV4 ✓ check + auto-fund
 *     - PaymasterV4 ETH in EntryPoint ✓ check
 *
 *   Test 2 (SuperPaymaster + aPNTs, deployer operator):
 *     - Deployer operator configured in SP ✓ check
 *     - Deployer operator aPNTs balance > 0 ✓ check + auto-deposit
 *     - Price cache fresh ✓ check + auto-refresh
 *
 *   Test 3 (SuperPaymaster + PNTs, Anni operator):
 *     - Anni operator configured in SP ✓ check
 *     - Anni operator PNTs balance > 0 ✓ check (Anni's private key needed for deposit)
 *     - Price cache fresh ✓ covered by Test 2 refresh
 *
 *   All tests:
 *     - AA accounts have token balance ✓ check (use transfer-tokens.js to fund)
 *
 * EXIT CODES:
 *   0 = all prerequisites met (or fixed successfully)
 *   1 = unrecoverable failure (manual intervention needed)
 */

const { ethers } = require('ethers');
const path = require('path');
const { loadConfig } = require('./load-config');
require('dotenv').config({ path: process.env.ENV_FILE || path.join(__dirname, '../../.env.sepolia') });

const ERC20_ABI = [
  'function balanceOf(address) view returns (uint256)',
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
  'function approve(address spender, uint256 amount) returns (bool)',
  'function allowance(address owner, address spender) view returns (uint256)',
];

const ENTRYPOINT_ABI = [
  'function getDepositInfo(address) view returns (uint112 deposit, bool staked, uint112 stake, uint32 unstakeDelaySec, uint48 withdrawTime)',
];

const PAYMASTER_V4_ABI = [
  'function balances(address user, address token) view returns (uint256)',
  'function depositFor(address user, address token, uint256 amount) external',
  'function version() view returns (string)',
  'function cachedPrice() view returns (uint208 price, uint48 updatedAt)',
  'function setCachedPrice(uint256 price, uint48 timestamp) external',
  'function priceStalenessThreshold() view returns (uint48)',
];

const SP_ABI = [
  'function operators(address) view returns (uint128 aPNTsBalance, uint256 exchangeRate, bool isConfigured, bool isPaused, address xPNTsToken, uint256 reputation, uint48 minTxInterval, address treasury, uint256 totalSpent, uint256 totalTxSponsored)',
  'function deposit(uint256 amount) external',
  'function updatePrice() external',
  'function priceValidUntil() view returns (uint48)',
  'function cachedPrice() view returns (int256 price, uint256 updatedAt, uint80 roundId, uint8 decimals)',
];

const PM_FACTORY_ABI = [
  'function paymasterByOperator(address) view returns (address)',
];

const PASS = '✅';
const FAIL = '❌';
const WARN = '⚠️ ';

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║         Gasless Tests Pre-Flight Setup                    ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  const config = loadConfig();
  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  const pk = process.env.OWNER_PRIVATE_KEY || process.env.DEPLOYER_PRIVATE_KEY;
  if (!rpcUrl) throw new Error('SEPOLIA_RPC_URL not set');
  if (!pk) throw new Error('OWNER_PRIVATE_KEY not set');

  const provider = new ethers.JsonRpcProvider(rpcUrl, 11155111, { staticNetwork: true });
  const wallet = new ethers.Wallet(pk, provider);
  const deployer = wallet.address;

  console.log(`Deployer: ${deployer}`);
  console.log(`Network:  Sepolia (chain 11155111)\n`);

  const APNTS = config.aPNTs;
  const PNTS  = config.pnts;
  const SP    = config.superPaymaster;
  const EP    = config.entryPoint;
  const PMF   = config.paymasterFactory;
  const AA_A  = process.env.TEST_AA_ACCOUNT_ADDRESS_A;
  const AA_B  = process.env.TEST_AA_ACCOUNT_ADDRESS_B;
  const AA_C  = process.env.TEST_AA_ACCOUNT_ADDRESS_C;
  const ANNI  = process.env.OPERATOR_ADDRESS_PNTS || process.env.OPERATOR_ADDRESS || '0xEcAACb915f7D92e9916f449F7ad42BD0408733c9';

  if (!AA_A || !AA_B || !AA_C) throw new Error('TEST_AA_ACCOUNT_ADDRESS_A/B/C not set in .env.sepolia');

  const apnts   = new ethers.Contract(APNTS, ERC20_ABI, provider);
  const pnts    = new ethers.Contract(PNTS,  ERC20_ABI, provider);
  const sp      = new ethers.Contract(SP, SP_ABI, wallet);
  const ep      = new ethers.Contract(EP, ENTRYPOINT_ABI, provider);
  const pmf     = new ethers.Contract(PMF, PM_FACTORY_ABI, provider);

  let failures = 0;
  const check = (label, ok, detail = '') => {
    const icon = ok ? PASS : FAIL;
    console.log(`  ${icon} ${label}${detail ? ': ' + detail : ''}`);
    if (!ok) failures++;
  };

  // ──────────────────────────────────────────────────────────────────────────
  // 1. Price cache refresh (needed for ALL SuperPaymaster tests)
  // The cache has priceStalenessThreshold (default 4200s / 70min) validity.
  // Call updatePrice() whenever the cache is expired or within 10 min of expiry.
  // ──────────────────────────────────────────────────────────────────────────
  console.log('━━━ Step 1: SuperPaymaster Price Cache ━━━');
  try {
    const validUntil = await sp.priceValidUntil();
    const now = BigInt(Math.floor(Date.now() / 1000));
    const secsRemaining = validUntil - now;
    const REFRESH_THRESHOLD = 600n; // refresh if < 10 min remaining
    if (validUntil === 0n || secsRemaining < REFRESH_THRESHOLD) {
      const label = validUntil === 0n ? 'not initialized' : `expires in ${secsRemaining}s`;
      console.log(`  ${WARN} Price cache ${label} — calling updatePrice()...`);
      const tx = await sp.updatePrice();
      console.log(`  Sent updatePrice(): ${tx.hash}`);
      await tx.wait();
      const newUntil = await sp.priceValidUntil();
      console.log(`  ${PASS} Price cache refreshed. Valid until: ${newUntil} (${newUntil - now}s from now)`);
    } else {
      check('Price cache fresh', true, `valid for ${secsRemaining}s`);
    }
  } catch (e) {
    check('Price cache refresh', false, e.message.substring(0, 100));
  }
  console.log();

  // ──────────────────────────────────────────────────────────────────────────
  // 2. Test 1: PaymasterV4 setup
  // ──────────────────────────────────────────────────────────────────────────
  console.log('━━━ Step 2: PaymasterV4 (Test 1) ━━━');
  const pmV4Addr = await pmf.paymasterByOperator(deployer);
  if (pmV4Addr === ethers.ZeroAddress) {
    check('PaymasterV4 deployed', false, 'run prepare-test sepolia first');
  } else {
    check('PaymasterV4 deployed', true, pmV4Addr);
    const pmV4 = new ethers.Contract(pmV4Addr, PAYMASTER_V4_ABI, wallet);

    // ETH deposit in EntryPoint
    const epInfo = await ep.getDepositInfo(pmV4Addr);
    check('PaymasterV4 ETH in EntryPoint', epInfo.deposit > 0n,
      `${ethers.formatEther(epInfo.deposit)} ETH`);

    // Price cache for PaymasterV4
    // PaymasterV4 stores Chainlink's updatedAt (not block.timestamp), so if Chainlink
    // hasn't published a new round, calling updatePrice() leaves validUntil in the past.
    // Fix: use setCachedPrice(price, block.timestamp - 60) to force a fresh validUntil.
    try {
      const v4Cache = await pmV4.cachedPrice();
      const v4Staleness = await pmV4.priceStalenessThreshold();
      const nowSec = BigInt(Math.floor(Date.now() / 1000));
      const v4ValidUntil = v4Cache.updatedAt + v4Staleness;
      const REFRESH_THRESHOLD_V4 = 600n;
      if (v4Cache.updatedAt === 0n || v4ValidUntil < nowSec + REFRESH_THRESHOLD_V4) {
        const label = v4Cache.updatedAt === 0n ? 'not initialized' : `expires in ${v4ValidUntil - nowSec}s`;
        console.log(`  ${WARN} PaymasterV4 price cache ${label} — calling setCachedPrice()...`);
        // Use current price from cache (or 0 if uninitialized); owner must call this.
        const freshTs = BigInt(Math.floor(Date.now() / 1000) - 60);
        const setCacheTx = await pmV4.setCachedPrice(v4Cache.price || 224913120000n, freshTs);
        console.log(`  Sent setCachedPrice(): ${setCacheTx.hash}`);
        await setCacheTx.wait();
        const v4CacheNew = await pmV4.cachedPrice();
        const newValidUntil = v4CacheNew.updatedAt + v4Staleness;
        console.log(`  ${PASS} PaymasterV4 price refreshed. Valid until: ${newValidUntil} (${newValidUntil - nowSec}s from now)`);
      } else {
        check('PaymasterV4 price cache fresh', true, `valid for ${v4ValidUntil - nowSec}s`);
      }
    } catch (e) {
      check('PaymasterV4 price cache', false, e.message.substring(0, 100));
    }

    // Token deposit for AA_A
    const aa_a_deposit = await pmV4.balances(AA_A, APNTS);
    // PaymasterV4 charges: gas_cost_wei * eth_usd * (1 + service_fee + validation_buffer) / token_price
    // At 2 gwei × 680k gas × $2249/ETH / $0.02 per aPNTs ≈ 170 aPNTs per tx.
    // Keep at least 500 to handle price fluctuations and multiple test runs.
    const REQUIRED_DEPOSIT = ethers.parseUnits('200', 18); // 200 aPNTs minimum
    if (aa_a_deposit < REQUIRED_DEPOSIT) {
      const depositAmount = ethers.parseUnits('500', 18); // deposit 500 aPNTs
      console.log(`  ${WARN} AA_A token deposit in PaymasterV4: ${ethers.formatEther(aa_a_deposit)} aPNTs — funding 500 aPNTs...`);
      // Deployer must approve PaymasterV4 to spend their aPNTs, then call depositFor
      const apntsWithSigner = new ethers.Contract(APNTS, ERC20_ABI, wallet);
      const deployerBalance = await apnts.balanceOf(deployer);
      if (deployerBalance < depositAmount) {
        check('Deployer aPNTs for V4 deposit', false,
          `only ${ethers.formatEther(deployerBalance)} aPNTs — need ${ethers.formatEther(depositAmount)}`);
      } else {
        const allowance = await apnts.allowance(deployer, pmV4Addr);
        if (allowance < depositAmount) {
          console.log(`  Approving PaymasterV4 to spend aPNTs...`);
          const approveTx = await apntsWithSigner.approve(pmV4Addr, ethers.MaxUint256);
          await approveTx.wait();
          console.log(`  ${PASS} Approved.`);
        }
        const depositTx = await pmV4.depositFor(AA_A, APNTS, depositAmount);
        console.log(`  Sent depositFor(AA_A, aPNTs, 500): ${depositTx.hash}`);
        await depositTx.wait();
        const newDeposit = await pmV4.balances(AA_A, APNTS);
        check('AA_A token deposit in PaymasterV4', newDeposit >= REQUIRED_DEPOSIT,
          `${ethers.formatEther(newDeposit)} aPNTs`);
      }
    } else {
      check('AA_A token deposit in PaymasterV4', true,
        `${ethers.formatEther(aa_a_deposit)} aPNTs`);
    }
  }
  console.log();

  // ──────────────────────────────────────────────────────────────────────────
  // 3. Test 2: SuperPaymaster deployer operator
  // ──────────────────────────────────────────────────────────────────────────
  console.log('━━━ Step 3: SuperPaymaster Deployer Operator (Test 2) ━━━');
  const deployerOp = await sp.operators(deployer);
  check('Deployer operator configured', deployerOp.isConfigured);
  check('Deployer operator not paused', !deployerOp.isPaused);
  check('Deployer xPNTsToken = aPNTs', deployerOp.xPNTsToken.toLowerCase() === APNTS.toLowerCase());

  const MIN_OP_BALANCE = ethers.parseUnits('100', 18); // 100 aPNTs minimum
  if (deployerOp.aPNTsBalance < MIN_OP_BALANCE) {
    const depositAmount = ethers.parseUnits('1000', 18); // top up 1000 aPNTs
    console.log(`  ${WARN} Deployer aPNTs in SP: ${ethers.formatEther(deployerOp.aPNTsBalance)} — depositing 1000 aPNTs...`);
    const apntsWithSigner = new ethers.Contract(APNTS, ERC20_ABI, wallet);
    const deployerBalance = await apnts.balanceOf(deployer);
    if (deployerBalance < depositAmount) {
      check('Deployer aPNTs balance for SP deposit', false,
        `only ${ethers.formatEther(deployerBalance)} aPNTs available`);
    } else {
      const allowance = await apnts.allowance(deployer, SP);
      if (allowance < depositAmount) {
        console.log(`  Approving SuperPaymaster to spend aPNTs...`);
        const approveTx = await apntsWithSigner.approve(SP, ethers.MaxUint256);
        await approveTx.wait();
        console.log(`  ${PASS} Approved.`);
      }
      const depositTx = await sp.deposit(depositAmount);
      console.log(`  Sent deposit(1000 aPNTs): ${depositTx.hash}`);
      await depositTx.wait();
      const updatedOp = await sp.operators(deployer);
      check('Deployer aPNTs in SuperPaymaster', updatedOp.aPNTsBalance >= MIN_OP_BALANCE,
        `${ethers.formatEther(updatedOp.aPNTsBalance)} aPNTs`);
    }
  } else {
    check('Deployer aPNTs in SuperPaymaster', true,
      `${ethers.formatEther(deployerOp.aPNTsBalance)} aPNTs`);
  }
  console.log();

  // ──────────────────────────────────────────────────────────────────────────
  // 4. Test 3: SuperPaymaster Anni operator
  // ──────────────────────────────────────────────────────────────────────────
  console.log('━━━ Step 4: SuperPaymaster Anni Operator (Test 3) ━━━');
  const anniOp = await sp.operators(ANNI);
  check('Anni operator configured', anniOp.isConfigured);
  check('Anni xPNTsToken = PNTs', anniOp.xPNTsToken.toLowerCase() === PNTS.toLowerCase());
  const anniBalance = anniOp.aPNTsBalance; // "aPNTs" field holds PNTs for Anni's operator
  if (anniBalance < ethers.parseUnits('10', 18)) {
    check('Anni PNTs in SuperPaymaster', false,
      `${ethers.formatEther(anniBalance)} — needs manual top-up via PRIVATE_KEY_ANNI`);
  } else {
    check('Anni PNTs in SuperPaymaster', true, `${ethers.formatEther(anniBalance)} PNTs`);
  }
  console.log();

  // ──────────────────────────────────────────────────────────────────────────
  // 5. Token balances in AA accounts
  // ──────────────────────────────────────────────────────────────────────────
  console.log('━━━ Step 5: AA Account Token Balances ━━━');
  const AA_MIN = ethers.parseUnits('2', 18); // 2 tokens minimum to transfer
  const aaBal = await apnts.balanceOf(AA_A);
  const abBal = await apnts.balanceOf(AA_B);
  const acBal = await pnts.balanceOf(AA_C);
  check(`AA_A aPNTs balance (Test 1)`, aaBal >= AA_MIN,
    `${ethers.formatEther(aaBal)} aPNTs${aaBal < AA_MIN ? ' — run: node transfer-tokens.js' : ''}`);
  check(`AA_B aPNTs balance (Test 2)`, abBal >= AA_MIN,
    `${ethers.formatEther(abBal)} aPNTs${abBal < AA_MIN ? ' — run: node transfer-tokens.js' : ''}`);
  check(`AA_C PNTs balance (Test 3)`, acBal >= AA_MIN,
    `${ethers.formatEther(acBal)} PNTs${acBal < AA_MIN ? ' — run: PRIVATE_KEY_ANNI=<key> node transfer-tokens.js' : ''}`);
  console.log();

  // ──────────────────────────────────────────────────────────────────────────
  // Summary
  // ──────────────────────────────────────────────────────────────────────────
  console.log('━━━ Summary ━━━');
  if (failures === 0) {
    console.log(`${PASS} All prerequisites met. Ready to run gasless tests.`);
    process.exit(0);
  } else {
    console.log(`${FAIL} ${failures} prerequisite(s) not met. Fix the above issues before running tests.`);
    process.exit(1);
  }
}

main().catch((e) => {
  console.error('\n❌ Setup error:', e.message);
  process.exit(1);
});

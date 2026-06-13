#!/usr/bin/env node
/**
 * Pre-flight Setup for Gasless Tests — auto-funds EVERY prerequisite.
 *
 * Design goals (project requirement, 2026-06-13):
 *   1. AUTO-FUND, never just check. Every AA test account is minted enough of
 *      every token it needs (aPNTs by the deployer, PNTs by Anni). A test must
 *      never SKIP for "zero balance" — the setup makes the balance true.
 *   2. NETWORK-ROBUST. Every write goes through sendAndWait (fee-bumped, retried,
 *      re-confirmed by hash); every read through retryView; and the whole setup
 *      is wrapped in a retry so a single transient RPC error can't abort it.
 *   3. IDEMPOTENT. Re-running is safe: each step only acts when under-funded.
 *
 * What it guarantees before test-case-1/2/3 run:
 *   - SuperPaymaster + PaymasterV4 price caches fresh
 *   - PaymasterV4 has AA_A token deposit + ETH in EntryPoint
 *   - Deployer operator (aPNTs) and Anni operator (PNTs) funded in SP
 *   - AA_A/B/C hold aPNTs; AA_A/B/C hold PNTs  (run-all maps TC2/TC3 onto AA_A,
 *     so AA_A must carry BOTH — we fund all three with both to be safe.)
 *
 * EXIT CODES: 0 = all prerequisites met/fixed · 1 = unrecoverable failure.
 */

const { ethers } = require('ethers');
const path = require('path');
const { loadConfig } = require('./load-config');
const { sendAndWait, retryView, isNetworkError, makeProvider } = require('./tx-utils');
require('dotenv').config({ path: process.env.ENV_FILE || path.join(__dirname, '../../.env.sepolia') });

const ERC20_ABI = [
  'function balanceOf(address) view returns (uint256)',
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
  'function approve(address spender, uint256 amount) returns (bool)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function mint(address to, uint256 amount) external',
  'function transfer(address to, uint256 amount) returns (bool)',
  'function communityOwner() view returns (address)',
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
  'function isTokenSupported(address token) view returns (bool)',
  'function setTokenPrice(address token, uint256 price) external',
];

// aPNTs gas-token USD price for PaymasterV4 (8 decimals): $0.02 = 2e6.
const APNTS_USD_PRICE_8DEC = 2_000000n;

const SP_ABI = [
  'function operators(address) view returns (uint128 aPNTsBalance, bool isConfigured, bool isPaused, address xPNTsToken, uint32 reputation, uint48 minTxInterval, address treasury, uint256 totalSpent, uint256 totalTxSponsored)',
  'function APNTS_TOKEN() view returns (address)',
  'function deposit(uint256 amount) external',
  'function updatePrice() external',
  'function priceValidUntil() view returns (uint48)',
  'function cachedPrice() view returns (int256 price, uint256 updatedAt, uint80 roundId, uint8 decimals)',
];

const PM_FACTORY_ABI = ['function paymasterByOperator(address) view returns (address)'];

const PASS = '✅';
const FAIL = '❌';
const WARN = '⚠️ ';

// Per-account funding targets. TARGET is the "enough to run" floor that also
// gates re-minting; TOPUP is how much we mint when below it. TARGET is set below
// TOPUP on purpose: a fresh mint can be partly consumed in the same tx by the
// token's automatic debt settlement (mint → burn of the holder's pending aPNTs
// debt), so requiring the full TOPUP would false-fail and re-mint every run.
const AA_TOKEN_TARGET   = ethers.parseUnits('500', 18);  // ≥ this = funded (won't re-mint)
const AA_TOKEN_TOPUP    = ethers.parseUnits('1000', 18); // mint this much when below target
const V4_DEPOSIT_MIN    = ethers.parseUnits('200', 18);
const V4_DEPOSIT_TOPUP  = ethers.parseUnits('500', 18);
// A gasless UserOp's validation locks aPNTs by the maxFeePerGas worst-case (~150-200
// aPNTs/op), refunded in postOp. The operator balance must clear that worst-case or
// validatePaymasterUserOp returns sigFailed → AA34. Keep a healthy buffer so several
// consecutive gasless ops (TC2/TC3 + credit path) never drain it below one op's need.
const SP_OP_MIN         = ethers.parseUnits('800', 18);  // top up when below this
const SP_OP_TOPUP       = ethers.parseUnits('2000', 18); // deposit this much

async function setupOnce(ctx) {
  const { provider, deployer, anni, config } = ctx;
  const APNTS = config.aPNTs;
  const PNTS  = config.pnts;
  const SP    = config.superPaymaster;
  const EP    = config.entryPoint;
  const PMF   = config.paymasterFactory;
  const AA = [
    process.env.TEST_AA_ACCOUNT_ADDRESS_A,
    process.env.TEST_AA_ACCOUNT_ADDRESS_B,
    process.env.TEST_AA_ACCOUNT_ADDRESS_C,
  ];
  if (AA.some((a) => !a)) throw new Error('TEST_AA_ACCOUNT_ADDRESS_A/B/C not set in .env.sepolia');

  const apntsRO = new ethers.Contract(APNTS, ERC20_ABI, provider);
  const pntsRO  = PNTS ? new ethers.Contract(PNTS, ERC20_ABI, provider) : null;
  const sp      = new ethers.Contract(SP, SP_ABI, deployer);
  const ep      = new ethers.Contract(EP, ENTRYPOINT_ABI, provider);
  const pmf     = new ethers.Contract(PMF, PM_FACTORY_ABI, provider);

  let failures = 0;
  const check = (label, ok, detail = '') => {
    console.log(`  ${ok ? PASS : FAIL} ${label}${detail ? ': ' + detail : ''}`);
    if (!ok) failures++;
  };

  // ── Step 1: SuperPaymaster price cache ──────────────────────────────────────
  console.log('━━━ Step 1: SuperPaymaster Price Cache ━━━');
  {
    const validUntil = await retryView(() => sp.priceValidUntil(), 'sp.priceValidUntil');
    const now = BigInt(Math.floor(Date.now() / 1000));
    if (validUntil === 0n || validUntil - now < 600n) {
      console.log(`  ${WARN} Price cache ${validUntil === 0n ? 'not initialized' : `expires in ${validUntil - now}s`} — updatePrice()...`);
      await sendAndWait(sp, 'updatePrice', [], 'sp.updatePrice');
      const newUntil = await retryView(() => sp.priceValidUntil(), 'sp.priceValidUntil');
      console.log(`  ${PASS} Price cache refreshed. Valid for ${newUntil - now}s`);
    } else {
      check('Price cache fresh', true, `valid for ${validUntil - now}s`);
    }
  }
  console.log();

  // ── Step 2: PaymasterV4 (Test 1) ────────────────────────────────────────────
  console.log('━━━ Step 2: PaymasterV4 (Test 1) ━━━');
  const pmV4Addr = await retryView(() => pmf.paymasterByOperator(deployer.address), 'pmf.paymasterByOperator');
  if (pmV4Addr === ethers.ZeroAddress) {
    check('PaymasterV4 deployed', false, 'run prepare-test sepolia first');
  } else {
    check('PaymasterV4 deployed', true, pmV4Addr);
    const pmV4 = new ethers.Contract(pmV4Addr, PAYMASTER_V4_ABI, deployer);

    const epInfo = await retryView(() => ep.getDepositInfo(pmV4Addr), 'ep.getDepositInfo');
    check('PaymasterV4 ETH in EntryPoint', epInfo.deposit > 0n, `${ethers.formatEther(epInfo.deposit)} ETH`);

    // PaymasterV4 stores Chainlink's updatedAt; force a fresh validUntil via setCachedPrice.
    const v4Cache = await retryView(() => pmV4.cachedPrice(), 'pmV4.cachedPrice');
    const v4Staleness = await retryView(() => pmV4.priceStalenessThreshold(), 'pmV4.priceStalenessThreshold');
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    if (v4Cache.updatedAt === 0n || v4Cache.updatedAt + v4Staleness < nowSec + 600n) {
      console.log(`  ${WARN} PaymasterV4 price cache stale — setCachedPrice()...`);
      const freshTs = BigInt(Math.floor(Date.now() / 1000) - 60);
      await sendAndWait(pmV4, 'setCachedPrice', [v4Cache.price || 224913120000n, freshTs], 'pmV4.setCachedPrice');
      console.log(`  ${PASS} PaymasterV4 price refreshed.`);
    } else {
      check('PaymasterV4 price cache fresh', true, `valid for ${v4Cache.updatedAt + v4Staleness - nowSec}s`);
    }

    // Ensure aPNTs is a supported gas token. beta.3 redeployed aPNTs, so the
    // PaymasterV4 may still only know the OLD token → depositFor reverts with
    // Paymaster__TokenNotSupported. Register it (owner-only) at $0.02 if missing.
    const apntsSupported = await retryView(() => pmV4.isTokenSupported(APNTS), 'pmV4.isTokenSupported');
    if (!apntsSupported) {
      console.log(`  ${WARN} aPNTs not a supported gas token in PaymasterV4 — registering at $0.02...`);
      await sendAndWait(pmV4, 'setTokenPrice', [APNTS, APNTS_USD_PRICE_8DEC], 'pmV4.setTokenPrice(aPNTs)');
      check('aPNTs registered as PaymasterV4 gas token', true);
    } else {
      check('aPNTs is a supported PaymasterV4 gas token', true);
    }

    // AA_A token deposit in PaymasterV4 (Test 1 pays gas from this).
    const aaADeposit = await retryView(() => pmV4.balances(AA[0], APNTS), 'pmV4.balances');
    if (aaADeposit < V4_DEPOSIT_MIN) {
      console.log(`  ${WARN} AA_A V4 deposit ${ethers.formatEther(aaADeposit)} aPNTs — funding ${ethers.formatEther(V4_DEPOSIT_TOPUP)}...`);
      await ensureBalance(apntsRO, deployer, deployer.address, V4_DEPOSIT_TOPUP, 'deployer aPNTs (for V4 deposit)');
      await ensureAllowance(apntsRO, deployer, pmV4Addr, V4_DEPOSIT_TOPUP, 'aPNTs→PaymasterV4');
      await sendAndWait(pmV4, 'depositFor', [AA[0], APNTS, V4_DEPOSIT_TOPUP], 'pmV4.depositFor(AA_A)');
      const nd = await retryView(() => pmV4.balances(AA[0], APNTS), 'pmV4.balances');
      check('AA_A token deposit in PaymasterV4', nd >= V4_DEPOSIT_MIN, `${ethers.formatEther(nd)} aPNTs`);
    } else {
      check('AA_A token deposit in PaymasterV4', true, `${ethers.formatEther(aaADeposit)} aPNTs`);
    }
  }
  console.log();

  // ── Step 3: SuperPaymaster deployer operator (Test 2) ───────────────────────
  console.log('━━━ Step 3: SuperPaymaster Deployer Operator (Test 2) ━━━');
  const deployerOp = await retryView(() => sp.operators(deployer.address), 'sp.operators(deployer)');
  check('Deployer operator configured', deployerOp.isConfigured);
  check('Deployer operator not paused', !deployerOp.isPaused);
  check('Deployer xPNTsToken = aPNTs', deployerOp.xPNTsToken.toLowerCase() === APNTS.toLowerCase());
  if (deployerOp.aPNTsBalance < SP_OP_MIN) {
    console.log(`  ${WARN} Deployer aPNTs in SP ${ethers.formatEther(deployerOp.aPNTsBalance)} — depositing ${ethers.formatEther(SP_OP_TOPUP)}...`);
    await fundOperator(provider, deployer, sp, deployer, SP_OP_TOPUP, 'deployer', check);
    const up = await retryView(() => sp.operators(deployer.address), 'sp.operators(deployer)');
    check('Deployer aPNTs in SuperPaymaster', up.aPNTsBalance >= SP_OP_MIN, `${ethers.formatEther(up.aPNTsBalance)} aPNTs`);
  } else {
    check('Deployer aPNTs in SuperPaymaster', true, `${ethers.formatEther(deployerOp.aPNTsBalance)} aPNTs`);
  }
  console.log();

  // ── Step 4: SuperPaymaster Anni operator (Test 3, PNTs) ─────────────────────
  console.log('━━━ Step 4: SuperPaymaster Anni Operator (Test 3) ━━━');
  if (!anni) {
    check('Anni operator funded', false, 'PRIVATE_KEY_ANNI not set — cannot fund PNTs operator');
  } else {
    const anniOp = await retryView(() => sp.operators(anni.address), 'sp.operators(anni)');
    check('Anni operator configured', anniOp.isConfigured);
    check('Anni xPNTsToken = PNTs', PNTS != null && anniOp.xPNTsToken.toLowerCase() === PNTS.toLowerCase());
    // NB: an operator's SP balance is denominated in SP.APNTS_TOKEN (aPNTs), NOT
    // the operator's xPNTsToken (PNTs). Fund it with the deposit token, not PNTs.
    if (anniOp.aPNTsBalance < SP_OP_MIN) {
      console.log(`  ${WARN} Anni operator balance ${ethers.formatEther(anniOp.aPNTsBalance)} — funding ${ethers.formatEther(SP_OP_TOPUP)} via APNTS_TOKEN...`);
      await fundOperator(provider, deployer, sp, anni, SP_OP_TOPUP, 'anni', check);
      const up = await retryView(() => sp.operators(anni.address), 'sp.operators(anni)');
      check('Anni aPNTs in SuperPaymaster', up.aPNTsBalance >= SP_OP_MIN, `${ethers.formatEther(up.aPNTsBalance)} aPNTs`);
    } else {
      check('Anni aPNTs in SuperPaymaster', anniOp.aPNTsBalance >= SP_OP_MIN, `${ethers.formatEther(anniOp.aPNTsBalance)} aPNTs`);
    }
  }
  console.log();

  // ── Step 5: Fund AA accounts with BOTH tokens (auto-mint) ───────────────────
  console.log('━━━ Step 5: Fund AA Account Token Balances ━━━');
  // aPNTs to every AA account (deployer is aPNTs communityOwner → can mint).
  for (let i = 0; i < AA.length; i++) {
    await mintUpTo(apntsRO, deployer, AA[i], AA_TOKEN_TARGET, AA_TOKEN_TOPUP, `AA_${'ABC'[i]} aPNTs`, check);
  }
  // PNTs to every AA account (Anni is PNTs communityOwner → can mint).
  if (PNTS && anni) {
    for (let i = 0; i < AA.length; i++) {
      await mintUpTo(pntsRO, anni, AA[i], AA_TOKEN_TARGET, AA_TOKEN_TOPUP, `AA_${'ABC'[i]} PNTs`, check);
    }
  } else {
    check('AA PNTs funding', false, 'PNTs config or PRIVATE_KEY_ANNI missing');
  }
  console.log();

  return failures;
}

// ── Funding helpers ───────────────────────────────────────────────────────────

// Mint `topup` of `token` to `to` if its balance is below `target`. The signer
// must be the token's communityOwner. Idempotent: no-op when already funded.
async function mintUpTo(token, signer, to, target, topup, label, check) {
  const [bal, decimals] = await Promise.all([
    retryView(() => token.balanceOf(to), `${label} balanceOf`),
    retryView(() => token.decimals(), `${label} decimals`),
  ]);
  if (bal >= target) {
    check(label, true, `${ethers.formatUnits(bal, decimals)} (already funded)`);
    return;
  }
  const tokenWithSigner = token.connect(signer);
  await sendAndWait(tokenWithSigner, 'mint', [to, topup], `mint ${label}`);
  const nb = await retryView(() => token.balanceOf(to), `${label} balanceOf`);
  check(label, nb >= target, `${ethers.formatUnits(nb, decimals)} (minted ${ethers.formatUnits(topup, decimals)})`);
}

// Ensure `owner` holds ≥ `need` of `token`; mint to self if the signer is the
// communityOwner, else just assert (cannot fund).
async function ensureBalance(token, signer, owner, need, label) {
  const bal = await retryView(() => token.balanceOf(owner), `${label} balanceOf`);
  if (bal >= need) return;
  // Try to mint to self (works when signer is communityOwner).
  await sendAndWait(token.connect(signer), 'mint', [owner, need], `mint ${label}`);
}

// Ensure `spender` is approved for ≥ `need` of `token` from `signer`.
async function ensureAllowance(token, signer, spender, need, label) {
  const cur = await retryView(() => token.allowance(signer.address, spender), `${label} allowance`);
  if (cur >= need) return;
  await sendAndWait(token.connect(signer), 'approve', [spender, ethers.MaxUint256], `approve ${label}`);
}

// Top up an operator's SuperPaymaster balance with `need` of the SP's deposit
// token. SP.deposit() ALWAYS pulls SP.APNTS_TOKEN (the canonical aPNTs used to
// price every operator's balance) — NOT the operator's own xPNTsToken, and NOT
// necessarily config.aPNTs (they diverge after a factory upgrade: SP.APNTS_TOKEN
// may still be the legacy token while config.aPNTs is the redeployed one). That
// legacy token can't be minted, so the deployer (which holds a large balance)
// transfers any shortfall to the operator before it approves + deposits.
async function fundOperator(provider, deployer, sp, opSigner, need, label, check) {
  const apntsTokenAddr = await retryView(() => sp.APNTS_TOKEN(), 'sp.APNTS_TOKEN');
  const token = new ethers.Contract(apntsTokenAddr, ERC20_ABI, provider);
  if (opSigner.address.toLowerCase() !== deployer.address.toLowerCase()) {
    const opBal = await retryView(() => token.balanceOf(opSigner.address), `${label} APNTS_TOKEN bal`);
    if (opBal < need) {
      const short = need - opBal + ethers.parseUnits('100', 18); // small margin
      await sendAndWait(token.connect(deployer), 'transfer', [opSigner.address, short], `transfer APNTS_TOKEN → ${label}`);
    }
  }
  await ensureAllowance(token, opSigner, sp.target, need, `APNTS_TOKEN→SP (${label})`);
  await sendAndWait(sp.connect(opSigner), 'deposit', [need], `sp.deposit(${label})`);
  check(`${label} operator funded via APNTS_TOKEN`, true);
}

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║         Gasless Tests Pre-Flight Setup                    ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  const config = loadConfig();
  const rpcUrl = process.env.SEPOLIA_RPC_URL || process.env.RPC_URL;
  const pk = process.env.PRIVATE_KEY || process.env.OWNER_PRIVATE_KEY || process.env.DEPLOYER_PRIVATE_KEY;
  const anniPk = process.env.PRIVATE_KEY_ANNI || process.env.ANNI_PRIVATE_KEY;
  if (!rpcUrl) throw new Error('SEPOLIA_RPC_URL / RPC_URL not set');
  if (!pk) throw new Error('PRIVATE_KEY not set');

  const provider = makeProvider(rpcUrl); // 20s/request timeout + read retry → survives RPC hiccups
  const deployer = new ethers.Wallet(pk, provider);
  const anni = anniPk ? new ethers.Wallet(anniPk, provider) : null;

  console.log(`Deployer: ${deployer.address}`);
  console.log(`Anni:     ${anni ? anni.address : '(PRIVATE_KEY_ANNI not set)'}`);
  console.log(`Network:  Sepolia (chain 11155111)\n`);

  const ctx = { provider, deployer, anni, config };

  // Whole-setup retry: a transient RPC failure mid-setup re-runs from the top.
  // setupOnce is idempotent (every step only acts when under-funded), so this is
  // safe and is the last line of defense beyond per-call retries in sendAndWait.
  const MAX_SETUP_ATTEMPTS = 3;
  let failures = 0;
  for (let attempt = 1; attempt <= MAX_SETUP_ATTEMPTS; attempt++) {
    try {
      failures = await setupOnce(ctx);
      break;
    } catch (e) {
      if (isNetworkError(e) && attempt < MAX_SETUP_ATTEMPTS) {
        console.log(`\n${WARN} setup hit a network error (${(e.message || '').slice(0, 70)}) — retrying whole setup ${attempt}/${MAX_SETUP_ATTEMPTS - 1} in 8s...\n`);
        await new Promise((r) => setTimeout(r, 8000));
        continue;
      }
      throw e;
    }
  }

  console.log('━━━ Summary ━━━');
  if (failures === 0) {
    console.log(`${PASS} All prerequisites met & funded. Ready to run gasless tests.`);
    process.exit(0);
  } else {
    console.log(`${FAIL} ${failures} prerequisite(s) not met. See above.`);
    process.exit(1);
  }
}

main().catch((e) => {
  console.error('\n❌ Setup error:', e.message);
  process.exit(1);
});

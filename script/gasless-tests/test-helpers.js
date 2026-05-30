/**
 * Shared test helpers for E2E gasless tests
 *
 * Provides: config loading, ABI definitions, role constants,
 * display utilities, assertion helpers, and safe TX wrappers.
 */
const { ethers } = require('ethers');
const path = require('path');
const { loadConfig } = require('./load-config');
require('dotenv').config({ path: process.env.ENV_FILE || path.join(__dirname, '../../.env.sepolia') });

// ============================================================
// Initialization
// ============================================================

// Only idempotent read RPC methods may be blindly retried on a transient
// network error. eth_sendRawTransaction / eth_sendTransaction are NOT here:
// if the node already accepted the tx but the response was lost, a retry would
// double-submit (or submit a second tx at the next nonce). Write retries are
// handled separately in sendTxSafe() with explicit nonce reconciliation.
const _RETRYABLE_RPC_METHODS = new Set([
  'eth_call', 'eth_estimateGas', 'eth_gasPrice', 'eth_maxPriorityFeePerGas',
  'eth_feeHistory', 'eth_blockNumber', 'eth_chainId',
  'eth_getBalance', 'eth_getCode', 'eth_getStorageAt', 'eth_getLogs',
  'eth_getTransactionCount', 'eth_getTransactionReceipt',
  'eth_getTransactionByHash', 'eth_getBlockByNumber', 'eth_getBlockByHash',
]);

function _addProviderRetry(provider) {
  const origSend = provider.send.bind(provider);
  provider.send = async function(method, params) {
    const canRetry = _RETRYABLE_RPC_METHODS.has(method);
    const MAX_RETRIES = 3;
    let lastErr;
    for (let i = 0; i <= MAX_RETRIES; i++) {
      try {
        return await origSend(method, params);
      } catch (e) {
        const msg = (e.message || '').toLowerCase();
        const isRetryable = msg.includes('econnreset') || msg.includes('socket hang up') ||
          msg.includes('etimedout') || msg.includes('read timeout') || msg.includes('network error');
        // Never auto-retry non-idempotent writes — a lost response may mean the
        // tx was already broadcast. Bubble up so sendTxSafe can reconcile nonce.
        if (!canRetry || !isRetryable || i === MAX_RETRIES) throw e;
        await new Promise(r => setTimeout(r, 500 * (i + 1)));
        lastErr = e;
      }
    }
    throw lastErr;
  };
  return provider;
}

function initTestEnv() {
  const config = loadConfig();
  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  if (!rpcUrl) throw new Error('SEPOLIA_RPC_URL not set');
  // staticNetwork avoids the initial eth_chainId auto-detect call that can fail under RPC rate limiting
  const provider = _addProviderRetry(
    new ethers.JsonRpcProvider(rpcUrl, 11155111, { staticNetwork: true })
  );

  const deployerKey = process.env.DEPLOYER_PRIVATE_KEY || process.env.PRIVATE_KEY;
  if (!deployerKey) throw new Error('DEPLOYER_PRIVATE_KEY not set');
  const deployer = new ethers.Wallet(deployerKey, provider);

  // Optional secondary wallets
  let anni = null;
  if (process.env.ANNI_PRIVATE_KEY) {
    anni = new ethers.Wallet(process.env.ANNI_PRIVATE_KEY, provider);
  }

  return { config, provider, deployer, anni };
}

// ============================================================
// ABI Definitions
// ============================================================

const ABI = {
  ERC20: [
    "function balanceOf(address) view returns (uint256)",
    "function totalSupply() view returns (uint256)",
    "function symbol() view returns (string)",
    "function decimals() view returns (uint8)",
    "function approve(address spender, uint256 amount) returns (bool)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function transfer(address to, uint256 amount) returns (bool)",
    "function mint(address to, uint256 amount)",
    "function cap() view returns (uint256)",
    "function owner() view returns (address)",
  ],

  Registry: [
    "function version() view returns (string)",
    "function owner() view returns (address)",
    // Wiring
    "function GTOKEN_STAKING() view returns (address)",
    "function MYSBT() view returns (address)",
    "function SUPER_PAYMASTER() view returns (address)",
    // Role management
    "function registerRole(bytes32 roleId, address user, bytes roleData)",
    "function safeMintForRole(bytes32 roleId, address user, bytes data) returns (uint256)",
    "function hasRole(bytes32 roleId, address user) view returns (bool)",
    "function getUserRoles(address user) view returns (bytes32[])",
    "function getRoleUserCount(bytes32 roleId) view returns (uint256)",
    "function getRoleConfig(bytes32 roleId) view returns (tuple(uint256 minStake, uint256 entryBurn, uint32 slashThreshold, uint32 slashBase, uint32 slashInc, uint32 slashMax, uint16 exitFeePercent, bool isActive, uint256 minExitFee, string description, address owner, uint256 roleLockDuration))",
    // Community & reputation
    "function communityByName(string name) view returns (address)",
    "function globalReputation(address user) view returns (uint256)",
    // Credit
    "function creditTierConfig(uint256 level) view returns (uint256)",
    "function setCreditTier(uint256 level, uint256 limit)",
    "function getCreditLimit(address user) view returns (uint256)",
    "function levelThresholds(uint256 index) view returns (uint256)",
  ],

  SuperPaymaster: [
    "function version() view returns (string)",
    "function owner() view returns (address)",
    "function REGISTRY() view returns (address)",
    "function ETH_USD_PRICE_FEED() view returns (address)",
    "function APNTS_TOKEN() view returns (address)",
    "function MAX_PROTOCOL_FEE() view returns (uint256)",
    // Operator
    // v5.3.3: exchangeRate removed from OperatorConfig (read live from xPNTsToken.exchangeRate())
    "function operators(address operator) view returns (uint128 aPNTsBalance, bool isConfigured, bool isPaused, address xPNTsToken, uint32 reputation, uint48 minTxInterval, address treasury, uint256 totalSpent, uint256 totalTxSponsored)",
    "function configureOperator(address xPNTsToken, address _opTreasury)",
    "function setOperatorLimits(uint48 _minTxInterval)",
    "function setOperatorPaused(address operator, bool paused)",
    // Deposits
    "function deposit(uint256 amount)",
    "function depositFor(address targetOperator, uint256 amount)",
    "function withdraw(uint256 amount)",
    // Pricing
    "function cachedPrice() view returns (int256 price, uint256 updatedAt, uint80 roundId, uint8 decimals)",
    "function updatePrice()",
    "function aPNTsPriceUSD() view returns (uint256)",
    "function setAPNTSPrice(uint256 newPrice)",
    // Protocol fee
    "function protocolFeeBPS() view returns (uint256)",
    "function setProtocolFee(uint256 newFeeBPS)",
    "function protocolRevenue() view returns (uint256)",
    "function totalTrackedBalance() view returns (uint256)",
    // SBT / user state
    "function sbtHolders(address user) view returns (bool)",
    "function userOpState(address operator, address user) view returns (uint48 lastTimestamp, bool isBlocked)",
    // Slash
    "function slashOperator(address operator, uint8 level, uint256 penaltyAmount, string reason)",
    "function getSlashCount(address operator) view returns (uint256)",
    "function getSlashHistory(address operator) view returns (tuple(uint256 timestamp, uint256 amount, uint256 reputationLoss, string reason, uint8 level)[])",
    "function updateReputation(address operator, uint256 newScore)",
    // V5.3: Agent Sponsorship
    "function agentIdentityRegistry() view returns (address)",
    "function agentReputationRegistry() view returns (address)",
    "function isEligibleForSponsorship(address user) view returns (bool)",
    "function isRegisteredAgent(address account) view returns (bool)",
    "function getAgentSponsorshipRate(address agent, address operator) view returns (uint256 bps)",
    "function setAgentPolicies(tuple(uint128 minReputationScore, uint64 sponsorshipBPS, uint64 maxDailyUSD)[] policies)",
    "function setAgentRegistries(address identity, address reputation)",
    "function agentPolicies(address operator, uint256 index) view returns (uint128 minReputationScore, uint64 sponsorshipBPS, uint64 maxDailyUSD)",
    // V5.3: x402 Facilitator
    "function facilitatorFeeBPS() view returns (uint256)",
    "function operatorFacilitatorFees(address operator) view returns (uint256)",
    "function x402SettlementNonces(bytes32 nonce) view returns (bool)",
    "function facilitatorEarnings(address operator, address asset) view returns (uint256)",
    "function setFacilitatorFeeBPS(uint256 _fee)",
    "function setOperatorFacilitatorFee(address operator, uint256 _fee)",
    "function withdrawFacilitatorEarnings(address asset)",
    "function settleX402Payment(address from, address to, address asset, uint256 amount, uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes signature) returns (bytes32)",
    "function settleX402PaymentDirect(address from, address to, address asset, uint256 amount, bytes32 settlementRef) returns (bytes32)",
    // V5.3: Credit
    "function getAvailableCredit(address user, address token) view returns (uint256)",
    // Governance / Admin (covered by B4)
    "function setTreasury(address _treasury)",
    "function updateSBTStatus(address user, bool status)",
    "function updateBlockedStatus(address operator, address[] users, bool[] statuses)",
    "function withdrawProtocolRevenue(address to, uint256 amount)",
    "function dryRunValidation(tuple(address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp, uint256 maxCost) view returns (bool ok, bytes32 reasonCode)",
    "function queueBLSAggregator(address _bls)",
    "function treasury() view returns (address)",
    "function pendingBLSAgg() view returns (address)",
    "function pendingBLSAggEta() view returns (uint48)",
    "function priceValidUntil() view returns (uint256)",
  ],

  MicroPaymentChannel: [
    "function version() view returns (string)",
    "function openChannel(address payee, address token, uint128 deposit, bytes32 salt, address authorizedSigner) returns (bytes32 channelId)",
    "function settleChannel(bytes32 channelId, uint128 cumulativeAmount, bytes signature)",
    "function closeChannel(bytes32 channelId, uint128 cumulativeAmount, bytes signature)",
    "function topUpChannel(bytes32 channelId, uint128 amount)",
    "function requestCloseChannel(bytes32 channelId)",
    "function withdrawChannel(bytes32 channelId)",
    "function getChannel(bytes32 channelId) view returns (tuple(address payer, address payee, address token, address authorizedSigner, uint128 deposit, uint128 settled, uint64 closeRequestedAt, bool finalized))",
    "function VOUCHER_TYPEHASH() view returns (bytes32)",
  ],

  GTokenStaking: [
    "function version() view returns (string)",
    "function owner() view returns (address)",
    "function GTOKEN() view returns (address)",
    "function REGISTRY() view returns (address)",
    "function treasury() view returns (address)",
    "function totalStaked() view returns (uint256)",
    "function stakes(address user) view returns (uint256 amount, uint256 slashedAmount, uint256 stakedAt, uint256 unstakeRequestedAt)",
    "function balanceOf(address user) view returns (uint256)",
    "function getLockedStake(address user, bytes32 roleId) view returns (uint256)",
    "function previewExitFee(address user, bytes32 roleId) view returns (uint256 fee, uint256 netAmount)",
    "function hasRoleLock(address user, bytes32 roleId) view returns (bool)",
  ],

  ReputationSystem: [
    "function version() view returns (string)",
    "function owner() view returns (address)",
    "function REGISTRY() view returns (address)",
    "function defaultRule() view returns (uint256 baseScore, uint256 activityBonus, uint256 maxBonus, string description)",
    "function communityRules(address community, bytes32 ruleId) view returns (uint256 baseScore, uint256 activityBonus, uint256 maxBonus, string description)",
    "function communityReputations(address community, address user) view returns (uint256)",
    "function entropyFactors(address community) view returns (uint256)",
    "function setRule(bytes32 ruleId, uint256 base, uint256 bonus, uint256 max, string desc)",
    "function setEntropyFactor(address community, uint256 factor)",
    "function setCommunityReputation(address community, address user, uint256 score)",
    "function getActiveRules(address community) view returns (bytes32[])",
    "function computeScore(address user, address[] communities, bytes32[][] ruleIds, uint256[][] activities) view returns (uint256)",
    "function getReputationBreakdown(address user, address community, uint256 sbtTokenId) view returns (uint256 baseScore, uint256 nftBonus, uint256 activityBonus, uint256 multiplier)",
    "function calculateReputation(address user, address community, uint256 sbtTokenId) view returns (uint256)",
    "function syncToRegistry(address user, address[] communities, bytes32[][] ruleIds, uint256[][] activities, uint256 epoch, bytes proof) external",
  ],

  MySBT: [
    "function version() view returns (string)",
    "function balanceOf(address owner) view returns (uint256)",
    "function ownerOf(uint256 tokenId) view returns (address)",
    "function tokenOfOwnerByIndex(address owner, uint256 index) view returns (uint256)",
  ],

  PaymasterFactory: [
    "function version() view returns (string)",
    "function paymasterByOperator(address operator) view returns (address)",
    "function hasPaymaster(address operator) view returns (bool)",
    "function totalDeployed() view returns (uint256)",
    "function getPaymasterList(uint256 offset, uint256 limit) view returns (address[])",
  ],

  PaymasterV4: [
    "function version() view returns (string)",
    "function owner() view returns (address)",
    "function updatePrice()",
    "function getSupportedTokens() view returns (address[])",
    "function cachedPrice() view returns (uint208 price, uint48 updatedAt)",
  ],

  PriceFeed: [
    "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
    "function decimals() view returns (uint8)",
    "function description() view returns (string)",
  ],

  EntryPoint: [
    "function handleOps((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature)[] ops, address beneficiary)",
    "function getUserOpHash((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp) view returns (bytes32)",
    "function balanceOf(address) view returns (uint256)",
    "function getNonce(address sender, uint192 key) view returns (uint256)",
  ],

  SimpleAccount: [
    "function execute(address dest, uint256 value, bytes func)",
    "function getNonce() view returns (uint256)",
  ],

  xPNTsToken: [
    "function balanceOf(address) view returns (uint256)",
    "function symbol() view returns (string)",
    "function decimals() view returns (uint8)",
    "function totalSupply() view returns (uint256)",
    "function name() view returns (string)",
    "function getDebt(address user) view returns (uint256)",
    "function repayDebt(uint256 amountXPNTs)",
    "function exchangeRate() view returns (uint256)",
    "function updateExchangeRate(uint256 newRate)",
    "function maxSingleTxLimit() view returns (uint256)",
    "function exchangeRateUpdatedAt() view returns (uint256)",
    "function burnFromWithOpHash(address from, uint256 amountAPNTs, bytes32 opHash)",
    "function recordDebt(address user, uint256 amountAPNTs)",
    "function recordDebtWithOpHash(address user, uint256 amountAPNTs, bytes32 opHash)",
    "function mint(address to, uint256 amount)",
    "function approve(address spender, uint256 amount) returns (bool)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function transfer(address to, uint256 amount) returns (bool)",
    "function transferFrom(address from, address to, uint256 amount) returns (bool)",
  ],
};

// ============================================================
// Role Constants
// ============================================================

const ROLES = {
  COMMUNITY:        ethers.keccak256(ethers.toUtf8Bytes("COMMUNITY")),
  ENDUSER:          ethers.keccak256(ethers.toUtf8Bytes("ENDUSER")),
  PAYMASTER_SUPER:  ethers.keccak256(ethers.toUtf8Bytes("PAYMASTER_SUPER")),
  PAYMASTER_AOA:    ethers.keccak256(ethers.toUtf8Bytes("PAYMASTER_AOA")),
  DVT:              ethers.keccak256(ethers.toUtf8Bytes("DVT")),
  ANODE:            ethers.keccak256(ethers.toUtf8Bytes("ANODE")),
  KMS:              ethers.keccak256(ethers.toUtf8Bytes("KMS")),
};

const ROLE_NAMES = {};
for (const [name, hash] of Object.entries(ROLES)) {
  ROLE_NAMES[hash] = name;
}

// Slash levels
const SLASH_LEVEL = { WARNING: 0, MINOR: 1, MAJOR: 2 };

// ============================================================
// Display Helpers
// ============================================================

let _testPassed = 0;
let _testFailed = 0;
let _testSkipped = 0;
// Subset of skips that are load-bearing: a state-changing write a test depends on
// that got skipped (nonce/in-flight conflict). These make the test INCONCLUSIVE
// (exit 2) rather than PASS — a skipped critical write means the test never
// actually verified what it claims. Optional cleanup skips are excluded.
let _criticalTxSkipped = 0;

function resetCounters() {
  _testPassed = 0;
  _testFailed = 0;
  _testSkipped = 0;
  _criticalTxSkipped = 0;
}

function getCounters() {
  return { passed: _testPassed, failed: _testFailed, skipped: _testSkipped, criticalSkipped: _criticalTxSkipped };
}

function printHeader(title) {
  const line = '='.repeat(60);
  console.log(`\n${line}`);
  console.log(`  ${title}`);
  console.log(`${line}\n`);
}

function printStep(n, label) {
  console.log(`\n  [Step ${n}] ${label}`);
  console.log(`  ${'-'.repeat(50)}`);
}

function printSuccess(msg) {
  console.log(`    PASS: ${msg}`);
  _testPassed++;
}

function printError(msg) {
  console.log(`    FAIL: ${msg}`);
  _testFailed++;
}

function printSkip(msg) {
  console.log(`    SKIP: ${msg}`);
  _testSkipped++;
}

function printInfo(msg) {
  console.log(`    ${msg}`);
}

function printKeyValue(key, value) {
  console.log(`    ${key}: ${value}`);
}

function printSummary(testName) {
  const { passed, failed, skipped, criticalSkipped } = getCounters();
  const total = passed + failed + skipped;
  const line = '='.repeat(60);
  console.log(`\n${line}`);
  console.log(`  ${testName} Summary`);
  console.log(`  Total: ${total} | Passed: ${passed} | Failed: ${failed} | Skipped: ${skipped}` +
    (criticalSkipped > 0 ? ` (${criticalSkipped} critical)` : ''));
  console.log(`${line}\n`);
  return failed === 0;
}

// Print the summary and return the process exit code following the suite
// convention: 0 = PASS, 1 = FAIL, 2 = SKIP/INCONCLUSIVE.
// A test is INCONCLUSIVE (not PASS) when a load-bearing write was skipped — its
// assertions never ran, so reporting PASS would hide a real gap (HIGH #2).
function finishTest(testName) {
  printSummary(testName);
  const { failed, criticalSkipped } = getCounters();
  if (failed > 0) return 1;
  if (criticalSkipped > 0) {
    console.log(`  ⏭️  INCONCLUSIVE: ${criticalSkipped} critical write(s) skipped — assertions did not run. Re-run after mempool clears.`);
    return 2;
  }
  return 0;
}

// ============================================================
// Assertion Helpers
// ============================================================

function assertEqual(actual, expected, label) {
  const a = typeof actual === 'bigint' ? actual.toString() : String(actual);
  const e = typeof expected === 'bigint' ? expected.toString() : String(expected);
  if (a === e) {
    printSuccess(`${label} == ${e}`);
    return true;
  } else {
    printError(`${label}: expected ${e}, got ${a}`);
    return false;
  }
}

function assertTrue(condition, label) {
  if (condition) {
    printSuccess(label);
    return true;
  } else {
    printError(`${label} (expected true, got false)`);
    return false;
  }
}

function assertFalse(condition, label) {
  if (!condition) {
    printSuccess(label);
    return true;
  } else {
    printError(`${label} (expected false, got true)`);
    return false;
  }
}

function assertGte(actual, expected, label) {
  if (actual >= expected) {
    printSuccess(`${label}: ${actual} >= ${expected}`);
    return true;
  } else {
    printError(`${label}: ${actual} < ${expected}`);
    return false;
  }
}

function assertGt(actual, expected, label) {
  if (actual > expected) {
    printSuccess(`${label}: ${actual} > ${expected}`);
    return true;
  } else {
    printError(`${label}: ${actual} not > ${expected}`);
    return false;
  }
}

async function expectRevert(fn, label) {
  try {
    await fn();
    printError(`${label}: expected revert but succeeded`);
    return false;
  } catch (err) {
    const reason = err.reason || err.shortMessage || err.message.substring(0, 100);
    printSuccess(`${label}: reverted (${reason})`);
    return true;
  }
}

// ============================================================
// Safe TX wrapper with nonce management
// ============================================================

// Global nonce tracker to avoid conflicts on rapid TX sends
let _nextNonce = null;
let _nonceWallet = null;

async function retryView(fn, label, retries = 3) {
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      return await fn();
    } catch (err) {
      if (_isNetworkError(err) && attempt < retries) {
        if (label) printInfo(`${label}: network error, retry ${attempt}/${retries - 1} in 3s...`);
        await new Promise(r => setTimeout(r, 3000));
        continue;
      }
      throw err;
    }
  }
}

function _isNetworkError(err) {
  const msg = (err.message || '').toLowerCase();
  return err.code === 'ETIMEDOUT' || err.code === 'ECONNRESET' ||
    msg.includes('etimedout') || msg.includes('econnreset') ||
    msg.includes('socket hang up') || msg.includes('request timeout') ||
    msg.includes('read timeout');
}

function _isNonceConflict(err) {
  const reason = (err.reason || err.shortMessage || err.message || '').toLowerCase();
  return reason.includes('replacement transaction underpriced') ||
    reason.includes('replacement underpriced') ||
    reason.includes('nonce too low') ||
    reason.includes('already known') ||
    reason.includes('in-flight transaction limit') ||
    reason.includes('nonce has already been used') ||
    (err.code || '').toLowerCase() === 'replacement_underpriced';
}

/**
 * Send a state-changing tx with nonce tracking and infra-aware error handling.
 *
 * @param opts.maxRetries  retry budget for PRE-broadcast network errors (default 3)
 * @param opts.critical    if true (default), a nonce/in-flight skip marks the test
 *                          INCONCLUSIVE (exit 2). Pass false for optional cleanup.
 *
 * Return values:
 *   - receipt object           → tx confirmed (has .gasUsed, .logs)
 *   - { applied:true } sentinel → tx was broadcast but receipt unavailable
 *                                 (network dropped post-broadcast). Truthy so
 *                                 read-back assertions still run; do NOT resend.
 *   - null                      → tx skipped (nonce conflict) or failed/reverted
 *
 * Write-safety (HIGH #3): a network error is only retried when we can prove the
 * tx was NOT broadcast (on-chain nonce unchanged). If the nonce advanced, the tx
 * landed and we never resend.
 */
async function sendTxSafe(contract, method, args, label, opts = {}) {
  if (typeof opts === 'number') opts = { maxRetries: opts }; // back-compat: numeric 5th arg
  const maxRetries = opts.maxRetries != null ? opts.maxRetries : 3;
  const critical = opts.critical !== false;
  const signer = contract.runner;

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    // Track nonce for this wallet ('pending' accounts for unconfirmed TXs)
    if (signer && signer.address && _nonceWallet !== signer.address) {
      _nonceWallet = signer.address;
      _nextNonce = await signer.getNonce('pending');
    }
    const sentNonce = _nextNonce;
    const txOpts = sentNonce !== null ? { nonce: sentNonce } : {};

    let tx;
    try {
      tx = await contract[method](...args, txOpts);
    } catch (err) {
      if (_isNetworkError(err)) {
        // Ambiguous: the node may have accepted the tx before the socket dropped.
        // Reconcile against the on-chain nonce before deciding to resend.
        let chainNonce = null;
        try { chainNonce = await signer.getNonce('latest'); } catch (_) {}
        if (chainNonce !== null && sentNonce !== null && chainNonce > sentNonce) {
          printInfo(`${label}: network error but nonce ${sentNonce} consumed — tx landed, NOT resending`);
          _nextNonce = chainNonce;
          return { applied: true, noReceipt: true };
        }
        if (attempt < maxRetries) {
          printInfo(`${label}: pre-broadcast network error (nonce ${sentNonce} intact), retry ${attempt}/${maxRetries - 1} in 4s...`);
          await new Promise(r => setTimeout(r, 4000));
          if (chainNonce !== null) _nextNonce = chainNonce;
          continue;
        }
      }
      const reason = err.reason || err.shortMessage || (err.message || '').substring(0, 120);
      if (_isNonceConflict(err)) {
        printSkip(`${label}: nonce/in-flight conflict (pending TXs in mempool) — skipped${critical ? ' [CRITICAL]' : ''}`);
        if (critical) _criticalTxSkipped++;
      } else {
        printError(`${label}: TX failed (${reason})`);
      }
      if (_nonceWallet && signer && signer.address === _nonceWallet) {
        try { _nextNonce = await signer.getNonce('latest'); } catch (_) {}
      }
      return null;
    }

    // Broadcast succeeded — advance nonce, then await confirmation.
    if (_nextNonce !== null) _nextNonce++;
    try {
      if (tx.wait) {
        const receipt = await tx.wait(1);
        printInfo(`${label}: TX confirmed (gas: ${receipt.gasUsed})`);
        return receipt;
      }
      return tx;
    } catch (waitErr) {
      // We have a tx hash; a confirmation-poll failure must NOT trigger a resend.
      if (_isNetworkError(waitErr)) {
        printInfo(`${label}: broadcast ok (${tx.hash}) but receipt poll failed — NOT resending`);
        return { applied: true, noReceipt: true, hash: tx.hash };
      }
      const reason = waitErr.reason || waitErr.shortMessage || (waitErr.message || '').substring(0, 120);
      printError(`${label}: TX reverted on-chain (${reason})`);
      return null;
    }
  }
}

// ============================================================
// Contract instantiation helpers
// ============================================================

function getContracts(config, signerOrProvider) {
  const contracts = {
    registry:         new ethers.Contract(config.registry, ABI.Registry, signerOrProvider),
    superPaymaster:   new ethers.Contract(config.superPaymaster, ABI.SuperPaymaster, signerOrProvider),
    gToken:           new ethers.Contract(config.gToken, ABI.ERC20, signerOrProvider),
    staking:          new ethers.Contract(config.staking, ABI.GTokenStaking, signerOrProvider),
    sbt:              new ethers.Contract(config.sbt, ABI.MySBT, signerOrProvider),
    aPNTs:            new ethers.Contract(config.aPNTs, ABI.ERC20, signerOrProvider),
    aPNTsToken:       new ethers.Contract(config.aPNTs, ABI.xPNTsToken, signerOrProvider),
    reputationSystem: new ethers.Contract(config.reputationSystem, ABI.ReputationSystem, signerOrProvider),
    paymasterFactory: new ethers.Contract(config.paymasterFactory, ABI.PaymasterFactory, signerOrProvider),
    priceFeed:        new ethers.Contract(config.priceFeed, ABI.PriceFeed, signerOrProvider),
    entryPoint:       new ethers.Contract(config.entryPoint, ABI.EntryPoint, signerOrProvider),
  };
  // V5.3 contracts (optional — only present after V5.3 deployment)
  if (config.microPaymentChannel) {
    contracts.microPaymentChannel = new ethers.Contract(config.microPaymentChannel, ABI.MicroPaymentChannel, signerOrProvider);
  }
  return contracts;
}

// ============================================================
// Role data encoding helpers
// ============================================================

function encodeCommunityRoleData(name, desc, stakeAmount) {
  return ethers.AbiCoder.defaultAbiCoder().encode(
    ["tuple(string,string,string,string,string,uint256)"],
    [[name, "", "", desc || "", "", stakeAmount || ethers.parseEther("30")]]
  );
}

function encodeEndUserRoleData(community, stakeAmount) {
  // EndUserRoleData struct: { address community; uint256 stakeAmount; }
  return ethers.AbiCoder.defaultAbiCoder().encode(
    ["tuple(address,uint256)"],
    [[community, stakeAmount || ethers.parseEther("0.3")]]
  );
}

// ============================================================
// Exports
// ============================================================

module.exports = {
  // Init
  initTestEnv,
  // ABIs
  ABI,
  // Roles
  ROLES,
  ROLE_NAMES,
  SLASH_LEVEL,
  // Display
  printHeader,
  printStep,
  printSuccess,
  printError,
  printSkip,
  printInfo,
  printKeyValue,
  printSummary,
  finishTest,
  resetCounters,
  getCounters,
  // Assertions
  assertEqual,
  assertTrue,
  assertFalse,
  assertGt,
  assertGte,
  expectRevert,
  // TX / View retry
  sendTxSafe,
  retryView,
  // Contracts
  getContracts,
  // Encoding
  encodeCommunityRoleData,
  encodeEndUserRoleData,
  // Re-export ethers
  ethers,
};

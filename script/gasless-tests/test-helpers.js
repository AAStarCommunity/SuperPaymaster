/**
 * Shared test helpers for E2E gasless tests
 *
 * Provides: config loading, ABI definitions, role constants,
 * display utilities, assertion helpers, and safe TX wrappers.
 */
const { ethers } = require('ethers');
const fs = require('fs');
const os = require('os');
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

// A transient RPC/network error worth retrying on idempotent reads / treating as
// SKIP. Deliberately NARROW so we never misclassify a contract revert as infra
// (that would hide a real failure):
//   - Hard guard: anything that looks like a revert / call exception → NOT infra.
//   - Match specific transport phrases, not the bare word "timeout" (which can
//     appear in a contract custom-error name like DeadlineTimeout).
//   - Do NOT treat bare SERVER_ERROR as infra — some RPCs return it for reverts.
function _isTransientRpcError(e) {
  if (!e) return false;
  const code = (e.code || '').toString().toUpperCase();
  // 1. Transport-level codes are infra REGARDLESS of any attached reason string.
  //    (ethers v6 TIMEOUT errors carry reason:"timeout", so this must come BEFORE
  //    the revert guard — otherwise a real timeout would be misread as a revert.)
  if (code === 'TIMEOUT' || code === 'ETIMEDOUT' ||
      code === 'ECONNRESET' || code === 'NETWORK_ERROR') return true;
  // 2. A genuine contract revert / call exception is NEVER infra. Use only the
  //    revert-specific signals (NOT e.reason, which timeouts also set).
  if (code === 'CALL_EXCEPTION' || e.revert != null) return false;
  // 3. Fall back to specific transport phrases (never the bare word "timeout",
  //    which can appear in a contract custom-error name like DeadlineTimeout).
  const msg = (e.message || '').toLowerCase();
  return msg.includes('econnreset') || msg.includes('econnrefused') ||
    msg.includes('socket hang up') || msg.includes('socket disconnected') ||
    msg.includes('request timeout') || msg.includes('read timeout') ||
    msg.includes('etimedout') || msg.includes('timeout exceeded') ||
    msg.includes('network error') || msg.includes('failed to fetch') ||
    msg.includes('bad gateway') || msg.includes('service unavailable');
}

function _addProviderRetry(provider) {
  const origSend = provider.send.bind(provider);
  provider.send = async function(method, params) {
    const canRetry = _RETRYABLE_RPC_METHODS.has(method);
    const MAX_RETRIES = 4;
    let lastErr;
    for (let i = 0; i <= MAX_RETRIES; i++) {
      try {
        return await origSend(method, params);
      } catch (e) {
        // Never auto-retry non-idempotent writes — a lost response may mean the
        // tx was already broadcast. Bubble up so sendTxSafe can reconcile nonce.
        if (!canRetry || !_isTransientRpcError(e) || i === MAX_RETRIES) throw e;
        await new Promise(r => setTimeout(r, 600 * (i + 1)));
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
  // staticNetwork avoids the initial eth_chainId auto-detect call that can fail under RPC rate limiting.
  // FetchRequest timeout caps each request at 20s (ethers' default is 300s), so a hung view fails fast
  // and _addProviderRetry can retry it — instead of blocking until the suite's 300s kill-switch fires
  // (the E1 "TIMEOUT after 300s" we hit on a flaky RPC).
  const _fr = new ethers.FetchRequest(rpcUrl);
  _fr.timeout = 20000;
  // CHAIN_ID override: this file's own default target is Sepolia, but staticNetwork means
  // ethers signs with whatever chain id it's given here rather than probing the RPC — against
  // a local anvil (chain 31337) that mismatch gets every signed tx rejected at the mempool.
  const chainId = Number(process.env.CHAIN_ID) || 11155111;
  const provider = _addProviderRetry(
    new ethers.JsonRpcProvider(_fr, chainId, { staticNetwork: true })
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
    // Slash (HIGH-1 two-step: queueSlash must precede slashOperator/executeSlashWithBLS)
    "function queueSlash(address operator)",
    "function cancelSlash(address operator)",
    "function isSlashPending(address operator) view returns (bool)",
    "function slashOperator(address operator, uint8 level, uint256 penaltyAmount, string reason)",
    "function getSlashCount(address operator) view returns (uint256)",
    "function getSlashHistory(address operator) view returns (tuple(uint256 timestamp, uint256 amount, uint256 reputationLoss, string reason, uint8 level)[])",
    "function updateReputation(address operator, uint256 newScore)",
    // V5.3: Agent Sponsorship (dual-channel: SBT OR registered agent NFT).
    // NOTE: the tiered AgentSponsorshipPolicy F1 design (getAgentSponsorshipRate /
    // setAgentPolicies / agentPolicies) was a V5.3 worktree experiment that was
    // NEVER merged into the deployed SuperPaymaster — those selectors do not exist
    // on-chain, so they are intentionally absent from this ABI.
    "function agentIdentityRegistry() view returns (address)",
    "function agentReputationRegistry() view returns (address)",
    "function isEligibleForSponsorship(address user) view returns (bool)",
    "function isRegisteredAgent(address account) view returns (bool)",
    "function setAgentRegistries(address identity, address reputation)",
    // V5.4 god-split: the x402 Facilitator layer (facilitatorFeeBPS / operatorFacilitatorFees /
    // facilitatorEarnings / settleX402* / set*/withdraw*) was extracted out of SuperPaymaster
    // into the standalone X402Facilitator contract — see the X402Facilitator ABI below.
    // 5.5.0 balance mode: getAvailableCredit(user, token) is GONE — the credit cap now lives
    // on the token itself (IxPNTsTokenV2.effectiveCreditCap, ABI.xPNTsToken below).
    // Governance / Admin (covered by B4)
    "function setTreasury(address _treasury)",
    "function updateSBTStatus(address user, bool status)",
    "function updateBlockedStatus(address operator, address[] users, bool[] statuses)",
    "function withdrawProtocolRevenue(address to, uint256 amount)",
    // dryRunValidation moved OUT of SuperPaymaster into SuperPaymasterLens in 5.5.0
    // (EIP-170 headroom, spec F1/§5). See ABI.SuperPaymasterLens — note its extra
    // leading `sp` address param (SuperPaymaster.sol:367; SuperPaymasterLens.sol:95).
    "function queueBLSAggregator(address _bls)",
    "function treasury() view returns (address)",
    "function pendingBLSAgg() view returns (address)",
    "function pendingBLSAggEta() view returns (uint48)",
    "function priceValidUntil() view returns (uint256)",
  ],

  // dryRunValidation's new home (5.5.0). Stateless/non-upgradeable, bound to ONE SP version
  // (answers VERSION_MISMATCH on any other). Same decision code as tryLockForGas/tryReserveCredit
  // via the token's previewLock/previewCredit (SuperPaymasterLens.sol).
  SuperPaymasterLens: [
    "function dryRunValidation(address sp, tuple(address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp, uint256 maxCost) view returns (bool ok, bytes32 reasonCode)",
    "function EXPECTED_SP_VERSION() view returns (bytes32)",
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

  // V5.4 god-split: standalone x402 settlement layer extracted from SuperPaymaster.
  // Same function signatures as the pre-v5.4 SuperPaymaster x402 surface (the funcs moved
  // verbatim), now hosted on the X402Facilitator contract (config.x402Facilitator).
  X402Facilitator: [
    "function version() view returns (string)",
    "function facilitatorFeeBPS() view returns (uint256)",
    "function operatorFacilitatorFees(address operator) view returns (uint256)",
    "function getEffectiveFacilitatorFee(address operator) view returns (uint256)",
    "function facilitatorEarnings(address operator, address asset) view returns (uint256)",
    "function x402SettlementNonces(bytes32 key) view returns (bool)",
    "function x402NonceKey(address asset, address from, bytes32 nonce) pure returns (bytes32)",
    "function setFacilitatorFeeBPS(uint256 _fee)",
    "function setOperatorFacilitatorFee(address operator, uint256 _fee)",
    "function withdrawFacilitatorEarnings(address asset)",
    // M-1: settleX402Payment takes `maxFee` right after `amount` (9-arg form).
    "function settleX402Payment(address from, address to, address asset, uint256 amount, uint256 maxFee, uint256 validAfter, uint256 validBefore, bytes32 salt, bytes signature) returns (bytes32)",
    "function settleX402PaymentDirect(address from, address to, address asset, uint256 amount, uint256 maxFee, uint256 validBefore, bytes32 nonce, bytes signature) returns (bytes32)",
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

  // xPNTs v2 (XPNTs-4.0.0, spec 03 §2.2). 3.x's burnFromWithOpHash / recordDebt /
  // recordDebtWithOpHash / getDebt are GONE — SP holds only tryLockForGas / settleLocked /
  // tryReserveCredit / settleCredit on a v2 token; debt is now the public `debts` mapping.
  xPNTsToken: [
    "function balanceOf(address) view returns (uint256)",
    "function symbol() view returns (string)",
    "function decimals() view returns (uint8)",
    "function totalSupply() view returns (uint256)",
    "function name() view returns (string)",
    "function debts(address user) view returns (uint256)",
    "function repayDebt(uint256 amountXPNTs)",
    "function exchangeRate() view returns (uint256)",
    "function updateExchangeRate(uint256 newRate)",
    "function maxSingleTxLimit() view returns (uint256)",
    "function exchangeRateUpdatedAt() view returns (uint256)",
    "function mint(address to, uint256 amount)",
    "function approve(address spender, uint256 amount) returns (bool)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function transfer(address to, uint256 amount) returns (bool)",
    "function transferFrom(address from, address to, uint256 amount) returns (bool)",
    // Balance-mode locks/credit (validation-time state, read here for post-tx assertions)
    "function lockedOf(address user) view returns (uint256)",
    "function creditReservedOf(address user) view returns (uint256)",
    "function effectiveCreditCap(address user) view returns (uint256)",
    "function autoAllowance(address user, address spender) view returns (uint256 cap, uint256 used)",
    "function BALANCE_MODE_VERSION() view returns (uint16)",
    // Credit policy / request (communityOwner-gated queue/execute has a 48h TIMELOCK — see
    // xPNTsV2Base.sol TIMELOCK / xPNTsTokenV2Ext.sol:161-176)
    "function communityOwner() view returns (address)",
    "function creditPolicy() view returns (uint8)",
    "function policyEpoch() view returns (uint32)",
    "function pendingPolicy() view returns (uint8)",
    "function pendingPolicyEta() view returns (uint64)",
    "function creditReq(address user) view returns (uint112 requestedCap, uint112 approvedCap, uint32 epoch)",
    "function requestCredit(uint256 maxCapAPNTs)",
    "function revokeCredit()",
    "function approveCredit(address user, uint256 capAPNTs)",
    "function queueCreditPolicy(uint8 p)",
    "function executeCreditPolicy()",
    "function cancelCreditPolicy()",
    // Read-only mirror of tryReserveCredit's decision (same code path, no state written) —
    // used to test rejection behavior without needing a real UserOp (test-group-I1).
    "function previewCredit(address spender, address user, bytes32 opHash, uint256 aPNTs) view returns (uint8 result)",
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

// Skip of a LOAD-BEARING step (e.g. a governance write/read we meant to verify
// was prevented by transient infra). Unlike printSkip (optional/expected skips
// that keep the test PASS), this marks the test INCONCLUSIVE → finishTest exits 2,
// so an honest "couldn't run" is never reported as a clean PASS.
function printCriticalSkip(msg) {
  console.log(`    SKIP*: ${msg} [INCONCLUSIVE]`);
  _testSkipped++;
  _criticalTxSkipped++;
}

// Shared step-level catch classifier: a transient RPC/network error means the
// step could not be exercised → INCONCLUSIVE skip (exit 2), NOT a silent PASS and
// NOT a false FAIL; a genuine contract/logic error → FAIL. Use in step `catch`
// blocks instead of a bare printError so transient infra never flips PASS↔FAIL.
// DSR review, 2026-09-17: a script that never sends a signed tx until deep into its run
// (e.g. test-group-I1's Step 5, the only write in an otherwise read-only script) surfaces
// a forgotten/wrong CHAIN_ID env var as a confusing "invalid chain id for signer" failure
// far from the actual misconfiguration (reads never trigger chain-id validation, only a
// signed send does). Reproduced: unsetting CHAIN_ID against a local anvil (so the default
// Sepolia chainId 11155111 gets signed into a tx sent to chain 31337) reproduces this exact
// message. Give the real cause instead of leaving the reader to guess.
function _isChainIdMismatch(e) {
  const msg = ((e && e.message) || '').toLowerCase();
  return msg.includes('invalid chain id for signer');
}

function catchStep(label, e) {
  if (_isChainIdMismatch(e)) {
    printError(`${label}: ${(e.message || '').substring(0, 100)}`);
    printError(`  hint: CHAIN_ID env likely does not match the RPC's actual chain (this file defaults to Sepolia, 11155111) — set CHAIN_ID=31337 when testing against anvil`);
  } else if (_isNetworkError(e)) {
    printCriticalSkip(`${label}: transient RPC error — ${(e.message || '').substring(0, 60)}`);
  } else {
    printError(`${label}: ${(e.message || '').substring(0, 100)}`);
  }
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
    // A transient RPC/network error is NOT a contract revert — counting it as a
    // successful revert would falsely PASS a negative test and hide a real gap.
    if (_isTransientRpcError(err)) {
      printCriticalSkip(`${label}: could not verify revert — transient RPC error (${(err.message || '').substring(0, 50)})`);
      return false;
    }
    const reason = err.reason || err.shortMessage || (err.message || '').substring(0, 100);
    printSuccess(`${label}: reverted (${reason})`);
    return true;
  }
}

// ============================================================
// Safe TX wrapper with nonce management
// ============================================================

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
  return _isTransientRpcError(err);
}

function _isNonceConflict(err) {
  const reason = (err.reason || err.shortMessage || err.message || '').toLowerCase();
  return reason.includes('replacement transaction underpriced') ||
    reason.includes('replacement underpriced') ||
    reason.includes('nonce too low') ||
    reason.includes('already known') ||
    reason.includes('in-flight transaction limit') ||
    reason.includes('could not coalesce') ||
    reason.includes('nonce has already been used') ||
    (err.code || '').toLowerCase() === 'replacement_underpriced';
}

// Codex stop-gate (2026-09-17), round 4: `_isNonceConflict` bundles two DIFFERENT signal
// strengths under one name. "nonce too low" / "already known" / "nonce has already been
// used" / "replacement (transaction) underpriced" are DEFINITIVE — the node is telling us
// something already occupies this exact (sender, nonce) slot, either mined or pending.
// "in-flight transaction limit" / "could not coalesce" are generic congestion/rate-limit
// signals from the RPC/mempool layer — they say nothing about whether THIS SPECIFIC nonce
// was ever accepted. Using the broad classifier to prove "the identical-nonce retry shows
// the original landed" was wrong: a genuinely UNDELIVERED original combined with an
// in-flight-limit/could-not-coalesce error on the retry would be misreported as
// `{applied:true}` — a silent false "success" for an operation that never happened at all,
// worse than the double-submit this whole fix chain has been closing.
function _isDefiniteNonceCollision(err) {
  const reason = (err.reason || err.shortMessage || err.message || '').toLowerCase();
  return reason.includes('replacement transaction underpriced') ||
    reason.includes('replacement underpriced') ||
    reason.includes('nonce too low') ||
    reason.includes('already known') ||
    reason.includes('nonce has already been used') ||
    (err.code || '').toLowerCase() === 'replacement_underpriced';
}

// The congestion/rate-limit subset of _isNonceConflict, deliberately excluding the
// definitive-collision strings above — used only to decide "still ambiguous, keep
// retrying the identical send" during post-broadcast reconciliation, never as proof.
function _isAmbiguousCongestion(err) {
  const reason = (err.reason || err.shortMessage || err.message || '').toLowerCase();
  return reason.includes('in-flight transaction limit') || reason.includes('could not coalesce');
}

// Root cause of DSR's "impossible nonce conflict on a fresh, single-process anvil"
// (2026-09-17): ethers v6's `Signer.getNonce()` / `Provider.getTransactionCount()`
// can return STALE data even immediately after this SAME wallet's own `tx.wait(1)`
// resolved for the tx that should have advanced it — reproduced in total isolation
// (one process, one wallet, no other writer): send at nonce N, await 1 confirmation,
// `wallet.getNonce('pending')` still reports N. Same disease as this file's earlier
// `provider.getBlock('latest')` caching bug (see `_waitMempoolDrain`'s original
// version / test-group-I1's `nextTxNonce` comment) — some layer inside ethers'
// Provider/Network machinery caches a response and does not invalidate on new
// blocks the way a raw JSON-RPC call does. Fix: never call `signer.getNonce()` or
// `provider.getTransactionCount()` for anything nonce-retry-sensitive — always hit
// the RPC directly. Verified empirically: `provider.send('eth_getTransactionCount',
// [addr, 'pending'])` correctly advances on every one of 3 repeated send/mine/read
// cycles in the same isolated probe where `wallet.getNonce('pending')` never did.
async function _rawNonce(signer, tag) {
  return parseInt(await signer.provider.send('eth_getTransactionCount', [signer.address, tag]), 16);
}

// Retry budget for an identical-nonce resend after an ambiguous post-broadcast network
// error (sendTxSafe) — see the Codex round-3 comment at that call site for why the nonce
// must stay fixed across these retries rather than being re-fetched.
const NETWORK_RETRY_BUDGET = 3;

// Codex stop-gate (2026-09-17), round 5: a definite nonce collision (nonce too low /
// already known / replacement underpriced) proves this (sender, nonce) slot is occupied —
// it does NOT prove the operation succeeded. "nonce too low" also follows a MINED-BUT-
// REVERTED original (a revert still consumes the nonce, only rolls back state); "replacement
// underpriced" can mean the original is merely PENDING, not yet mined at all. Returning an
// "applied" sentinel on nonce-occupancy alone can report success for a reverted, or not-yet-
// decided, operation. Look up the actual transaction mined at that nonce and read ITS real
// status instead of inferring one from the collision error shape.
//
// How: scan recent blocks (raw eth_getBlockByNumber, full tx objects) for a tx `from` this
// signer `with nonce === targetNonce`. Bounded search — this is a test-harness reconciliation
// path, not a production indexer; a local/typical remote chain mines the tx we're looking for
// within a handful of blocks of "now" since we only reach this code seconds after sending it.
// Codex stop-gate (2026-09-17), round 6: matching only (from, nonce) is not enough — if
// the ORIGINAL broadcast never actually landed, but some OTHER write from this same wallet
// (a concurrent script, a manual `cast send`, anything outside this call's own retry loop)
// happened to occupy that exact nonce, a from+nonce match finds THAT unrelated transaction
// and a successful receipt for it would be misreported as proof our intended call landed.
// Also require the mined tx's `to` and calldata to match the call we actually intended —
// only that is proof this specific operation is the one that occupied the nonce.
async function _findMinedTxAtNonce(signer, targetNonce, expectedTo, expectedData, maxBlocksBack = 20) {
  const wantTo = (expectedTo || '').toLowerCase();
  const wantData = (expectedData || '').toLowerCase();
  const latest = parseInt(await signer.provider.send('eth_blockNumber', []), 16);
  for (let i = 0; i <= maxBlocksBack && latest - i >= 0; i++) {
    const blockNum = '0x' + (latest - i).toString(16);
    let block;
    try { block = await signer.provider.send('eth_getBlockByNumber', [blockNum, true]); } catch (_) { continue; }
    if (!block || !Array.isArray(block.transactions)) continue;
    const match = block.transactions.find((t) => {
      if (!t.from || t.from.toLowerCase() !== signer.address.toLowerCase()) return false;
      if (parseInt(t.nonce, 16) !== targetNonce) return false;
      if (!t.to || t.to.toLowerCase() !== wantTo) return false;
      // Ethereum JSON-RPC's standard calldata field is `input`; some clients also mirror it
      // as `data` — accept either rather than assuming one.
      const calldata = (t.input ?? t.data ?? '').toLowerCase();
      if (calldata !== wantData) return false;
      // sendTxSafe never attaches a `value` override today (grepped: no caller in this repo
      // passes one) — expected value is always 0. If that ever changes, this must take the
      // real expected value as a parameter instead of hardcoding 0n.
      const val = t.value ? BigInt(t.value) : 0n;
      return val === 0n;
    });
    if (match) return match.hash;
  }
  return null;
}

async function _rawReceipt(signer, hash) {
  return signer.provider.send('eth_getTransactionReceipt', [hash]);
}

// Wait until the signer's mempool drains (pending nonce == latest nonce), i.e. all
// previously-broadcast txs for this account have mined. This is the cure for the
// "in-flight transaction limit" / nonce-conflict skips seen when the full suite
// fires many txs back-to-back: instead of skipping a critical tx, we wait for the
// queue to clear and retry with a fresh nonce. Returns the drained 'latest' nonce,
// or null on timeout.
async function _waitMempoolDrain(signer, maxWaitMs = 90000) {
  const start = Date.now();
  while (Date.now() - start < maxWaitMs) {
    try {
      const [pending, latest] = await Promise.all([
        _rawNonce(signer, 'pending'),
        _rawNonce(signer, 'latest'),
      ]);
      if (pending <= latest) return latest; // no in-flight txs left
    } catch (_) { /* transient RPC — retry below */ }
    await new Promise(r => setTimeout(r, 4000));
  }
  return null;
}

// Cross-PROCESS mutex for wallet nonce sequencing (DSR review, 2026-09-17). Root
// cause of the "nonce/in-flight conflict" retries DSR hit on a supposedly
// uncontended fresh anvil: this repo's E2E scripts are separate `node` processes
// that routinely share one wallet (deployer) — D7's 12 migrated scripts, or simply
// two scripts investigated side by side. Fetching the nonce fresh from 'pending'
// on every attempt (rather than caching a locally-incremented counter, which is
// only safe against a SINGLE process's own writes) closes the STALENESS window
// but not the TOCTOU race: two processes can both read the same 'pending' value
// before either has broadcast. Reproduced empirically — running two D7 scripts
// against the same deployer wallet concurrently on a single freshly-deployed
// anvil (confirmed via `ps aux` to have zero unrelated contention) collided
// deterministically even with a fresh fetch per attempt. A lockfile (atomic
// exclusive create — OS-level, no dependency needed) serializes the
// fetch-nonce -> broadcast -> confirm section per (chainId, wallet) across
// independent processes, which fresh-fetching alone cannot do.
const _NONCE_LOCK_DIR = path.join(os.tmpdir(), 'sp-e2e-nonce-locks');
const _NONCE_LOCK_STALE_MS = 120000; // a crashed holder's lock is reclaimable after 2 min
const _NONCE_LOCK_WAIT_MS = 60000; // give up and surface an error rather than hang the suite forever

async function _withWalletLock(signer, fn) {
  if (!signer || !signer.address) return fn();
  let chainId = 'unknown';
  try { chainId = (await signer.provider.getNetwork()).chainId.toString(); } catch (_) { /* fall through with 'unknown' */ }
  fs.mkdirSync(_NONCE_LOCK_DIR, { recursive: true });
  const lockPath = path.join(_NONCE_LOCK_DIR, `${chainId}-${signer.address.toLowerCase()}.lock`);
  const deadline = Date.now() + _NONCE_LOCK_WAIT_MS;
  for (;;) {
    try {
      const fd = fs.openSync(lockPath, 'wx'); // atomic exclusive create — the actual mutex
      fs.writeSync(fd, `${process.pid} ${Date.now()}`);
      fs.closeSync(fd);
      break;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      try {
        if (Date.now() - fs.statSync(lockPath).mtimeMs > _NONCE_LOCK_STALE_MS) {
          fs.unlinkSync(lockPath); // reclaim a crashed holder's lock
          continue;
        }
      } catch (_) { /* lock vanished between our stat and unlink — loop will just retry the create */ }
      if (Date.now() > deadline) throw new Error(`nonce lock timeout waiting for ${lockPath}`);
      await new Promise(r => setTimeout(r, 150 + Math.random() * 150)); // jittered poll, avoid lockstep retries
    }
  }
  try {
    return await fn();
  } finally {
    try { fs.unlinkSync(lockPath); } catch (_) { /* already gone (stale-reclaim race) — fine */ }
  }
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
 *
 * The whole attempt loop runs inside `_withWalletLock` (see above) — nonce fetch,
 * broadcast, and confirmation wait are one critical section per wallet, safe
 * against other `sendTxSafe` calls for the same wallet in THIS or ANY OTHER
 * process holding the same lockfile.
 */
async function sendTxSafe(contract, method, args, label, opts = {}) {
  if (typeof opts === 'number') opts = { maxRetries: opts }; // back-compat: numeric 5th arg
  const maxRetries = opts.maxRetries != null ? opts.maxRetries : 3;
  const critical = opts.critical !== false;
  const signer = contract.runner;
  return _withWalletLock(signer, () => _sendTxSafeInner(contract, method, args, label, signer, maxRetries, critical));
}

async function _sendTxSafeInner(contract, method, args, label, signer, maxRetries, critical) {

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    // 'pending' accounts for this wallet's own unconfirmed txs; fetched fresh every
    // attempt (see nonce-strategy note above) so a concurrent writer elsewhere is
    // always visible before we build the next tx.
    //
    // Codex stop-gate (2026-09-17): broadcasting with sentNonce === null is a double-submit
    // hazard, not a safe fallback. The post-broadcast network-error reconciliation above
    // ("pending nonce advanced -> tx accepted, NOT resending") only works when sentNonce is
    // known — with sentNonce === null the `sentNonce !== null` guard can never fire, so a lost
    // response after a successful broadcast falls through to a resend of the same state-
    // changing call. A failed nonce READ (no tx sent yet) is safe to retry with a short
    // backoff; only give up on the whole attempt (never broadcast blind) if it keeps failing.
    let sentNonce = null;
    if (signer && signer.address) {
      let nonceReadFailed = false;
      for (let nonceAttempt = 1; nonceAttempt <= 3; nonceAttempt++) {
        try { sentNonce = await _rawNonce(signer, 'pending'); break; }
        catch (e) {
          if (nonceAttempt === 3) {
            // Same infra-vs-logic classification as the rest of this function's failure
            // paths: this is a transient RPC problem, not a contract/logic bug, so it
            // follows the caller's `critical` flag rather than always hard-FAILing.
            printSkip(`${label}: could not read nonce after 3 attempts (${(e.message || '').substring(0, 80)}) — not broadcasting blind${critical ? ' [CRITICAL]' : ''}`);
            if (critical) _criticalTxSkipped++;
            nonceReadFailed = true;
            break;
          }
          await new Promise(r => setTimeout(r, 2000));
        }
      }
      if (nonceReadFailed) return null;
    }
    const txOpts = sentNonce !== null ? { nonce: sentNonce } : {};

    let tx;
    try {
      tx = await contract[method](...args, txOpts);
    } catch (err) {
      if (_isNetworkError(err)) {
        // Codex stop-gate (2026-09-17), round 3: a side-channel nonce READ used to
        // "reconcile" whether an ambiguous send landed can itself be stale on a
        // load-balanced remote RPC (this project defaults to Alchemy, which this repo
        // has documented eventual-consistency quirks for elsewhere). Round 2 treated
        // "pendingNonce === sentNonce" as proof of non-delivery, but that read can lag:
        // by the time we'd loop back to the top of the outer attempt loop and fetch a
        // FRESH nonce for the retry, propagation may have caught up, so the retry sends
        // at an INCREMENTED nonce — a genuinely new, non-conflicting transaction — while
        // the original also lands, executing the call twice.
        //
        // Fix: don't reconcile via a side-channel read at all. Retry the IDENTICAL send
        // (same sentNonce, same txOpts) directly, without returning to the outer loop's
        // fresh-nonce fetch. If the original actually landed, this identical-nonce retry
        // is rejected by the node as a nonce conflict (already known / nonce too low) —
        // Ethereum's own nonce-uniqueness guarantee IS the reconciliation, and unlike a
        // side-channel read it cannot be stale: at most one transaction can ever be
        // mined for a given (sender, nonce) pair, so retrying that exact pair can never
        // itself cause a double execution.
        let resolved = false;
        for (let netAttempt = 1; netAttempt <= NETWORK_RETRY_BUDGET; netAttempt++) {
          await new Promise(r => setTimeout(r, 4000));
          try {
            tx = await contract[method](...args, txOpts); // SAME txOpts/nonce — identical send
            resolved = true;
            break;
          } catch (err2) {
            // Codex stop-gate (2026-09-17), round 4: only a DEFINITIVE nonce-collision
            // signal proves this exact (sender, nonce) slot is already occupied. The
            // broader `_isNonceConflict` also matches "in-flight transaction limit" /
            // "could not coalesce" — generic congestion signals that say nothing about
            // whether THIS send was ever accepted. Treating those as proof would let a
            // genuinely undelivered original get reported as `{applied:true}` — a false
            // "success" for an op that never happened, silently, with no critical skip.
            if (_isDefiniteNonceCollision(err2)) {
              // Codex round 5: this proves the (sender, sentNonce) slot is occupied, not
              // that the operation succeeded (see the _findMinedTxAtNonce comment above —
              // mined-but-reverted still consumes the nonce; "replacement underpriced" can
              // mean merely pending). Look up and verify the real outcome, don't assume.
              printInfo(`${label}: identical-nonce retry rejected (${(err2.message || '').substring(0, 60)}) — looking up the actual mined tx to verify the outcome, not assuming success`);
              // Codex round 6: (from, nonce) alone can match an UNRELATED transaction that
              // happened to occupy this nonce (a concurrent write outside this call's own
              // retry loop) — require `to` and calldata to match the call we actually
              // intended before trusting its receipt as proof of anything.
              let expectedData = null;
              try { expectedData = contract.interface.encodeFunctionData(method, args); } catch (_) { /* leave null — no match possible below, falls to inconclusive */ }
              const foundHash = expectedData
                ? await _findMinedTxAtNonce(signer, sentNonce, contract.target, expectedData).catch(() => null)
                : null;
              const foundReceipt = foundHash ? await _rawReceipt(signer, foundHash).catch(() => null) : null;
              if (foundReceipt && foundReceipt.status === '0x1') {
                printInfo(`${label}: verified — original send mined and succeeded (${foundHash}), NOT resending`);
                return { applied: true, hash: foundHash, receipt: foundReceipt };
              }
              if (foundReceipt && foundReceipt.status === '0x0') {
                printError(`${label}: original send was MINED BUT REVERTED (${foundHash}) — the nonce was consumed, the operation was not`);
                return null;
              }
              // Couldn't find/verify the mined tx (still pending, outside the scan window,
              // or the RPC doesn't expose full block tx objects) — nonce occupancy alone is
              // not enough to report success per Codex's finding; stop as inconclusive.
              printSkip(`${label}: nonce ${sentNonce} is occupied but the mined outcome could not be verified — stopping as inconclusive rather than assume success${critical ? ' [CRITICAL]' : ''}`);
              if (critical) _criticalTxSkipped++;
              return null;
            }
            if (_isNetworkError(err2) || _isAmbiguousCongestion(err2)) {
              // Still ambiguous either way — neither proves delivery nor proves it
              // failed — so keep retrying the SAME (sender, nonce) rather than guess.
              if (netAttempt < NETWORK_RETRY_BUDGET) {
                printInfo(`${label}: ambiguous error persists on identical-nonce retry ${netAttempt}/${NETWORK_RETRY_BUDGET - 1} (${(err2.message || '').substring(0, 60)})...`);
                continue;
              }
              break; // exhausted — handled by the `if (!resolved)` branch below
            }
            // A genuinely different, definitive error surfaced on the identical-nonce
            // retry (e.g. a real revert) — that is a real outcome for this (sender,
            // nonce), not more ambiguity, so report it directly instead of pretending
            // it's the original error.
            const reason2 = err2.reason || err2.shortMessage || (err2.message || '').substring(0, 120);
            printError(`${label}: TX failed on identical-nonce retry (${reason2})`);
            return null;
          }
        }
        if (!resolved) {
          printSkip(`${label}: network error persisted after ${NETWORK_RETRY_BUDGET} identical-nonce retries — stopping rather than guess whether the original landed${critical ? ' [CRITICAL]' : ''}`);
          if (critical) _criticalTxSkipped++;
          return null;
        }
        // resolved === true: `tx` now holds a handle from the successful identical-nonce
        // retry. Fall through to the confirmation-wait code below — the generic error
        // classifiers in the `else` branch are for the ORIGINAL `err`, which is now moot.
      } else {
        const reason = err.reason || err.shortMessage || (err.message || '').substring(0, 120);
        if (_isNonceConflict(err)) {
          // RETRYABLE — never skip a critical tx on the first nonce/in-flight conflict.
          // Root cause is mempool congestion (RPC "in-flight transaction limit") or a
          // concurrent writer elsewhere advancing this wallet's nonce between our fetch
          // and our send. Cure: wait for the mempool to drain, then retry (the next
          // attempt re-fetches 'pending' fresh, so no manual resync is needed here). This
          // is a REJECTED send (never entered the mempool), unlike the ambiguous
          // network-error case above — a fresh nonce on retry is safe here.
          if (attempt < maxRetries) {
            printInfo(`${label}: nonce/in-flight conflict — draining mempool & retrying ${attempt}/${maxRetries - 1}...`);
            if (signer) await _waitMempoolDrain(signer);
            continue;
          }
          // Budget exhausted — only NOW treat as an (inconclusive) skip.
          printSkip(`${label}: nonce/in-flight conflict persisted after ${maxRetries} attempts — skipped${critical ? ' [CRITICAL]' : ''}`);
          if (critical) _criticalTxSkipped++;
          return null;
        }
        printError(`${label}: TX failed (${reason})`);
        return null;
      }
    }

    try {
      if (tx.wait) {
        const receipt = await tx.wait(1);
        // Print the on-chain tx hash + explorer link so every state-changing call
        // leaves a verifiable, auditable trail (real-transaction evidence).
        printInfo(`${label}: TX confirmed (gas: ${receipt.gasUsed}) tx=${tx.hash} https://sepolia.etherscan.io/tx/${tx.hash}`);
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
    // 5.5.0: config.aPNTs is now SP's own operator-deposit collateral asset, NOT a
    // balance-mode xPNTs v2 token — it does not implement tryLockForGas/debts/
    // effectiveCreditCap etc. aPNTsToken is kept bound to it only for legacy plain-ERC20
    // reads existing callers already rely on; use aastarXPNTsV2 below for v2 reads.
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
  // V5.4 god-split: x402 settlement layer is a standalone contract. Address sourced from
  // config.x402Facilitator (deployments/config.sepolia.json) with an X402_FACILITATOR env
  // override; only present after the v5.4 redeploy. Callers should null-check + SKIP.
  const x402Addr = config.x402Facilitator || process.env.X402_FACILITATOR;
  if (x402Addr) {
    contracts.x402Facilitator = new ethers.Contract(x402Addr, ABI.X402Facilitator, signerOrProvider);
  }
  // 5.5.0: dryRunValidation's new home (only present after a 5.5.0 deployment).
  if (config.superPaymasterLens) {
    contracts.superPaymasterLens = new ethers.Contract(config.superPaymasterLens, ABI.SuperPaymasterLens, signerOrProvider);
  }
  // 5.5.0: the actual balance-mode xPNTs v2 token (tryLockForGas/settleLocked/
  // tryReserveCredit/settleCredit/debts/effectiveCreditCap) — distinct from config.aPNTs
  // above. Optional key so this helper still works against a pre-5.5.0 deployment.
  if (config.aastarXPNTsV2) {
    contracts.aastarXPNTsV2 = new ethers.Contract(config.aastarXPNTsV2, ABI.xPNTsToken, signerOrProvider);
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
  printCriticalSkip,
  catchStep,
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
  // Infra-error classifier for step-level catches (network/timeout → SKIP, not FAIL)
  isInfraError: _isNetworkError,
  // Contracts
  getContracts,
  // Encoding
  encodeCommunityRoleData,
  encodeEndUserRoleData,
  // Re-export ethers
  ethers,
};

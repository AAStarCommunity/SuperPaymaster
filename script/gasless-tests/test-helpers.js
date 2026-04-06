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

function initTestEnv() {
  const config = loadConfig();
  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  if (!rpcUrl) throw new Error('SEPOLIA_RPC_URL not set');
  const provider = new ethers.JsonRpcProvider(rpcUrl);

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
    // Role constants
    "function ROLE_COMMUNITY() view returns (bytes32)",
    "function ROLE_ENDUSER() view returns (bytes32)",
    "function ROLE_PAYMASTER_SUPER() view returns (bytes32)",
    "function ROLE_PAYMASTER_AOA() view returns (bytes32)",
    "function ROLE_DVT() view returns (bytes32)",
    "function ROLE_ANODE() view returns (bytes32)",
    "function ROLE_KMS() view returns (bytes32)",
    // Wiring
    "function GTOKEN_STAKING() view returns (address)",
    "function MYSBT() view returns (address)",
    "function SUPER_PAYMASTER() view returns (address)",
    // Role management
    "function registerRole(bytes32 roleId, address user, bytes roleData)",
    "function safeMintForRole(bytes32 roleId, address user, bytes data) returns (uint256)",
    "function hasRole(bytes32 roleId, address user) view returns (bool)",
    "function getUserRoles(address user) view returns (bytes32[])",
    "function getRoleMembers(bytes32 roleId) view returns (address[])",
    "function getRoleUserCount(bytes32 roleId) view returns (uint256)",
    "function getRoleConfig(bytes32 roleId) view returns (tuple(uint256 minStake, uint256 entryBurn, uint32 slashThreshold, uint32 slashBase, uint32 slashInc, uint32 slashMax, uint16 exitFeePercent, bool isActive, uint256 minExitFee, string description, address owner, uint256 roleLockDuration))",
    // Community & reputation
    "function communityByName(string name) view returns (address)",
    "function globalReputation(address user) view returns (uint256)",
    "function accountToUser(address account) view returns (address)",
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
    "function operators(address operator) view returns (uint128 aPNTsBalance, uint96 exchangeRate, bool isConfigured, bool isPaused, address xPNTsToken, uint32 reputation, uint48 minTxInterval, address treasury, uint256 totalSpent, uint256 totalTxSponsored)",
    "function configureOperator(address xPNTsToken, address _opTreasury, uint256 exchangeRate)",
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

function resetCounters() {
  _testPassed = 0;
  _testFailed = 0;
  _testSkipped = 0;
}

function getCounters() {
  return { passed: _testPassed, failed: _testFailed, skipped: _testSkipped };
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
  const { passed, failed, skipped } = getCounters();
  const total = passed + failed + skipped;
  const line = '='.repeat(60);
  console.log(`\n${line}`);
  console.log(`  ${testName} Summary`);
  console.log(`  Total: ${total} | Passed: ${passed} | Failed: ${failed} | Skipped: ${skipped}`);
  console.log(`${line}\n`);
  return failed === 0;
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

async function sendTxSafe(contract, method, args, label) {
  try {
    const signer = contract.runner;

    // Initialize nonce tracker for this wallet
    if (signer && signer.address) {
      if (_nonceWallet !== signer.address) {
        _nonceWallet = signer.address;
        _nextNonce = await signer.getNonce('latest');
      }
    }

    // Send TX with explicit nonce
    const txOpts = _nextNonce !== null ? { nonce: _nextNonce } : {};
    const tx = await contract[method](...args, txOpts);
    if (_nextNonce !== null) _nextNonce++;

    if (tx.wait) {
      const receipt = await tx.wait(1);
      printInfo(`${label}: TX confirmed (gas: ${receipt.gasUsed})`);
      return receipt;
    }
    return tx;
  } catch (err) {
    const reason = err.reason || err.shortMessage || err.message.substring(0, 120);
    printError(`${label}: TX failed (${reason})`);
    // Refresh nonce on failure to resync
    if (_nonceWallet && contract.runner && contract.runner.address === _nonceWallet) {
      try {
        _nextNonce = await contract.runner.getNonce('latest');
      } catch (_) {}
    }
    return null;
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

function encodeEndUserRoleData(account, community, stakeAmount) {
  return ethers.AbiCoder.defaultAbiCoder().encode(
    ["tuple(address,address,string,string,uint256)"],
    [[account, community, "", "", stakeAmount || ethers.parseEther("0.3")]]
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
  resetCounters,
  getCounters,
  // Assertions
  assertEqual,
  assertTrue,
  assertFalse,
  assertGte,
  expectRevert,
  // TX
  sendTxSafe,
  // Contracts
  getContracts,
  // Encoding
  encodeCommunityRoleData,
  encodeEndUserRoleData,
  // Re-export ethers
  ethers,
};

#!/usr/bin/env node
/**
 * Test Assets Preparation Script
 *
 * This script prepares all necessary assets for testing AOA and AOA+ modes.
 * Uses @aastar/shared-config for all contract addresses.
 */

require("dotenv").config();
const { ethers } = require("ethers");
const {
  getCoreContracts,
  getTokenContracts,
  getTestTokenContracts,
  getPaymasterV4_1,
  getSuperPaymasterV2
} = require("@aastar/shared-config");

// Network configuration
const NETWORK = "sepolia";
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

// Private keys from env/.env
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;
const OWNER2_PRIVATE_KEY = process.env.OWNER2_PRIVATE_KEY;

if (!DEPLOYER_PRIVATE_KEY || !OWNER2_PRIVATE_KEY) {
  console.error("❌ Missing private keys! Please check env/.env file");
  console.error("   Required: DEPLOYER_PRIVATE_KEY, OWNER2_PRIVATE_KEY");
  process.exit(1);
}

// Get addresses from shared-config
const core = getCoreContracts(NETWORK);
const tokens = getTokenContracts(NETWORK);
const testTokens = getTestTokenContracts(NETWORK);
const paymasterV4 = getPaymasterV4_1(NETWORK);
const superPaymasterV2 = getSuperPaymasterV2(NETWORK);

// Test accounts (from env/.env)
const OWNER2_ADDRESS = "0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA";
const TEST_AA_ACCOUNT_ADDRESS_A = "0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584";
const TEST_AA_ACCOUNT_ADDRESS_B = "0x57b2e6f08399c276b2c1595825219d29990d0921";
const TEST_AA_ACCOUNT_ADDRESS_C = "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";

// AAStar and BuilderDAO community owners (from shared-config)
const AASTAR_OWNER = "0x411BD567E46C0781248dbB6a9211891C032885e5"; // Deployer 1
const BUILDERDAO_OWNER = "0x3c053322AfBEB5B2C9917A6Cbda590f1736590cd"; // Deployer 2

// Contract ABIs
const GTokenABI = [
  "function mint(address to, uint256 amount) external",
  "function balanceOf(address account) external view returns (uint256)",
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function owner() external view returns (address)"
];

const GTokenStakingABI = [
  "function stake(uint256 amount) external returns (uint256)",
  "function balanceOf(address account) external view returns (uint256)",
  "function getStakeInfo(address user) external view returns (tuple(uint256 amount, uint256 sGTokenShares, uint256 stakedAt, uint256 unstakeRequestedAt))"
];

const MySBTABI = [
  "function safeMint(address to) external returns (uint256)",
  "function balanceOf(address account) external view returns (uint256)",
  "function owner() external view returns (address)",
  "function mintSBT(address community) external returns (uint256)"
];

const xPNTsABI = [
  "function mint(address to, uint256 amount) external",
  "function balanceOf(address account) external view returns (uint256)",
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function owner() external view returns (address)",
  "function allowance(address owner, address spender) external view returns (uint256)"
];

const PaymasterV4ABI = [
  "function supportedSBTs(uint256) external view returns (address)",
  "function supportedGasTokens(uint256) external view returns (address)",
  "function gasTokenExchangeRate(address) external view returns (uint256)",
  "function aPNTsPriceUSD() external view returns (uint256)"
];

const SuperPaymasterV2ABI = [
  "function accounts(address operator) external view returns (tuple(uint256 aPNTsBalance, uint256 totalSpent, uint256 operatorStakedAmount, uint256 reputation, bool isActive, address[] supportedSBTs, address xPNTsToken))",
  "function getOperatorConfig(address operator, address xPNTsToken) external view returns (uint256 exchangeRate, bool isSupported)"
];

async function main() {
  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║           Test Assets Preparation Script                        ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const deployerSigner = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);
  const owner2Signer = new ethers.Wallet(OWNER2_PRIVATE_KEY, provider);

  console.log("📋 Configuration from @aastar/shared-config:");
  console.log("─────────────────────────────────────────────────────────────────");
  console.log("Core Contracts:");
  console.log("  SuperPaymasterV2:  ", core.superPaymasterV2);
  console.log("  Registry:          ", core.registry);
  console.log("  GToken:            ", core.gToken);
  console.log("  GTokenStaking:     ", core.gTokenStaking);
  console.log("\nToken Contracts:");
  console.log("  xPNTsFactory:      ", tokens.xPNTsFactory);
  console.log("  MySBT:             ", tokens.mySBT);
  console.log("\nTest Tokens:");
  console.log("  aPNTs (AAStar):    ", testTokens.aPNTs);
  console.log("  bPNTs (BuilderDAO):", testTokens.bPNTs);
  console.log("\nPaymasters:");
  console.log("  PaymasterV4_1:     ", paymasterV4);
  console.log("  SuperPaymasterV2:  ", superPaymasterV2);
  console.log();

  // ==========================================
  // STEP 1: Verify Contract Configurations
  // ==========================================
  console.log("🔍 Step 1: Verifying Contract Configurations");
  console.log("─────────────────────────────────────────────────────────────────");

  // 1.1 Check PaymasterV4 supported tokens
  const paymasterV4Contract = new ethers.Contract(paymasterV4, PaymasterV4ABI, provider);

  console.log("\n📌 PaymasterV4_1 Configuration:");
  try {
    // Check supported SBTs
    const sbtAddress = await paymasterV4Contract.supportedSBTs(0);
    console.log("  Supported SBT[0]:  ", sbtAddress);

    // Check if it matches MySBT from shared-config
    if (sbtAddress.toLowerCase() !== tokens.mySBT.toLowerCase()) {
      console.warn("  ⚠️ Warning: SBT mismatch! PaymasterV4 expects:", sbtAddress);
      console.warn("     but shared-config has:", tokens.mySBT);
    } else {
      console.log("  ✅ SBT address matches shared-config");
    }
  } catch (e) {
    console.log("  ℹ️ Could not fetch supported SBTs (may need configuration)");
  }

  try {
    // Check aPNTs price
    const apntsPrice = await paymasterV4Contract.aPNTsPriceUSD();
    console.log("  aPNTs Price USD:   ", ethers.formatUnits(apntsPrice, 18), "USD");
  } catch (e) {
    console.log("  ℹ️ Could not fetch aPNTs price");
  }

  // 1.2 Check xPNTs tokens allowances (pre-approved by factory)
  console.log("\n📌 Token Approvals Check:");

  const apntsContract = new ethers.Contract(testTokens.aPNTs, xPNTsABI, provider);
  const bpntsContract = new ethers.Contract(testTokens.bPNTs, xPNTsABI, provider);

  // Check aPNTs approvals
  const apntsAllowanceV4 = await apntsContract.allowance(TEST_AA_ACCOUNT_ADDRESS_A, paymasterV4);
  const apntsAllowanceV2 = await apntsContract.allowance(TEST_AA_ACCOUNT_ADDRESS_A, superPaymasterV2);

  console.log("  aPNTs Allowances for Account A:");
  console.log("    → PaymasterV4_1:    ", apntsAllowanceV4 === ethers.MaxUint256 ? "MAX ✅" : ethers.formatUnits(apntsAllowanceV4, 18));
  console.log("    → SuperPaymasterV2: ", apntsAllowanceV2 === ethers.MaxUint256 ? "MAX ✅" : ethers.formatUnits(apntsAllowanceV2, 18));

  // Check bPNTs approvals
  const bpntsAllowanceV4 = await bpntsContract.allowance(TEST_AA_ACCOUNT_ADDRESS_A, paymasterV4);
  const bpntsAllowanceV2 = await bpntsContract.allowance(TEST_AA_ACCOUNT_ADDRESS_A, superPaymasterV2);

  console.log("  bPNTs Allowances for Account A:");
  console.log("    → PaymasterV4_1:    ", bpntsAllowanceV4 === ethers.MaxUint256 ? "MAX ✅" : ethers.formatUnits(bpntsAllowanceV4, 18));
  console.log("    → SuperPaymasterV2: ", bpntsAllowanceV2 === ethers.MaxUint256 ? "MAX ✅" : ethers.formatUnits(bpntsAllowanceV2, 18));

  // 1.3 Check gas token exchange rates
  console.log("\n📌 Exchange Rates Check:");
  try {
    const apntsRate = await paymasterV4Contract.gasTokenExchangeRate(testTokens.aPNTs);
    const bpntsRate = await paymasterV4Contract.gasTokenExchangeRate(testTokens.bPNTs);

    console.log("  PaymasterV4_1 Exchange Rates:");
    console.log("    aPNTs → aPNTs:     ", apntsRate > 0 ? ethers.formatUnits(apntsRate, 18) + " ✅" : "Not Set ❌");
    console.log("    bPNTs → aPNTs:     ", bpntsRate > 0 ? ethers.formatUnits(bpntsRate, 18) + " ✅" : "Not Set ❌");
  } catch (e) {
    console.log("  ℹ️ Could not fetch exchange rates");
  }

  // 1.4 Check SuperPaymasterV2 operator registration
  console.log("\n📌 SuperPaymasterV2 Operator Check:");
  const superPaymasterV2Contract = new ethers.Contract(superPaymasterV2, SuperPaymasterV2ABI, provider);

  try {
    const operatorInfo = await superPaymasterV2Contract.accounts(AASTAR_OWNER);
    console.log("  AAStar Operator:");
    console.log("    aPNTs Balance:     ", ethers.formatUnits(operatorInfo.aPNTsBalance, 18));
    console.log("    Total Spent:       ", ethers.formatUnits(operatorInfo.totalSpent, 18));
    console.log("    Staked Amount:     ", ethers.formatUnits(operatorInfo.operatorStakedAmount, 18), "sGT");
    console.log("    Is Active:         ", operatorInfo.isActive ? "✅" : "❌");

    if (!operatorInfo.isActive) {
      console.warn("  ⚠️ Operator not registered! Need to register first.");
    }
  } catch (e) {
    console.log("  ℹ️ Operator not found (need to register)");
  }

  // ==========================================
  // STEP 2: Check Token Ownership
  // ==========================================
  console.log("\n🔑 Step 2: Checking Token Ownership");
  console.log("─────────────────────────────────────────────────────────────────");

  // Check aPNTs owner
  try {
    const apntsOwner = await apntsContract.owner();
    console.log("  aPNTs Owner:       ", apntsOwner);
    console.log("    Expected:        ", AASTAR_OWNER);
    console.log("    Match:           ", apntsOwner.toLowerCase() === AASTAR_OWNER.toLowerCase() ? "✅" : "❌");

    if (apntsOwner.toLowerCase() === deployerSigner.address.toLowerCase()) {
      console.log("    🔑 We have the private key for minting!");
    }
  } catch (e) {
    console.log("  ℹ️ Could not fetch aPNTs owner");
  }

  // Check bPNTs owner
  try {
    const bpntsOwner = await bpntsContract.owner();
    console.log("\n  bPNTs Owner:       ", bpntsOwner);
    console.log("    Expected:        ", BUILDERDAO_OWNER);
    console.log("    Match:           ", bpntsOwner.toLowerCase() === BUILDERDAO_OWNER.toLowerCase() ? "✅" : "❌");

    if (bpntsOwner.toLowerCase() === deployerSigner.address.toLowerCase()) {
      console.log("    🔑 We have the private key for minting!");
    }
  } catch (e) {
    console.log("  ℹ️ Could not fetch bPNTs owner");
  }

  // ==========================================
  // STEP 3: Check Current Balances
  // ==========================================
  console.log("\n💰 Step 3: Checking Current Balances");
  console.log("─────────────────────────────────────────────────────────────────");

  const gTokenContract = new ethers.Contract(core.gToken, GTokenABI, provider);
  const gTokenStakingContract = new ethers.Contract(core.gTokenStaking, GTokenStakingABI, provider);
  const mySBTContract = new ethers.Contract(tokens.mySBT, MySBTABI, provider);

  for (const [name, address] of [
    ["Account A", TEST_AA_ACCOUNT_ADDRESS_A],
    ["Account B", TEST_AA_ACCOUNT_ADDRESS_B],
    ["Account C", TEST_AA_ACCOUNT_ADDRESS_C]
  ]) {
    console.log(`\n  ${name} (${address.slice(0, 10)}...):`);

    // Check ETH balance
    const ethBalance = await provider.getBalance(address);
    console.log(`    ETH:      ${ethers.formatEther(ethBalance)} ETH`);

    // Check GToken balance
    const gTokenBalance = await gTokenContract.balanceOf(address);
    console.log(`    GToken:   ${ethers.formatUnits(gTokenBalance, 18)} GT`);

    // Check staked GToken
    const stGTokenBalance = await gTokenStakingContract.balanceOf(address);
    console.log(`    stGToken: ${ethers.formatUnits(stGTokenBalance, 18)} stGT`);

    // Check SBT balance
    const sbtBalance = await mySBTContract.balanceOf(address);
    console.log(`    SBT:      ${sbtBalance.toString()} ${sbtBalance > 0 ? "✅" : "❌"}`);

    // Check aPNTs balance
    const apntsBalance = await apntsContract.balanceOf(address);
    console.log(`    aPNTs:    ${ethers.formatUnits(apntsBalance, 18)} aPNTs`);

    // Check bPNTs balance
    const bpntsBalance = await bpntsContract.balanceOf(address);
    console.log(`    bPNTs:    ${ethers.formatUnits(bpntsBalance, 18)} bPNTs`);
  }

  // ==========================================
  // STEP 4: Summary and Next Steps
  // ==========================================
  console.log("\n📊 Summary & Required Actions");
  console.log("═══════════════════════════════════════════════════════════════════");

  console.log("\n🔧 For AOA Mode Testing (PaymasterV4_1 + bPNTs):");
  console.log("  1. Ensure test accounts have SBT");
  console.log("  2. Ensure test accounts have bPNTs (BuilderDAO gas token)");
  console.log("  3. Check bPNTs is approved to PaymasterV4_1");
  console.log("  4. Set exchange rate for bPNTs in PaymasterV4_1");

  console.log("\n🔧 For AOA+ Mode Testing (SuperPaymasterV2 + aPNTs):");
  console.log("  1. Register operator in SuperPaymasterV2");
  console.log("  2. Stake sGToken for operator");
  console.log("  3. Deposit aPNTs to operator account");
  console.log("  4. Configure xPNTs exchange rate");
  console.log("  5. Ensure test accounts have aPNTs");

  console.log("\n📝 Run the following scripts to prepare assets:");
  console.log("  - scripts/mint-tokens.js      : Mint GToken, aPNTs, bPNTs");
  console.log("  - scripts/stake-gtoken.js     : Stake GToken to get stGToken");
  console.log("  - scripts/mint-sbt.js         : Mint SBT for test accounts");
  console.log("  - scripts/register-operator.js: Register operator in SuperPaymasterV2");

  console.log("\n✅ Script completed!");
}

// Run the script
main().catch((error) => {
  console.error("\n❌ Error:", error);
  process.exit(1);
});
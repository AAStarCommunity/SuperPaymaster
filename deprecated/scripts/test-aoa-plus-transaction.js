#!/usr/bin/env node
/**
 * Test AOA+ Mode Transaction
 *
 * Tests SuperPaymasterV2 with aPNTs as gas token
 * Uses @aastar/shared-config for all addresses
 */

// Load env from correct path
const path = require("path");
require("dotenv").config({ path: path.join(__dirname, "../../env/.env") });

const { ethers } = require("ethers");
const {
  getCoreContracts,
  getTestTokenContracts,
  getTokenContracts,
  getSuperPaymasterV2,
  getEntryPoint
} = require("@aastar/shared-config");

// Network configuration
const NETWORK = "sepolia";
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

// Private key from env/.env
const OWNER2_PRIVATE_KEY = process.env.OWNER2_PRIVATE_KEY;
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;

if (!OWNER2_PRIVATE_KEY || !DEPLOYER_PRIVATE_KEY) {
  console.error("❌ Missing private keys! Please check env/.env file");
  console.error("   Required: OWNER2_PRIVATE_KEY, DEPLOYER_PRIVATE_KEY");
  process.exit(1);
}

// Get addresses from shared-config
const core = getCoreContracts(NETWORK);
const testTokens = getTestTokenContracts(NETWORK);
const tokens = getTokenContracts(NETWORK);
const superPaymasterV2 = getSuperPaymasterV2(NETWORK);
const entryPoint = getEntryPoint(NETWORK);

// Test accounts (SimpleAccounts controlled by OWNER2)
const TEST_ACCOUNT_A = "0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584";
const TEST_ACCOUNT_B = "0x57b2e6f08399c276b2c1595825219d29990d0921";

// Gas token for AOA+ test: aPNTs (AAStar token)
const GAS_TOKEN_ADDRESS = testTokens.aPNTs;

// Operator address (deployer is the operator for AAStar)
const OPERATOR_ADDRESS = "0x411BD567E46C0781248dbB6a9211891C032885e5";

// ABIs
const EntryPointABI = [
  "function handleOps((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature)[] ops, address payable beneficiary) external",
  "function getUserOpHash((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp) external view returns (bytes32)"
];

const SimpleAccountABI = [
  "function execute(address dest, uint256 value, bytes calldata func) external",
  "function getNonce() public view returns (uint256)"
];

const ERC20ABI = [
  "function transfer(address to, uint256 amount) external returns (bool)",
  "function balanceOf(address) external view returns (uint256)",
  "function allowance(address owner, address spender) external view returns (uint256)"
];

const SuperPaymasterV2ABI = [
  "function accounts(address operator) external view returns (tuple(uint256 aPNTsBalance, uint256 totalSpent, uint256 operatorStakedAmount, uint256 reputation, bool isActive, address[] supportedSBTs, address xPNTsToken))",
  "function getOperatorConfig(address operator, address xPNTsToken) external view returns (uint256 exchangeRate, bool isSupported)"
];

const MySBTABI = [
  "function balanceOf(address) external view returns (uint256)"
];

async function main() {
  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║      AOA+ Mode Test - SuperPaymasterV2 with aPNTs               ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const owner2Signer = new ethers.Wallet(OWNER2_PRIVATE_KEY, provider);
  const deployerSigner = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

  console.log("📋 Configuration (from @aastar/shared-config):");
  console.log("─────────────────────────────────────────────────────────────────");
  console.log("  Network:          ", NETWORK);
  console.log("  EntryPoint v0.7:  ", entryPoint);
  console.log("  SuperPaymasterV2: ", superPaymasterV2);
  console.log("  Gas Token:        ", GAS_TOKEN_ADDRESS, "(aPNTs)");
  console.log("  MySBT:            ", tokens.mySBT);
  console.log("  Operator:         ", OPERATOR_ADDRESS);
  console.log("  SimpleAccount A:  ", TEST_ACCOUNT_A);
  console.log("  SimpleAccount B:  ", TEST_ACCOUNT_B);
  console.log("  Account Owner:    ", owner2Signer.address);
  console.log();

  // Initialize contracts
  const entryPointContract = new ethers.Contract(entryPoint, EntryPointABI, owner2Signer);
  const accountContract = new ethers.Contract(TEST_ACCOUNT_A, SimpleAccountABI, provider);
  const gasTokenContract = new ethers.Contract(GAS_TOKEN_ADDRESS, ERC20ABI, provider);
  const superPaymasterContract = new ethers.Contract(superPaymasterV2, SuperPaymasterV2ABI, provider);
  const sbtContract = new ethers.Contract(tokens.mySBT, MySBTABI, provider);

  // ==========================================
  // Pre-transaction Verification
  // ==========================================
  console.log("🔍 Pre-transaction Verification:");
  console.log("─────────────────────────────────────────────────────────────────");

  // 1. Verify SBT ownership
  const sbtBalance = await sbtContract.balanceOf(TEST_ACCOUNT_A);
  console.log("  SBT Balance:      ", sbtBalance.toString(), sbtBalance > 0 ? "✅" : "❌ MISSING!");
  if (sbtBalance === 0n) {
    console.error("\n❌ Account A doesn't have SBT! Run scripts/mint-sbt.js first.");
    process.exit(1);
  }

  // 2. Verify operator registration
  const operatorInfo = await superPaymasterContract.accounts(OPERATOR_ADDRESS);
  console.log("\n  Operator Status:");
  console.log("    aPNTs Balance:  ", ethers.formatUnits(operatorInfo.aPNTsBalance, 18));
  console.log("    Total Spent:    ", ethers.formatUnits(operatorInfo.totalSpent, 18));
  console.log("    Staked Amount:  ", ethers.formatUnits(operatorInfo.operatorStakedAmount, 18), "sGT");
  console.log("    Is Active:      ", operatorInfo.isActive ? "✅" : "❌ NOT ACTIVE!");

  if (!operatorInfo.isActive) {
    console.error("\n❌ Operator not registered in SuperPaymasterV2!");
    console.error("   Need to register operator first.");
    process.exit(1);
  }

  // 3. Verify exchange rate configuration
  const [exchangeRate, isSupported] = await superPaymasterContract.getOperatorConfig(
    OPERATOR_ADDRESS,
    GAS_TOKEN_ADDRESS
  );
  console.log("\n  aPNTs Config:");
  console.log("    Exchange Rate:  ", exchangeRate > 0 ? ethers.formatUnits(exchangeRate, 18) + " ✅" : "Not Set ❌");
  console.log("    Is Supported:   ", isSupported ? "✅" : "❌");

  if (!isSupported || exchangeRate === 0n) {
    console.error("\n❌ aPNTs not configured for operator!");
    process.exit(1);
  }

  // 4. Check allowance
  const allowance = await gasTokenContract.allowance(TEST_ACCOUNT_A, superPaymasterV2);
  console.log("\n  Token Allowance:  ", allowance === ethers.MaxUint256 ? "MAX ✅" : ethers.formatUnits(allowance, 18));

  // ==========================================
  // State BEFORE Transaction
  // ==========================================
  console.log("\n📊 State BEFORE Transaction:");
  console.log("─────────────────────────────────────────────────────────────────");

  const beforeAccountAPNTs = await gasTokenContract.balanceOf(TEST_ACCOUNT_A);
  const beforeRecipientAPNTs = await gasTokenContract.balanceOf(TEST_ACCOUNT_B);
  const beforeOperatorAPNTs = operatorInfo.aPNTsBalance;
  const beforeAccountETH = await provider.getBalance(TEST_ACCOUNT_A);

  console.log("  Account A aPNTs:  ", ethers.formatUnits(beforeAccountAPNTs, 18), "aPNTs");
  console.log("  Account B aPNTs:  ", ethers.formatUnits(beforeRecipientAPNTs, 18), "aPNTs");
  console.log("  Operator aPNTs:   ", ethers.formatUnits(beforeOperatorAPNTs, 18), "aPNTs (internal)");
  console.log("  Account A ETH:    ", ethers.formatUnits(beforeAccountETH, 18), "ETH");

  // Validation
  if (beforeAccountAPNTs < ethers.parseUnits("10", 18)) {
    console.error("\n❌ Insufficient aPNTs balance! Run scripts/mint-tokens.js first.");
    process.exit(1);
  }

  if (beforeOperatorAPNTs < ethers.parseUnits("10", 18)) {
    console.error("\n❌ Operator has insufficient aPNTs balance!");
    console.error("   Need to deposit aPNTs to operator account.");
    process.exit(1);
  }

  // ==========================================
  // Construct UserOperation
  // ==========================================
  console.log("\n🔧 Constructing UserOperation:");
  console.log("─────────────────────────────────────────────────────────────────");

  const nonce = await accountContract.getNonce();
  const transferAmount = ethers.parseUnits("0.5", 18); // Transfer 0.5 aPNTs

  console.log("  Transfer Amount:  ", ethers.formatUnits(transferAmount, 18), "aPNTs");
  console.log("  Nonce:            ", nonce.toString());

  // Construct calldata for aPNTs transfer
  const transferCalldata = gasTokenContract.interface.encodeFunctionData("transfer", [
    TEST_ACCOUNT_B,
    transferAmount
  ]);

  const executeCalldata = accountContract.interface.encodeFunctionData("execute", [
    GAS_TOKEN_ADDRESS,
    0,
    transferCalldata
  ]);

  // Gas configuration
  const callGasLimit = 100000n;
  const verificationGasLimit = 300000n;
  const preVerificationGas = 100000n;
  const maxPriorityFeePerGas = ethers.parseUnits("0.1", "gwei");
  const latestBlock = await provider.getBlock("latest");
  const baseFeePerGas = latestBlock.baseFeePerGas || ethers.parseUnits("0.001", "gwei");
  const maxFeePerGas = baseFeePerGas + maxPriorityFeePerGas + ethers.parseUnits("0.001", "gwei");

  console.log("\n  Gas Configuration:");
  console.log("    callGasLimit:          ", callGasLimit.toString());
  console.log("    verificationGasLimit:  ", verificationGasLimit.toString());
  console.log("    preVerificationGas:    ", preVerificationGas.toString());
  console.log("    maxFeePerGas:          ", ethers.formatUnits(maxFeePerGas, "gwei"), "gwei");
  console.log("    maxPriorityFeePerGas:  ", ethers.formatUnits(maxPriorityFeePerGas, "gwei"), "gwei");

  // Pack gas limits (EntryPoint v0.7 format)
  const accountGasLimits = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(verificationGasLimit), 16),
    ethers.zeroPadValue(ethers.toBeHex(callGasLimit), 16)
  ]);

  const gasFees = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(maxPriorityFeePerGas), 16),
    ethers.zeroPadValue(ethers.toBeHex(maxFeePerGas), 16)
  ]);

  // PaymasterAndData: SuperPaymasterV2 address + operator address + gas token address
  const paymasterAndData = ethers.concat([
    superPaymasterV2,
    ethers.zeroPadValue(OPERATOR_ADDRESS, 32),
    ethers.zeroPadValue(GAS_TOKEN_ADDRESS, 32)
  ]);

  console.log("\n  PaymasterAndData:");
  console.log("    SuperPaymaster:   ", superPaymasterV2);
  console.log("    Operator:         ", OPERATOR_ADDRESS);
  console.log("    Gas Token:        ", GAS_TOKEN_ADDRESS);

  // Construct UserOperation
  const userOp = {
    sender: TEST_ACCOUNT_A,
    nonce: nonce,
    initCode: "0x",
    callData: executeCalldata,
    accountGasLimits: accountGasLimits,
    preVerificationGas: preVerificationGas,
    gasFees: gasFees,
    paymasterAndData: paymasterAndData,
    signature: "0x" // Will be filled after signing
  };

  // Get UserOp hash for signing
  const userOpHash = await entryPointContract.getUserOpHash(userOp);
  console.log("\n  UserOp Hash:      ", userOpHash);

  // Sign the hash
  const signature = await owner2Signer.signMessage(ethers.getBytes(userOpHash));
  userOp.signature = signature;

  console.log("  Signature:        ", signature.slice(0, 20) + "...");

  // ==========================================
  // Submit to EntryPoint
  // ==========================================
  console.log("\n📤 Submitting to EntryPoint:");
  console.log("─────────────────────────────────────────────────────────────────");

  try {
    // Estimate gas
    const gasEstimate = await entryPointContract.estimateGas.handleOps(
      [userOp],
      owner2Signer.address
    );
    console.log("  Gas Estimate:     ", gasEstimate.toString());

    // Submit transaction
    console.log("  Submitting UserOp...");
    const tx = await entryPointContract.handleOps(
      [userOp],
      owner2Signer.address, // Beneficiary receives refunded ETH
      { gasLimit: gasEstimate * 150n / 100n } // Add 50% buffer
    );

    console.log("  TX Hash:          ", tx.hash);
    console.log("  Waiting for confirmation...");

    const receipt = await tx.wait();
    console.log("  ✅ Confirmed in block", receipt.blockNumber);
    console.log("  Gas Used:         ", receipt.gasUsed.toString());

  } catch (error) {
    console.error("\n❌ Transaction failed:", error.message);
    if (error.data) {
      try {
        // Decode revert reason
        const revertData = error.data;
        console.log("  Revert data:", revertData);
      } catch (e) {}
    }
    process.exit(1);
  }

  // ==========================================
  // State AFTER Transaction
  // ==========================================
  console.log("\n📊 State AFTER Transaction:");
  console.log("─────────────────────────────────────────────────────────────────");

  const afterAccountAPNTs = await gasTokenContract.balanceOf(TEST_ACCOUNT_A);
  const afterRecipientAPNTs = await gasTokenContract.balanceOf(TEST_ACCOUNT_B);
  const afterOperatorInfo = await superPaymasterContract.accounts(OPERATOR_ADDRESS);
  const afterOperatorAPNTs = afterOperatorInfo.aPNTsBalance;
  const afterAccountETH = await provider.getBalance(TEST_ACCOUNT_A);

  console.log("  Account A aPNTs:  ", ethers.formatUnits(afterAccountAPNTs, 18), "aPNTs");
  console.log("  Account B aPNTs:  ", ethers.formatUnits(afterRecipientAPNTs, 18), "aPNTs");
  console.log("  Operator aPNTs:   ", ethers.formatUnits(afterOperatorAPNTs, 18), "aPNTs (internal)");
  console.log("  Operator Spent:   ", ethers.formatUnits(afterOperatorInfo.totalSpent, 18), "aPNTs (total)");
  console.log("  Account A ETH:    ", ethers.formatUnits(afterAccountETH, 18), "ETH");

  // Calculate changes
  console.log("\n📈 Changes:");
  console.log("─────────────────────────────────────────────────────────────────");

  const accountAPNTsChange = afterAccountAPNTs - beforeAccountAPNTs;
  const recipientAPNTsChange = afterRecipientAPNTs - beforeRecipientAPNTs;
  const operatorAPNTsChange = afterOperatorAPNTs - beforeOperatorAPNTs;
  const accountETHChange = afterAccountETH - beforeAccountETH;

  console.log("  Account A aPNTs:  ", ethers.formatUnits(accountAPNTsChange, 18), "aPNTs");
  console.log("  Account B aPNTs:  ", ethers.formatUnits(recipientAPNTsChange, 18), "aPNTs");
  console.log("  Operator aPNTs:   ", ethers.formatUnits(operatorAPNTsChange, 18), "aPNTs (internal)");
  console.log("  Account A ETH:    ", ethers.formatUnits(accountETHChange, 18), "ETH (should be 0)");

  // Verify gasless
  if (accountETHChange === 0n) {
    console.log("\n✅ SUCCESS! Gasless transaction completed using aPNTs!");
    console.log("   - User paid gas in aPNTs");
    console.log("   - Operator's internal aPNTs balance decreased");
    console.log("   - No ETH was consumed by the user");
  } else {
    console.log("\n⚠️ Warning: Account A ETH balance changed!");
  }

  const gasFeeInAPNTs = -(accountAPNTsChange + recipientAPNTsChange);
  console.log("\n💰 Gas Fee Paid:   ", ethers.formatUnits(gasFeeInAPNTs, 18), "aPNTs");
  console.log("   Operator Cost:  ", ethers.formatUnits(-operatorAPNTsChange, 18), "aPNTs (internal)");
}

// Run the script
main().catch((error) => {
  console.error("\n❌ Error:", error);
  console.error(error.stack);
  process.exit(1);
});
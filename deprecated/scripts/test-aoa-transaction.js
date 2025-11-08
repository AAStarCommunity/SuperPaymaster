#!/usr/bin/env node
/**
 * Test AOA Mode Transaction
 *
 * Tests PaymasterV4_1 with bPNTs as gas token
 * Uses @aastar/shared-config for all addresses
 */

// Load env from correct path
const path = require("path");
require("dotenv").config({ path: path.join(__dirname, "../../env/.env") });

const { ethers } = require("ethers");
const {
  getTestTokenContracts,
  getPaymasterV4_1,
  getTokenContracts,
  getEntryPoint
} = require("@aastar/shared-config");

// Network configuration
const NETWORK = "sepolia";
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

// Private key from env/.env
const OWNER2_PRIVATE_KEY = process.env.OWNER2_PRIVATE_KEY;

if (!OWNER2_PRIVATE_KEY) {
  console.error("❌ Missing OWNER2_PRIVATE_KEY! Please check env/.env file");
  process.exit(1);
}

// Get addresses from shared-config
const testTokens = getTestTokenContracts(NETWORK);
const tokens = getTokenContracts(NETWORK);
const paymasterV4 = getPaymasterV4_1(NETWORK);
const entryPoint = getEntryPoint(NETWORK);

// Test accounts (SimpleAccounts controlled by OWNER2)
const TEST_ACCOUNT_A = "0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584";
const TEST_ACCOUNT_B = "0x57b2e6f08399c276b2c1595825219d29990d0921";

// Gas token for AOA test: bPNTs (BuilderDAO token)
const GAS_TOKEN_ADDRESS = testTokens.bPNTs;

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
  "function allowance(address owner, address spender) external view returns (uint256)",
  "function approve(address spender, uint256 amount) external returns (bool)"
];

const PaymasterABI = [
  "function treasury() external view returns (address)",
  "function supportedSBTs(uint256) external view returns (address)",
  "function gasTokenExchangeRate(address) external view returns (uint256)"
];

const MySBTABI = [
  "function balanceOf(address) external view returns (uint256)"
];

async function main() {
  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║         AOA Mode Test - PaymasterV4_1 with bPNTs                ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(OWNER2_PRIVATE_KEY, provider);

  console.log("📋 Configuration (from @aastar/shared-config):");
  console.log("─────────────────────────────────────────────────────────────────");
  console.log("  Network:         ", NETWORK);
  console.log("  EntryPoint v0.7: ", entryPoint);
  console.log("  PaymasterV4_1:   ", paymasterV4);
  console.log("  Gas Token:       ", GAS_TOKEN_ADDRESS, "(bPNTs)");
  console.log("  MySBT:           ", tokens.mySBT);
  console.log("  SimpleAccount A: ", TEST_ACCOUNT_A);
  console.log("  SimpleAccount B: ", TEST_ACCOUNT_B);
  console.log("  Account Owner:   ", signer.address);
  console.log();

  // Initialize contracts
  const entryPointContract = new ethers.Contract(entryPoint, EntryPointABI, signer);
  const accountContract = new ethers.Contract(TEST_ACCOUNT_A, SimpleAccountABI, provider);
  const gasTokenContract = new ethers.Contract(GAS_TOKEN_ADDRESS, ERC20ABI, provider);
  const paymasterContract = new ethers.Contract(paymasterV4, PaymasterABI, provider);
  const sbtContract = new ethers.Contract(tokens.mySBT, MySBTABI, provider);

  // ==========================================
  // Pre-transaction Verification
  // ==========================================
  console.log("🔍 Pre-transaction Verification:");
  console.log("─────────────────────────────────────────────────────────────────");

  // 1. Verify SBT ownership
  const sbtBalance = await sbtContract.balanceOf(TEST_ACCOUNT_A);
  console.log("  SBT Balance:     ", sbtBalance.toString(), sbtBalance > 0 ? "✅" : "❌ MISSING!");
  if (sbtBalance === 0n) {
    console.error("\n❌ Account A doesn't have SBT! Run scripts/mint-sbt.js first.");
    process.exit(1);
  }

  // 2. Verify supported SBT in Paymaster
  try {
    const supportedSBT = await paymasterContract.supportedSBTs(0);
    console.log("  Paymaster SBT:   ", supportedSBT);
    console.log("  Match MySBT:     ", supportedSBT.toLowerCase() === tokens.mySBT.toLowerCase() ? "✅" : "❌");
  } catch (e) {
    console.log("  ⚠️ Could not fetch supported SBT from paymaster");
  }

  // 3. Verify exchange rate
  const exchangeRate = await paymasterContract.gasTokenExchangeRate(GAS_TOKEN_ADDRESS);
  console.log("  Exchange Rate:   ", exchangeRate > 0 ? ethers.formatUnits(exchangeRate, 18) + " ✅" : "Not Set ❌");
  if (exchangeRate === 0n) {
    console.error("\n❌ Exchange rate not set for bPNTs! Contact paymaster owner.");
    process.exit(1);
  }

  // 4. Check allowance
  const allowance = await gasTokenContract.allowance(TEST_ACCOUNT_A, paymasterV4);
  console.log("  Allowance:       ", allowance === ethers.MaxUint256 ? "MAX ✅" : ethers.formatUnits(allowance, 18));

  // Get treasury
  const treasury = await paymasterContract.treasury();
  console.log("  Treasury:        ", treasury);

  // ==========================================
  // State BEFORE Transaction
  // ==========================================
  console.log("\n📊 State BEFORE Transaction:");
  console.log("─────────────────────────────────────────────────────────────────");

  const beforeAccountBPNTs = await gasTokenContract.balanceOf(TEST_ACCOUNT_A);
  const beforeRecipientBPNTs = await gasTokenContract.balanceOf(TEST_ACCOUNT_B);
  const beforeTreasuryBPNTs = await gasTokenContract.balanceOf(treasury);
  const beforeAccountETH = await provider.getBalance(TEST_ACCOUNT_A);

  console.log("  Account A bPNTs: ", ethers.formatUnits(beforeAccountBPNTs, 18), "bPNTs");
  console.log("  Account B bPNTs: ", ethers.formatUnits(beforeRecipientBPNTs, 18), "bPNTs");
  console.log("  Treasury bPNTs:  ", ethers.formatUnits(beforeTreasuryBPNTs, 18), "bPNTs");
  console.log("  Account A ETH:   ", ethers.formatUnits(beforeAccountETH, 18), "ETH");

  // Validation
  if (beforeAccountBPNTs < ethers.parseUnits("10", 18)) {
    console.error("\n❌ Insufficient bPNTs balance! Run scripts/mint-tokens.js first.");
    process.exit(1);
  }

  // ==========================================
  // Construct UserOperation
  // ==========================================
  console.log("\n🔧 Constructing UserOperation:");
  console.log("─────────────────────────────────────────────────────────────────");

  const nonce = await accountContract.getNonce();
  const transferAmount = ethers.parseUnits("0.5", 18); // Transfer 0.5 bPNTs

  console.log("  Transfer Amount: ", ethers.formatUnits(transferAmount, 18), "bPNTs");
  console.log("  Nonce:           ", nonce.toString());

  // Construct calldata for bPNTs transfer
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
  console.log("    callGasLimit:         ", callGasLimit.toString());
  console.log("    verificationGasLimit: ", verificationGasLimit.toString());
  console.log("    preVerificationGas:   ", preVerificationGas.toString());
  console.log("    maxFeePerGas:         ", ethers.formatUnits(maxFeePerGas, "gwei"), "gwei");
  console.log("    maxPriorityFeePerGas: ", ethers.formatUnits(maxPriorityFeePerGas, "gwei"), "gwei");

  // Pack gas limits (EntryPoint v0.7 format)
  const accountGasLimits = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(verificationGasLimit), 16),
    ethers.zeroPadValue(ethers.toBeHex(callGasLimit), 16)
  ]);

  const gasFees = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(maxPriorityFeePerGas), 16),
    ethers.zeroPadValue(ethers.toBeHex(maxFeePerGas), 16)
  ]);

  // PaymasterAndData: paymaster address + gas token address
  const paymasterAndData = ethers.concat([
    paymasterV4,
    ethers.zeroPadValue(GAS_TOKEN_ADDRESS, 32)
  ]);

  console.log("  PaymasterAndData:");
  console.log("    Paymaster:       ", paymasterV4);
  console.log("    Gas Token:       ", GAS_TOKEN_ADDRESS);

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
  console.log("\n  UserOp Hash:     ", userOpHash);

  // Sign the hash
  const signature = await signer.signMessage(ethers.getBytes(userOpHash));
  userOp.signature = signature;

  console.log("  Signature:       ", signature.slice(0, 20) + "...");

  // ==========================================
  // Submit to EntryPoint
  // ==========================================
  console.log("\n📤 Submitting to EntryPoint:");
  console.log("─────────────────────────────────────────────────────────────────");

  try {
    // Estimate gas
    const gasEstimate = await entryPointContract.estimateGas.handleOps(
      [userOp],
      signer.address
    );
    console.log("  Gas Estimate:    ", gasEstimate.toString());

    // Submit transaction
    console.log("  Submitting UserOp...");
    const tx = await entryPointContract.handleOps(
      [userOp],
      signer.address, // Beneficiary receives refunded ETH
      { gasLimit: gasEstimate * 150n / 100n } // Add 50% buffer
    );

    console.log("  TX Hash:         ", tx.hash);
    console.log("  Waiting for confirmation...");

    const receipt = await tx.wait();
    console.log("  ✅ Confirmed in block", receipt.blockNumber);
    console.log("  Gas Used:        ", receipt.gasUsed.toString());

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

  const afterAccountBPNTs = await gasTokenContract.balanceOf(TEST_ACCOUNT_A);
  const afterRecipientBPNTs = await gasTokenContract.balanceOf(TEST_ACCOUNT_B);
  const afterTreasuryBPNTs = await gasTokenContract.balanceOf(treasury);
  const afterAccountETH = await provider.getBalance(TEST_ACCOUNT_A);

  console.log("  Account A bPNTs: ", ethers.formatUnits(afterAccountBPNTs, 18), "bPNTs");
  console.log("  Account B bPNTs: ", ethers.formatUnits(afterRecipientBPNTs, 18), "bPNTs");
  console.log("  Treasury bPNTs:  ", ethers.formatUnits(afterTreasuryBPNTs, 18), "bPNTs");
  console.log("  Account A ETH:   ", ethers.formatUnits(afterAccountETH, 18), "ETH");

  // Calculate changes
  console.log("\n📈 Changes:");
  console.log("─────────────────────────────────────────────────────────────────");

  const accountBPNTsChange = afterAccountBPNTs - beforeAccountBPNTs;
  const recipientBPNTsChange = afterRecipientBPNTs - beforeRecipientBPNTs;
  const treasuryBPNTsChange = afterTreasuryBPNTs - beforeTreasuryBPNTs;
  const accountETHChange = afterAccountETH - beforeAccountETH;

  console.log("  Account A bPNTs: ", ethers.formatUnits(accountBPNTsChange, 18), "bPNTs");
  console.log("  Account B bPNTs: ", ethers.formatUnits(recipientBPNTsChange, 18), "bPNTs");
  console.log("  Treasury bPNTs:  ", ethers.formatUnits(treasuryBPNTsChange, 18), "bPNTs");
  console.log("  Account A ETH:   ", ethers.formatUnits(accountETHChange, 18), "ETH (should be 0)");

  // Verify gasless
  if (accountETHChange === 0n) {
    console.log("\n✅ SUCCESS! Gasless transaction completed using bPNTs!");
  } else {
    console.log("\n⚠️ Warning: Account A ETH balance changed!");
  }

  const gasFeeInBPNTs = -(accountBPNTsChange + recipientBPNTsChange);
  console.log("\n💰 Gas Fee Paid:  ", ethers.formatUnits(gasFeeInBPNTs, 18), "bPNTs");
}

// Run the script
main().catch((error) => {
  console.error("\n❌ Error:", error);
  console.error(error.stack);
  process.exit(1);
});
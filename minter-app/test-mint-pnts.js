#!/usr/bin/env node

/**
 * Test script for minting PNTs tokens
 * Usage: node test-mint-pnts.js <recipient_address> <amount>
 * Example: node test-mint-pnts.js 0xE3D28Aa77c95d5C098170698e5ba68824BFC008d 100
 */

require("dotenv").config({ path: "./contracts/.env" });
const { ethers } = require("ethers");

// Configuration from environment
const config = {
  // Use public Sepolia RPC if Alchemy is not available
  alchemyRpcUrl: process.env.ALCHEMY_RPC_URL || "https://rpc.sepolia.org",
  serverPrivateKey: process.env.SEPOLIA_PRIVATE_KEY,
  pntsContractAddress: process.env.PNTS_CONTRACT_ADDRESS,
};

// PNTs contract ABI
const PNTS_ABI = ["function mint(address to, uint256 amount)"];

async function mintPNTs(recipientAddress, amount) {
  try {
    console.log("🚀 Starting PNTs minting process...\n");

    // Validate inputs
    if (!ethers.isAddress(recipientAddress)) {
      throw new Error(`Invalid recipient address: ${recipientAddress}`);
    }

    if (isNaN(amount) || Number(amount) <= 0) {
      throw new Error(`Invalid amount: ${amount}`);
    }

    // Validate configuration
    if (
      !config.alchemyRpcUrl ||
      !config.serverPrivateKey ||
      !config.pntsContractAddress
    ) {
      throw new Error(
        "Missing required environment variables. Check contracts/.env file.",
      );
    }

    console.log("📋 Configuration:");
    console.log(`   RPC URL: ${config.alchemyRpcUrl.substring(0, 50)}...`);
    console.log(`   PNTS Contract: ${config.pntsContractAddress}`);
    console.log(`   Recipient: ${recipientAddress}`);
    console.log(`   Amount: ${amount} PNTS\n`);

    // Create provider and wallet
    const provider = new ethers.JsonRpcProvider(config.alchemyRpcUrl);
    const wallet = new ethers.Wallet(config.serverPrivateKey, provider);

    console.log(`🔑 Minter wallet: ${wallet.address}`);

    // Check wallet balance
    const balance = await provider.getBalance(wallet.address);
    console.log(`💰 Wallet balance: ${ethers.formatEther(balance)} ETH\n`);

    if (balance === 0n) {
      throw new Error("Wallet has no ETH for gas fees!");
    }

    // Create contract instance
    const pntsContract = new ethers.Contract(
      config.pntsContractAddress,
      PNTS_ABI,
      wallet,
    );

    // Parse amount to Wei (18 decimals)
    const amountWei = ethers.parseUnits(amount.toString(), 18);
    console.log(`📊 Amount in Wei: ${amountWei.toString()}\n`);

    // Send transaction
    console.log("📤 Sending mint transaction...");
    const txResponse = await pntsContract.mint(recipientAddress, amountWei, {
      gasLimit: 300000,
    });

    console.log(`✅ Transaction sent!`);
    console.log(`   Hash: ${txResponse.hash}`);
    console.log(
      `   Explorer: https://sepolia.etherscan.io/tx/${txResponse.hash}\n`,
    );

    // Wait for confirmation
    console.log("⏳ Waiting for confirmation...");
    const receipt = await txResponse.wait();

    console.log(`\n🎉 Mint successful!`);
    console.log(`   Block: ${receipt.blockNumber}`);
    console.log(`   Gas used: ${receipt.gasUsed.toString()}`);
    console.log(
      `   Status: ${receipt.status === 1 ? "✅ Success" : "❌ Failed"}`,
    );

    return {
      success: true,
      txHash: txResponse.hash,
      blockNumber: receipt.blockNumber,
      gasUsed: receipt.gasUsed.toString(),
    };
  } catch (error) {
    console.error("\n❌ Minting failed:");
    console.error(`   Error: ${error.message}`);
    if (error.reason) {
      console.error(`   Reason: ${error.reason}`);
    }
    return {
      success: false,
      error: error.message,
      reason: error.reason,
    };
  }
}

// Main execution
async function main() {
  const args = process.argv.slice(2);

  if (args.length < 2) {
    console.log("Usage: node test-mint-pnts.js <recipient_address> <amount>");
    console.log(
      "Example: node test-mint-pnts.js 0xE3D28Aa77c95d5C098170698e5ba68824BFC008d 100",
    );
    process.exit(1);
  }

  const [recipientAddress, amount] = args;
  const result = await mintPNTs(recipientAddress, amount);

  process.exit(result.success ? 0 : 1);
}

// Run if called directly
if (require.main === module) {
  main();
}

module.exports = { mintPNTs };

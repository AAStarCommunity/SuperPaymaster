#!/usr/bin/env node

/**
 * Deploy GasTokenV2 via GasTokenFactoryV2
 *
 * Features:
 * - Creates new GasTokenV2 with updatable paymaster
 * - Auto-approves paymaster for all token holders
 * - Owner can change paymaster address via setPaymaster()
 *
 * Usage:
 *   node scripts/deploy-gastokenv2.js
 */

const { ethers } = require("ethers");
require("dotenv").config();

// Configuration
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL || "https://rpc.sepolia.org";
const PRIVATE_KEY = (process.env.SEPOLIA_PRIVATE_KEY || "").trim();

// PaymasterV4 address (initial paymaster)
const PAYMASTER_V4 = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";

// Token configuration
const TOKEN_NAME = "Points Token V2";
const TOKEN_SYMBOL = "PNTv2";
const EXCHANGE_RATE = ethers.parseEther("1"); // 1:1 with base PNT

async function main() {
  console.log("🚀 Deploying GasTokenV2 System...\n");

  // Setup provider and wallet
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log("📋 Configuration:");
  console.log("  Deployer:", wallet.address);
  console.log("  Network:", (await provider.getNetwork()).name);
  console.log("  Initial Paymaster:", PAYMASTER_V4);
  console.log("  Token Name:", TOKEN_NAME);
  console.log("  Token Symbol:", TOKEN_SYMBOL);
  console.log("  Exchange Rate:", ethers.formatEther(EXCHANGE_RATE), "PNT");
  console.log();

  // Step 1: Deploy GasTokenFactoryV2
  console.log("📦 Step 1: Deploying GasTokenFactoryV2...");

  const GasTokenFactoryV2 = await ethers.getContractFactory("GasTokenFactoryV2", wallet);
  const factory = await GasTokenFactoryV2.deploy();
  await factory.waitForDeployment();

  const factoryAddress = await factory.getAddress();
  console.log("  ✅ GasTokenFactoryV2:", factoryAddress);
  console.log();

  // Step 2: Create GasTokenV2 via Factory
  console.log("📦 Step 2: Creating GasTokenV2...");

  const createTx = await factory.createToken(
    TOKEN_NAME,
    TOKEN_SYMBOL,
    PAYMASTER_V4,
    EXCHANGE_RATE
  );

  console.log("  Transaction:", createTx.hash);
  const receipt = await createTx.wait();
  console.log("  ✅ Confirmed in block:", receipt.blockNumber);

  // Get deployed token address from event
  const tokenAddress = await factory.tokenBySymbol(TOKEN_SYMBOL);
  console.log("  ✅ GasTokenV2:", tokenAddress);
  console.log();

  // Step 3: Verify deployment
  console.log("📋 Step 3: Verifying Deployment...");

  const GasTokenV2 = await ethers.getContractFactory("GasTokenV2", wallet);
  const token = GasTokenV2.attach(tokenAddress);

  const name = await token.name();
  const symbol = await token.symbol();
  const owner = await token.owner();
  const [paymaster, exchangeRate, totalSupply] = await token.getInfo();

  console.log("  Token Name:", name);
  console.log("  Token Symbol:", symbol);
  console.log("  Owner:", owner);
  console.log("  Paymaster:", paymaster);
  console.log("  Exchange Rate:", ethers.formatEther(exchangeRate), "PNT");
  console.log("  Total Supply:", ethers.formatEther(totalSupply), symbol);
  console.log();

  // Step 4: Mint test tokens
  console.log("📦 Step 4: Minting Test Tokens...");

  const mintAmount = ethers.parseEther("1000"); // 1000 tokens
  const mintTx = await token.mint(wallet.address, mintAmount);

  console.log("  Transaction:", mintTx.hash);
  await mintTx.wait();
  console.log("  ✅ Minted:", ethers.formatEther(mintAmount), symbol);

  // Verify auto-approval
  const balance = await token.balanceOf(wallet.address);
  const allowance = await token.allowance(wallet.address, PAYMASTER_V4);

  console.log("  Balance:", ethers.formatEther(balance), symbol);
  console.log("  Auto-Approval:", allowance === ethers.MaxUint256 ? "✅ MAX" : `❌ ${ethers.formatEther(allowance)}`);
  console.log();

  // Summary
  console.log("✅ Deployment Complete!\n");
  console.log("📋 Summary:");
  console.log("  GasTokenFactoryV2:", factoryAddress);
  console.log("  GasTokenV2:", tokenAddress);
  console.log("  Token Symbol:", symbol);
  console.log("  Initial Paymaster:", paymaster);
  console.log();

  console.log("📝 Next Steps:");
  console.log("  1. Save contract addresses for future use");
  console.log("  2. To change paymaster: token.setPaymaster(newPaymasterAddress)");
  console.log("  3. To mint more: token.mint(recipient, amount)");
  console.log("  4. Auto-approval happens on mint and transfer automatically");
  console.log();

  console.log("🔗 Verify on Sepolia Etherscan:");
  console.log(`  Factory: https://sepolia.etherscan.io/address/${factoryAddress}`);
  console.log(`  Token: https://sepolia.etherscan.io/address/${tokenAddress}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Error:", error);
    process.exit(1);
  });

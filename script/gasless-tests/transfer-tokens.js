#!/usr/bin/env node
/**
 * Transfer xPNTs tokens from deployer to AA accounts for testing
 * Addresses are loaded from deployments/config.sepolia.json
 */
const { ethers } = require('ethers');
const path = require('path');
const { loadConfig } = require('./load-config');
require('dotenv').config({ path: process.env.ENV_FILE || path.join(__dirname, '../../.env.sepolia') });

const ERC20_ABI = [
  "function transfer(address to, uint256 amount) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)"
];

async function main() {
  console.log("╔═══════════════════════════════════════════════════════════╗");
  console.log("║       Transfer xPNTs Tokens to AA Accounts               ║");
  console.log("╚═══════════════════════════════════════════════════════════╝\n");

  const config = loadConfig();
  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  const deployerPrivateKey = process.env.DEPLOYER_PRIVATE_KEY;

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const deployer = new ethers.Wallet(deployerPrivateKey, provider);
  console.log(`Deployer: ${deployer.address}\n`);

  const transfers = [
    {
      tokenName: "aPNTs",
      tokenAddress: config.aPNTs,
      recipient: process.env.TEST_AA_ACCOUNT_ADDRESS_A || "0x0000000000000000000000000000000000000001",
      recipientName: "AA Account A",
      amount: "100"
    },
    {
      tokenName: "aPNTs",
      tokenAddress: config.aPNTs,
      recipient: process.env.TEST_AA_ACCOUNT_ADDRESS_B || "0x0000000000000000000000000000000000000002",
      recipientName: "AA Account B",
      amount: "100"
    },
    {
      tokenName: "aPNTs",
      tokenAddress: config.aPNTs,
      recipient: process.env.TEST_AA_ACCOUNT_ADDRESS_C || "0x0000000000000000000000000000000000000003",
      recipientName: "AA Account C",
      amount: "100"
    }
  ];

  for (const transfer of transfers) {
    console.log(`\n  ${transfer.tokenName} -> ${transfer.recipientName}`);
    console.log(`   Token: ${transfer.tokenAddress}`);
    console.log(`   To: ${transfer.recipient}`);

    try {
      const token = new ethers.Contract(transfer.tokenAddress, ERC20_ABI, deployer);
      const [symbol, decimals, deployerBalance] = await Promise.all([
        token.symbol(), token.decimals(), token.balanceOf(deployer.address)
      ]);

      console.log(`   Deployer Balance: ${ethers.formatUnits(deployerBalance, decimals)} ${symbol}`);

      const transferAmountWei = ethers.parseUnits(transfer.amount, decimals);
      if (deployerBalance < transferAmountWei) {
        console.log(`   Insufficient balance`);
        continue;
      }

      console.log(`   Transferring ${transfer.amount} ${symbol}...`);
      const tx = await token.transfer(transfer.recipient, transferAmountWei);
      console.log(`   TX: ${tx.hash}`);
      const receipt = await tx.wait();

      if (receipt.status === 1) {
        const recipientBalance = await token.balanceOf(transfer.recipient);
        console.log(`   Transfer successful! Recipient: ${ethers.formatUnits(recipientBalance, decimals)} ${symbol}`);
      }
    } catch (err) {
      console.log(`   Error: ${err.message.substring(0, 100)}`);
    }
  }

  console.log("\n  Transfers Complete");
}

main().catch(console.error);

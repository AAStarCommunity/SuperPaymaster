#!/usr/bin/env node
/**
 * Mint xPNTs tokens to AA accounts for testing
 * Addresses are loaded from deployments/config.sepolia.json
 */
const { ethers } = require('ethers');
const path = require('path');
const { loadConfig } = require('./load-config');
require('dotenv').config({ path: process.env.ENV_FILE || path.join(__dirname, '../../.env.sepolia') });

const ERC20_ABI = [
  "function mint(address to, uint256 amount) external",
  "function balanceOf(address) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function owner() view returns (address)"
];

async function main() {
  console.log("╔═══════════════════════════════════════════════════════════╗");
  console.log("║            Mint xPNTs Tokens for Testing                 ║");
  console.log("╚═══════════════════════════════════════════════════════════╝\n");

  const config = loadConfig();
  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  const privateKey = process.env.OWNER_PRIVATE_KEY || process.env.DEPLOYER_PRIVATE_KEY;

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const wallet = new ethers.Wallet(privateKey, provider);

  console.log(`Signer: ${wallet.address}\n`);

  const tokens = [
    { name: "aPNTs (deployer xPNTs)", address: config.aPNTs }
  ];

  const recipients = [
    { name: "AA Account A", address: process.env.TEST_AA_ACCOUNT_ADDRESS_A },
    { name: "AA Account B", address: process.env.TEST_AA_ACCOUNT_ADDRESS_B },
    { name: "AA Account C", address: process.env.TEST_AA_ACCOUNT_ADDRESS_C }
  ].filter(r => r.address);

  for (const token of tokens) {
    for (const recipient of recipients) {
      console.log(`\n  ${token.name} -> ${recipient.name}`);
      console.log(`   Token: ${token.address}`);
      console.log(`   Recipient: ${recipient.address}`);

      try {
        const tokenContract = new ethers.Contract(token.address, ERC20_ABI, wallet);
        const [symbol, decimals, owner] = await Promise.all([
          tokenContract.symbol(), tokenContract.decimals(), tokenContract.owner()
        ]);

        if (owner.toLowerCase() !== wallet.address.toLowerCase()) {
          console.log(`   Skipping: Not token owner`);
          continue;
        }

        const mintAmount = ethers.parseUnits("1000", decimals);
        console.log(`   Minting: 1000 ${symbol}...`);
        const tx = await tokenContract.mint(recipient.address, mintAmount);
        console.log(`   TX: ${tx.hash}`);
        const receipt = await tx.wait();
        if (receipt.status === 1) {
          const balance = await tokenContract.balanceOf(recipient.address);
          console.log(`   Minted! Balance: ${ethers.formatUnits(balance, decimals)} ${symbol}`);
        }
      } catch (err) {
        console.log(`   Error: ${err.message.substring(0, 100)}`);
      }
    }
  }

  console.log("\n  Minting Complete");
}

main().catch(console.error);

#!/usr/bin/env node
const { ethers } = require('ethers');
const path = require('path');
const { loadConfig } = require('./load-config');
require('dotenv').config({ path: process.env.ENV_FILE || path.join(__dirname, '../../.env.sepolia') });

const ERC20_ABI = ["function balanceOf(address) view returns (uint256)", "function symbol() view returns (string)", "function decimals() view returns (uint8)", "function totalSupply() view returns (uint256)"];
const ENTRYPOINT_ABI = ["function balanceOf(address) view returns (uint256)"];

async function main() {
  const config = loadConfig();
  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  const provider = new ethers.JsonRpcProvider(rpcUrl);

  const tokens = [
    { name: "aPNTs (deployer xPNTs)", address: config.aPNTs },
    { name: "PNTs Token", address: config.pnts }
  ];

  const accounts = [
    { name: "Deployer", address: process.env.DEPLOYER_ADDRESS || "0xb5600060e6de5E11D3636731964218E53caadf0E" },
    { name: "AA Account A", address: process.env.TEST_AA_ACCOUNT_ADDRESS_A },
    { name: "AA Account B", address: process.env.TEST_AA_ACCOUNT_ADDRESS_B },
    { name: "AA Account C", address: process.env.TEST_AA_ACCOUNT_ADDRESS_C }
  ].filter(a => a.address);

  console.log("═══════════════════════════════════════════════════════════");
  console.log("Token Balance Check (from config.sepolia.json)");
  console.log("═══════════════════════════════════════════════════════════\n");

  for (const token of tokens) {
    console.log(`\n  ${token.name} (${token.address})`);

    try {
      const tokenContract = new ethers.Contract(token.address, ERC20_ABI, provider);
      const [symbol, decimals, totalSupply] = await Promise.all([
        tokenContract.symbol(),
        tokenContract.decimals(),
        tokenContract.totalSupply()
      ]);

      console.log(`   Symbol: ${symbol}, Total Supply: ${ethers.formatUnits(totalSupply, decimals)}`);

      for (const account of accounts) {
        const balance = await tokenContract.balanceOf(account.address);
        const formatted = ethers.formatUnits(balance, decimals);
        console.log(`     ${account.name}: ${formatted} ${symbol}`);
      }
    } catch (err) {
      console.log(`   ERROR: ${err.message.substring(0, 80)}`);
    }
  }

  // EntryPoint deposit balances
  console.log("\n═══════════════════════════════════════════════════════════");
  console.log("EntryPoint ETH Deposits");
  console.log("═══════════════════════════════════════════════════════════\n");

  const entryPoint = new ethers.Contract(config.entryPoint, ENTRYPOINT_ABI, provider);
  const depositChecks = [
    { name: "SuperPaymaster", address: config.superPaymaster }
  ];

  for (const check of depositChecks) {
    try {
      const deposit = await entryPoint.balanceOf(check.address);
      console.log(`  ${check.name}: ${ethers.formatEther(deposit)} ETH`);
    } catch (err) {
      console.log(`  ${check.name}: ERROR - ${err.message.substring(0, 80)}`);
    }
  }
}

main().catch(console.error);

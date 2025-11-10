#!/usr/bin/env node
const { ethers } = require('ethers');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../../../env/.env') });

const ERC20_ABI = ["function balanceOf(address) view returns (uint256)", "function symbol() view returns (string)", "function decimals() view returns (uint8)", "function totalSupply() view returns (uint256)"];

async function main() {
  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  const provider = new ethers.JsonRpcProvider(rpcUrl);

  const tokens = [
    { name: "xPNTs", address: "0x31a8c3046864F8aa7ADF0B3D3e16934F122Fe215" },
    { name: "xPNTs1", address: "0xfb56CB85C9a214328789D3C92a496d6AA185e3d3" },
    { name: "xPNTs2", address: "0x311580CC1dF2dE49f9FCebB57f97c5182a57964f" }
  ];

  const accounts = [
    { name: "AA Account A", address: "0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584" },
    { name: "AA Account B", address: "0x57b2e6f08399c276b2c1595825219d29990d0921" },
    { name: "AA Account C", address: "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce" },
    { name: "Owner EOA", address: process.env.OWNER_PRIVATE_KEY ? new ethers.Wallet(process.env.OWNER_PRIVATE_KEY).address : null }
  ];

  console.log("═══════════════════════════════════════════════════════════");
  console.log("Token Balance Check");
  console.log("═══════════════════════════════════════════════════════════\n");

  for (const token of tokens) {
    console.log(`\n📊 ${token.name} (${token.address})`);
    
    try {
      const tokenContract = new ethers.Contract(token.address, ERC20_ABI, provider);
      const [symbol, decimals, totalSupply] = await Promise.all([
        tokenContract.symbol(),
        tokenContract.decimals(),
        tokenContract.totalSupply()
      ]);
      
      console.log(`   Symbol: ${symbol}`);
      console.log(`   Total Supply: ${ethers.formatUnits(totalSupply, decimals)}`);
      console.log(`   Balances:`);

      for (const account of accounts) {
        if (!account.address) continue;
        const balance = await tokenContract.balanceOf(account.address);
        const formatted = ethers.formatUnits(balance, decimals);
        console.log(`     ${account.name}: ${formatted} ${symbol}`);
      }
    } catch (err) {
      console.log(`   ❌ Error: ${err.message}`);
    }
  }
}

main().catch(console.error);

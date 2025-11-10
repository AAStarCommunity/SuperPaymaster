#!/usr/bin/env node
const { ethers } = require('ethers');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../../../env/.env') });

async function main() {
  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  const provider = new ethers.JsonRpcProvider(rpcUrl);

  const contracts = [
    { name: "xPNTs", address: "0x31a8c3046864F8aa7ADF0B3D3e16934F122Fe215" },
    { name: "xPNTs1", address: "0xfb56CB85C9a214328789D3C92a496d6AA185e3d3" },
    { name: "xPNTs2", address: "0x311580CC1dF2dE49f9FCebB57f97c5182a57964f" },
    { name: "PaymasterV4", address: "0x0cf072952047bC42F43694631ca60508B3fF7f5e" },
    { name: "SuperPaymasterV2", address: "0xD6aa17587737C59cbb82986Afbac88Db75771857" }
  ];

  console.log("═══════════════════════════════════════════════════════════");
  console.log("Contract Deployment Check");
  console.log("═══════════════════════════════════════════════════════════\n");

  for (const contract of contracts) {
    console.log(`📋 ${contract.name}: ${contract.address}`);
    
    try {
      const code = await provider.getCode(contract.address);
      const codeSize = (code.length - 2) / 2;
      
      if (code === '0x' || codeSize === 0) {
        console.log(`   ❌ NOT DEPLOYED (no code)\n`);
      } else {
        console.log(`   ✅ Deployed (${codeSize} bytes)\n`);
      }
    } catch (err) {
      console.log(`   ❌ Error: ${err.message}\n`);
    }
  }
}

main().catch(console.error);

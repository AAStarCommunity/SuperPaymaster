#!/usr/bin/env node
const { ethers } = require('ethers');
const path = require('path');
const { loadConfig } = require('./load-config');
require('dotenv').config({ path: process.env.ENV_FILE || path.join(__dirname, '../../.env.sepolia') });

async function main() {
  const config = loadConfig();
  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  const provider = new ethers.JsonRpcProvider(rpcUrl);

  const contracts = [
    { name: "Registry (UUPS Proxy)", address: config.registry },
    { name: "SuperPaymaster (UUPS Proxy)", address: config.superPaymaster },
    { name: "GToken", address: config.gToken },
    { name: "GTokenStaking", address: config.staking },
    { name: "MySBT", address: config.sbt },
    { name: "aPNTs (xPNTs)", address: config.aPNTs },
    { name: "xPNTsFactory", address: config.xPNTsFactory },
    { name: "PaymasterFactory", address: config.paymasterFactory },
    { name: "PaymasterV4 Impl", address: config.paymasterV4Impl },
    { name: "BLSAggregator", address: config.blsAggregator },
    { name: "DVTValidator", address: config.dvtValidator },
    { name: "ReputationSystem", address: config.reputationSystem },
    { name: "EntryPoint v0.7", address: config.entryPoint }
  ];

  console.log("═══════════════════════════════════════════════════════════");
  console.log("Contract Deployment Check (from config.sepolia.json)");
  console.log("═══════════════════════════════════════════════════════════\n");

  let allDeployed = true;
  for (const contract of contracts) {
    process.stdout.write(`  ${contract.name}: ${contract.address} ... `);

    try {
      const code = await provider.getCode(contract.address);
      const codeSize = (code.length - 2) / 2;

      if (code === '0x' || codeSize === 0) {
        console.log(`NOT DEPLOYED`);
        allDeployed = false;
      } else {
        console.log(`OK (${codeSize} bytes)`);
      }
    } catch (err) {
      console.log(`ERROR: ${err.message}`);
      allDeployed = false;
    }
  }

  console.log(allDeployed
    ? "\n  All contracts deployed!"
    : "\n  WARNING: Some contracts not deployed!");

  // Check version strings
  console.log("\n═══════════════════════════════════════════════════════════");
  console.log("Version String Verification");
  console.log("═══════════════════════════════════════════════════════════\n");

  const VERSION_ABI = ["function version() view returns (string)"];
  const versionChecks = [
    { name: "Registry", address: config.registry, expected: "Registry-4.1.0" },
    { name: "SuperPaymaster", address: config.superPaymaster, expected: "SuperPaymaster-4.1.0" },
    { name: "GTokenStaking", address: config.staking, expected: "Staking-3.2.0" },
    { name: "MySBT", address: config.sbt, expected: "MySBT-3.1.3" },
    { name: "GToken", address: config.gToken, expected: "GToken-2.1.2" }
  ];

  for (const check of versionChecks) {
    try {
      const contract = new ethers.Contract(check.address, VERSION_ABI, provider);
      const version = await contract.version();
      const match = version === check.expected;
      console.log(`  ${check.name}: ${version} ${match ? '(OK)' : `(MISMATCH, expected ${check.expected})`}`);
    } catch (err) {
      console.log(`  ${check.name}: ERROR - ${err.message.substring(0, 80)}`);
    }
  }
}

main().catch(console.error);

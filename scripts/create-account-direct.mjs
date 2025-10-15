#!/usr/bin/env node
/**
 * Create SimpleAccount directly via contract (no Faucet API)
 *
 * Usage: node scripts/create-account-direct.mjs <salt>
 */

import { ethers } from "ethers";
import { config } from "dotenv";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

config({ path: path.join(__dirname, "../../env/.env") });

const RPC_URL = process.env.SEPOLIA_RPC_URL;
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;
const OWNER_ADDRESS = process.env.TEST_EOA_ADDRESS; // 0xc8d1Ae1063176BEBC750D9aD5D057BA4A65daf3d
const FACTORY_ADDRESS = "0x9bD66892144FCf0BAF5B6946AEAFf38B0d967881";

const provider = new ethers.JsonRpcProvider(RPC_URL);
const deployer = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

const FACTORY_ABI = [
  "function createAccount(address owner, uint256 salt) returns (address)",
  "function getAddress(address owner, uint256 salt) view returns (address)"
];

async function createAccount(salt) {
  console.log(`\n🔄 Creating SimpleAccount V1...`);
  console.log(`   Owner: ${OWNER_ADDRESS}`);
  console.log(`   Salt: ${salt}`);
  console.log(`   Factory: ${FACTORY_ADDRESS}`);
  console.log(`   Deployer: ${deployer.address}\n`);

  const factory = new ethers.Contract(FACTORY_ADDRESS, FACTORY_ABI, deployer);

  // Get predicted address
  const predictedAddress = await factory.getAddress(OWNER_ADDRESS, salt);
  console.log(`   Predicted Address: ${predictedAddress}`);

  // Check if already deployed
  const code = await provider.getCode(predictedAddress);
  if (code !== "0x") {
    console.log(`   ✅ Account already exists at ${predictedAddress}`);
    return predictedAddress;
  }

  // Create account
  console.log(`\n   ⏳ Sending transaction...`);
  try {
    const tx = await factory.createAccount(OWNER_ADDRESS, salt);
    console.log(`   Tx Hash: ${tx.hash}`);

    const receipt = await tx.wait();
    console.log(`   ✅ Account created at block ${receipt.blockNumber}`);
    console.log(`   Account Address: ${predictedAddress}\n`);

    return predictedAddress;
  } catch (error) {
    console.log(`   ❌ Failed: ${error.message}`);
    return null;
  }
}

const salt = process.argv[2] || Math.floor(Math.random() * 1000000);

createAccount(salt).catch(console.error);

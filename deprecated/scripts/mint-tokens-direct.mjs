#!/usr/bin/env node
/**
 * Mint SBT and PNT directly using contract calls
 *
 * Usage: node scripts/mint-tokens-direct.mjs <accountAddress>
 */

import { ethers } from "ethers";
import { config } from "dotenv";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load environment
config({ path: path.join(__dirname, "../.env.v3") });

const RPC_URL = process.env.SEPOLIA_RPC_URL;
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;
const PNT_TOKEN = "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
const SBT_TOKEN = "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f";
const PAYMASTER = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";

const provider = new ethers.JsonRpcProvider(RPC_URL);
const deployer = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

// ABIs
const PNT_ABI = [
  "function mint(address to, uint256 amount) external",
  "function balanceOf(address account) view returns (uint256)"
];

const SBT_ABI = [
  "function safeMint(address to) external",
  "function balanceOf(address account) view returns (uint256)"
];

const SIMPLE_ACCOUNT_ABI = [
  "function execute(address dest, uint256 value, bytes calldata func) external"
];

async function mintTokens(accountAddress) {
  console.log(`\n🔄 Minting tokens for ${accountAddress}...\n`);
  console.log(`   Deployer: ${deployer.address}\n`);

  // Step 1: Mint SBT
  console.log(`⏳ Step 1: Minting SBT...`);
  try {
    const sbtContract = new ethers.Contract(SBT_TOKEN, SBT_ABI, deployer);
    const currentBalance = await sbtContract.balanceOf(accountAddress);
    console.log(`   Current SBT balance: ${currentBalance.toString()}`);

    if (currentBalance > 0) {
      console.log(`✅ Account already has SBT, skipping...`);
    } else {
      const tx = await sbtContract.safeMint(accountAddress);
      console.log(`   Tx sent: ${tx.hash}`);
      await tx.wait();
      console.log(`✅ SBT minted successfully`);
    }
  } catch (error) {
    console.log(`❌ SBT mint error: ${error.message}`);
  }

  // Step 2: Mint PNT
  console.log(`\n⏳ Step 2: Minting PNT (100 tokens)...`);
  try {
    const pntContract = new ethers.Contract(PNT_TOKEN, PNT_ABI, deployer);
    const currentBalance = await pntContract.balanceOf(accountAddress);
    console.log(`   Current PNT balance: ${ethers.formatUnits(currentBalance, 18)}`);

    const mintAmount = ethers.parseUnits("100", 18);
    const tx = await pntContract.mint(accountAddress, mintAmount);
    console.log(`   Tx sent: ${tx.hash}`);
    await tx.wait();
    console.log(`✅ PNT minted successfully`);

    const newBalance = await pntContract.balanceOf(accountAddress);
    console.log(`   New PNT balance: ${ethers.formatUnits(newBalance, 18)}`);
  } catch (error) {
    console.log(`❌ PNT mint error: ${error.message}`);
  }

  // Step 3: Approve Paymaster from SimpleAccount
  console.log(`\n⏳ Step 3: Approving PNT for Paymaster...`);
  console.log(`   Note: This needs to be done via UserOperation, skipping for now`);
  console.log(`   The account will need to approve Paymaster when sending first transaction\n`);

  console.log(`✅ Token minting completed for ${accountAddress}\n`);
}

// Get account address
const accountAddress = process.argv[2];

if (!accountAddress) {
  console.error('Usage: node mint-tokens-direct.mjs <accountAddress>');
  process.exit(1);
}

mintTokens(accountAddress).catch(console.error);

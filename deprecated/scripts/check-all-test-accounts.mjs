#!/usr/bin/env node
/**
 * Check all test accounts (C, D, E, F, G) status
 */

import { ethers } from "ethers";
import { config } from "dotenv";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

config({ path: path.join(__dirname, "../../env/.env") });

const RPC_URL = process.env.SEPOLIA_RPC_URL || "https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N";
const PNT_TOKEN = "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
const SBT_TOKEN = "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f";
const PAYMASTER = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";

const provider = new ethers.JsonRpcProvider(RPC_URL);

const ACCOUNTS = [
  { name: "C", address: process.env.TEST_AA_ACCOUNT_ADDRESS_C, hasKey: "OWNER_PRIVATE_KEY" },
  { name: "D", address: process.env.TEST_AA_ACCOUNT_ADDRESS_D, hasKey: "unknown" },
  { name: "E", address: process.env.TEST_AA_ACCOUNT_ADDRESS_E, hasKey: "unknown" },
  { name: "F", address: process.env.TEST_AA_ACCOUNT_ADDRESS_F, hasKey: "OWNER2_PRIVATE_KEY" },
  { name: "G", address: process.env.TEST_AA_ACCOUNT_ADDRESS_G, hasKey: "OWNER2_PRIVATE_KEY" },
];

const ERC20_ABI = ["function balanceOf(address) view returns (uint256)"];
const ERC721_ABI = ["function balanceOf(address) view returns (uint256)"];

async function checkAccount(account) {
  console.log(`\n🔍 Account ${account.name}: ${account.address}`);
  console.log(`   Private Key: ${account.hasKey}`);

  // Check if it's a contract
  const code = await provider.getCode(account.address);
  const isContract = code !== "0x";
  console.log(`   Is Contract: ${isContract ? "✅" : "❌"}`);

  if (!isContract) {
    return;
  }

  // Check PNT balance
  const pntContract = new ethers.Contract(PNT_TOKEN, ERC20_ABI, provider);
  const pntBalance = await pntContract.balanceOf(account.address);
  console.log(`   PNT Balance: ${ethers.formatUnits(pntBalance, 18)}`);

  // Check SBT balance
  const sbtContract = new ethers.Contract(SBT_TOKEN, ERC721_ABI, provider);
  const sbtBalance = await sbtContract.balanceOf(account.address);
  console.log(`   SBT Balance: ${sbtBalance.toString()}`);

  // Check ETH balance
  const ethBalance = await provider.getBalance(account.address);
  console.log(`   ETH Balance: ${ethers.formatEther(ethBalance)}`);

  // Ready status
  const isReady = isContract && pntBalance > 0 && sbtBalance > 0;
  console.log(`   Status: ${isReady ? "✅ Ready" : "⚠️ Needs tokens"}`);
}

async function main() {
  console.log("=== Checking All Test Accounts ===\n");

  for (const account of ACCOUNTS) {
    if (account.address) {
      await checkAccount(account);
    } else {
      console.log(`\n🔍 Account ${account.name}: Not configured`);
    }
  }

  console.log("\n\n📊 Summary:");
  console.log("================================================================================");
  console.log("\nPrivate Keys Available:");
  console.log("  - OWNER_PRIVATE_KEY → Account C");
  console.log("  - OWNER2_PRIVATE_KEY → Accounts F, G");
  console.log("\nNext Steps:");
  console.log("  1. Account C already has tokens - can send transactions immediately");
  console.log("  2. Accounts F, G need tokens minted (but deployer lacks permission)");
  console.log("  3. Consider using only Account C for testing, or get admin access to mint tokens");
}

main().catch(console.error);

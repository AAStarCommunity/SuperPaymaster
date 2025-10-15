#!/usr/bin/env node
/**
 * Check the three new test accounts
 */

import { ethers } from "ethers";
import { config } from "dotenv";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

config({ path: path.join(__dirname, "../../env/.env") });

const RPC_URL = process.env.SEPOLIA_RPC_URL;
const PNT_TOKEN = "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
const SBT_TOKEN = "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f";

const provider = new ethers.JsonRpcProvider(RPC_URL);

const ACCOUNTS = [
  { name: "1", address: process.env.TEST_AA_ACCOUNT_ADDRESS_1 },
  { name: "2", address: process.env.TEST_AA_ACCOUNT_ADDRESS_2 },
  { name: "3", address: process.env.TEST_AA_ACCOUNT_ADDRESS_3 },
];

const ERC20_ABI = ["function balanceOf(address) view returns (uint256)"];
const ERC721_ABI = ["function balanceOf(address) view returns (uint256)"];

async function checkAccount(account) {
  console.log(`\n🔍 Account ${account.name}: ${account.address}`);

  const code = await provider.getCode(account.address);
  const isContract = code !== "0x";
  console.log(`   Is Contract: ${isContract ? "✅" : "❌"}`);

  if (!isContract) {
    return false;
  }

  const pntContract = new ethers.Contract(PNT_TOKEN, ERC20_ABI, provider);
  const pntBalance = await pntContract.balanceOf(account.address);
  console.log(`   PNT Balance: ${ethers.formatUnits(pntBalance, 18)}`);

  const sbtContract = new ethers.Contract(SBT_TOKEN, ERC721_ABI, provider);
  const sbtBalance = await sbtContract.balanceOf(account.address);
  console.log(`   SBT Balance: ${sbtBalance.toString()}`);

  const isReady = pntBalance > 0 && sbtBalance > 0;
  console.log(`   Status: ${isReady ? "✅ Ready" : "⚠️ Needs tokens"}`);

  return isReady;
}

async function main() {
  console.log("=== Checking Three Test Accounts ===\n");

  const results = [];
  for (const account of ACCOUNTS) {
    const ready = await checkAccount(account);
    results.push({ name: account.name, address: account.address, ready });
  }

  console.log("\n\n📊 Summary:");
  console.log("================================================================================");
  const readyAccounts = results.filter(r => r.ready);
  console.log(`\n✅ Ready: ${readyAccounts.length}/3`);

  if (readyAccounts.length > 0) {
    console.log("\nReady to send transactions:");
    readyAccounts.forEach(r => console.log(`  - Account ${r.name}: ${r.address}`));
  }
}

main().catch(console.error);

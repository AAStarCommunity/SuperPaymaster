#!/usr/bin/env node
/**
 * Mint SBT and PNT tokens for test accounts using Faucet API
 *
 * Usage: node scripts/mint-tokens-for-accounts.mjs
 */

import { config } from "dotenv";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load environment variables
config({ path: path.join(__dirname, "../../env/.env") });

const FAUCET_API = "https://faucet.aastar.io/api";

// Test accounts from env
const TEST_ACCOUNTS = [
  { name: "Account A", address: process.env.TEST_AA_ACCOUNT_ADDRESS_A },
  { name: "Account B", address: process.env.TEST_AA_ACCOUNT_ADDRESS_B },
  { name: "Account C", address: process.env.TEST_AA_ACCOUNT_ADDRESS_C },
  { name: "Account D", address: process.env.TEST_AA_ACCOUNT_ADDRESS_D },
  { name: "Account E", address: process.env.TEST_AA_ACCOUNT_ADDRESS_E },
  { name: "Account F", address: process.env.TEST_AA_ACCOUNT_ADDRESS_F },
  { name: "Account G", address: process.env.TEST_AA_ACCOUNT_ADDRESS_G },
].filter((acc) => acc.address && acc.address.length > 0);

/**
 * Mint SBT token for an account
 */
async function mintSBT(accountAddress) {
  try {
    const response = await fetch(`${FAUCET_API}/mint-sbt`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ accountAddress }),
    });

    if (!response.ok) {
      const error = await response.text();
      throw new Error(`HTTP ${response.status}: ${error}`);
    }

    const result = await response.json();
    return result;
  } catch (error) {
    console.error(`  ❌ Failed to mint SBT: ${error.message}`);
    return null;
  }
}

/**
 * Mint PNT tokens for an account
 */
async function mintPNT(accountAddress, amount = "100000000000000000000") {
  try {
    const response = await fetch(`${FAUCET_API}/mint-pnt`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        accountAddress,
        amount, // 100 PNT in wei (18 decimals)
      }),
    });

    if (!response.ok) {
      const error = await response.text();
      throw new Error(`HTTP ${response.status}: ${error}`);
    }

    const result = await response.json();
    return result;
  } catch (error) {
    console.error(`  ❌ Failed to mint PNT: ${error.message}`);
    return null;
  }
}

/**
 * Approve Paymaster to spend PNT
 */
async function approvePNT(accountAddress) {
  try {
    const response = await fetch(`${FAUCET_API}/approve-pnt`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ accountAddress }),
    });

    if (!response.ok) {
      const error = await response.text();
      throw new Error(`HTTP ${response.status}: ${error}`);
    }

    const result = await response.json();
    return result;
  } catch (error) {
    console.error(`  ❌ Failed to approve PNT: ${error.message}`);
    return null;
  }
}

/**
 * Process single account
 */
async function processAccount(account) {
  console.log(`\n🔄 Processing ${account.name}: ${account.address}`);

  // Mint SBT
  console.log(`  ⏳ Minting SBT...`);
  const sbtResult = await mintSBT(account.address);
  if (sbtResult) {
    console.log(`  ✅ SBT minted successfully`);
    if (sbtResult.transactionHash) {
      console.log(`     Tx: ${sbtResult.transactionHash}`);
    }
  }

  // Wait 2 seconds between calls
  await new Promise((resolve) => setTimeout(resolve, 2000));

  // Mint PNT
  console.log(`  ⏳ Minting PNT (100 tokens)...`);
  const pntResult = await mintPNT(account.address);
  if (pntResult) {
    console.log(`  ✅ PNT minted successfully`);
    if (pntResult.transactionHash) {
      console.log(`     Tx: ${pntResult.transactionHash}`);
    }
  }

  // Wait 2 seconds between calls
  await new Promise((resolve) => setTimeout(resolve, 2000));

  // Approve PNT
  console.log(`  ⏳ Approving PNT for Paymaster...`);
  const approveResult = await approvePNT(account.address);
  if (approveResult) {
    console.log(`  ✅ PNT approved successfully`);
    if (approveResult.transactionHash) {
      console.log(`     Tx: ${approveResult.transactionHash}`);
    }
  }

  // Wait 3 seconds before next account
  await new Promise((resolve) => setTimeout(resolve, 3000));
}

/**
 * Main function
 */
async function main() {
  console.log("🚀 Starting token minting for test accounts...\n");
  console.log(`📋 Found ${TEST_ACCOUNTS.length} accounts to process\n`);

  for (const account of TEST_ACCOUNTS) {
    await processAccount(account);
  }

  console.log("\n✅ All accounts processed!");
  console.log("\n💡 Next step: Use send-test-tx.mjs to send test transactions");
}

main().catch(console.error);

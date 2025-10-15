#!/usr/bin/env node

/**
 * Create multiple SimpleAccount V1 addresses using Faucet API
 */

import dotenv from 'dotenv';
import { ethers } from 'ethers';

dotenv.config({ path: '.env.v3' });

const FAUCET_API = "https://faucet.aastar.io/api";
const FACTORY_ADDRESS = "0x9bD66892144FCf0BAF5B6946AEAFf38B0d967881"; // SimpleAccount V1 Factory
const OWNER_ADDRESS = "0xc8d1Ae1063176BEBC750D9aD5D057BA4A65daf3d"; // From OWNER_PRIVATE_KEY
const PAYMASTER_V4 = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
const PNT_TOKEN = "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";

const COUNT = parseInt(process.argv[2] || "6");

async function createAccount() {
  const response = await fetch(`${FAUCET_API}/create-account`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      factoryAddress: FACTORY_ADDRESS,
      ownerAddress: OWNER_ADDRESS,
      salt: Math.floor(Math.random() * 1000000).toString()
    })
  });

  if (!response.ok) {
    throw new Error(`Failed to create account: ${response.statusText}`);
  }

  const data = await response.json();
  return data.accountAddress;
}

async function mintTokens(accountAddress) {
  // Mint PNT
  const pntResponse = await fetch(`${FAUCET_API}/mint`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      accountAddress,
      tokenAddress: PNT_TOKEN,
      amount: "100" // 100 PNT
    })
  });

  if (!pntResponse.ok) {
    console.error(`  ❌ Failed to mint PNT: ${pntResponse.statusText}`);
    return false;
  }

  // Mint SBT
  const sbtResponse = await fetch(`${FAUCET_API}/mint-sbt`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      accountAddress
    })
  });

  if (!sbtResponse.ok) {
    console.error(`  ❌ Failed to mint SBT: ${sbtResponse.statusText}`);
    return false;
  }

  return true;
}

async function approvePaymaster(accountAddress) {
  const response = await fetch(`${FAUCET_API}/approve`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      accountAddress,
      tokenAddress: PNT_TOKEN,
      spenderAddress: PAYMASTER_V4
    })
  });

  if (!response.ok) {
    console.error(`  ❌ Failed to approve Paymaster: ${response.statusText}`);
    return false;
  }

  return true;
}

async function main() {
  console.log("🏭 Creating SimpleAccount V1 Accounts\n");
  console.log(`Factory: ${FACTORY_ADDRESS}`);
  console.log(`Owner: ${OWNER_ADDRESS}`);
  console.log(`Count: ${COUNT}\n`);

  const accounts = [];

  for (let i = 1; i <= COUNT; i++) {
    console.log(`\n[${i}/${COUNT}] Creating account...`);

    try {
      // Step 1: Create account
      const accountAddress = await createAccount();
      console.log(`  ✅ Account created: ${accountAddress}`);

      // Wait a bit for the transaction to be mined
      await new Promise(resolve => setTimeout(resolve, 2000));

      // Step 2: Mint tokens
      console.log(`  🪙 Minting PNT and SBT...`);
      const mintSuccess = await mintTokens(accountAddress);
      if (!mintSuccess) {
        console.log(`  ⚠️  Token minting may have failed, continuing...`);
      } else {
        console.log(`  ✅ Tokens minted`);
      }

      await new Promise(resolve => setTimeout(resolve, 2000));

      // Step 3: Approve Paymaster
      console.log(`  🔓 Approving Paymaster...`);
      const approveSuccess = await approvePaymaster(accountAddress);
      if (!approveSuccess) {
        console.log(`  ⚠️  Approval may have failed, continuing...`);
      } else {
        console.log(`  ✅ Paymaster approved`);
      }

      accounts.push({
        index: i,
        address: accountAddress,
        ready: mintSuccess && approveSuccess
      });

      // Wait between accounts
      if (i < COUNT) {
        console.log(`  ⏳ Waiting 3 seconds...`);
        await new Promise(resolve => setTimeout(resolve, 3000));
      }

    } catch (error) {
      console.error(`  ❌ Error creating account ${i}:`, error.message);
      accounts.push({
        index: i,
        address: null,
        ready: false,
        error: error.message
      });
    }
  }

  // Summary
  console.log("\n\n" + "=".repeat(70));
  console.log("📊 SUMMARY");
  console.log("=".repeat(70));

  const successful = accounts.filter(a => a.ready);
  console.log(`\n✅ Successfully Created: ${successful.length}/${COUNT}`);

  if (successful.length > 0) {
    console.log("\nReady Accounts:");
    successful.forEach(acc => {
      console.log(`  ${acc.index}. ${acc.address}`);
    });

    console.log("\n\n📝 Add to .env.v3:");
    successful.forEach((acc, idx) => {
      console.log(`TEST_ACCOUNT_${idx + 1}="${acc.address}"`);
    });

    console.log("\n\n📝 JavaScript Array:");
    console.log("const NEW_ACCOUNTS = [");
    successful.forEach(acc => {
      console.log(`  "${acc.address}",`);
    });
    console.log("];");
  }

  const failed = accounts.filter(a => !a.ready);
  if (failed.length > 0) {
    console.log(`\n❌ Failed: ${failed.length}`);
    failed.forEach(acc => {
      console.log(`  ${acc.index}. ${acc.error || 'Unknown error'}`);
    });
  }
}

main().catch(console.error);

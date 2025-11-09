#!/usr/bin/env ts-node
/**
 * Deactivate Inactive Paymasters Script
 *
 * Purpose: Deactivate Paymasters with 0 transactions from Registry v1.2
 *
 * Target Paymasters (0 transactions):
 * - #2: 0x9091a9...deff4c
 * - #3: 0x19afE5...1aB648
 * - #4: 0x798Dfe...35f88F
 * - #5: 0xC0C85a...B27F02
 * - #6: 0x11bfab...9dC875
 * - #7: 0x17fe4D...94ed97
 */

import { ethers } from "ethers";
import * as dotenv from "dotenv";
import * as path from "path";
import * as fs from "fs";

// Load environment variables from env/.env
const envPath = path.join(__dirname, "../env/.env");
if (!fs.existsSync(envPath)) {
  console.error(`❌ Environment file not found: ${envPath}`);
  process.exit(1);
}

dotenv.config({ path: envPath });

// Configuration
const RPC_URL = process.env.SEPOLIA_RPC_URL;
const REGISTRY_ADDRESS = process.env.SuperPaymasterRegistryV1_2;

// Paymasters to deactivate (0 transactions, from Registry query)
const INACTIVE_PAYMASTERS = [
  "0x9091a98e43966cDa2677350CCc41efF9cedeff4c", // #0
  "0x19afE5Ad8E5C6A1b16e3aCb545193041f61aB648", // #1
  "0x798Dfe9E38a75D3c5fdE53FFf29f966C7635f88F", // #2
  "0xC0C85a8B3703ad24DeD8207dcBca0104B9B27F02", // #3
  "0x11bfab68f8eAB4Cd3dAa598955782b01cf9dC875", // #4
  "0x17fe4D317D780b0d257a1a62E848Badea094ed97", // #5
  // #6 (0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445) has transactions, skip
];

// Private keys to try (will test which one is the deployer)
const PRIVATE_KEYS = [
  process.env.OWNER_PRIVATE_KEY,
  process.env.DEPLOYER_PRIVATE_KEY,
  process.env.OWNER2_PRIVATE_KEY,
];

// Registry ABI (only deactivate function)
const REGISTRY_ABI = [
  "function deactivate() external",
  "function paymasters(address) external view returns (address paymasterAddress, uint256 stakedAmount, bool isActive, uint256 registeredAt, uint256 lastActiveAt)",
];

async function main() {
  console.log("🔧 Deactivate Inactive Paymasters");
  console.log("=".repeat(70));
  console.log(`📍 Registry: ${REGISTRY_ADDRESS}`);
  console.log(`🌐 RPC: ${RPC_URL}\n`);

  if (!RPC_URL || !REGISTRY_ADDRESS) {
    console.error("❌ Missing required environment variables");
    console.error("Required: SEPOLIA_RPC_URL, SuperPaymasterRegistryV1_2");
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(RPC_URL);

  // Get current block number
  const currentBlock = await provider.getBlockNumber();
  console.log(`📊 Current block: ${currentBlock}\n`);

  // Filter out invalid private keys
  const validPrivateKeys = PRIVATE_KEYS.filter(
    (key) => key && key !== "undefined",
  );

  if (validPrivateKeys.length === 0) {
    console.error("❌ No valid private keys found in env/.env");
    process.exit(1);
  }

  console.log(`🔑 Found ${validPrivateKeys.length} private keys to try\n`);

  // Process each Paymaster
  let successCount = 0;
  let failCount = 0;
  const results: Array<{
    paymaster: string;
    status: string;
    tx?: string;
    error?: string;
  }> = [];

  for (const paymaster of INACTIVE_PAYMASTERS) {
    console.log(`\n${"=".repeat(70)}`);
    console.log(`📍 Processing Paymaster: ${paymaster}`);
    console.log(`${"=".repeat(70)}`);

    // Check if paymaster exists and is active
    try {
      const registry = new ethers.Contract(
        REGISTRY_ADDRESS!,
        REGISTRY_ABI,
        provider,
      );
      const info = await registry.paymasters(paymaster);

      console.log(`\n📋 Paymaster Info:`);
      console.log(`   Address: ${info.paymasterAddress}`);
      console.log(`   Staked: ${ethers.formatEther(info.stakedAmount)} ETH`);
      console.log(`   Active: ${info.isActive}`);
      console.log(`   Registered: Block ${info.registeredAt}`);
      console.log(`   Last Active: Block ${info.lastActiveAt}`);

      if (info.paymasterAddress === ethers.ZeroAddress) {
        console.log(`\n⚠️  Paymaster not registered, skipping`);
        results.push({ paymaster, status: "NOT_REGISTERED" });
        failCount++;
        continue;
      }

      if (!info.isActive) {
        console.log(`\n✅ Already inactive, skipping`);
        results.push({ paymaster, status: "ALREADY_INACTIVE" });
        successCount++;
        continue;
      }

      // Try each private key to find the deployer
      let deactivated = false;

      for (let i = 0; i < validPrivateKeys.length; i++) {
        const privateKey = validPrivateKeys[i]!;
        const wallet = new ethers.Wallet(privateKey, provider);
        const walletAddress = await wallet.getAddress();

        console.log(`\n🔑 Trying private key #${i + 1}: ${walletAddress}`);

        // Check if this wallet is the paymaster deployer
        if (walletAddress.toLowerCase() !== paymaster.toLowerCase()) {
          console.log(`   ⚠️  Not the paymaster address, skipping`);
          continue;
        }

        // Execute deactivate transaction
        try {
          const registryWithSigner = new ethers.Contract(
            REGISTRY_ADDRESS!,
            REGISTRY_ABI,
            wallet,
          );

          console.log(`\n📤 Sending deactivate() transaction...`);
          const tx = await registryWithSigner.deactivate();

          console.log(`   📝 Transaction hash: ${tx.hash}`);
          console.log(`   ⏳ Waiting for confirmation...`);

          const receipt = await tx.wait();

          console.log(`   ✅ Transaction confirmed!`);
          console.log(`   📊 Block: ${receipt!.blockNumber}`);
          console.log(`   ⛽ Gas used: ${receipt!.gasUsed.toString()}`);
          console.log(
            `   🔗 Etherscan: https://sepolia.etherscan.io/tx/${tx.hash}`,
          );

          results.push({
            paymaster,
            status: "DEACTIVATED",
            tx: tx.hash,
          });
          successCount++;
          deactivated = true;
          break;
        } catch (error: any) {
          console.error(`   ❌ Transaction failed: ${error.message}`);

          if (error.message.includes("insufficient funds")) {
            console.error(`   💰 Wallet has insufficient ETH for gas`);
          } else if (error.message.includes("not registered")) {
            console.error(`   ⚠️  Paymaster not registered`);
          } else {
            console.error(
              `   ⚠️  Error: ${error.shortMessage || error.message}`,
            );
          }
          continue;
        }
      }

      if (!deactivated) {
        console.log(`\n❌ Failed to deactivate with any private key`);
        results.push({
          paymaster,
          status: "FAILED",
          error: "No matching private key or insufficient permissions",
        });
        failCount++;
      }
    } catch (error: any) {
      console.error(`\n❌ Error processing paymaster: ${error.message}`);
      results.push({
        paymaster,
        status: "ERROR",
        error: error.message,
      });
      failCount++;
    }
  }

  // Summary
  console.log(`\n\n${"=".repeat(70)}`);
  console.log(`📊 SUMMARY`);
  console.log(`${"=".repeat(70)}`);
  console.log(`Total Paymasters: ${INACTIVE_PAYMASTERS.length}`);
  console.log(`✅ Success: ${successCount}`);
  console.log(`❌ Failed: ${failCount}\n`);

  console.log(`📋 Detailed Results:\n`);
  results.forEach((result, index) => {
    console.log(`${index + 1}. ${result.paymaster}`);
    console.log(`   Status: ${result.status}`);
    if (result.tx) {
      console.log(`   TX: https://sepolia.etherscan.io/tx/${result.tx}`);
    }
    if (result.error) {
      console.log(`   Error: ${result.error}`);
    }
    console.log();
  });

  console.log(`${"=".repeat(70)}`);
  console.log(`✅ Script completed`);
  console.log(`${"=".repeat(70)}\n`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Fatal error:", error);
    process.exit(1);
  });

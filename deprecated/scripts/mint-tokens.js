#!/usr/bin/env node
/**
 * Mint Tokens Script
 *
 * Mints GToken, aPNTs, and bPNTs for test accounts
 * Uses @aastar/shared-config for addresses
 */

require("dotenv").config();
const { ethers } = require("ethers");
const {
  getCoreContracts,
  getTestTokenContracts
} = require("@aastar/shared-config");

// Network configuration
const NETWORK = "sepolia";
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

// Private keys from env/.env
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;

if (!DEPLOYER_PRIVATE_KEY) {
  console.error("❌ Missing DEPLOYER_PRIVATE_KEY! Please check env/.env file");
  process.exit(1);
}

// Get addresses from shared-config
const core = getCoreContracts(NETWORK);
const testTokens = getTestTokenContracts(NETWORK);

// Test accounts (from env/.env)
const TEST_ACCOUNTS = [
  { name: "Account A", address: "0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584" },
  { name: "Account B", address: "0x57b2e6f08399c276b2c1595825219d29990d0921" },
  { name: "Account C", address: "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce" },
];

// Mint amounts
const GTOKEN_AMOUNT = ethers.parseUnits("1000", 18); // 1000 GToken
const APNTS_AMOUNT = ethers.parseUnits("2000", 18);  // 2000 aPNTs
const BPNTS_AMOUNT = ethers.parseUnits("2000", 18);  // 2000 bPNTs

// Contract ABIs
const GTokenABI = [
  "function mint(address to, uint256 amount) external",
  "function balanceOf(address account) external view returns (uint256)",
  "function owner() external view returns (address)",
  "function transfer(address to, uint256 amount) external returns (bool)"
];

const xPNTsABI = [
  "function mint(address to, uint256 amount) external",
  "function balanceOf(address account) external view returns (uint256)",
  "function owner() external view returns (address)"
];

async function mintTokens(signer, tokenContract, tokenName, amount, recipient) {
  console.log(`\n  Minting ${ethers.formatUnits(amount, 18)} ${tokenName} to ${recipient.name}...`);

  try {
    // Check current balance
    const balanceBefore = await tokenContract.balanceOf(recipient.address);
    console.log(`    Current balance: ${ethers.formatUnits(balanceBefore, 18)} ${tokenName}`);

    // Check if we are the owner
    const owner = await tokenContract.owner();
    if (owner.toLowerCase() !== signer.address.toLowerCase()) {
      console.log(`    ⚠️ Warning: Not owner! Owner is ${owner}`);
      console.log(`       Our address: ${signer.address}`);

      // Try to transfer instead if we have balance
      const signerBalance = await tokenContract.balanceOf(signer.address);
      if (signerBalance >= amount) {
        console.log(`    💱 Transferring from our balance instead...`);
        const tx = await tokenContract.connect(signer).transfer(recipient.address, amount);
        await tx.wait();
        console.log(`    ✅ Transferred! TX: ${tx.hash}`);
        return;
      } else {
        console.log(`    ❌ Cannot mint (not owner) or transfer (insufficient balance)`);
        return;
      }
    }

    // Mint tokens
    const tx = await tokenContract.connect(signer).mint(recipient.address, amount);
    console.log(`    📤 TX sent: ${tx.hash}`);

    const receipt = await tx.wait();
    console.log(`    ✅ Confirmed in block ${receipt.blockNumber}`);

    // Check new balance
    const balanceAfter = await tokenContract.balanceOf(recipient.address);
    console.log(`    New balance: ${ethers.formatUnits(balanceAfter, 18)} ${tokenName}`);

  } catch (error) {
    console.log(`    ❌ Error: ${error.message}`);
  }
}

async function main() {
  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║                 Mint Tokens for Test Accounts                   ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const deployerSigner = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

  console.log("📋 Configuration:");
  console.log("─────────────────────────────────────────────────────────────────");
  console.log("  Deployer:     ", deployerSigner.address);
  console.log("  Network:      ", NETWORK);
  console.log("\nContracts (from @aastar/shared-config):");
  console.log("  GToken:       ", core.gToken);
  console.log("  aPNTs:        ", testTokens.aPNTs);
  console.log("  bPNTs:        ", testTokens.bPNTs);

  // Initialize contracts
  const gTokenContract = new ethers.Contract(core.gToken, GTokenABI, provider);
  const apntsContract = new ethers.Contract(testTokens.aPNTs, xPNTsABI, provider);
  const bpntsContract = new ethers.Contract(testTokens.bPNTs, xPNTsABI, provider);

  // Check ownership
  console.log("\n🔑 Checking Ownership:");
  console.log("─────────────────────────────────────────────────────────────────");

  const gTokenOwner = await gTokenContract.owner();
  const apntsOwner = await apntsContract.owner();
  const bpntsOwner = await bpntsContract.owner();

  console.log("  GToken owner: ", gTokenOwner);
  console.log("    We control: ", gTokenOwner.toLowerCase() === deployerSigner.address.toLowerCase() ? "✅" : "❌");

  console.log("  aPNTs owner:  ", apntsOwner);
  console.log("    We control: ", apntsOwner.toLowerCase() === deployerSigner.address.toLowerCase() ? "✅" : "❌");

  console.log("  bPNTs owner:  ", bpntsOwner);
  console.log("    We control: ", bpntsOwner.toLowerCase() === deployerSigner.address.toLowerCase() ? "✅" : "❌");

  // Mint tokens for each test account
  for (const account of TEST_ACCOUNTS) {
    console.log("\n═══════════════════════════════════════════════════════════════════");
    console.log(`💰 Minting for ${account.name}: ${account.address}`);

    // Mint GToken
    await mintTokens(deployerSigner, gTokenContract, "GToken", GTOKEN_AMOUNT, account);

    // Mint aPNTs
    await mintTokens(deployerSigner, apntsContract, "aPNTs", APNTS_AMOUNT, account);

    // Mint bPNTs
    await mintTokens(deployerSigner, bpntsContract, "bPNTs", BPNTS_AMOUNT, account);
  }

  console.log("\n✅ Minting completed!");
  console.log("\n📝 Next steps:");
  console.log("  1. Run scripts/stake-gtoken.js to stake GToken");
  console.log("  2. Run scripts/mint-sbt.js to mint SBT for accounts");
  console.log("  3. Run scripts/test-aoa-transaction.js for AOA mode test");
  console.log("  4. Run scripts/test-aoa-plus-transaction.js for AOA+ mode test");
}

// Run the script
main().catch((error) => {
  console.error("\n❌ Error:", error);
  process.exit(1);
});
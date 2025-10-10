require("dotenv").config({ path: "./contracts/.env" });
const { ethers } = require("ethers");

// Upgrade an existing SimpleAccount to SimpleAccountV2
// This uses the UUPS upgradeTo() function

const SIMPLE_ACCOUNT_V2_IMPL = process.env.SIMPLE_ACCOUNT_V2_IMPL;
const AA_ACCOUNT_TO_UPGRADE = process.env.AA_ACCOUNT_TO_UPGRADE;
const OWNER_PRIVATE_KEY = process.env.PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

const SimpleAccountABI = [
  "function upgradeTo(address newImplementation) external",
  "function version() public view returns (string)",
  "function owner() public view returns (address)",
];

async function main() {
  if (!SIMPLE_ACCOUNT_V2_IMPL) {
    console.error("❌ SIMPLE_ACCOUNT_V2_IMPL not set in .env");
    console.error("   Please deploy SimpleAccountV2 first");
    process.exit(1);
  }

  if (!AA_ACCOUNT_TO_UPGRADE) {
    console.error("❌ AA_ACCOUNT_TO_UPGRADE not set in .env");
    console.error("   Set the AA account address you want to upgrade");
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const owner = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

  console.log("=== Upgrade SimpleAccount to V2 ===\n");
  console.log("Owner:", owner.address);
  console.log("AA Account:", AA_ACCOUNT_TO_UPGRADE);
  console.log("New Implementation:", SIMPLE_ACCOUNT_V2_IMPL);

  const simpleAccount = new ethers.Contract(
    AA_ACCOUNT_TO_UPGRADE,
    SimpleAccountABI,
    owner,
  );

  // Verify owner
  const accountOwner = await simpleAccount.owner();
  console.log("\nAA Account Owner:", accountOwner);

  if (accountOwner.toLowerCase() !== owner.address.toLowerCase()) {
    console.error("❌ You are not the owner of this AA account!");
    console.error(`   Account owner: ${accountOwner}`);
    console.error(`   Your address: ${owner.address}`);
    process.exit(1);
  }

  // Check current version (if available)
  try {
    const currentVersion = await simpleAccount.version();
    console.log("Current Version:", currentVersion);
  } catch (e) {
    console.log("Current Version: 1.0.0 (V1 doesn't have version() function)");
  }

  console.log("\n🔄 Upgrading to SimpleAccountV2...");

  const tx = await simpleAccount.upgradeTo(SIMPLE_ACCOUNT_V2_IMPL, {
    gasLimit: 200000,
  });

  console.log("Transaction hash:", tx.hash);
  console.log("Waiting for confirmation...");

  const receipt = await tx.wait();
  console.log("✅ Upgrade successful! Block:", receipt.blockNumber);

  // Verify new version
  const newVersion = await simpleAccount.version();
  console.log("New Version:", newVersion);

  console.log("\n✅ Done!");
  console.log("\nYour AA account now supports personal_sign!");
  console.log("You can now use MetaMask's signMessage for UserOperations.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

require("dotenv").config();
const { ethers } = require("ethers");

/**
 * Mint SBT for test account
 * Strategy: Register deployer as community, then mint SBT
 */

const SBT_ADDRESS = "0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8";
const REGISTRY_ADDRESS = "0x3F7E822C7FD54dBF8df29C6EC48E08Ce8AcEBeb3"; // From MySBT
const TEST_ACCOUNT = process.env.SIMPLE_ACCOUNT_B || "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

const MySBT_ABI = [
  "function daoMultisig() view returns (address)",
  "function REGISTRY() view returns (address)",
  "function userToSBT(address) view returns (uint256)",
  "function mintOrAddMembership(address user, string metadata) external returns (uint256 tokenId, bool isNewMint)",
];

const Registry_ABI = [
  "function register(address paymaster, string memory name) external returns (bool)",
  "function isPaymasterActive(address) view returns (bool)",
  "function paymasters(address) view returns (uint256 feeRate, bool isActive, uint256 successCount, uint256 totalAttempts, string name)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const deployer = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║              Mint SBT for Test Account                        ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  console.log("📋 Configuration:");
  console.log("   Deployer:", deployer.address);
  console.log("   Test Account:", TEST_ACCOUNT);
  console.log("   SBT Contract:", SBT_ADDRESS);
  console.log("   Registry:", REGISTRY_ADDRESS);
  console.log("");

  const sbt = new ethers.Contract(SBT_ADDRESS, MySBT_ABI, deployer);
  const registry = new ethers.Contract(REGISTRY_ADDRESS, Registry_ABI, deployer);

  // Check if test account already has SBT
  const existingTokenId = await sbt.userToSBT(TEST_ACCOUNT);
  if (existingTokenId > 0n) {
    console.log("✅ Test account already has SBT (Token ID:", existingTokenId.toString() + ")");
    return;
  }

  console.log("⚠️  Test account does not have SBT yet\n");

  // Check if deployer is registered as community (paymaster)
  console.log("🔍 Checking if deployer is registered in Registry...");
  const paymasterInfo = await registry.paymasters(deployer.address);
  const isActive = paymasterInfo.isActive;

  console.log("   Deployer registered:", isActive);

  if (!isActive) {
    console.log("\n💳 Registering deployer as paymaster in Registry...");
    try {
      const tx = await registry.register(deployer.address, "Test Community", {
        gasLimit: 300000n,
      });

      console.log("   Transaction hash:", tx.hash);
      await tx.wait();
      console.log("   ✅ Deployer registered\n");
    } catch (error) {
      console.error("   ❌ Failed to register:", error.message);
      console.log("\n   💡 Alternative: Use DAO multisig or existing community account");
      return;
    }
  } else {
    console.log("   ✅ Deployer is already registered\n");
  }

  // Now mint SBT
  console.log("💳 Minting SBT for test account...");
  const metadata = "Test SBT for PaymasterV4 Testing";

  try {
    const tx = await sbt.mintOrAddMembership(TEST_ACCOUNT, metadata, {
      gasLimit: 500000n,
    });

    console.log("   Transaction hash:", tx.hash);
    console.log("   Sepolia Etherscan:", `https://sepolia.etherscan.io/tx/${tx.hash}`);

    console.log("\n   ⏳ Waiting for confirmation...");
    const receipt = await tx.wait();

    console.log("   ✅ SBT minted!");
    console.log("   Block:", receipt.blockNumber);

    const newTokenId = await sbt.userToSBT(TEST_ACCOUNT);
    console.log("   Token ID:", newTokenId.toString());

    console.log("\n╔════════════════════════════════════════════════════════════════╗");
    console.log("║           ✅ SBT MINTED - READY FOR TESTING                   ║");
    console.log("║                                                                ║");
    console.log("║  Now run: node scripts/test-paymaster-v4-bread.js             ║");
    console.log("╚════════════════════════════════════════════════════════════════╝");

  } catch (error) {
    console.error("\n❌ Failed to mint SBT:");
    console.error("   Error:", error.message);
    if (error.data) {
      console.error("   Data:", error.data);
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

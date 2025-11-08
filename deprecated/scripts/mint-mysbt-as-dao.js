require("dotenv").config();
const { ethers } = require("ethers");

/**
 * Mint MySBT by temporarily disabling Registry check
 * deployer is DAO, so can call setRegistry
 */

const SBT_ADDRESS = "0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8";
const TEST_ACCOUNT = "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

const MySBT_ABI = [
  "function daoMultisig() view returns (address)",
  "function REGISTRY() view returns (address)",
  "function userToSBT(address) view returns (uint256)",
  "function setRegistry(address registry) external",  // onlyDAO
  "function mintOrAddMembership(address user, string metadata) external returns (uint256 tokenId, bool isNewMint)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const deployer = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║          Mint MySBT as DAO (Temporarily Disable Registry)     ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  console.log("Deployer:", deployer.address);
  console.log("Test Account:", TEST_ACCOUNT);
  console.log("MySBT:", SBT_ADDRESS);
  console.log("");

  const sbt = new ethers.Contract(SBT_ADDRESS, MySBT_ABI, deployer);

  // Check if already has SBT
  const existingTokenId = await sbt.userToSBT(TEST_ACCOUNT);
  if (existingTokenId > 0n) {
    console.log("✅ Test account already has SBT (Token ID:", existingTokenId.toString() + ")");
    return;
  }

  // Get current state
  const dao = await sbt.daoMultisig();
  const oldRegistry = await sbt.REGISTRY();

  console.log("DAO Multisig:", dao);
  console.log("Current Registry:", oldRegistry);
  console.log("Deployer:", deployer.address);

  if (dao.toLowerCase() !== deployer.address.toLowerCase()) {
    console.error("\n❌ Deployer is not DAO!");
    return;
  }

  console.log("\n✅ Deployer is DAO\n");

  // Step 1: Disable Registry temporarily
  console.log("💳 Step 1: Disable Registry (set to 0x0)");
  const setRegistryTx = await sbt.setRegistry(ethers.ZeroAddress, {
    gasLimit: 200000n,
  });
  console.log("   Transaction hash:", setRegistryTx.hash);
  await setRegistryTx.wait();
  console.log("   ✅ Registry disabled\n");

  // Step 2: Mint SBT
  console.log("💳 Step 2: Mint SBT");
  const metadata = "Test SBT for PaymasterV4 Testing";

  try {
    const mintTx = await sbt.mintOrAddMembership(TEST_ACCOUNT, metadata, {
      gasLimit: 500000n,
    });

    console.log("   Transaction hash:", mintTx.hash);
    await mintTx.wait();
    console.log("   ✅ SBT minted!");

    const newTokenId = await sbt.userToSBT(TEST_ACCOUNT);
    console.log("   Token ID:", newTokenId.toString());
  } catch (error) {
    console.error("   ❌ Mint failed:", error.message);
  }

  // Step 3: Restore Registry
  console.log("\n💳 Step 3: Restore Registry");
  const restoreRegistryTx = await sbt.setRegistry(oldRegistry, {
    gasLimit: 200000n,
  });
  console.log("   Transaction hash:", restoreRegistryTx.hash);
  await restoreRegistryTx.wait();
  console.log("   ✅ Registry restored\n");

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║                 ✅ READY FOR TESTING                           ║");
  console.log("║                                                                ║");
  console.log("║  Now run: node scripts/test-paymaster-v4-bread.js             ║");
  console.log("╚════════════════════════════════════════════════════════════════╝");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

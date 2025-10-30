require("dotenv").config();
const { ethers } = require("ethers");

/**
 * Temporarily remove SBT from PaymasterV4 to test with only GasToken
 */

const PAYMASTER_V4 = "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38";
const MYSBT_ADDRESS = "0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8";
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

const PaymasterV4_ABI = [
  "function owner() view returns (address)",
  "function removeSBT(address sbtToken) external",
  "function getSupportedSBTs() view returns (address[])",
  "function isSBTSupported(address) view returns (bool)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const deployer = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║      Temporarily Remove SBT Requirement from PaymasterV4      ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  console.log("Deployer:", deployer.address);
  console.log("PaymasterV4:", PAYMASTER_V4);
  console.log("MySBT:", MYSBT_ADDRESS);
  console.log("");

  const paymaster = new ethers.Contract(PAYMASTER_V4, PaymasterV4_ABI, deployer);

  // Check owner
  const owner = await paymaster.owner();
  console.log("PaymasterV4 owner:", owner);

  if (owner.toLowerCase() !== deployer.address.toLowerCase()) {
    console.error("❌ Deployer is not owner!");
    return;
  }

  console.log("✅ Deployer is owner\n");

  // Check current SBTs
  const supportedSBTs = await paymaster.getSupportedSBTs();
  console.log("Current supported SBTs:", supportedSBTs.length);
  supportedSBTs.forEach((sbt, i) => {
    console.log(`  [${i}] ${sbt}`);
  });

  if (supportedSBTs.length === 0) {
    console.log("\n✅ No SBTs configured - can test with only GasToken!");
    return;
  }

  // Remove MySBT
  console.log("\n💳 Removing MySBT from PaymasterV4...");
  const removeTx = await paymaster.removeSBT(MYSBT_ADDRESS, {
    gasLimit: 200000n,
  });

  console.log("   Transaction hash:", removeTx.hash);
  console.log("   Etherscan:", `https://sepolia.etherscan.io/tx/${removeTx.hash}`);

  await removeTx.wait();
  console.log("   ✅ MySBT removed!");

  // Verify
  const newSupportedSBTs = await paymaster.getSupportedSBTs();
  const isStillSupported = await paymaster.isSBTSupported(MYSBT_ADDRESS);

  console.log("\n📊 After removal:");
  console.log("   Total supported SBTs:", newSupportedSBTs.length);
  console.log("   MySBT still supported:", isStillSupported);

  console.log("\n╔════════════════════════════════════════════════════════════════╗");
  console.log("║            ✅ SBT REQUIREMENT REMOVED                          ║");
  console.log("║                                                                ║");
  console.log("║  PaymasterV4 will now work with only GasToken (BREAD)         ║");
  console.log("║  No SBT required for testing                                   ║");
  console.log("║                                                                ║");
  console.log("║  Now run: node scripts/test-paymaster-v4-bread.js             ║");
  console.log("║                                                                ║");
  console.log("║  ⚠️  Remember to add MySBT back after testing                  ║");
  console.log("╚════════════════════════════════════════════════════════════════╝");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

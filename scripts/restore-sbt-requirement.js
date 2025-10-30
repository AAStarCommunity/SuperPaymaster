require("dotenv").config();
const { ethers } = require("ethers");

/**
 * Restore MySBT to PaymasterV4
 */

const PAYMASTER_V4 = "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38";
const MYSBT_ADDRESS = "0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8";
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

const PaymasterV4_ABI = [
  "function owner() view returns (address)",
  "function addSBT(address sbtToken) external",
  "function getSupportedSBTs() view returns (address[])",
  "function isSBTSupported(address) view returns (bool)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const deployer = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║           RESTORE MySBT to PaymasterV4                        ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  console.log("Deployer:", deployer.address);
  console.log("PaymasterV4:", PAYMASTER_V4);
  console.log("MySBT:", MYSBT_ADDRESS);
  console.log("");

  const paymaster = new ethers.Contract(PAYMASTER_V4, PaymasterV4_ABI, deployer);

  // Check current status
  const isSupported = await paymaster.isSBTSupported(MYSBT_ADDRESS);
  console.log("Current status:");
  console.log("   MySBT supported:", isSupported);

  if (isSupported) {
    console.log("\n✅ MySBT is already configured!");
    return;
  }

  // Add MySBT back
  console.log("\n💳 Adding MySBT back to PaymasterV4...");
  const addTx = await paymaster.addSBT(MYSBT_ADDRESS, {
    gasLimit: 200000n,
  });

  console.log("   Transaction hash:", addTx.hash);
  console.log("   Etherscan:", `https://sepolia.etherscan.io/tx/${addTx.hash}`);

  await addTx.wait();
  console.log("   ✅ MySBT restored!");

  // Verify
  const newSupportedSBTs = await paymaster.getSupportedSBTs();
  const nowSupported = await paymaster.isSBTSupported(MYSBT_ADDRESS);

  console.log("\n📊 After restoration:");
  console.log("   Total supported SBTs:", newSupportedSBTs.length);
  console.log("   MySBT supported:", nowSupported);
  newSupportedSBTs.forEach((sbt, i) => {
    console.log(`      [${i}] ${sbt}`);
  });

  console.log("\n╔════════════════════════════════════════════════════════════════╗");
  console.log("║              ✅ MySBT RESTORED                                 ║");
  console.log("╚════════════════════════════════════════════════════════════════╝");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

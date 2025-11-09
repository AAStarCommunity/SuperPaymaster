require("dotenv").config({ path: "env/.env" });
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

/**
 * Deploy TestSBT, mint to test account, and add to PaymasterV4
 */

const PAYMASTER_V4 = "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38";
const TEST_ACCOUNT = "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";
const DEPLOYER_PRIVATE_KEY = process.env.PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

const PaymasterV4_ABI = [
  "function addSBT(address sbtToken) external",
  "function getSupportedSBTs() view returns (address[])",
  "function isSBTSupported(address) view returns (bool)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const deployer = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║        Deploy TestSBT and Configure PaymasterV4              ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  console.log("Deployer:", deployer.address);
  console.log("Test Account:", TEST_ACCOUNT);
  console.log("");

  // Read TestSBT contract
  const artifactPath = path.join(__dirname, "../out/TestSBT.sol/TestSBT.json");
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));

  // Step 1: Deploy TestSBT
  console.log("💳 Step 1: Deploy TestSBT");
  const TestSBTFactory = new ethers.ContractFactory(
    artifact.abi,
    artifact.bytecode.object,
    deployer
  );

  const testSBT = await TestSBTFactory.deploy({
    gasLimit: 2000000n,
  });
  await testSBT.waitForDeployment();
  const testSBTAddress = await testSBT.getAddress();

  console.log("   TestSBT deployed:", testSBTAddress);
  console.log("   Etherscan:", `https://sepolia.etherscan.io/address/${testSBTAddress}`);
  console.log("");

  // Step 2: Mint to test account
  console.log("💳 Step 2: Mint TestSBT to test account");
  const mintTx = await testSBT.mint(TEST_ACCOUNT, {
    gasLimit: 200000n,
  });
  console.log("   Transaction:", mintTx.hash);
  await mintTx.wait();
  console.log("   ✅ TestSBT minted\n");

  const balance = await testSBT.balanceOf(TEST_ACCOUNT);
  console.log("   Test account balance:", balance.toString(), "SBT\n");

  // Step 3: Add TestSBT to PaymasterV4
  console.log("💳 Step 3: Add TestSBT to PaymasterV4");
  const paymaster = new ethers.Contract(PAYMASTER_V4, PaymasterV4_ABI, deployer);

  const isSupported = await paymaster.isSBTSupported(testSBTAddress);
  if (isSupported) {
    console.log("   ✅ TestSBT already added to PaymasterV4\n");
  } else {
    const addTx = await paymaster.addSBT(testSBTAddress, {
      gasLimit: 200000n,
    });
    console.log("   Transaction:", addTx.hash);
    await addTx.wait();
    console.log("   ✅ TestSBT added to PaymasterV4\n");
  }

  // Verify
  const supportedSBTs = await paymaster.getSupportedSBTs();
  console.log("📊 PaymasterV4 Supported SBTs:", supportedSBTs.length);
  supportedSBTs.forEach((sbt, i) => {
    console.log(`   [${i}] ${sbt}${sbt === testSBTAddress ? " (TestSBT - NEW)" : ""}`);
  });

  console.log("\n╔════════════════════════════════════════════════════════════════╗");
  console.log("║                 ✅ READY FOR TESTING                           ║");
  console.log("║                                                                ║");
  console.log("║  TestSBT:", testSBTAddress.padEnd(42), "║");
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

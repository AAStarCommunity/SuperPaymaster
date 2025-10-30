require("dotenv").config();
const { ethers } = require("ethers");

/**
 * Deploy TestSBT, mint to test account, and add to PaymasterV4
 */

const PAYMASTER_V4 = "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38";
const TEST_ACCOUNT = "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

// TestSBT bytecode (compiled from TestSBT.sol)
const TEST_SBT_BYTECODE = "0x608060405234801561000f575f80fd5b506040518060400160405280600881526020017f5465737420534254000000000000000000000000000000000000000000000000815250604051806040016040528060048152602001635453425460e01b81525081600090816100709190610123565b50600161007d8282610123565b5050505f600155506101de565b634e487b7160e01b5f52604160045260245ffd5b600181811c908216806100b257607f821691505b6020821081036100d057634e487b7160e01b5f52602260045260245ffd5b50919050565b601f82111561011e57805f5260205f20601f840160051c810160208510156100fb5750805b601f840160051c820191505b8181101561011a575f8155600101610107565b5050505b505050565b81516001600160401b0381111561013c5761013c61008a565b6101508161014a845461009e565b846100d6565b6020601f821160018114610182575f83156101" +
  "6b5750848201515b5f19600385901b1c1916600184901b17845561011a565b5f84815260208120601f198516915b828110156101b15787850151825560209485019460019092019101610191565b50848210156101ce57868401515f19600387901b60f8161c191681555b50505050600190811b01905550565b61086c806101eb5f395ff3fe608060405234801561000f575f80fd5b5060043610610091575f3560e01c80636a627842116100645780636a627842146101255780636352211e1461013857806370a082311461014b578063";

const TEST_SBT_ABI = [
  "constructor()",
  "function mint(address to) external returns (uint256)",
  "function hasToken(address user) external view returns (bool)",
  "function balanceOf(address) external view returns (uint256)",
  "function ownerOf(uint256) external view returns (address)",
];

const PaymasterV4_ABI = [
  "function addSBT(address sbtToken) external",
  "function owner() view returns (address)",
  "function getSupportedSBTs() view returns (address[])",
  "function isSBTSupported(address) view returns (bool)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const deployer = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║         Deploy TestSBT and Add to PaymasterV4                 ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  console.log("📋 Configuration:");
  console.log("   Deployer:", deployer.address);
  console.log("   Test Account:", TEST_ACCOUNT);
  console.log("   PaymasterV4:", PAYMASTER_V4);
  console.log("");

  // === Step 1: Deploy TestSBT ===
  console.log("🚀 Step 1: Deploy TestSBT");

  const TestSBT = new ethers.ContractFactory(
    TEST_SBT_ABI,
    TEST_SBT_BYTECODE,
    deployer
  );

  const testSBT = await TestSBT.deploy({
    gasLimit: 1000000n,
  });

  await testSBT.waitForDeployment();
  const testSBTAddress = await testSBT.getAddress();

  console.log("   ✅ TestSBT deployed at:", testSBTAddress);
  console.log("   Etherscan:", `https://sepolia.etherscan.io/address/${testSBTAddress}`);
  console.log("");

  // === Step 2: Mint SBT to test account ===
  console.log("💳 Step 2: Mint SBT to test account");

  const mintTx = await testSBT.mint(TEST_ACCOUNT, {
    gasLimit: 200000n,
  });

  console.log("   Transaction hash:", mintTx.hash);
  await mintTx.wait();

  const hasToken = await testSBT.hasToken(TEST_ACCOUNT);
  const balance = await testSBT.balanceOf(TEST_ACCOUNT);

  console.log("   ✅ SBT minted!");
  console.log("   Test account has SBT:", hasToken);
  console.log("   Test account balance:", balance.toString());
  console.log("");

  // === Step 3: Add TestSBT to PaymasterV4 ===
  console.log("⚙️  Step 3: Add TestSBT to PaymasterV4");

  const paymaster = new ethers.Contract(PAYMASTER_V4, PaymasterV4_ABI, deployer);

  const owner = await paymaster.owner();
  console.log("   PaymasterV4 owner:", owner);
  console.log("   Deployer:", deployer.address);

  if (owner.toLowerCase() !== deployer.address.toLowerCase()) {
    console.error("   ❌ Deployer is not PaymasterV4 owner!");
    return;
  }

  const addSBTTx = await paymaster.addSBT(testSBTAddress, {
    gasLimit: 200000n,
  });

  console.log("   Transaction hash:", addSBTTx.hash);
  await addSBTTx.wait();

  const isSuppor ted = await paymaster.isSBTSupported(testSBTAddress);
  const supportedSBTs = await paymaster.getSupportedSBTs();

  console.log("   ✅ TestSBT added to PaymasterV4!");
  console.log("   Is supported:", isSupported);
  console.log("   Total supported SBTs:", supportedSBTs.length);
  supportedSBTs.forEach((sbt, i) => {
    console.log(`      [${i}] ${sbt}`);
  });
  console.log("");

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║              ✅ TEST SBT READY                                 ║");
  console.log("║                                                                ║");
  console.log("║  TestSBT:", testSBTAddress.padEnd(42, ' '), "║");
  console.log("║  Test account has SBT:", hasToken ? "Yes" : "No", "                              ║");
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

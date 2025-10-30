require("dotenv").config({ path: "env/.env" });
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

/**
 * Deploy GasTokenV2 as BREAD replacement
 */

const PAYMASTER_V4 = "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38";
const TEST_ACCOUNT = "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";

const PRIVATE_KEY = process.env.PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

const PaymasterV4_ABI = [
  "function addGasToken(address gasToken) external",
  "function removeGasToken(address gasToken) external",
  "function getSupportedGasTokens() view returns (address[])",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const deployer = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║        Deploy GasTokenV2 as BREAD Replacement                 ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  console.log("Deployer:", deployer.address);
  console.log("");

  // Read GasTokenV2 contract
  const artifactPath = path.join(__dirname, "../out/GasTokenV2.sol/GasTokenV2.json");
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));

  // Step 1: Deploy GasTokenV2
  console.log("💳 Step 1: Deploy GasTokenV2 (BREAD v2)");

  const GasTokenFactory = new ethers.ContractFactory(
    artifact.abi,
    artifact.bytecode.object,
    deployer
  );

  // Constructor parameters for GasTokenV2
  // constructor(name, symbol, paymaster, basePriceToken, exchangeRate, priceUSD)
  const name = "Bread Token v2";
  const symbol = "BREADv2";
  const _paymaster = PAYMASTER_V4; // Auto-approve this paymaster
  const _basePriceToken = ethers.ZeroAddress; // Base token (not derived)
  const _exchangeRate = ethers.parseUnits("1", 18); // 1e18 for base token
  const _priceUSD = ethers.parseUnits("0.02", 18); // $0.02 per BREAD

  const gasToken = await GasTokenFactory.deploy(
    name,
    symbol,
    _paymaster,
    _basePriceToken,
    _exchangeRate,
    _priceUSD,
    {
      gasLimit: 3000000n,
    }
  );

  await gasToken.waitForDeployment();
  const gasTokenAddress = await gasToken.getAddress();

  console.log("   GasTokenV2 deployed:", gasTokenAddress);
  console.log("   Etherscan:", `https://sepolia.etherscan.io/address/${gasTokenAddress}`);
  console.log("");

  // Step 2: Mint to test account
  console.log("💳 Step 2: Mint 1000 BREAD to test account");
  const mintTx = await gasToken.mint(TEST_ACCOUNT, ethers.parseUnits("1000", 18), {
    gasLimit: 200000n,
  });
  console.log("   Transaction:", mintTx.hash);
  await mintTx.wait();
  console.log("   ✅ BREAD minted\n");

  // Step 3: Remove old BREAD from PaymasterV4
  console.log("💳 Step 3: Replace Gas Token in PaymasterV4");
  const paymaster = new ethers.Contract(PAYMASTER_V4, PaymasterV4_ABI, deployer);

  const oldBREAD = "0x13da8229f5ca3e1Ab2be3c010BBBb5dbAed85621";

  try {
    const removeTx = await paymaster.removeGasToken(oldBREAD, {
      gasLimit: 200000n,
    });
    console.log("   Remove old BREAD tx:", removeTx.hash);
    await removeTx.wait();
    console.log("   ✅ Old BREAD removed");
  } catch (e) {
    console.log("   ⚠️  Could not remove old BREAD:", e.message.split('\\n')[0]);
  }

  // Step 4: Add new GasTokenV2
  const addTx = await paymaster.addGasToken(gasTokenAddress, {
    gasLimit: 200000n,
  });
  console.log("   Add new BREAD tx:", addTx.hash);
  await addTx.wait();
  console.log("   ✅ New GasTokenV2 added\n");

  // Verify
  const supportedTokens = await paymaster.getSupportedGasTokens();
  console.log("📊 PaymasterV4 Supported Gas Tokens:", supportedTokens.length);
  supportedTokens.forEach((token, i) => {
    console.log(`   [${i}] ${token}${token === gasTokenAddress ? " (BREADv2 - NEW)" : ""}`);
  });

  console.log("\n╔════════════════════════════════════════════════════════════════╗");
  console.log("║                 ✅ READY FOR TESTING                           ║");
  console.log("║                                                                ║");
  console.log("║  GasTokenV2 (BREAD v2):", gasTokenAddress.padEnd(42), "║");
  console.log("║                                                                ║");
  console.log("║  Next steps:                                                   ║");
  console.log("║  1. Approve BREAD to PaymasterV4                               ║");
  console.log("║  2. Update test script with new BREAD address                  ║");
  console.log("║  3. Run: node scripts/test-paymaster-v4-simple.js              ║");
  console.log("╚════════════════════════════════════════════════════════════════╝");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

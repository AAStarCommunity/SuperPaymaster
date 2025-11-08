require("dotenv").config();
const { ethers } = require("ethers");

/**
 * Verify contracts and mint tokens
 */

const PAYMASTER_V4 = "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38";
const TEST_ACCOUNT = process.env.SIMPLE_ACCOUNT_B || "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

const PaymasterV4_ABI = [
  "function getSupportedSBTs() view returns (address[])",
  "function getSupportedGasTokens() view returns (address[])",
  "function owner() view returns (address)",
];

const ERC20_ABI = [
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function balanceOf(address) view returns (uint256)",
  "function owner() view returns (address)",
  "function mint(address to, uint256 amount) external",
  "function totalSupply() view returns (uint256)",
];

const ERC721_ABI = [
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function balanceOf(address) view returns (uint256)",
  "function ownerOf(uint256) view returns (address)",
  "function totalSupply() view returns (uint256)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const deployer = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║             Verify & Mint Tokens for Testing                  ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  console.log("📋 Configuration:");
  console.log("   Deployer:", deployer.address);
  console.log("   Test Account:", TEST_ACCOUNT);
  console.log("   PaymasterV4:", PAYMASTER_V4);
  console.log("");

  // === Step 1: Get supported tokens from PaymasterV4 ===
  console.log("🔍 Step 1: Query PaymasterV4 for supported tokens\n");

  const paymaster = new ethers.Contract(PAYMASTER_V4, PaymasterV4_ABI, provider);

  let sbtAddress, gasTokenAddress;
  try {
    const supportedSBTs = await paymaster.getSupportedSBTs();
    const supportedGasTokens = await paymaster.getSupportedGasTokens();

    console.log("   Supported SBTs:", supportedSBTs);
    console.log("   Supported Gas Tokens:", supportedGasTokens);

    if (supportedSBTs.length === 0) {
      console.log("\n   ❌ No SBTs configured in PaymasterV4");
      return;
    }

    if (supportedGasTokens.length === 0) {
      console.log("\n   ❌ No Gas Tokens configured in PaymasterV4");
      return;
    }

    sbtAddress = supportedSBTs[0];
    gasTokenAddress = supportedGasTokens[0];

    console.log("\n   ✅ Will use:");
    console.log("      SBT:", sbtAddress);
    console.log("      GasToken:", gasTokenAddress);
    console.log("");

  } catch (error) {
    console.error("   ❌ Failed to query PaymasterV4:", error.message);
    return;
  }

  // === Step 2: Verify contract existence ===
  console.log("🔍 Step 2: Verify contract existence\n");

  try {
    const sbtCode = await provider.getCode(sbtAddress);
    const gasTokenCode = await provider.getCode(gasTokenAddress);

    console.log("   SBT code length:", sbtCode.length, "bytes");
    console.log("   GasToken code length:", gasTokenCode.length, "bytes");

    if (sbtCode === "0x") {
      console.log("   ❌ SBT contract not deployed at", sbtAddress);
      return;
    }

    if (gasTokenCode === "0x") {
      console.log("   ❌ GasToken contract not deployed at", gasTokenAddress);
      return;
    }

    console.log("   ✅ Both contracts exist\n");

  } catch (error) {
    console.error("   ❌ Failed to verify contracts:", error.message);
    return;
  }

  // === Step 3: Check SBT status ===
  console.log("🔍 Step 3: Check SBT status\n");

  try {
    const sbt = new ethers.Contract(sbtAddress, ERC721_ABI, provider);

    const sbtName = await sbt.name();
    const sbtSymbol = await sbt.symbol();
    const sbtBalance = await sbt.balanceOf(TEST_ACCOUNT);

    console.log("   SBT Info:");
    console.log("      Name:", sbtName);
    console.log("      Symbol:", sbtSymbol);
    console.log("      Test Account Balance:", sbtBalance.toString());

    if (sbtBalance > 0n) {
      console.log("      ✅ Test account already has SBT\n");
    } else {
      console.log("      ⚠️  Test account doesn't have SBT");
      console.log("      💡 SBT needs to be minted by authorized community\n");
    }

  } catch (error) {
    console.error("   ⚠️  Could not query SBT:", error.message);
    console.log("   💡 This might be a non-standard ERC721 or requires different ABI\n");
  }

  // === Step 4: Check GasToken and mint if needed ===
  console.log("🔍 Step 4: Check GasToken and mint if needed\n");

  try {
    const gasToken = new ethers.Contract(gasTokenAddress, ERC20_ABI, deployer);

    const tokenName = await gasToken.name();
    const tokenSymbol = await gasToken.symbol();
    const tokenDecimals = await gasToken.decimals();
    const currentBalance = await gasToken.balanceOf(TEST_ACCOUNT);

    console.log("   GasToken Info:");
    console.log("      Name:", tokenName);
    console.log("      Symbol:", tokenSymbol);
    console.log("      Decimals:", tokenDecimals);
    console.log("      Test Account Balance:", ethers.formatUnits(currentBalance, tokenDecimals), tokenSymbol);

    // Check if deployer is owner
    let tokenOwner;
    try {
      tokenOwner = await gasToken.owner();
      console.log("      Owner:", tokenOwner);
    } catch (error) {
      console.log("      ⚠️  Could not determine owner (might not have owner() function)");
    }

    if (currentBalance >= ethers.parseUnits("100", tokenDecimals)) {
      console.log("      ✅ Balance sufficient (>= 100)\n");
      console.log("✅ Test account is ready for testing!");
      return;
    }

    // Try to mint
    console.log("\n💳 Attempting to mint 1000", tokenSymbol, "...");

    if (tokenOwner && tokenOwner.toLowerCase() !== deployer.address.toLowerCase()) {
      console.log("   ❌ Deployer is not the owner");
      console.log("      Owner:", tokenOwner);
      console.log("      Deployer:", deployer.address);
      console.log("\n   💡 You need to use the owner account to mint");
      return;
    }

    const mintAmount = ethers.parseUnits("1000", tokenDecimals);
    console.log("   Minting:", ethers.formatUnits(mintAmount, tokenDecimals), tokenSymbol);
    console.log("   To:", TEST_ACCOUNT);

    const tx = await gasToken.mint(TEST_ACCOUNT, mintAmount, {
      gasLimit: 200000n,
    });

    console.log("\n   ✅ Transaction submitted!");
    console.log("   Transaction hash:", tx.hash);
    console.log("   Sepolia Etherscan:", `https://sepolia.etherscan.io/tx/${tx.hash}`);

    console.log("\n   ⏳ Waiting for confirmation...");
    const receipt = await tx.wait();

    console.log("   ✅ Minted successfully!");
    console.log("   Block:", receipt.blockNumber);
    console.log("   Gas Used:", receipt.gasUsed.toString());

    // Check new balance
    const newBalance = await gasToken.balanceOf(TEST_ACCOUNT);
    console.log("\n   New Balance:", ethers.formatUnits(newBalance, tokenDecimals), tokenSymbol);

    console.log("\n╔════════════════════════════════════════════════════════════════╗");
    console.log("║                ✅ TOKENS READY FOR TESTING                     ║");
    console.log("╚════════════════════════════════════════════════════════════════╝");

  } catch (error) {
    console.error("\n❌ GasToken operation failed:");
    console.error("   Error:", error.message);
    if (error.data) {
      console.error("   Error Data:", error.data);
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

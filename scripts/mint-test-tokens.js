require("dotenv").config();
const { ethers } = require("ethers");

/**
 * Mint test tokens for PaymasterV4.1 testing
 * 1. Mint SBT (MySBT v2.3) to test account
 * 2. Mint GasToken (1000 tokens) to test account
 */

// Contract Addresses
const SBT_ADDRESS = "0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8"; // MySBT v2.3
const GAS_TOKEN_ADDRESS = "0x13da8229f5ca3e1Ab2be3c010BBBb5dbAed85621"; // GasToken
const TEST_ACCOUNT = process.env.SIMPLE_ACCOUNT_B || "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";

// Environment
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

if (!DEPLOYER_PRIVATE_KEY || !SEPOLIA_RPC_URL) {
  console.error("❌ Missing required environment variables:");
  console.error("   DEPLOYER_PRIVATE_KEY:", DEPLOYER_PRIVATE_KEY ? "✓" : "✗");
  console.error("   SEPOLIA_RPC_URL:", SEPOLIA_RPC_URL ? "✓" : "✗");
  process.exit(1);
}

// ABIs
const MySBT_ABI = [
  "function daoMultisig() view returns (address)",
  "function REGISTRY() view returns (address)",
  "function userToSBT(address) view returns (uint256)",
  "function mintOrAddMembership(address user, string metadata) external returns (uint256 tokenId, bool isNewMint)",
  "function sbtData(uint256) view returns (address holder, address firstCommunity, uint256 mintTime, uint256 totalCommunities)",
];

const GasToken_ABI = [
  "function owner() view returns (address)",
  "function mint(address to, uint256 amount) external",
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function name() view returns (string)",
  "function symbol() view returns (string)",
];

const Registry_ABI = [
  "function paymasters(address) view returns (uint256 feeRate, bool isActive, uint256 successCount, uint256 totalAttempts, string name)",
  "function isCommunityRegistered(address) view returns (bool)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const deployer = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║          Mint Test Tokens for PaymasterV4.1 Testing           ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  console.log("📋 Configuration:");
  console.log("   Deployer:", deployer.address);
  console.log("   Test Account:", TEST_ACCOUNT);
  console.log("   SBT Contract:", SBT_ADDRESS);
  console.log("   GasToken Contract:", GAS_TOKEN_ADDRESS);
  console.log("");

  const sbtContract = new ethers.Contract(SBT_ADDRESS, MySBT_ABI, deployer);
  const gasTokenContract = new ethers.Contract(GAS_TOKEN_ADDRESS, GasToken_ABI, deployer);

  // ========================================
  // Part 1: Mint SBT
  // ========================================
  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║                    Part 1: Mint SBT                            ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  try {
    // Check if user already has SBT
    const existingTokenId = await sbtContract.userToSBT(TEST_ACCOUNT);
    console.log("📊 Checking existing SBT...");
    console.log("   Existing Token ID:", existingTokenId.toString());

    if (existingTokenId > 0n) {
      console.log("   ✅ User already has SBT (Token ID:", existingTokenId.toString() + ")");

      // Get SBT data
      const sbtData = await sbtContract.sbtData(existingTokenId);
      console.log("   Holder:", sbtData.holder);
      console.log("   First Community:", sbtData.firstCommunity);
      console.log("   Total Communities:", sbtData.totalCommunities.toString());
      console.log("\n   ℹ️  Skipping SBT mint (already exists)\n");
    } else {
      console.log("   ⚠️  User does not have SBT yet\n");

      // Check deployer's role
      console.log("🔍 Checking permissions...");
      const daoMultisig = await sbtContract.daoMultisig();
      const registryAddress = await sbtContract.REGISTRY();
      console.log("   DAO Multisig:", daoMultisig);
      console.log("   Registry:", registryAddress);
      console.log("   Deployer:", deployer.address);

      // Check if deployer is registered as community
      const registry = new ethers.Contract(registryAddress, Registry_ABI, provider);
      const isCommunityRegistered = await registry.isCommunityRegistered(deployer.address);
      console.log("   Is Deployer Registered as Community:", isCommunityRegistered);

      if (!isCommunityRegistered) {
        console.log("\n   ❌ Deployer is not registered as a community in Registry");
        console.log("   💡 Options:");
        console.log("      1. Register deployer as community in Registry");
        console.log("      2. Use a registered community account to mint SBT");
        console.log("      3. Use DAO multisig to directly mint");
        console.log("\n   ⏭️  Skipping SBT mint for now\n");
      } else {
        // Mint SBT
        console.log("\n💳 Minting SBT...");
        const metadata = "Test SBT for PaymasterV4.1";
        console.log("   Metadata:", metadata);

        const tx = await sbtContract.mintOrAddMembership(TEST_ACCOUNT, metadata, {
          gasLimit: 500000n,
        });

        console.log("   ✅ Transaction submitted!");
        console.log("   Transaction hash:", tx.hash);
        console.log("   Sepolia Etherscan:", `https://sepolia.etherscan.io/tx/${tx.hash}`);

        console.log("\n   ⏳ Waiting for confirmation...");
        const receipt = await tx.wait();

        console.log("   ✅ SBT minted!");
        console.log("   Block Number:", receipt.blockNumber);
        console.log("   Gas Used:", receipt.gasUsed.toString());

        // Get new token ID
        const newTokenId = await sbtContract.userToSBT(TEST_ACCOUNT);
        console.log("   New Token ID:", newTokenId.toString());
        console.log("");
      }
    }
  } catch (error) {
    console.error("\n❌ SBT Mint Failed:");
    console.error("   Error:", error.message);
    if (error.data) {
      console.error("   Error Data:", error.data);
    }
    console.log("\n   ⏭️  Continuing to GasToken mint...\n");
  }

  // ========================================
  // Part 2: Mint GasToken
  // ========================================
  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║                 Part 2: Mint GasToken                          ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  try {
    // Get token info
    const tokenName = await gasTokenContract.name();
    const tokenSymbol = await gasTokenContract.symbol();
    const tokenDecimals = await gasTokenContract.decimals();
    const tokenOwner = await gasTokenContract.owner();

    console.log("📊 GasToken Info:");
    console.log("   Name:", tokenName);
    console.log("   Symbol:", tokenSymbol);
    console.log("   Decimals:", tokenDecimals);
    console.log("   Owner:", tokenOwner);
    console.log("   Deployer:", deployer.address);

    // Check current balance
    const currentBalance = await gasTokenContract.balanceOf(TEST_ACCOUNT);
    console.log("\n   Current Balance:", ethers.formatUnits(currentBalance, tokenDecimals), tokenSymbol);

    // Check if deployer is owner
    if (tokenOwner.toLowerCase() !== deployer.address.toLowerCase()) {
      console.log("\n   ❌ Deployer is not the owner of GasToken");
      console.log("   💡 You need to use the owner account to mint");
      console.log("      Owner:", tokenOwner);
      console.log("      Deployer:", deployer.address);
      console.log("\n   ⏭️  Skipping GasToken mint\n");
    } else {
      // Mint 1000 tokens
      const mintAmount = ethers.parseUnits("1000", tokenDecimals);
      console.log("\n💳 Minting GasToken...");
      console.log("   Amount:", ethers.formatUnits(mintAmount, tokenDecimals), tokenSymbol);
      console.log("   To:", TEST_ACCOUNT);

      const tx = await gasTokenContract.mint(TEST_ACCOUNT, mintAmount, {
        gasLimit: 200000n,
      });

      console.log("   ✅ Transaction submitted!");
      console.log("   Transaction hash:", tx.hash);
      console.log("   Sepolia Etherscan:", `https://sepolia.etherscan.io/tx/${tx.hash}`);

      console.log("\n   ⏳ Waiting for confirmation...");
      const receipt = await tx.wait();

      console.log("   ✅ GasToken minted!");
      console.log("   Block Number:", receipt.blockNumber);
      console.log("   Gas Used:", receipt.gasUsed.toString());

      // Check new balance
      const newBalance = await gasTokenContract.balanceOf(TEST_ACCOUNT);
      console.log("\n   New Balance:", ethers.formatUnits(newBalance, tokenDecimals), tokenSymbol);
      console.log("   Minted:", ethers.formatUnits(newBalance - currentBalance, tokenDecimals), tokenSymbol);
      console.log("");
    }
  } catch (error) {
    console.error("\n❌ GasToken Mint Failed:");
    console.error("   Error:", error.message);
    if (error.data) {
      console.error("   Error Data:", error.data);
    }
    console.log("");
  }

  // ========================================
  // Summary
  // ========================================
  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║                         Summary                                ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  try {
    const tokenId = await sbtContract.userToSBT(TEST_ACCOUNT);
    const gasBalance = await gasTokenContract.balanceOf(TEST_ACCOUNT);
    const decimals = await gasTokenContract.decimals();
    const symbol = await gasTokenContract.symbol();

    console.log("📊 Test Account Status:");
    console.log("   Account:", TEST_ACCOUNT);
    console.log("   SBT Token ID:", tokenId > 0n ? tokenId.toString() : "None");
    console.log("   GasToken Balance:", ethers.formatUnits(gasBalance, decimals), symbol);

    if (tokenId > 0n && gasBalance > 0n) {
      console.log("\n✅ Test account is ready for PaymasterV4.1 testing!");
      console.log("\n💡 Next steps:");
      console.log("   1. Approve PaymasterV4.1 to spend GasToken");
      console.log("   2. Run: node scripts/test-new-paymaster-v4.js");
    } else {
      console.log("\n⚠️  Test account may need additional setup:");
      if (tokenId === 0n) {
        console.log("   - SBT: Not minted yet");
      }
      if (gasBalance === 0n) {
        console.log("   - GasToken: Balance is 0");
      }
    }
  } catch (error) {
    console.error("   Error checking final status:", error.message);
  }

  console.log("");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

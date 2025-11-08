#!/usr/bin/env node
/**
 * Register AAStar Community to Registry v2.1.3
 */

require("dotenv").config();
const { ethers } = require("ethers");

// v0.2.10 Contract Addresses
const REGISTRY = "0xb6286F53d8ff25eF99e6a43b2907B8e6BD0f019A";
const MYSBT = "0x73E635Fc9eD362b7061495372B6eDFF511D9E18F";
const APNTS_TOKEN = "0xBD0710596010a157B88cd141d797E8Ad4bb2306b";
const SUPER_PAYMASTER_V2 = "0x95B20d8FdF173a1190ff71e41024991B2c5e58eF";
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY || process.env.PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

// Registry ABI
const RegistryABI = [
  `function registerCommunity(
    (
      string name,
      string ensName,
      address xPNTsToken,
      address[] supportedSBTs,
      uint8 nodeType,
      address paymasterAddress,
      address community,
      uint256 registeredAt,
      uint256 lastUpdatedAt,
      bool isActive
    ) profile,
    uint256 stGTokenAmount
  ) external`,
  "function getCommunity(address) external view returns (string, string, address, address[], uint8, address, address, uint256, uint256, bool)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const deployer = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

  console.log("=== Register AAStar Community ===\n");
  console.log("Deployer:", deployer.address);
  console.log("Registry:", REGISTRY);
  console.log();

  const registry = new ethers.Contract(REGISTRY, RegistryABI, deployer);

  // Check if already registered
  try {
    const community = await registry.getCommunity(deployer.address);
    if (community[0] !== "") {
      console.log("✅ AAStar community already registered!");
      console.log("  Name:", community[0]);
      console.log("  ENS:", community[1]);
      console.log("  xPNTs Token:", community[2]);
      return;
    }
  } catch (e) {
    console.log("🔍 Community not yet registered, proceeding...\n");
  }

  // Prepare CommunityProfile
  const profile = {
    name: "AAStar",
    ensName: "aastar.eth",
    xPNTsToken: APNTS_TOKEN,
    supportedSBTs: [MYSBT],
    nodeType: 1, // PAYMASTER_SUPER
    paymasterAddress: SUPER_PAYMASTER_V2,
    community: ethers.ZeroAddress, // Will be set to msg.sender
    registeredAt: 0, // Will be set by contract
    lastUpdatedAt: 0, // Will be set by contract
    isActive: false, // Will be set by contract
  };

  const stGTokenAmount = ethers.parseEther("50"); // 50 stGToken

  console.log("📝 Community Profile:");
  console.log("  Name:", profile.name);
  console.log("  ENS:", profile.ensName);
  console.log("  xPNTs Token:", profile.xPNTsToken);
  console.log("  Supported SBTs:", profile.supportedSBTs);
  console.log("  Node Type: PAYMASTER_SUPER (1)");
  console.log("  Paymaster Address:", profile.paymasterAddress);
  console.log("  Stake Amount:", ethers.formatEther(stGTokenAmount), "stGToken");
  console.log();

  console.log("🚀 Registering community...");
  try {
    const tx = await registry.registerCommunity(profile, stGTokenAmount, {
      gasLimit: 500000n,
    });

    console.log("  Transaction Hash:", tx.hash);
    console.log("  Waiting for confirmation...");

    const receipt = await tx.wait();
    console.log("  ✅ Community registered!");
    console.log("  Block Number:", receipt.blockNumber);
    console.log("  Gas Used:", receipt.gasUsed.toString());
    console.log();

    // Verify registration
    const registered = await registry.getCommunity(deployer.address);
    console.log("✅ Verification:");
    console.log("  Name:", registered[0]);
    console.log("  ENS:", registered[1]);
    console.log("  xPNTs Token:", registered[2]);
    console.log();
  } catch (error) {
    console.error("\n❌ Registration Failed:");
    console.error("  Error:", error.message);
    if (error.data) {
      console.error("  Error Data:", error.data);
    }
    throw error;
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

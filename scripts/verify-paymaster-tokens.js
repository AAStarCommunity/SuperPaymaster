require("dotenv").config();
const { ethers } = require("ethers");

/**
 * Verify that SBT and GasToken are supported in PaymasterV4
 */

const PAYMASTER_V4 = "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38";
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

const PaymasterV4_ABI = [
  "function getSupportedSBTs() view returns (address[])",
  "function getSupportedGasTokens() view returns (address[])",
  "function isSBTSupported(address) view returns (bool)",
  "function isGasTokenSupported(address) view returns (bool)",
  "function owner() view returns (address)",
  "function treasury() view returns (address)",
  "function serviceFeeRate() view returns (uint256)",
  "function maxGasCostCap() view returns (uint256)",
  "function paused() view returns (bool)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const paymaster = new ethers.Contract(PAYMASTER_V4, PaymasterV4_ABI, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║        Verify PaymasterV4 Supported Tokens                    ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  console.log("📋 PaymasterV4 Address:", PAYMASTER_V4);
  console.log("");

  // === Check contract info ===
  console.log("🔍 PaymasterV4 Configuration:");
  try {
    const owner = await paymaster.owner();
    const treasury = await paymaster.treasury();
    const serviceFeeRate = await paymaster.serviceFeeRate();
    const maxGasCostCap = await paymaster.maxGasCostCap();
    const paused = await paymaster.paused();

    console.log("   Owner:", owner);
    console.log("   Treasury:", treasury);
    console.log("   Service Fee Rate:", serviceFeeRate.toString(), "bps (basis points)");
    console.log("   Max Gas Cost Cap:", ethers.formatEther(maxGasCostCap), "ETH");
    console.log("   Paused:", paused);
    console.log("");
  } catch (error) {
    console.error("   ❌ Failed to get config:", error.message);
    console.log("");
  }

  // === Get supported SBTs ===
  console.log("🎯 Supported SBTs:");
  try {
    const supportedSBTs = await paymaster.getSupportedSBTs();

    console.log("   Count:", supportedSBTs.length);

    if (supportedSBTs.length === 0) {
      console.log("   ❌ No SBTs configured!");
    } else {
      supportedSBTs.forEach((sbt, index) => {
        console.log(`   [${index}] ${sbt}`);
      });

      // Verify each SBT
      console.log("\n   Verification:");
      for (let i = 0; i < supportedSBTs.length; i++) {
        const sbtAddress = supportedSBTs[i];
        const isSupported = await paymaster.isSBTSupported(sbtAddress);
        console.log(`   ${sbtAddress} → ${isSupported ? "✅ Supported" : "❌ Not Supported"}`);
      }
    }
    console.log("");
  } catch (error) {
    console.error("   ❌ Failed to get SBTs:", error.message);
    console.log("");
  }

  // === Get supported GasTokens ===
  console.log("💰 Supported Gas Tokens:");
  try {
    const supportedGasTokens = await paymaster.getSupportedGasTokens();

    console.log("   Count:", supportedGasTokens.length);

    if (supportedGasTokens.length === 0) {
      console.log("   ❌ No Gas Tokens configured!");
    } else {
      supportedGasTokens.forEach((token, index) => {
        console.log(`   [${index}] ${token}`);
      });

      // Verify each token and get info
      console.log("\n   Verification:");
      const ERC20_ABI = ["function name() view returns (string)", "function symbol() view returns (string)"];

      for (let i = 0; i < supportedGasTokens.length; i++) {
        const tokenAddress = supportedGasTokens[i];
        const isSupported = await paymaster.isGasTokenSupported(tokenAddress);

        // Get token info
        try {
          const tokenContract = new ethers.Contract(tokenAddress, ERC20_ABI, provider);
          const name = await tokenContract.name();
          const symbol = await tokenContract.symbol();

          console.log(`   ${tokenAddress}`);
          console.log(`      Status: ${isSupported ? "✅ Supported" : "❌ Not Supported"}`);
          console.log(`      Name: ${name}`);
          console.log(`      Symbol: ${symbol}`);
        } catch (error) {
          console.log(`   ${tokenAddress}`);
          console.log(`      Status: ${isSupported ? "✅ Supported" : "❌ Not Supported"}`);
          console.log(`      Info: Could not fetch token info`);
        }
      }
    }
    console.log("");
  } catch (error) {
    console.error("   ❌ Failed to get Gas Tokens:", error.message);
    console.log("");
  }

  // === Test specific addresses ===
  console.log("🧪 Test Specific Addresses:");

  const testAddresses = {
    "MySBT v2.3": "0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8",
    "BREAD Token": "0x13da8229f5ca3e1Ab2be3c010BBBb5dbAed85621",
  };

  for (const [name, address] of Object.entries(testAddresses)) {
    console.log(`\n   ${name} (${address}):`);

    try {
      const isSBT = await paymaster.isSBTSupported(address);
      const isGasToken = await paymaster.isGasTokenSupported(address);

      console.log(`      As SBT: ${isSBT ? "✅ Supported" : "❌ Not Supported"}`);
      console.log(`      As GasToken: ${isGasToken ? "✅ Supported" : "❌ Not Supported"}`);

      if (isSBT || isGasToken) {
        console.log(`      ✅ This address IS configured in PaymasterV4`);
      } else {
        console.log(`      ❌ This address is NOT configured in PaymasterV4`);
      }
    } catch (error) {
      console.log(`      ❌ Failed to check: ${error.message}`);
    }
  }

  console.log("\n╔════════════════════════════════════════════════════════════════╗");
  console.log("║                  Verification Complete                         ║");
  console.log("╚════════════════════════════════════════════════════════════════╝");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

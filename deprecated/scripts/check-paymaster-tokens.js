require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  
  const PAYMASTER_V4 = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
  const PNT_TOKEN = "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
  const SBT_TOKEN = "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f";
  
  const PaymasterABI = [
    "function supportedGasTokens(address token) external view returns (bool)",
    "function gasTokenPriceUSD(address token) external view returns (uint256)",
  ];
  
  const paymaster = new ethers.Contract(PAYMASTER_V4, PaymasterABI, provider);
  
  console.log("=== Checking PaymasterV4 Gas Token Registration ===\n");
  console.log("PaymasterV4:", PAYMASTER_V4);
  console.log();
  
  // Check PNT
  const pntSupported = await paymaster.supportedGasTokens(PNT_TOKEN);
  console.log("PNT Token:", PNT_TOKEN);
  console.log("  Supported:", pntSupported ? "✅ YES" : "❌ NO");
  
  if (pntSupported) {
    const pntPrice = await paymaster.gasTokenPriceUSD(PNT_TOKEN);
    console.log("  Price:", ethers.formatUnits(pntPrice, 18), "USD");
  }
  
  console.log();
  
  // Check SBT
  const sbtSupported = await paymaster.supportedGasTokens(SBT_TOKEN);
  console.log("SBT Token:", SBT_TOKEN);
  console.log("  Supported:", sbtSupported ? "✅ YES" : "❌ NO");
  
  if (sbtSupported) {
    const sbtPrice = await paymaster.gasTokenPriceUSD(SBT_TOKEN);
    console.log("  Price:", ethers.formatUnits(sbtPrice, 18), "USD");
  }
}

main().catch(console.error);

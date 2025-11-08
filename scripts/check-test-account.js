require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  
  const TEST_ACCOUNT = "0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584";
  const PNT_TOKEN = "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
  const SBT_TOKEN = "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f";
  const PAYMASTER_V4 = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
  
  const ERC20ABI = [
    "function balanceOf(address) external view returns (uint256)",
    "function allowance(address owner, address spender) external view returns (uint256)"
  ];
  
  const pnt = new ethers.Contract(PNT_TOKEN, ERC20ABI, provider);
  const sbt = new ethers.Contract(SBT_TOKEN, ERC20ABI, provider);
  
  console.log("=== Checking TEST_AA_ACCOUNT_ADDRESS_A ===");
  console.log("Account:", TEST_ACCOUNT);
  console.log();
  
  // Check if deployed
  const code = await provider.getCode(TEST_ACCOUNT);
  console.log("Account deployed:", code !== "0x");
  
  if (code === "0x") {
    console.log("❌ Account not deployed!");
    return;
  }
  
  // Check balances
  const pntBalance = await pnt.balanceOf(TEST_ACCOUNT);
  const sbtBalance = await sbt.balanceOf(TEST_ACCOUNT);
  const ethBalance = await provider.getBalance(TEST_ACCOUNT);
  
  console.log("\nBalances:");
  console.log("  PNT:", ethers.formatEther(pntBalance));
  console.log("  SBT:", sbtBalance.toString());
  console.log("  ETH:", ethers.formatEther(ethBalance));
  
  // Check allowances
  const pntAllowance = await pnt.allowance(TEST_ACCOUNT, PAYMASTER_V4);
  console.log("\nAllowances:");
  console.log("  PNT to PaymasterV4:", ethers.formatEther(pntAllowance));
  
  // Check if ready for testing
  console.log("\n=== Ready for V4 Testing ===");
  console.log("  PNT balance >= 10:", pntBalance >= ethers.parseEther("10") ? "✅" : "❌");
  console.log("  PNT allowance >= 10:", pntAllowance >= ethers.parseEther("10") ? "✅" : "❌");
  console.log("  SBT balance >= 1:", sbtBalance >= 1n ? "✅" : "❌");
}

main().catch(console.error);

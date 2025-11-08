require("dotenv").config();
const { ethers } = require("ethers");

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const PAYMASTER_V4 = "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38";
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

const EntryPoint_ABI = [
  "function balanceOf(address account) view returns (uint256)",
  "function getDepositInfo(address account) view returns (tuple(uint112 deposit, bool staked, uint112 stake, uint32 unstakeDelaySec, uint48 withdrawTime))",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const entryPoint = new ethers.Contract(ENTRYPOINT, EntryPoint_ABI, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║          Check PaymasterV4 Deposit in EntryPoint              ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  const balance = await entryPoint.balanceOf(PAYMASTER_V4);
  const depositInfo = await entryPoint.getDepositInfo(PAYMASTER_V4);

  console.log("PaymasterV4:", PAYMASTER_V4);
  console.log("");
  console.log("💰 EntryPoint Balance:", ethers.formatEther(balance), "ETH");
  console.log("");
  console.log("📊 Deposit Info:");
  console.log("   Deposit:", ethers.formatEther(depositInfo.deposit), "ETH");
  console.log("   Staked:", depositInfo.staked);
  console.log("   Stake:", ethers.formatEther(depositInfo.stake), "ETH");
  console.log("   Unstake Delay:", depositInfo.unstakeDelaySec, "seconds");
  console.log("");

  if (balance < ethers.parseEther("0.001")) {
    console.log("❌ INSUFFICIENT DEPOSIT!");
    console.log("   PaymasterV4 needs ETH deposit in EntryPoint to pay for gas");
    console.log("   Current:", ethers.formatEther(balance), "ETH");
    console.log("   Recommended: >= 0.01 ETH");
    console.log("");
    console.log("💡 To deposit:");
    console.log("   entryPoint.addDeposit(PAYMASTER_V4, { value: ethers.parseEther('0.01') })");
  } else {
    console.log("✅ Deposit sufficient");
  }
}

main().catch(console.error);

/**
 * Add deposit to PaymasterV4 in EntryPoint
 * Usage: OWNER2_PRIVATE_KEY=0x... node scripts/add-deposit-v4.js [amount_in_eth]
 */

const { ethers } = require("ethers");

// Configuration
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL || "https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N";
const PRIVATE_KEY = process.env.OWNER2_PRIVATE_KEY || process.env.PRIVATE_KEY;
const PAYMASTER_V4 = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
const ENTRYPOINT_V07 = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";

// Amount from command line args or default to 0.5 ETH
const DEPOSIT_AMOUNT = process.argv[2] || "0.5";

const PaymasterV4ABI = [
  "function addDeposit() external payable",
  "function owner() public view returns (address)",
];

const EntryPointABI = [
  "function balanceOf(address account) external view returns (uint256)",
  "function getDepositInfo(address account) external view returns (uint256 deposit, bool staked, uint112 stake, uint32 unstakeDelaySec, uint48 withdrawTime)",
];

async function main() {
  if (!PRIVATE_KEY) {
    console.error("❌ Error: OWNER2_PRIVATE_KEY or PRIVATE_KEY not set");
    console.log("Usage: OWNER2_PRIVATE_KEY=0x... node scripts/add-deposit-v4.js [amount_in_eth]");
    process.exit(1);
  }

  console.log("🚀 Adding Deposit to PaymasterV4\n");

  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log("📝 Configuration:");
  console.log("Signer Address:", signer.address);
  console.log("PaymasterV4:", PAYMASTER_V4);
  console.log("EntryPoint:", ENTRYPOINT_V07);
  console.log("Deposit Amount:", DEPOSIT_AMOUNT, "ETH\n");

  // Check signer balance
  const signerBalance = await provider.getBalance(signer.address);
  console.log("💰 Signer Balance:", ethers.formatEther(signerBalance), "ETH");

  const depositAmount = ethers.parseEther(DEPOSIT_AMOUNT);
  if (signerBalance < depositAmount) {
    console.error("❌ Insufficient balance for deposit");
    process.exit(1);
  }

  // Check current deposit
  const entryPoint = new ethers.Contract(ENTRYPOINT_V07, EntryPointABI, provider);
  const currentDeposit = await entryPoint.balanceOf(PAYMASTER_V4);
  console.log("\n📊 Current PaymasterV4 Deposit:", ethers.formatEther(currentDeposit), "ETH");

  // Get deposit info
  const depositInfo = await entryPoint.getDepositInfo(PAYMASTER_V4);
  console.log("   Deposit:", ethers.formatEther(depositInfo.deposit), "ETH");
  console.log("   Staked:", depositInfo.staked);
  console.log("   Stake:", ethers.formatEther(depositInfo.stake), "ETH");

  // Verify ownership (optional, just for safety)
  const paymaster = new ethers.Contract(PAYMASTER_V4, PaymasterV4ABI, provider);
  const owner = await paymaster.owner();
  console.log("\n🔑 PaymasterV4 Owner:", owner);
  console.log("   Signer:", signer.address);

  if (owner.toLowerCase() !== signer.address.toLowerCase()) {
    console.log("⚠️  Warning: Signer is not the owner, but addDeposit() is still callable");
  }

  // Add deposit
  console.log("\n💸 Adding deposit...");
  const paymasterWithSigner = new ethers.Contract(PAYMASTER_V4, PaymasterV4ABI, signer);

  const tx = await paymasterWithSigner.addDeposit({
    value: depositAmount,
    gasLimit: 100000n,
  });

  console.log("📝 Transaction Hash:", tx.hash);
  console.log("⏳ Waiting for confirmation...");

  const receipt = await tx.wait();

  if (receipt.status === 1) {
    console.log("\n✅ SUCCESS!");
    console.log("   Block:", receipt.blockNumber);
    console.log("   Gas Used:", receipt.gasUsed.toString());
    console.log("   Etherscan:", `https://sepolia.etherscan.io/tx/${receipt.hash}`);

    // Check new deposit
    const newDeposit = await entryPoint.balanceOf(PAYMASTER_V4);
    console.log("\n📊 New PaymasterV4 Deposit:", ethers.formatEther(newDeposit), "ETH");
    console.log("   Increase:", ethers.formatEther(newDeposit - currentDeposit), "ETH");
  } else {
    console.log("\n❌ FAILED!");
    console.log("   Transaction reverted");
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Error:", error.message);
    console.error(error);
    process.exit(1);
  });

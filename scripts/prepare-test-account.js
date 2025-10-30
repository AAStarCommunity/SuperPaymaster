require("dotenv").config();
const { ethers } = require("ethers");

/**
 * Prepare SimpleAccount for PaymasterV4 testing
 * 1. Check PNT balance
 * 2. Approve PaymasterV4 to spend PNT
 */

const SIMPLE_ACCOUNT = process.env.SIMPLE_ACCOUNT_B || "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";
const PAYMASTER_V4 = "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38";
const PNT_TOKEN = process.env.PNT_TOKEN_ADDRESS || "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
const OWNER_PRIVATE_KEY = process.env.OWNER_PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

const ERC20ABI = [
  "function balanceOf(address) external view returns (uint256)",
  "function allowance(address owner, address spender) external view returns (uint256)",
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function transfer(address to, uint256 amount) external returns (bool)",
];

const SimpleAccountABI = [
  "function execute(address dest, uint256 value, bytes calldata func) external",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║         Prepare SimpleAccount for PaymasterV4 Test            ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  console.log("📋 Configuration:");
  console.log("   Signer:", signer.address);
  console.log("   SimpleAccount:", SIMPLE_ACCOUNT);
  console.log("   PaymasterV4:", PAYMASTER_V4);
  console.log("   PNT Token:", PNT_TOKEN);
  console.log("");

  const pntContract = new ethers.Contract(PNT_TOKEN, ERC20ABI, provider);
  const accountContract = new ethers.Contract(SIMPLE_ACCOUNT, SimpleAccountABI, signer);

  // === Step 1: Check PNT balance ===
  console.log("📊 Step 1: Check PNT Balance");
  const pntBalance = await pntContract.balanceOf(SIMPLE_ACCOUNT);
  console.log("   Current Balance:", ethers.formatUnits(pntBalance, 18), "PNT");

  if (pntBalance < ethers.parseUnits("10", 18)) {
    console.log("   ⚠️  Low balance (< 10 PNT)");
    console.log("   💡 You may need to transfer PNT to SimpleAccount");
  } else {
    console.log("   ✅ Balance sufficient");
  }
  console.log("");

  // === Step 2: Check current allowance ===
  console.log("📝 Step 2: Check Current Allowance");
  const currentAllowance = await pntContract.allowance(SIMPLE_ACCOUNT, PAYMASTER_V4);
  console.log("   Current Allowance:", ethers.formatUnits(currentAllowance, 18), "PNT");

  if (currentAllowance >= ethers.parseUnits("100", 18)) {
    console.log("   ✅ Allowance already sufficient (>= 100 PNT)");
    console.log("\n✅ Account is ready for testing!");
    return;
  }

  // === Step 3: Approve PaymasterV4 ===
  console.log("\n💳 Step 3: Approve PaymasterV4");
  const approveAmount = ethers.parseUnits("1000", 18); // Approve 1000 PNT
  console.log("   Approving:", ethers.formatUnits(approveAmount, 18), "PNT");
  console.log("   To:", PAYMASTER_V4);

  // Construct approve calldata
  const approveCalldata = pntContract.interface.encodeFunctionData("approve", [
    PAYMASTER_V4,
    approveAmount,
  ]);

  // Execute via SimpleAccount
  console.log("\n   Submitting approval transaction...");
  try {
    const tx = await accountContract.execute(PNT_TOKEN, 0, approveCalldata, {
      gasLimit: 200000n,
    });

    console.log("   ✅ Transaction submitted!");
    console.log("   Transaction hash:", tx.hash);
    console.log("   Sepolia Etherscan:", `https://sepolia.etherscan.io/tx/${tx.hash}`);

    console.log("\n   ⏳ Waiting for confirmation...");
    const receipt = await tx.wait();

    console.log("   ✅ Approval confirmed!");
    console.log("   Block Number:", receipt.blockNumber);
    console.log("   Gas Used:", receipt.gasUsed.toString());

    // Verify new allowance
    const newAllowance = await pntContract.allowance(SIMPLE_ACCOUNT, PAYMASTER_V4);
    console.log("\n   New Allowance:", ethers.formatUnits(newAllowance, 18), "PNT");

    console.log("\n╔════════════════════════════════════════════════════════════════╗");
    console.log("║              ✅ ACCOUNT PREPARED SUCCESSFULLY                  ║");
    console.log("║                                                                ║");
    console.log("║  You can now run: node scripts/test-new-paymaster-v4.js       ║");
    console.log("╚════════════════════════════════════════════════════════════════╝");

  } catch (error) {
    console.error("\n❌ Approval Failed:");
    console.error("   Error:", error.message);

    if (error.data) {
      console.error("   Error Data:", error.data);
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

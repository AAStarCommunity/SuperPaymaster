require("dotenv").config();
const { ethers } = require("ethers");

/**
 * Test script for new PaymasterV4: 0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38
 *
 * This script submits UserOp directly via EntryPoint (no bundler)
 * PaymasterV4 uses direct payment mode without Settlement contract
 */

// Contract Addresses
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"; // EntryPoint v0.7
const SIMPLE_ACCOUNT = process.env.SIMPLE_ACCOUNT_B || "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";
const PAYMASTER_V4 = "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38"; // NEW PaymasterV4
const PNT_TOKEN = process.env.PNT_TOKEN_ADDRESS || "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
const RECIPIENT = process.env.OWNER2_ADDRESS || "0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA";

// Environment
const OWNER_PRIVATE_KEY = process.env.OWNER_PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

if (!OWNER_PRIVATE_KEY || !SEPOLIA_RPC_URL) {
  console.error("❌ Missing required environment variables:");
  console.error("   OWNER_PRIVATE_KEY:", OWNER_PRIVATE_KEY ? "✓" : "✗");
  console.error("   SEPOLIA_RPC_URL:", SEPOLIA_RPC_URL ? "✓" : "✗");
  process.exit(1);
}

// ABIs
const EntryPointABI = [
  "function handleOps((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature)[] ops, address payable beneficiary) external",
  "function getUserOpHash((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp) external view returns (bytes32)",
  "function getNonce(address sender, uint192 key) external view returns (uint256 nonce)",
];

const SimpleAccountABI = [
  "function execute(address dest, uint256 value, bytes calldata func) external",
];

const ERC20ABI = [
  "function transfer(address to, uint256 amount) external returns (bool)",
  "function balanceOf(address) external view returns (uint256)",
  "function allowance(address owner, address spender) external view returns (uint256)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║     Test New PaymasterV4 via EntryPoint (Direct)              ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  console.log("📋 Configuration:");
  console.log("   Signer:", signer.address);
  console.log("   SimpleAccount:", SIMPLE_ACCOUNT);
  console.log("   PaymasterV4:", PAYMASTER_V4);
  console.log("   PNT Token:", PNT_TOKEN);
  console.log("   EntryPoint:", ENTRYPOINT);
  console.log("   Recipient:", RECIPIENT);
  console.log("");

  const entryPoint = new ethers.Contract(ENTRYPOINT, EntryPointABI, signer);
  const accountContract = new ethers.Contract(SIMPLE_ACCOUNT, SimpleAccountABI, provider);
  const pntContract = new ethers.Contract(PNT_TOKEN, ERC20ABI, provider);

  // === Step 1: Check PNT balance and allowance ===
  console.log("📊 Step 1: Check PNT Balance & Allowance");
  const pntBalance = await pntContract.balanceOf(SIMPLE_ACCOUNT);
  const pntAllowance = await pntContract.allowance(SIMPLE_ACCOUNT, PAYMASTER_V4);
  console.log("   PNT Balance:", ethers.formatUnits(pntBalance, 18), "PNT");
  console.log("   PNT Allowance:", ethers.formatUnits(pntAllowance, 18), "PNT");

  if (pntBalance < ethers.parseUnits("10", 18)) {
    console.error("\n❌ Insufficient PNT balance (need >= 10 PNT)");
    console.error("   Current balance:", ethers.formatUnits(pntBalance, 18), "PNT");
    process.exit(1);
  }

  if (pntAllowance < ethers.parseUnits("10", 18)) {
    console.error("\n❌ Insufficient PNT allowance (need >= 10 PNT approved to PaymasterV4)");
    console.error("   Current allowance:", ethers.formatUnits(pntAllowance, 18), "PNT");
    console.error("\n💡 To fix: Approve PNT to PaymasterV4:");
    console.error("   pntContract.approve(PAYMASTER_V4, ethers.parseUnits('1000', 18))");
    process.exit(1);
  }
  console.log("   ✅ PNT balance and allowance sufficient\n");

  // === Step 2: Get nonce ===
  console.log("📝 Step 2: Get Nonce");
  const nonce = await entryPoint.getNonce(SIMPLE_ACCOUNT, 0);
  console.log("   Nonce:", nonce.toString());
  console.log("");

  // === Step 3: Construct calldata ===
  console.log("🔧 Step 3: Construct CallData");
  const transferAmount = ethers.parseUnits("0.5", 18);
  console.log("   Transfer Amount:", ethers.formatUnits(transferAmount, 18), "PNT");
  console.log("   Transfer To:", RECIPIENT);

  const transferCalldata = pntContract.interface.encodeFunctionData("transfer", [
    RECIPIENT,
    transferAmount,
  ]);
  const executeCalldata = accountContract.interface.encodeFunctionData("execute", [
    PNT_TOKEN,
    0,
    transferCalldata,
  ]);
  console.log("   CallData Length:", executeCalldata.length, "bytes");
  console.log("");

  // === Step 4: Configure gas ===
  console.log("⛽ Step 4: Configure Gas");
  const callGasLimit = 100000n;
  const verificationGasLimit = 300000n;
  const preVerificationGas = 100000n;
  const maxPriorityFeePerGas = ethers.parseUnits("0.1", "gwei");

  const latestBlock = await provider.getBlock("latest");
  const baseFeePerGas = latestBlock.baseFeePerGas || ethers.parseUnits("0.001", "gwei");
  const maxFeePerGas = baseFeePerGas + maxPriorityFeePerGas + ethers.parseUnits("0.001", "gwei");

  console.log("   callGasLimit:", callGasLimit.toString());
  console.log("   verificationGasLimit:", verificationGasLimit.toString());
  console.log("   preVerificationGas:", preVerificationGas.toString());
  console.log("   maxFeePerGas:", ethers.formatUnits(maxFeePerGas, "gwei"), "gwei");
  console.log("   maxPriorityFeePerGas:", ethers.formatUnits(maxPriorityFeePerGas, "gwei"), "gwei");
  console.log("");

  // Pack gas limits
  const accountGasLimits = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(verificationGasLimit), 16),
    ethers.zeroPadValue(ethers.toBeHex(callGasLimit), 16),
  ]);

  const gasFees = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(maxPriorityFeePerGas), 16),
    ethers.zeroPadValue(ethers.toBeHex(maxFeePerGas), 16),
  ]);

  // === Step 5: Construct paymasterAndData ===
  console.log("💳 Step 5: Construct PaymasterAndData");
  console.log("   Format: [paymaster(20) | pmVerifyGas(16) | pmPostOpGas(16) | gasToken(20)]");

  const paymasterAndData = ethers.concat([
    PAYMASTER_V4, // paymaster address (20 bytes)
    ethers.zeroPadValue(ethers.toBeHex(200000n), 16), // paymasterVerificationGasLimit (16 bytes)
    ethers.zeroPadValue(ethers.toBeHex(100000n), 16), // paymasterPostOpGasLimit (16 bytes)
    PNT_TOKEN, // userSpecifiedGasToken (20 bytes) - use PNT
  ]);

  console.log("   Length:", paymasterAndData.length, "bytes (expected 72)");
  console.log("   Paymaster:", PAYMASTER_V4);
  console.log("   VerificationGasLimit: 200000");
  console.log("   PostOpGasLimit: 100000");
  console.log("   GasToken:", PNT_TOKEN);
  console.log("   Full hex:", paymasterAndData);
  console.log("");

  // === Step 6: Build PackedUserOp ===
  console.log("📦 Step 6: Build PackedUserOp");
  const packedUserOp = {
    sender: SIMPLE_ACCOUNT,
    nonce: nonce,
    initCode: "0x",
    callData: executeCalldata,
    accountGasLimits: accountGasLimits,
    preVerificationGas: preVerificationGas,
    gasFees: gasFees,
    paymasterAndData: paymasterAndData,
    signature: "0x", // Will be filled after signing
  };
  console.log("   ✅ PackedUserOp constructed");
  console.log("");

  // === Step 7: Sign UserOp ===
  console.log("✍️  Step 7: Sign UserOp");
  const userOpHash = await entryPoint.getUserOpHash(packedUserOp);
  console.log("   UserOpHash:", userOpHash);

  // SimpleAccount V1 uses raw signature (direct hash signing, no prefix)
  const signingKey = new ethers.SigningKey(OWNER_PRIVATE_KEY);
  const signature = signingKey.sign(userOpHash).serialized;
  packedUserOp.signature = signature;
  console.log("   Signature:", signature);
  console.log("   ✅ UserOp signed");
  console.log("");

  // === Step 8: Submit to EntryPoint ===
  console.log("🚀 Step 8: Submit to EntryPoint.handleOps()");
  console.log("   Submitting...");

  try {
    const tx = await entryPoint.handleOps([packedUserOp], signer.address, {
      gasLimit: 1000000n, // Set high gas limit for safety
    });

    console.log("\n✅ Transaction Submitted!");
    console.log("   Transaction hash:", tx.hash);
    console.log("   Sepolia Etherscan:", `https://sepolia.etherscan.io/tx/${tx.hash}`);

    console.log("\n⏳ Waiting for confirmation...");
    const receipt = await tx.wait();

    console.log("\n🎉 UserOp Executed Successfully!");
    console.log("   Block Number:", receipt.blockNumber);
    console.log("   Gas Used:", receipt.gasUsed.toString());
    console.log("   Status:", receipt.status === 1 ? "✅ Success" : "❌ Failed");

    // === Step 9: Check final balance ===
    console.log("\n💰 Step 9: Check Final Balance");
    const finalBalance = await pntContract.balanceOf(SIMPLE_ACCOUNT);
    const pntSpent = pntBalance - finalBalance;

    console.log("   Initial PNT Balance:", ethers.formatUnits(pntBalance, 18), "PNT");
    console.log("   Final PNT Balance:", ethers.formatUnits(finalBalance, 18), "PNT");
    console.log("   PNT Spent (transfer + gas):", ethers.formatUnits(pntSpent, 18), "PNT");
    console.log("   Transfer Amount:", ethers.formatUnits(transferAmount, 18), "PNT");
    console.log("   Gas Cost in PNT:", ethers.formatUnits(pntSpent - transferAmount, 18), "PNT");

    console.log("\n╔════════════════════════════════════════════════════════════════╗");
    console.log("║                    ✅ TEST SUCCESSFUL                          ║");
    console.log("╚════════════════════════════════════════════════════════════════╝");

  } catch (error) {
    console.error("\n❌ Transaction Failed:");
    console.error("   Error:", error.message);

    if (error.data) {
      console.error("   Error Data:", error.data);
    }

    if (error.error) {
      console.error("   Inner Error:", error.error);
    }

    // Try to decode the error
    if (error.data) {
      try {
        const decodedError = entryPoint.interface.parseError(error.data);
        console.error("   Decoded Error:", decodedError);
      } catch (e) {
        console.error("   Could not decode error data");
      }
    }

    console.log("\n╔════════════════════════════════════════════════════════════════╗");
    console.log("║                     ❌ TEST FAILED                             ║");
    console.log("╚════════════════════════════════════════════════════════════════╝");

    throw error;
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

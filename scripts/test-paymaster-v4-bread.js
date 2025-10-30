require("dotenv").config();
const { ethers } = require("ethers");

/**
 * Test PaymasterV4.1 (AOA Mode) with BREAD gas token
 * Address: 0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38
 * GasToken: BREAD (0x13da8229f5ca3e1Ab2be3c010BBBb5dbAed85621)
 *
 * Submit UserOp directly via EntryPoint (no bundler)
 */

// Contract Addresses
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"; // EntryPoint v0.7
const SIMPLE_ACCOUNT = process.env.SIMPLE_ACCOUNT_B || "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";
const PAYMASTER_V4 = "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38"; // PaymasterV4.1
const BREAD_TOKEN = "0x13da8229f5ca3e1Ab2be3c010BBBb5dbAed85621"; // BREAD gas token
const PNT_TOKEN = process.env.PNT_TOKEN_ADDRESS || "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
const RECIPIENT = process.env.OWNER2_ADDRESS || "0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA";

// Environment
const OWNER_PRIVATE_KEY = process.env.OWNER_PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

if (!OWNER_PRIVATE_KEY || !SEPOLIA_RPC_URL) {
  console.error("❌ Missing required environment variables");
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
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║       Test PaymasterV4.1 (AOA) with BREAD Gas Token          ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  console.log("📋 Configuration:");
  console.log("   Signer:", signer.address);
  console.log("   SimpleAccount:", SIMPLE_ACCOUNT);
  console.log("   PaymasterV4.1:", PAYMASTER_V4);
  console.log("   BREAD Token:", BREAD_TOKEN);
  console.log("   PNT Token:", PNT_TOKEN);
  console.log("   Recipient:", RECIPIENT);
  console.log("");

  const entryPoint = new ethers.Contract(ENTRYPOINT, EntryPointABI, signer);
  const accountContract = new ethers.Contract(SIMPLE_ACCOUNT, SimpleAccountABI, provider);
  const breadContract = new ethers.Contract(BREAD_TOKEN, ERC20ABI, provider);
  const pntContract = new ethers.Contract(PNT_TOKEN, ERC20ABI, provider);

  // === Step 1: Check BREAD balance and allowance ===
  console.log("📊 Step 1: Check BREAD Balance & Allowance");

  const breadDecimals = await breadContract.decimals();
  const breadSymbol = await breadContract.symbol();
  const breadBalance = await breadContract.balanceOf(SIMPLE_ACCOUNT);
  const breadAllowance = await breadContract.allowance(SIMPLE_ACCOUNT, PAYMASTER_V4);

  console.log("   BREAD Balance:", ethers.formatUnits(breadBalance, breadDecimals), breadSymbol);
  console.log("   BREAD Allowance:", ethers.formatUnits(breadAllowance, breadDecimals), breadSymbol);

  if (breadBalance < ethers.parseUnits("10", breadDecimals)) {
    console.error("\n❌ Insufficient BREAD balance (need >= 10 BREAD)");
    console.error("   Run: node scripts/verify-and-mint.js");
    process.exit(1);
  }

  if (breadAllowance < ethers.parseUnits("10", breadDecimals)) {
    console.log("\n⚠️  BREAD allowance insufficient, approving now...");

    // Approve via SimpleAccount
    const approveCalldata = breadContract.interface.encodeFunctionData("approve", [
      PAYMASTER_V4,
      ethers.parseUnits("1000", breadDecimals),
    ]);
    const executeCalldata = accountContract.interface.encodeFunctionData("execute", [
      BREAD_TOKEN,
      0,
      approveCalldata,
    ]);

    const accountWithSigner = accountContract.connect(signer);
    const approveTx = await accountWithSigner.execute(BREAD_TOKEN, 0, approveCalldata, {
      gasLimit: 200000n,
    });

    console.log("   Transaction hash:", approveTx.hash);
    await approveTx.wait();
    console.log("   ✅ BREAD approved\n");

    const newAllowance = await breadContract.allowance(SIMPLE_ACCOUNT, PAYMASTER_V4);
    console.log("   New Allowance:", ethers.formatUnits(newAllowance, breadDecimals), breadSymbol);
  } else {
    console.log("   ✅ BREAD allowance sufficient");
  }
  console.log("");

  // === Step 2: Get nonce ===
  console.log("📝 Step 2: Get Nonce");
  const nonce = await entryPoint.getNonce(SIMPLE_ACCOUNT, 0);
  console.log("   Nonce:", nonce.toString());
  console.log("");

  // === Step 3: Construct calldata - Transfer PNT ===
  console.log("🔧 Step 3: Construct CallData (Transfer 0.5 PNT)");
  const transferAmount = ethers.parseUnits("0.5", 18);
  console.log("   Transfer Amount:", ethers.formatUnits(transferAmount, 18), "PNT");
  console.log("   To:", RECIPIENT);

  const transferCalldata = pntContract.interface.encodeFunctionData("transfer", [
    RECIPIENT,
    transferAmount,
  ]);
  const executeCalldata = accountContract.interface.encodeFunctionData("execute", [
    PNT_TOKEN,
    0,
    transferCalldata,
  ]);
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
  console.log("💳 Step 5: Construct PaymasterAndData (using BREAD)");
  const paymasterAndData = ethers.concat([
    PAYMASTER_V4, // paymaster address (20 bytes)
    ethers.zeroPadValue(ethers.toBeHex(200000n), 16), // paymasterVerificationGasLimit
    ethers.zeroPadValue(ethers.toBeHex(100000n), 16), // paymasterPostOpGasLimit
    BREAD_TOKEN, // userSpecifiedGasToken = BREAD
  ]);

  console.log("   Length:", paymasterAndData.length, "bytes (expected 72)");
  console.log("   GasToken: BREAD");
  console.log("");

  // === Step 6: Build and sign UserOp ===
  console.log("📦 Step 6: Build and Sign UserOp");
  const packedUserOp = {
    sender: SIMPLE_ACCOUNT,
    nonce: nonce,
    initCode: "0x",
    callData: executeCalldata,
    accountGasLimits: accountGasLimits,
    preVerificationGas: preVerificationGas,
    gasFees: gasFees,
    paymasterAndData: paymasterAndData,
    signature: "0x",
  };

  const userOpHash = await entryPoint.getUserOpHash(packedUserOp);
  console.log("   UserOpHash:", userOpHash);

  const signingKey = new ethers.SigningKey(OWNER_PRIVATE_KEY);
  const signature = signingKey.sign(userOpHash).serialized;
  packedUserOp.signature = signature;
  console.log("   ✅ UserOp signed");
  console.log("");

  // === Step 7: Submit to EntryPoint ===
  console.log("🚀 Step 7: Submit to EntryPoint.handleOps()");

  try {
    const tx = await entryPoint.handleOps([packedUserOp], signer.address, {
      gasLimit: 1000000n,
    });

    console.log("\n✅ Transaction Submitted!");
    console.log("   Hash:", tx.hash);
    console.log("   Etherscan:", `https://sepolia.etherscan.io/tx/${tx.hash}`);

    console.log("\n⏳ Waiting for confirmation...");
    const receipt = await tx.wait();

    console.log("\n🎉 UserOp Executed Successfully!");
    console.log("   Block:", receipt.blockNumber);
    console.log("   Gas Used:", receipt.gasUsed.toString());

    // Check final balances
    const finalBreadBalance = await breadContract.balanceOf(SIMPLE_ACCOUNT);
    const breadSpent = breadBalance - finalBreadBalance;

    console.log("\n💰 Final Balances:");
    console.log("   Initial BREAD:", ethers.formatUnits(breadBalance, breadDecimals), breadSymbol);
    console.log("   Final BREAD:", ethers.formatUnits(finalBreadBalance, breadDecimals), breadSymbol);
    console.log("   BREAD Spent (gas):", ethers.formatUnits(breadSpent, breadDecimals), breadSymbol);

    console.log("\n╔════════════════════════════════════════════════════════════════╗");
    console.log("║               ✅ PAYMASTER V4.1 TEST SUCCESS                   ║");
    console.log("╚════════════════════════════════════════════════════════════════╝");

  } catch (error) {
    console.error("\n❌ Transaction Failed:");
    console.error("   Error:", error.message);
    if (error.data) {
      console.error("   Data:", error.data);
    }

    console.log("\n╔════════════════════════════════════════════════════════════════╗");
    console.log("║                  ❌ TEST FAILED                                ║");
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

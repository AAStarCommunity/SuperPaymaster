require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

// This script submits UserOp directly via EntryPoint using PaymasterV4
// PaymasterV4 uses direct payment mode without Settlement contract

const ENTRYPOINT =
  process.env.ENTRYPOINT_V07 || "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const SIMPLE_ACCOUNT = "0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D";
const PAYMASTER_V4 = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
const PNT_TOKEN =
  process.env.GAS_TOKEN_ADDRESS ||
  "0x090e34709a592210158aa49a969e4a04e3a29ebd";
const OWNER_PRIVATE_KEY = process.env.PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;
const RECIPIENT = "0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA";

const EntryPointABI = [
  "function handleOps((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature)[] ops, address payable beneficiary) external",
  "function getUserOpHash((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp) external view returns (bytes32)",
];

const SimpleAccountABI = [
  "function execute(address dest, uint256 value, bytes calldata func) external",
  "function getNonce() public view returns (uint256)",
];

const ERC20ABI = [
  "function transfer(address to, uint256 amount) external returns (bool)",
  "function balanceOf(address) external view returns (uint256)",
  "function allowance(address owner, address spender) external view returns (uint256)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

  console.log("=== Submit UserOp via EntryPoint (PaymasterV4) ===\n");
  console.log("Signer:", signer.address);
  console.log("SimpleAccount:", SIMPLE_ACCOUNT);
  console.log("PaymasterV4:", PAYMASTER_V4);

  const entryPoint = new ethers.Contract(ENTRYPOINT, EntryPointABI, signer);
  const accountContract = new ethers.Contract(
    SIMPLE_ACCOUNT,
    SimpleAccountABI,
    provider,
  );
  const pntContract = new ethers.Contract(PNT_TOKEN, ERC20ABI, provider);

  // Check PNT balance and allowance
  const pntBalance = await pntContract.balanceOf(SIMPLE_ACCOUNT);
  const pntAllowance = await pntContract.allowance(SIMPLE_ACCOUNT, PAYMASTER_V4);
  console.log("PNT Balance:", ethers.formatUnits(pntBalance, 18));
  console.log("PNT Allowance:", ethers.formatUnits(pntAllowance, 18));

  if (pntBalance < ethers.parseUnits("10", 18)) {
    console.error("❌ Insufficient PNT balance (need >= 10 PNT)");
    process.exit(1);
  }

  if (pntAllowance < ethers.parseUnits("10", 18)) {
    console.error("❌ Insufficient PNT allowance (need >= 10 PNT approved to PaymasterV4)");
    process.exit(1);
  }

  // Get nonce
  const nonce = await accountContract.getNonce();
  console.log("Nonce:", nonce.toString());

  // Construct calldata: transfer 0.5 PNT
  const transferAmount = ethers.parseUnits("0.5", 18);
  const transferCalldata = pntContract.interface.encodeFunctionData(
    "transfer",
    [RECIPIENT, transferAmount],
  );
  const executeCalldata = accountContract.interface.encodeFunctionData(
    "execute",
    [PNT_TOKEN, 0, transferCalldata],
  );

  // Gas limits
  const callGasLimit = 100000n;
  const verificationGasLimit = 300000n;
  const preVerificationGas = 100000n;
  const maxPriorityFeePerGas = ethers.parseUnits("0.1", "gwei");
  const latestBlock = await provider.getBlock("latest");
  const baseFeePerGas =
    latestBlock.baseFeePerGas || ethers.parseUnits("0.001", "gwei");
  const maxFeePerGas =
    baseFeePerGas + maxPriorityFeePerGas + ethers.parseUnits("0.001", "gwei");

  console.log("\nGas Configuration:");
  console.log("- callGasLimit:", callGasLimit.toString());
  console.log("- verificationGasLimit:", verificationGasLimit.toString());
  console.log("- preVerificationGas:", preVerificationGas.toString());
  console.log("- maxFeePerGas:", ethers.formatUnits(maxFeePerGas, "gwei"), "gwei");
  console.log("- maxPriorityFeePerGas:", ethers.formatUnits(maxPriorityFeePerGas, "gwei"), "gwei");

  // Pack gas limits
  const accountGasLimits = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(verificationGasLimit), 16),
    ethers.zeroPadValue(ethers.toBeHex(callGasLimit), 16),
  ]);

  const gasFees = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(maxPriorityFeePerGas), 16),
    ethers.zeroPadValue(ethers.toBeHex(maxFeePerGas), 16),
  ]);

  // PaymasterV4 paymasterAndData format:
  // [0:20]  paymaster address (20 bytes)
  // [20:36] paymasterVerificationGasLimit (16 bytes)
  // [36:52] paymasterPostOpGasLimit (16 bytes)
  // [52:72] userSpecifiedGasToken (20 bytes) - optional, can be zero address for auto-select
  const paymasterAndData = ethers.concat([
    PAYMASTER_V4,                                       // paymaster address (20 bytes)
    ethers.zeroPadValue(ethers.toBeHex(200000n), 16), // paymasterVerificationGasLimit (16 bytes)
    ethers.zeroPadValue(ethers.toBeHex(100000n), 16), // paymasterPostOpGasLimit (16 bytes) - reduced for V4 (no Settlement)
    PNT_TOKEN,                                         // userSpecifiedGasToken (20 bytes) - use PNT
  ]);

  console.log("\nPaymasterAndData:");
  console.log("- Length:", paymasterAndData.length, "bytes");
  console.log("- Paymaster:", PAYMASTER_V4);
  console.log("- VerificationGasLimit: 200000");
  console.log("- PostOpGasLimit: 100000");
  console.log("- UserSpecifiedGasToken:", PNT_TOKEN);
  console.log("- Full paymasterAndData:", paymasterAndData);

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

  // Get userOpHash and sign
  const userOpHash = await entryPoint.getUserOpHash(packedUserOp);
  console.log("\nUserOpHash:", userOpHash);

  const signingKey = new ethers.SigningKey(OWNER_PRIVATE_KEY);
  const signature = signingKey.sign(userOpHash).serialized;
  packedUserOp.signature = signature;
  console.log("Signature:", signature);

  // Submit via handleOps
  console.log("\nSubmitting UserOp via EntryPoint.handleOps...");
  try {
    const tx = await entryPoint.handleOps([packedUserOp], signer.address, {
      gasLimit: 1000000n, // Set high gas limit for safety
    });
    console.log("✅ Transaction submitted!");
    console.log("Transaction hash:", tx.hash);
    console.log("Sepolia Etherscan:", `https://sepolia.etherscan.io/tx/${tx.hash}`);

    console.log("\nWaiting for confirmation...");
    const receipt = await tx.wait();
    console.log("✅ UserOp executed! Block:", receipt.blockNumber);
    console.log("Gas used:", receipt.gasUsed.toString());
    console.log("Status:", receipt.status === 1 ? "Success" : "Failed");

    // Check final balance
    const finalBalance = await pntContract.balanceOf(SIMPLE_ACCOUNT);
    console.log("\nFinal PNT Balance:", ethers.formatUnits(finalBalance, 18));
    console.log("PNT Spent:", ethers.formatUnits(pntBalance - finalBalance, 18));
  } catch (error) {
    console.error("\n❌ Transaction failed:");
    console.error(error.message);
    if (error.data) {
      console.error("Error data:", error.data);
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

require("dotenv").config();
const { ethers } = require("ethers");

/**
 * Final PaymasterV4 test with actual PNT transfer
 */

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const SIMPLE_ACCOUNT = process.env.SIMPLE_ACCOUNT_B || "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";
const PAYMASTER_V4 = "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38";
const BREAD_TOKEN = "0x22e7951ae23755FB31bfcE0067f47597Ca8093a5"; // GasTokenV2 (BREAD v2)
const PNT_TOKEN = process.env.PNT_TOKEN_ADDRESS || "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
const RECIPIENT = process.env.OWNER2_ADDRESS || "0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA";

const OWNER_PRIVATE_KEY = process.env.OWNER_PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

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
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║       Final PaymasterV4 Test with PNT Transfer               ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  console.log("Signer:", signer.address);
  console.log("SimpleAccount:", SIMPLE_ACCOUNT);
  console.log("PaymasterV4:", PAYMASTER_V4);
  console.log("BREAD v2:", BREAD_TOKEN);
  console.log("PNT:", PNT_TOKEN);
  console.log("Recipient:", RECIPIENT);
  console.log("");

  const entryPoint = new ethers.Contract(ENTRYPOINT, EntryPointABI, signer);
  const accountContract = new ethers.Contract(SIMPLE_ACCOUNT, SimpleAccountABI, provider);
  const pntContract = new ethers.Contract(PNT_TOKEN, ERC20ABI, provider);

  // Get nonce
  const nonce = await entryPoint.getNonce(SIMPLE_ACCOUNT, 0);
  console.log("Nonce:", nonce.toString());

  // Construct callData - Transfer 0.1 PNT
  const transferAmount = ethers.parseUnits("0.1", 18);
  console.log("Transfer Amount:", ethers.formatUnits(transferAmount, 18), "PNT\n");

  const transferCalldata = pntContract.interface.encodeFunctionData("transfer", [
    RECIPIENT,
    transferAmount,
  ]);

  const callData = accountContract.interface.encodeFunctionData("execute", [
    PNT_TOKEN,
    0,
    transferCalldata,
  ]);

  // Gas config
  const callGasLimit = 100000n;
  const verificationGasLimit = 300000n;
  const preVerificationGas = 100000n;
  const maxPriorityFeePerGas = ethers.parseUnits("0.1", "gwei");

  const latestBlock = await provider.getBlock("latest");
  const baseFeePerGas = latestBlock.baseFeePerGas || ethers.parseUnits("0.001", "gwei");
  const maxFeePerGas = baseFeePerGas + maxPriorityFeePerGas;

  console.log("maxFeePerGas:", ethers.formatUnits(maxFeePerGas, "gwei"), "gwei\n");

  // Pack gas limits (v0.7 format)
  const accountGasLimits = ethers.solidityPacked(
    ["uint128", "uint128"],
    [verificationGasLimit, callGasLimit]
  );

  const gasFees = ethers.solidityPacked(
    ["uint128", "uint128"],
    [maxPriorityFeePerGas, maxFeePerGas]
  );

  // PaymasterAndData with BREAD token
  const paymasterAndData = ethers.solidityPacked(
    ["address", "uint128", "uint128", "address"],
    [
      PAYMASTER_V4,
      100000n, // pmVerifyGas
      100000n, // pmPostOpGas
      BREAD_TOKEN, // gasToken
    ]
  );

  // Build UserOp
  const userOp = {
    sender: SIMPLE_ACCOUNT,
    nonce,
    initCode: "0x",
    callData,
    accountGasLimits,
    preVerificationGas,
    gasFees,
    paymasterAndData,
    signature: "0x",
  };

  // Get UserOp hash
  const userOpHash = await entryPoint.getUserOpHash(userOp);
  console.log("UserOpHash:", userOpHash);

  // Sign with SigningKey (no prefix)
  const signingKey = new ethers.SigningKey(OWNER_PRIVATE_KEY);
  const signature = signingKey.sign(userOpHash).serialized;
  userOp.signature = signature;

  console.log("Signature:", signature.slice(0, 20) + "...\n");

  // Submit
  console.log("🚀 Submitting to EntryPoint...\n");

  try {
    const tx = await entryPoint.handleOps([userOp], signer.address, {
      gasLimit: 3000000n,
    });

    console.log("✅ Transaction Submitted!");
    console.log("   Hash:", tx.hash);
    console.log("   Etherscan: https://sepolia.etherscan.io/tx/" + tx.hash);

    console.log("\n⏳ Waiting for confirmation...\n");
    const receipt = await tx.wait();

    console.log("╔════════════════════════════════════════════════════════════════╗");
    console.log("║                  ✅ TEST PASSED                                ║");
    console.log("╚════════════════════════════════════════════════════════════════╝");
    console.log("\nGas used:", receipt.gasUsed.toString());
    console.log("\n📊 PaymasterV4 successfully processed gas payment with BREAD!");
  } catch (error) {
    console.log("╔════════════════════════════════════════════════════════════════╗");
    console.log("║                  ❌ TEST FAILED                                ║");
    console.log("╚════════════════════════════════════════════════════════════════╝\n");
    console.error("❌ Transaction Failed:");
    console.error("   Error:", error.message.split('\n')[0]);

    if (error.receipt) {
      console.error("   Gas used:", error.receipt.gasUsed.toString());
      console.error("   Transaction:", error.receipt.hash);
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

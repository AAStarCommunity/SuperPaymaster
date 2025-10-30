require("dotenv").config();
const { ethers } = require("ethers");

/**
 * Use EntryPoint.simulateValidation to debug UserOp issues
 */

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const SIMPLE_ACCOUNT = process.env.SIMPLE_ACCOUNT_B || "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";
const PAYMASTER_V4 = "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38";
const BREAD_TOKEN = "0x13da8229f5ca3e1Ab2be3c010BBBb5dbAed85621";

const OWNER_PRIVATE_KEY = process.env.OWNER_PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

const EntryPointABI = [
  "function simulateValidation((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp) external",
  "function getNonce(address sender, uint192 key) external view returns (uint256 nonce)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║            Simulate UserOp Validation                         ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  const entryPoint = new ethers.Contract(ENTRYPOINT, EntryPointABI, provider);
  const entryPointWithSigner = entryPoint.connect(signer);

  // Get nonce
  const nonce = await entryPoint.getNonce(SIMPLE_ACCOUNT, 0);
  console.log("Nonce:", nonce.toString());

  // Empty callData
  const callData = "0x";

  // Gas config
  const callGasLimit = 50000n;
  const verificationGasLimit = 300000n;
  const preVerificationGas = 50000n;
  const maxPriorityFeePerGas = ethers.parseUnits("0.1", "gwei");

  const latestBlock = await provider.getBlock("latest");
  const baseFeePerGas = latestBlock.baseFeePerGas || ethers.parseUnits("0.001", "gwei");
  const maxFeePerGas = baseFeePerGas + maxPriorityFeePerGas;

  // Pack gas limits
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
    signature: "0x", // Empty signature for simulation
  };

  console.log("\n📦 UserOp:");
  console.log("   sender:", userOp.sender);
  console.log("   nonce:", userOp.nonce.toString());
  console.log("   callData:", userOp.callData);
  console.log("   paymasterAndData length:", paymasterAndData.length, "chars");
  console.log("");

  // Simulate validation
  console.log("🔍 Simulating validation...\n");

  try {
    const result = await entryPointWithSigner.simulateValidation.staticCall(userOp);
    console.log("✅ Validation Successful!");
    console.log(result);
  } catch (error) {
    console.log("❌ Validation Failed\n");
    console.error("Error message:", error.message);

    // Try to decode revert reason
    if (error.data) {
      console.log("\nRevert data:", error.data);

      // Try to extract AA error code
      const aaErrorMatch = error.message.match(/AA\d+/);
      if (aaErrorMatch) {
        console.log("\n🔴 AA Error Code:", aaErrorMatch[0]);
      }
    }

    // Full error for debugging
    console.log("\n📋 Full error:");
    console.log(JSON.stringify(error, null, 2));
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

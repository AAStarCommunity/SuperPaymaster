require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

// This script submits UserOp directly via EntryPoint instead of bundler
// to bypass Alchemy's gas efficiency policy

const ENTRYPOINT =
  process.env.ENTRYPOINT_V07 || "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const SIMPLE_ACCOUNT = "0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D";
const PAYMASTER =
  process.env.PAYMASTER_V3_ADDRESS ||
  process.env.PAYMASTER_V3 ||
  "0x4D66379b88Ff32dFf8325e7aa877fdB4A4E2599C";
const PNT_TOKEN =
  process.env.GAS_TOKEN_ADDRESS ||
  process.env.PNTS_TOKEN ||
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
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

  console.log("=== Submit UserOp via EntryPoint Directly ===\n");
  console.log("Signer:", signer.address);
  console.log("SimpleAccount:", SIMPLE_ACCOUNT);

  const entryPoint = new ethers.Contract(ENTRYPOINT, EntryPointABI, signer);
  const accountContract = new ethers.Contract(
    SIMPLE_ACCOUNT,
    SimpleAccountABI,
    provider,
  );
  const pntContract = new ethers.Contract(PNT_TOKEN, ERC20ABI, provider);

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

  // Pack gas limits
  const accountGasLimits = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(verificationGasLimit), 16),
    ethers.zeroPadValue(ethers.toBeHex(callGasLimit), 16),
  ]);

  const gasFees = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(maxPriorityFeePerGas), 16),
    ethers.zeroPadValue(ethers.toBeHex(maxFeePerGas), 16),
  ]);

  const paymasterAndData = ethers.concat([
    PAYMASTER,
    ethers.zeroPadValue(ethers.toBeHex(200000n), 16), // paymasterVerificationGasLimit
    ethers.zeroPadValue(ethers.toBeHex(300000n), 16), // paymasterPostOpGasLimit (increased for Settlement.recordGasFee)
    "0x", // paymasterData
  ]);

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
  console.log("UserOpHash:", userOpHash);

  const signingKey = new ethers.SigningKey(OWNER_PRIVATE_KEY);
  const signature = signingKey.sign(userOpHash).serialized;
  packedUserOp.signature = signature;
  console.log("Signature:", signature, "\n");

  // Submit via handleOps
  console.log("Submitting UserOp via EntryPoint.handleOps...");
  const tx = await entryPoint.handleOps([packedUserOp], signer.address, {
    gasLimit: 1000000n, // Set high gas limit for safety
  });
  console.log("Transaction hash:", tx.hash);

  const receipt = await tx.wait();
  console.log("✅ UserOp executed! Block:", receipt.blockNumber);
  console.log("Gas used:", receipt.gasUsed.toString());
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

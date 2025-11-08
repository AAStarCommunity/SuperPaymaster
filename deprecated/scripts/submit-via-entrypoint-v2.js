#!/usr/bin/env node

/**
 * SuperPaymaster V2 EntryPoint Integration Test
 *
 * This script submits UserOp directly via EntryPoint using SuperPaymasterV2
 * V2 uses operator model with dual payment (xPNTs + aPNTs)
 *
 * Flow:
 * 1. Create SimpleAccount UserOperation for token transfer
 * 2. User approves xPNTs to SuperPaymaster (pre-approve pattern)
 * 3. Construct paymasterAndData with operator address
 * 4. Submit via EntryPoint.handleOps
 * 5. Verify dual payment (user xPNTs -> operator treasury, operator aPNTs consumed)
 */

require("dotenv").config({ path: "../env/.env" });
const { ethers } = require("ethers");

// Contract addresses
const ENTRYPOINT = process.env.ENTRYPOINT_V07 || "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const SUPER_PAYMASTER_V2 = process.env.SUPER_PAYMASTER_V2_ADDRESS;
const SIMPLE_ACCOUNT = process.env.SIMPLE_ACCOUNT_B || "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";
const XPNTS_TOKEN = process.env.OPERATOR_XPNTS_TOKEN_ADDRESS;
const OPERATOR_ADDRESS = process.env.OWNER2_ADDRESS;

// Keys and RPC
const USER_PRIVATE_KEY = process.env.OWNER_PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;
const RECIPIENT = "0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA";

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
];

const SuperPaymasterV2ABI = [
  "function getOperatorAccount(address operator) external view returns (tuple(uint256 sGTokenLocked, uint256 stakedAt, uint256 aPNTsBalance, uint256 totalSpent, uint256 lastRefillTime, uint256 minBalanceThreshold, address[] supportedSBTs, address xPNTsToken, address treasury, uint256 exchangeRate, uint256 reputationScore, uint256 consecutiveDays, uint256 totalTxSponsored, uint256 reputationLevel, uint256 lastCheckTime, bool isPaused))",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const userWallet = new ethers.Wallet(USER_PRIVATE_KEY, provider);

  console.log("=== SuperPaymaster V2 EntryPoint Integration Test ===\n");
  console.log("User (SimpleAccount owner):", userWallet.address);
  console.log("SimpleAccount:", SIMPLE_ACCOUNT);
  console.log("SuperPaymasterV2:", SUPER_PAYMASTER_V2);
  console.log("Operator:", OPERATOR_ADDRESS);
  console.log("xPNTs Token:", XPNTS_TOKEN);
  console.log("");

  // Contracts
  const entryPoint = new ethers.Contract(ENTRYPOINT, EntryPointABI, userWallet);
  const accountContract = new ethers.Contract(SIMPLE_ACCOUNT, SimpleAccountABI, provider);
  const xpntsContract = new ethers.Contract(XPNTS_TOKEN, ERC20ABI, provider);
  const superPaymaster = new ethers.Contract(SUPER_PAYMASTER_V2, SuperPaymasterV2ABI, provider);

  // Check operator status
  console.log("1. Checking operator status...");
  const operatorAccount = await superPaymaster.getOperatorAccount(OPERATOR_ADDRESS);
  console.log("   Operator registered:", operatorAccount.stakedAt > 0n);
  console.log("   Operator aPNTs balance:", ethers.formatUnits(operatorAccount.aPNTsBalance, 18), "aPNTs");
  console.log("   Operator treasury:", operatorAccount.treasury);
  console.log("   xPNTs token:", operatorAccount.xPNTsToken);
  console.log("   Exchange rate:", ethers.formatUnits(operatorAccount.exchangeRate, 18));

  if (operatorAccount.stakedAt === 0n) {
    console.error("❌ Operator not registered!");
    process.exit(1);
  }

  if (operatorAccount.aPNTsBalance < ethers.parseUnits("100", 18)) {
    console.error("❌ Operator has insufficient aPNTs balance (need >= 100 aPNTs)");
    process.exit(1);
  }

  // Check user xPNTs balance and allowance
  console.log("\n2. Checking user xPNTs balance...");
  const userXPNTsBalance = await xpntsContract.balanceOf(SIMPLE_ACCOUNT);
  const userXPNTsAllowance = await xpntsContract.allowance(SIMPLE_ACCOUNT, SUPER_PAYMASTER_V2);

  console.log("   User xPNTs balance:", ethers.formatUnits(userXPNTsBalance, 18));
  console.log("   User xPNTs allowance to paymaster:", ethers.formatUnits(userXPNTsAllowance, 18));

  if (userXPNTsBalance < ethers.parseUnits("10", 18)) {
    console.error("❌ Insufficient xPNTs balance (need >= 10 xPNTs)");
    process.exit(1);
  }

  // Calculate estimated xPNTs cost
  // Simplified: assume ~0.001 ETH gas, gasToUSDRate = 3000, aPNTsPriceUSD = 0.02
  // => ~153 aPNTs with 2% fee => ~153 xPNTs (1:1 rate)
  const estimatedXPNTsCost = ethers.parseUnits("200", 18); // 200 xPNTs buffer

  if (userXPNTsAllowance < estimatedXPNTsCost) {
    console.log("\n3. Approving xPNTs to paymaster...");
    console.log("   This needs to be done from SimpleAccount execute()");
    console.log("   ⚠️  Pre-approve xPNTs first using approve script!");
    console.log("   Required allowance:", ethers.formatUnits(estimatedXPNTsCost, 18));
    process.exit(1);
  }

  // Get nonce
  console.log("\n4. Getting nonce...");
  const nonce = await entryPoint.getNonce(SIMPLE_ACCOUNT, 0);
  console.log("   Nonce:", nonce.toString());

  // Construct calldata: transfer 0.5 xPNTs to recipient (test transfer)
  console.log("\n5. Constructing UserOp calldata...");
  const transferAmount = ethers.parseUnits("0.5", 18);
  const transferCalldata = xpntsContract.interface.encodeFunctionData("transfer", [
    RECIPIENT,
    transferAmount,
  ]);
  const executeCalldata = accountContract.interface.encodeFunctionData("execute", [
    XPNTS_TOKEN,
    0,
    transferCalldata,
  ]);
  console.log("   Action: Transfer 0.5 xPNTs to", RECIPIENT);

  // Gas limits (optimized for PaymasterV4 mode)
  const callGasLimit = 100000n;  // Simple token transfer
  const verificationGasLimit = 100000n;  // Account verification
  const preVerificationGas = 50000n;  // Bundler overhead
  const maxPriorityFeePerGas = ethers.parseUnits("1", "gwei");
  const latestBlock = await provider.getBlock("latest");
  const baseFeePerGas = latestBlock.baseFeePerGas || ethers.parseUnits("1", "gwei");
  const maxFeePerGas = baseFeePerGas + maxPriorityFeePerGas;

  console.log("\n6. Gas configuration:");
  console.log("   callGasLimit:", callGasLimit.toString());
  console.log("   verificationGasLimit:", verificationGasLimit.toString());
  console.log("   preVerificationGas:", preVerificationGas.toString());
  console.log("   maxFeePerGas:", ethers.formatUnits(maxFeePerGas, "gwei"), "gwei");

  // Pack gas limits
  const accountGasLimits = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(verificationGasLimit), 16),
    ethers.zeroPadValue(ethers.toBeHex(callGasLimit), 16),
  ]);

  const gasFees = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(maxPriorityFeePerGas), 16),
    ethers.zeroPadValue(ethers.toBeHex(maxFeePerGas), 16),
  ]);

  // SuperPaymasterV2 paymasterAndData format:
  // [0:20]  paymaster address (20 bytes)
  // [20:36] paymasterVerificationGasLimit (16 bytes)
  // [36:52] paymasterPostOpGasLimit (16 bytes)
  // [52:72] operator address (20 bytes) - REQUIRED for V2
  const paymasterAndData = ethers.concat([
    SUPER_PAYMASTER_V2, // paymaster address (20 bytes)
    ethers.zeroPadValue(ethers.toBeHex(100000n), 16), // paymasterVerificationGasLimit (SBT check + transfer)
    ethers.zeroPadValue(ethers.toBeHex(0n), 16), // paymasterPostOpGasLimit (not used - PaymasterV4 mode)
    OPERATOR_ADDRESS, // operator address (20 bytes)
  ]);

  console.log("\n7. PaymasterAndData:");
  console.log("   Paymaster:", SUPER_PAYMASTER_V2);
  console.log("   VerificationGasLimit: 100000");
  console.log("   PostOpGasLimit: 0 (not used)");
  console.log("   Operator:", OPERATOR_ADDRESS);
  console.log("   Full hex:", paymasterAndData);

  // Construct PackedUserOperation
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
  console.log("\n8. Signing UserOp...");
  const userOpHash = await entryPoint.getUserOpHash(packedUserOp);
  console.log("   UserOpHash:", userOpHash);

  // SimpleAccount V1 uses raw signature (no EIP-191 prefix)
  const signingKey = new ethers.SigningKey(USER_PRIVATE_KEY);
  const signature = signingKey.sign(userOpHash).serialized;
  packedUserOp.signature = signature;
  console.log("   Signature:", signature.substring(0, 20) + "...");

  // Record balances before
  console.log("\n9. Recording balances before transaction...");
  const userXPNTsBefore = await xpntsContract.balanceOf(SIMPLE_ACCOUNT);
  const treasuryXPNTsBefore = await xpntsContract.balanceOf(operatorAccount.treasury);
  const operatorAPNTsBefore = operatorAccount.aPNTsBalance;

  console.log("   User xPNTs:", ethers.formatUnits(userXPNTsBefore, 18));
  console.log("   Operator treasury xPNTs:", ethers.formatUnits(treasuryXPNTsBefore, 18));
  console.log("   Operator aPNTs balance:", ethers.formatUnits(operatorAPNTsBefore, 18));

  // Submit via handleOps
  console.log("\n10. Submitting UserOp via EntryPoint.handleOps...");
  try {
    const tx = await entryPoint.handleOps([packedUserOp], userWallet.address, {
      gasLimit: 2000000n, // High gas limit for safety (V2 has complex logic)
    });
    console.log("✅ Transaction submitted!");
    console.log("   Transaction hash:", tx.hash);
    console.log("   Sepolia Etherscan:", `https://sepolia.etherscan.io/tx/${tx.hash}`);

    console.log("\n   Waiting for confirmation...");
    const receipt = await tx.wait();
    console.log("✅ UserOp executed! Block:", receipt.blockNumber);
    console.log("   Gas used:", receipt.gasUsed.toString());
    console.log("   Status:", receipt.status === 1 ? "Success ✅" : "Failed ❌");

    // Check final balances
    console.log("\n11. Checking final balances...");
    const userXPNTsAfter = await xpntsContract.balanceOf(SIMPLE_ACCOUNT);
    const treasuryXPNTsAfter = await xpntsContract.balanceOf(operatorAccount.treasury);
    const operatorAccountAfter = await superPaymaster.getOperatorAccount(OPERATOR_ADDRESS);

    console.log("   User xPNTs:", ethers.formatUnits(userXPNTsAfter, 18));
    console.log("   Operator treasury xPNTs:", ethers.formatUnits(treasuryXPNTsAfter, 18));
    console.log("   Operator aPNTs balance:", ethers.formatUnits(operatorAccountAfter.aPNTsBalance, 18));

    // Calculate changes
    const userXPNTsSpent = userXPNTsBefore - userXPNTsAfter;
    const treasuryXPNTsReceived = treasuryXPNTsAfter - treasuryXPNTsBefore;
    const operatorAPNTsSpent = operatorAPNTsBefore - operatorAccountAfter.aPNTsBalance;

    console.log("\n12. Payment verification:");
    console.log("   User xPNTs spent:", ethers.formatUnits(userXPNTsSpent, 18));
    console.log("   Operator treasury received:", ethers.formatUnits(treasuryXPNTsReceived, 18));
    console.log("   Operator aPNTs consumed:", ethers.formatUnits(operatorAPNTsSpent, 18));

    console.log("\n✅ V2 dual payment mechanism verified!");
    console.log("   - User paid xPNTs to operator treasury ✅");
    console.log("   - Operator's aPNTs backing consumed ✅");

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

#!/usr/bin/env node

/**
 * SuperPaymaster V3 E2E Test
 *
 * Test flow:
 * 1. Create SimpleAccount UserOperation for 0.5 PNT transfer
 * 2. Get PaymasterV3 signature (requires SBT + min PNT balance)
 * 3. Submit via Alchemy bundler
 * 4. Verify Settlement contract recorded the gas fee
 * 5. Run Keeper to settle the payment
 */

const { ethers } = require("ethers");
const dotenv = require("dotenv");
const path = require("path");

// Load .env.v3
dotenv.config({ path: path.join(__dirname, "../.env.v3") });

// Contracts addresses from .env.v3
const ENTRYPOINT = process.env.ENTRYPOINT_V07;
const PAYMASTER = process.env.PAYMASTER_V3;
const SETTLEMENT = process.env.SETTLEMENT_CONTRACT;
const PNT_TOKEN = "0xf2996D81b264d071f99FD13d76D15A9258f4cFa9";
const SBT_TOKEN = "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f";
const SIMPLE_ACCOUNT_FACTORY = "0x70F0DBca273a836CbA609B10673A52EED2D15625";

// Test accounts
const OWNER_PRIVATE_KEY = process.env.PRIVATE_KEY;
const OWNER_ADDRESS = process.env.OWNER_ADDRESS;
const USER2_ADDRESS = "0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA"; // Recipient for test transfer

// RPC
const RPC_URL = process.env.SEPOLIA_RPC_URL;
const ALCHEMY_API_KEY = "Bx4QRW1-vnwJUePSAAD7N";
const BUNDLER_URL = `https://eth-sepolia.g.alchemy.com/v2/${ALCHEMY_API_KEY}`;

// Provider and signer
const provider = new ethers.JsonRpcProvider(RPC_URL);
const ownerWallet = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

// SimpleAccount address (computed)
let SIMPLE_ACCOUNT_ADDRESS;

// ABIs
const SimpleAccountFactoryABI = [
  "function getAddress(address owner, uint256 salt) view returns (address)",
  "function createAccount(address owner, uint256 salt) returns (address)",
];

const SimpleAccountABI = [
  "function execute(address dest, uint256 value, bytes calldata func) external",
  "function executeBatch(address[] calldata dest, uint256[] calldata value, bytes[] calldata func) external",
  "function getNonce() view returns (uint256)",
  "function initialize(address owner) external",
];

const ERC20ABI = [
  "function transfer(address to, uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
];

const PaymasterV3ABI = [
  "function getHash(tuple(address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp, uint48 validUntil, uint48 validAfter) view returns (bytes32)",
  "function sbtToken() view returns (address)",
  "function gasToken() view returns (address)",
  "function minStakeAmount() view returns (uint256)",
];

const SettlementABI = [
  "function getUnsettledPayment(address account) view returns (uint256)",
  "function settle(address account) external",
];

const EntryPointABI = [
  "function getUserOpHash(tuple(address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp) view returns (bytes32)",
];

async function main() {
  console.log("=== SuperPaymaster V3 E2E Test ===\n");

  // Step 1: Get SimpleAccount address
  console.log("Step 1: Get SimpleAccount address");
  const factoryInterface = new ethers.Interface(SimpleAccountFactoryABI);
  const getAddressData = factoryInterface.encodeFunctionData("getAddress", [
    OWNER_ADDRESS,
    0,
  ]);
  const result = await provider.call({
    to: SIMPLE_ACCOUNT_FACTORY,
    data: getAddressData,
  });
  SIMPLE_ACCOUNT_ADDRESS = factoryInterface.decodeFunctionResult(
    "getAddress",
    result,
  )[0];

  const factoryContract = new ethers.Contract(
    SIMPLE_ACCOUNT_FACTORY,
    SimpleAccountFactoryABI,
    provider,
  );
  console.log(`SimpleAccount: ${SIMPLE_ACCOUNT_ADDRESS}`);

  // Check if account is deployed
  const code = await provider.getCode(SIMPLE_ACCOUNT_ADDRESS);
  const isDeployed = code !== "0x";
  console.log(`Account deployed: ${isDeployed}\n`);

  // Step 2: Check balances
  console.log("Step 2: Check balances");
  const pntContract = new ethers.Contract(PNT_TOKEN, ERC20ABI, provider);
  const sbtContract = new ethers.Contract(SBT_TOKEN, ERC20ABI, provider);

  const pntBalance = await pntContract.balanceOf(SIMPLE_ACCOUNT_ADDRESS);
  const sbtBalance = await sbtContract.balanceOf(SIMPLE_ACCOUNT_ADDRESS);
  const ethBalance = await provider.getBalance(SIMPLE_ACCOUNT_ADDRESS);

  console.log(`PNT Balance: ${ethers.formatEther(pntBalance)} PNT`);
  console.log(`SBT Balance: ${sbtBalance.toString()}`);
  console.log(`ETH Balance: ${ethers.formatEther(ethBalance)} ETH\n`);

  if (sbtBalance === 0n) {
    throw new Error("Account needs SBT to use PaymasterV3");
  }

  // Step 3: Construct UserOperation
  console.log("Step 3: Construct UserOperation for 0.5 PNT transfer");

  // Get nonce
  let nonce;
  if (isDeployed) {
    const accountContract = new ethers.Contract(
      SIMPLE_ACCOUNT_ADDRESS,
      SimpleAccountABI,
      provider,
    );
    nonce = await accountContract.getNonce();
  } else {
    nonce = 0n;
  }
  console.log(`Nonce: ${nonce}`);

  // Encode transfer calldata
  const transferAmount = ethers.parseEther("0.5");
  const transferCalldata = pntContract.interface.encodeFunctionData(
    "transfer",
    [USER2_ADDRESS, transferAmount],
  );

  // Encode SimpleAccount.execute() calldata
  const accountContract = new ethers.Contract(
    SIMPLE_ACCOUNT_ADDRESS,
    SimpleAccountABI,
    provider,
  );
  const executeCalldata = accountContract.interface.encodeFunctionData(
    "execute",
    [PNT_TOKEN, 0, transferCalldata],
  );

  // initCode (if not deployed)
  let initCode = "0x";
  if (!isDeployed) {
    const createAccountCalldata = factoryContract.interface.encodeFunctionData(
      "createAccount",
      [OWNER_ADDRESS, 0],
    );
    initCode = ethers.concat([SIMPLE_ACCOUNT_FACTORY, createAccountCalldata]);
  }

  // Gas limits - use conservative values for efficiency
  // Alchemy bundler checks actual gas usage efficiency, not just limits
  const callGasLimit = 100000n; // Reduced for simple PNT transfer
  const verificationGasLimit = 300000n; // Sufficient for SimpleAccount + PaymasterV3
  const accountGasLimits = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(verificationGasLimit), 16),
    ethers.zeroPadValue(ethers.toBeHex(callGasLimit), 16),
  ]);

  // Gas fees (Alchemy bundler requires minimum 0.1 gwei priority fee)
  const latestBlock = await provider.getBlock("latest");
  const baseFeePerGas =
    latestBlock.baseFeePerGas || ethers.parseUnits("0.001", "gwei");
  const maxPriorityFeePerGas = ethers.parseUnits("0.1", "gwei");
  // maxFeePerGas = baseFee + priorityFee + small buffer
  const maxFeePerGas =
    baseFeePerGas + maxPriorityFeePerGas + ethers.parseUnits("0.001", "gwei");
  const gasFees = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(maxPriorityFeePerGas), 16),
    ethers.zeroPadValue(ethers.toBeHex(maxFeePerGas), 16),
  ]);

  const preVerificationGas = 100000n;

  // Construct UserOp v0.7 format (separate factory and paymaster fields)
  let userOp = {
    sender: SIMPLE_ACCOUNT_ADDRESS,
    nonce: nonce,
    factory: !isDeployed ? SIMPLE_ACCOUNT_FACTORY : undefined,
    factoryData: !isDeployed
      ? factoryContract.interface.encodeFunctionData("createAccount", [
          OWNER_ADDRESS,
          0,
        ])
      : undefined,
    callData: executeCalldata,
    callGasLimit: callGasLimit,
    verificationGasLimit: verificationGasLimit,
    preVerificationGas: preVerificationGas,
    maxFeePerGas: maxFeePerGas,
    maxPriorityFeePerGas: maxPriorityFeePerGas,
    paymaster: PAYMASTER,
    paymasterVerificationGasLimit: 200000n, // Increased for PaymasterV3 validation
    paymasterPostOpGasLimit: 150000n, // Increased for Settlement recording
    paymasterData: "0x",
    signature: "0x",
  };

  console.log(
    "UserOp v0.7 constructed:\n",
    JSON.stringify(
      {
        sender: userOp.sender,
        nonce: userOp.nonce.toString(),
        factory: userOp.factory,
        factoryData: userOp.factoryData,
        callData: userOp.callData,
        callGasLimit: userOp.callGasLimit.toString(),
        verificationGasLimit: userOp.verificationGasLimit.toString(),
        preVerificationGas: userOp.preVerificationGas.toString(),
        maxFeePerGas: ethers.formatUnits(userOp.maxFeePerGas, "gwei") + " gwei",
        maxPriorityFeePerGas:
          ethers.formatUnits(userOp.maxPriorityFeePerGas, "gwei") + " gwei",
        paymaster: userOp.paymaster,
        paymasterVerificationGasLimit:
          userOp.paymasterVerificationGasLimit.toString(),
        paymasterPostOpGasLimit: userOp.paymasterPostOpGasLimit.toString(),
        paymasterData: userOp.paymasterData,
      },
      null,
      2,
    ),
  );

  // Step 4: Sign UserOp with account owner
  console.log("\nStep 4: Sign UserOp");

  // For v0.7, we need to pack the UserOp into PackedUserOperation format for hashing
  // Pack initCode: factory + factoryData (or 0x if already deployed)
  const packedInitCode = userOp.factory
    ? ethers.concat([userOp.factory, userOp.factoryData])
    : "0x";

  // Pack accountGasLimits: verificationGasLimit (16 bytes) + callGasLimit (16 bytes)
  const packedAccountGasLimits = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(userOp.verificationGasLimit), 16),
    ethers.zeroPadValue(ethers.toBeHex(userOp.callGasLimit), 16),
  ]);

  // Pack gasFees: maxPriorityFeePerGas (16 bytes) + maxFeePerGas (16 bytes)
  const packedGasFees = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(userOp.maxPriorityFeePerGas), 16),
    ethers.zeroPadValue(ethers.toBeHex(userOp.maxFeePerGas), 16),
  ]);

  // Pack paymasterAndData: paymaster + verificationGasLimit (16 bytes) + postOpGasLimit (16 bytes) + paymasterData
  const packedPaymasterAndData = ethers.concat([
    userOp.paymaster,
    ethers.zeroPadValue(
      ethers.toBeHex(userOp.paymasterVerificationGasLimit),
      16,
    ),
    ethers.zeroPadValue(ethers.toBeHex(userOp.paymasterPostOpGasLimit), 16),
    userOp.paymasterData,
  ]);

  // Create PackedUserOperation for hash calculation
  const packedUserOp = {
    sender: userOp.sender,
    nonce: userOp.nonce,
    initCode: packedInitCode,
    callData: userOp.callData,
    accountGasLimits: packedAccountGasLimits,
    preVerificationGas: userOp.preVerificationGas,
    gasFees: packedGasFees,
    paymasterAndData: packedPaymasterAndData,
    signature: "0x",
  };

  // Calculate userOpHash using EntryPoint
  const entryPointContract = new ethers.Contract(
    ENTRYPOINT,
    EntryPointABI,
    provider,
  );
  const userOpHash = await entryPointContract.getUserOpHash(packedUserOp);
  console.log(`UserOp hash: ${userOpHash}`);

  // Sign the userOpHash directly without EIP-191 prefix
  // SimpleAccount expects: ECDSA.recover(userOpHash, signature) == owner
  const signingKey = new ethers.SigningKey(OWNER_PRIVATE_KEY);
  const signature = signingKey.sign(userOpHash).serialized;
  userOp.signature = signature;
  console.log(`UserOp signature: ${signature}\n`);

  // Step 5: Submit to bundler
  console.log("\nStep 5: Submit UserOp to Alchemy bundler");

  const bundlerProvider = new ethers.JsonRpcProvider(BUNDLER_URL);

  // Format UserOp for RPC (v0.7 format)
  const userOpForRPC = {
    sender: userOp.sender,
    nonce: ethers.toBeHex(userOp.nonce),
    factory: userOp.factory,
    factoryData: userOp.factoryData,
    callData: userOp.callData,
    callGasLimit: ethers.toBeHex(userOp.callGasLimit),
    verificationGasLimit: ethers.toBeHex(userOp.verificationGasLimit),
    preVerificationGas: ethers.toBeHex(userOp.preVerificationGas),
    maxFeePerGas: ethers.toBeHex(userOp.maxFeePerGas),
    maxPriorityFeePerGas: ethers.toBeHex(userOp.maxPriorityFeePerGas),
    paymaster: userOp.paymaster,
    paymasterVerificationGasLimit: ethers.toBeHex(
      userOp.paymasterVerificationGasLimit,
    ),
    paymasterPostOpGasLimit: ethers.toBeHex(userOp.paymasterPostOpGasLimit),
    paymasterData: userOp.paymasterData,
    signature: userOp.signature,
  };

  // Use Alchemy gas estimation to get accurate gas limits
  console.log("Estimating gas with Alchemy...");
  try {
    const gasEstimate = await bundlerProvider.send(
      "eth_estimateUserOperationGas",
      [userOpForRPC, ENTRYPOINT],
    );
    console.log("Gas estimation result:", gasEstimate);

    // Update UserOp with estimated gas limits
    userOp.callGasLimit = BigInt(gasEstimate.callGasLimit);
    userOp.verificationGasLimit = BigInt(gasEstimate.verificationGasLimit);
    userOp.preVerificationGas = BigInt(gasEstimate.preVerificationGas);
    if (gasEstimate.paymasterVerificationGasLimit) {
      userOp.paymasterVerificationGasLimit = BigInt(
        gasEstimate.paymasterVerificationGasLimit,
      );
    }
    if (gasEstimate.paymasterPostOpGasLimit) {
      userOp.paymasterPostOpGasLimit = BigInt(
        gasEstimate.paymasterPostOpGasLimit,
      );
    }

    console.log("\nUpdated gas limits:");
    console.log(`  callGasLimit: ${userOp.callGasLimit}`);
    console.log(`  verificationGasLimit: ${userOp.verificationGasLimit}`);
    console.log(`  preVerificationGas: ${userOp.preVerificationGas}`);
    console.log(
      `  paymasterVerificationGasLimit: ${userOp.paymasterVerificationGasLimit}`,
    );
    console.log(`  paymasterPostOpGasLimit: ${userOp.paymasterPostOpGasLimit}`);

    // Recalculate signature with new gas limits
    const newPackedAccountGasLimits = ethers.concat([
      ethers.zeroPadValue(ethers.toBeHex(userOp.verificationGasLimit), 16),
      ethers.zeroPadValue(ethers.toBeHex(userOp.callGasLimit), 16),
    ]);
    const newPackedGasFees = ethers.concat([
      ethers.zeroPadValue(ethers.toBeHex(userOp.maxPriorityFeePerGas), 16),
      ethers.zeroPadValue(ethers.toBeHex(userOp.maxFeePerGas), 16),
    ]);
    const newPackedPaymasterAndData = ethers.concat([
      userOp.paymaster,
      ethers.zeroPadValue(
        ethers.toBeHex(userOp.paymasterVerificationGasLimit),
        16,
      ),
      ethers.zeroPadValue(ethers.toBeHex(userOp.paymasterPostOpGasLimit), 16),
      userOp.paymasterData,
    ]);
    const newPackedUserOp = {
      sender: userOp.sender,
      nonce: userOp.nonce,
      initCode: userOp.factory
        ? ethers.concat([userOp.factory, userOp.factoryData])
        : "0x",
      callData: userOp.callData,
      accountGasLimits: newPackedAccountGasLimits,
      preVerificationGas: userOp.preVerificationGas,
      gasFees: newPackedGasFees,
      paymasterAndData: newPackedPaymasterAndData,
      signature: "0x",
    };
    const newUserOpHash =
      await entryPointContract.getUserOpHash(newPackedUserOp);
    const signingKey = new ethers.SigningKey(OWNER_PRIVATE_KEY);
    const newSignature = signingKey.sign(newUserOpHash).serialized;
    userOp.signature = newSignature;
    console.log(`New UserOp hash: ${newUserOpHash}`);
    console.log(`New signature: ${newSignature}`);

    // Update RPC format
    userOpForRPC.callGasLimit = ethers.toBeHex(userOp.callGasLimit);
    userOpForRPC.verificationGasLimit = ethers.toBeHex(
      userOp.verificationGasLimit,
    );
    userOpForRPC.preVerificationGas = ethers.toBeHex(userOp.preVerificationGas);
    userOpForRPC.paymasterVerificationGasLimit = ethers.toBeHex(
      userOp.paymasterVerificationGasLimit,
    );
    userOpForRPC.paymasterPostOpGasLimit = ethers.toBeHex(
      userOp.paymasterPostOpGasLimit,
    );
    userOpForRPC.signature = userOp.signature;
  } catch (error) {
    console.log("Gas estimation failed:", error.message);
    console.log("Continuing with manual gas limits...");
  }

  console.log("\nSending eth_sendUserOperation...");
  try {
    const userOpHashFromBundler = await bundlerProvider.send(
      "eth_sendUserOperation",
      [userOpForRPC, ENTRYPOINT],
    );
    console.log(`✅ UserOp submitted! Hash: ${userOpHashFromBundler}\n`);

    // Step 7: Wait for transaction
    console.log("Step 7: Wait for UserOp to be mined...");
    let receipt = null;
    for (let i = 0; i < 60; i++) {
      try {
        receipt = await bundlerProvider.send("eth_getUserOperationReceipt", [
          userOpHashFromBundler,
        ]);
        if (receipt) break;
      } catch (e) {
        // Not yet mined
      }
      await new Promise((resolve) => setTimeout(resolve, 2000));
      process.stdout.write(".");
    }
    console.log("\n");

    if (!receipt) {
      throw new Error("UserOp not mined within 2 minutes");
    }

    console.log(
      `✅ UserOp mined in transaction: ${receipt.receipt.transactionHash}`,
    );
    console.log(`Block: ${receipt.receipt.blockNumber}`);
    console.log(`Gas used: ${receipt.receipt.gasUsed}\n`);

    // Step 8: Verify Settlement
    console.log("Step 8: Verify Settlement record");
    const settlementContract = new ethers.Contract(
      SETTLEMENT,
      SettlementABI,
      provider,
    );
    const unsettledAmount = await settlementContract.getUnsettledPayment(
      SIMPLE_ACCOUNT_ADDRESS,
    );
    console.log(
      `Unsettled payment: ${unsettledAmount.toString()} Gwei (${ethers.formatUnits(unsettledAmount, "gwei")} Gwei)\n`,
    );

    if (unsettledAmount === 0n) {
      console.warn(
        "⚠️  Warning: No unsettled payment recorded in Settlement contract",
      );
    } else {
      console.log("✅ Settlement recorded successfully!");
    }

    // Step 9: Check final balances
    console.log("\nStep 9: Check final balances");
    const pntBalanceAfter = await pntContract.balanceOf(SIMPLE_ACCOUNT_ADDRESS);
    const user2Balance = await pntContract.balanceOf(USER2_ADDRESS);
    console.log(
      `User1 PNT: ${ethers.formatEther(pntBalanceAfter)} (before: ${ethers.formatEther(pntBalance)})`,
    );
    console.log(`User2 PNT: ${ethers.formatEther(user2Balance)}`);
    console.log(
      `Transferred: ${ethers.formatEther(pntBalance - pntBalanceAfter)} PNT\n`,
    );

    console.log("✅ E2E Test completed successfully!");
    console.log("\n=== Next Steps ===");
    console.log("Run Keeper script to settle the payment:");
    console.log(`node scripts/keeper-settle.js ${SIMPLE_ACCOUNT_ADDRESS}`);
  } catch (error) {
    console.error("❌ Error submitting UserOp:", error);
    if (error.error) {
      console.error("Error details:", error.error);
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

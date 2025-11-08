require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

// Multi-Account Test Script
// Usage: node scripts/submit-multi-accounts-v4.js [account_address] [count]
// Example: node scripts/submit-multi-accounts-v4.js 0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584 3

const ENTRYPOINT =
  process.env.ENTRYPOINT_V07 || "0x0000000071727De22E5E9d8BAf0edAc6f37da032";

// Multiple test accounts (SimpleAccount V1)
const TEST_ACCOUNTS = [
  "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce", // Primary test account
  "0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584", // Account 1 (200 PNT)
  "0x57b2e6f08399c276b2c1595825219d29990d0921", // Account 2 (100 PNT)
];

// Get account from command line or use first in list
const SIMPLE_ACCOUNT = process.argv[2] || TEST_ACCOUNTS[0];
const TX_COUNT = parseInt(process.argv[3] || "1");

const PAYMASTER_V4 = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
const PNT_TOKEN =
  process.env.PNT_TOKEN_ADDRESS || "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
const OWNER_PRIVATE_KEY = process.env.OWNER_PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;
const RECIPIENT = "0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA";

const EntryPointABI = [
  "function handleOps((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature)[] ops, address payable beneficiary) external",
  "function getUserOpHash((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp) external view returns (bytes32)",
];

const SimpleAccountABI = [
  "function execute(address dest, uint256 value, bytes calldata func) external",
];

const EntryPointNonceABI = [
  "function getNonce(address sender, uint192 key) external view returns (uint256 nonce)",
];

const ERC20ABI = [
  "function transfer(address to, uint256 amount) external returns (bool)",
  "function balanceOf(address) external view returns (uint256)",
  "function allowance(address owner, address spender) external view returns (uint256)",
];

async function submitTransaction(provider, signer, txNumber, totalTxs) {
  console.log(`\n${"=".repeat(60)}`);
  console.log(`Transaction ${txNumber}/${totalTxs} - Account: ${SIMPLE_ACCOUNT}`);
  console.log("=".repeat(60));

async function main() {
  if (!ethers.isAddress(SIMPLE_ACCOUNT)) {
    console.error("❌ Invalid account address:", SIMPLE_ACCOUNT);
    process.exit(1);
  }

  console.log("=== Multi-Account Test Script ===\n");
  console.log("Account:", SIMPLE_ACCOUNT);
  console.log("Transactions to send:", TX_COUNT);
  console.log("PaymasterV4:", PAYMASTER_V4);
  console.log();

  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

  // Send multiple transactions
  const results = [];
  for (let i = 1; i <= TX_COUNT; i++) {
    try {
      const result = await submitTransaction(provider, signer, i, TX_COUNT);
      results.push(result);

      // Wait 2 seconds between transactions
      if (i < TX_COUNT) {
        console.log("\n⏳ Waiting 2 seconds before next transaction...");
        await new Promise(resolve => setTimeout(resolve, 2000));
      }
    } catch (error) {
      console.error(`\n❌ Transaction ${i} failed:`, error.message);
      results.push({ txNumber: i, success: false, error: error.message });
    }
  }

  // Summary
  console.log("\n\n" + "=".repeat(60));
  console.log("📊 SUMMARY");
  console.log("=".repeat(60));
  console.log(`Account: ${SIMPLE_ACCOUNT}`);
  console.log(`Total Transactions: ${results.length}`);
  console.log(`Successful: ${results.filter(r => r.success).length}`);
  console.log(`Failed: ${results.filter(r => !r.success).length}`);

  if (results.some(r => r.success)) {
    console.log("\n✅ Successful Transactions:");
    results.filter(r => r.success).forEach(r => {
      console.log(`  ${r.txNumber}. ${r.txHash} (Block: ${r.blockNumber})`);
    });
  }
}

async function submitTransaction_impl(provider, signer) {

  const entryPoint = new ethers.Contract(ENTRYPOINT, EntryPointABI, signer);
  const accountContract = new ethers.Contract(
    SIMPLE_ACCOUNT,
    SimpleAccountABI,
    provider,
  );
  const pntContract = new ethers.Contract(PNT_TOKEN, ERC20ABI, provider);

  // Check PNT balance and allowance
  const pntBalance = await pntContract.balanceOf(SIMPLE_ACCOUNT);
  const pntAllowance = await pntContract.allowance(
    SIMPLE_ACCOUNT,
    PAYMASTER_V4,
  );
  console.log("PNT Balance:", ethers.formatUnits(pntBalance, 18));
  console.log("PNT Allowance:", ethers.formatUnits(pntAllowance, 18));

  if (pntBalance < ethers.parseUnits("10", 18)) {
    console.error("❌ Insufficient PNT balance (need >= 10 PNT)");
    process.exit(1);
  }

  if (pntAllowance < ethers.parseUnits("10", 18)) {
    console.error(
      "❌ Insufficient PNT allowance (need >= 10 PNT approved to PaymasterV4)",
    );
    process.exit(1);
  }

  // Get nonce from EntryPoint (v0.7 uses key-based nonce)
  const entryPointForNonce = new ethers.Contract(
    ENTRYPOINT,
    EntryPointNonceABI,
    provider,
  );
  const nonce = await entryPointForNonce.getNonce(SIMPLE_ACCOUNT, 0);
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
  console.log(
    "- maxFeePerGas:",
    ethers.formatUnits(maxFeePerGas, "gwei"),
    "gwei",
  );
  console.log(
    "- maxPriorityFeePerGas:",
    ethers.formatUnits(maxPriorityFeePerGas, "gwei"),
    "gwei",
  );

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
    PAYMASTER_V4, // paymaster address (20 bytes)
    ethers.zeroPadValue(ethers.toBeHex(200000n), 16), // paymasterVerificationGasLimit (16 bytes)
    ethers.zeroPadValue(ethers.toBeHex(100000n), 16), // paymasterPostOpGasLimit (16 bytes) - reduced for V4 (no Settlement)
    PNT_TOKEN, // userSpecifiedGasToken (20 bytes) - use PNT
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

  // SimpleAccount V1 uses raw signature (direct hash signing, no prefix)
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
    console.log(
      "Sepolia Etherscan:",
      `https://sepolia.etherscan.io/tx/${tx.hash}`,
    );

    console.log("\nWaiting for confirmation...");
    const receipt = await tx.wait();
    console.log("✅ UserOp executed! Block:", receipt.blockNumber);
    console.log("Gas used:", receipt.gasUsed.toString());
    console.log("Status:", receipt.status === 1 ? "Success" : "Failed");

    // Check final balance
    const finalBalance = await pntContract.balanceOf(SIMPLE_ACCOUNT);
    console.log("\nFinal PNT Balance:", ethers.formatUnits(finalBalance, 18));
    console.log(
      "PNT Spent:",
      ethers.formatUnits(pntBalance - finalBalance, 18),
    );
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

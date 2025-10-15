require("dotenv").config({ path: "../env/.env" });
const { ethers } = require("ethers");

/**
 * Send test transactions for 4 accounts to generate Paymaster analytics data
 * Usage: node scripts/send-test-transactions.js
 */

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const PAYMASTER_V4 = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
const PNT_TOKEN = "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
const OWNER_PRIVATE_KEY = process.env.OWNER_PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;
const RECIPIENT = "0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA";

// 4 Test accounts to send transactions
const TEST_ACCOUNTS = [
  "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce", // TEST_AA_ACCOUNT_ADDRESS_C
  "0xc06D99e32c6BAE8FFCb2C269Fe76B34fE6547F61", // TEST_AA_ACCOUNT_ADDRESS_1
  "0x60D70Cb25A0d412F4C01B723dD676d9B2237b997", // TEST_AA_ACCOUNT_ADDRESS_2
  "0x552257eb48685b694EEF5532Dd4DC6bfA61eD81A", // TEST_AA_ACCOUNT_ADDRESS_3
];

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

async function sendTransaction(provider, signer, accountAddress, accountIndex) {
  console.log(`\n${"=".repeat(70)}`);
  console.log(`📤 Account ${accountIndex + 1}/4: ${accountAddress}`);
  console.log("=".repeat(70));

  const entryPoint = new ethers.Contract(ENTRYPOINT, EntryPointABI, signer);
  const accountContract = new ethers.Contract(
    accountAddress,
    SimpleAccountABI,
    provider,
  );
  const pntContract = new ethers.Contract(PNT_TOKEN, ERC20ABI, provider);

  // Check PNT balance and allowance
  const pntBalance = await pntContract.balanceOf(accountAddress);
  const pntAllowance = await pntContract.allowance(accountAddress, PAYMASTER_V4);

  console.log("💰 PNT Balance:", ethers.formatUnits(pntBalance, 18), "PNT");
  console.log("✅ PNT Allowance:", ethers.formatUnits(pntAllowance, 18), "PNT");

  if (pntBalance < ethers.parseUnits("10", 18)) {
    console.error("❌ Insufficient PNT balance (need >= 10 PNT)");
    return { success: false, error: "Insufficient balance" };
  }

  if (pntAllowance < ethers.parseUnits("10", 18)) {
    console.error("❌ Insufficient PNT allowance (need >= 10 PNT approved)");
    return { success: false, error: "Insufficient allowance" };
  }

  // Get nonce
  const nonce = await entryPoint.getNonce(accountAddress, 0);
  console.log("🔢 Nonce:", nonce.toString());

  // Construct calldata: transfer 0.5 PNT
  const transferAmount = ethers.parseUnits("0.5", 18);
  const transferCalldata = pntContract.interface.encodeFunctionData("transfer", [
    RECIPIENT,
    transferAmount,
  ]);
  const executeCalldata = accountContract.interface.encodeFunctionData("execute", [
    PNT_TOKEN,
    0,
    transferCalldata,
  ]);

  // Gas configuration
  const callGasLimit = 100000n;
  const verificationGasLimit = 300000n;
  const preVerificationGas = 100000n;
  const maxPriorityFeePerGas = ethers.parseUnits("0.1", "gwei");
  const latestBlock = await provider.getBlock("latest");
  const baseFeePerGas = latestBlock.baseFeePerGas || ethers.parseUnits("0.001", "gwei");
  const maxFeePerGas = baseFeePerGas + maxPriorityFeePerGas + ethers.parseUnits("0.001", "gwei");

  // Pack gas limits
  const accountGasLimits = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(verificationGasLimit), 16),
    ethers.zeroPadValue(ethers.toBeHex(callGasLimit), 16),
  ]);

  const gasFees = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(maxPriorityFeePerGas), 16),
    ethers.zeroPadValue(ethers.toBeHex(maxFeePerGas), 16),
  ]);

  // PaymasterAndData
  const paymasterAndData = ethers.concat([
    PAYMASTER_V4,
    ethers.zeroPadValue(ethers.toBeHex(200000n), 16),
    ethers.zeroPadValue(ethers.toBeHex(100000n), 16),
    PNT_TOKEN,
  ]);

  const packedUserOp = {
    sender: accountAddress,
    nonce: nonce,
    initCode: "0x",
    callData: executeCalldata,
    accountGasLimits: accountGasLimits,
    preVerificationGas: preVerificationGas,
    gasFees: gasFees,
    paymasterAndData: paymasterAndData,
    signature: "0x",
  };

  // Sign UserOp
  const userOpHash = await entryPoint.getUserOpHash(packedUserOp);
  const signingKey = new ethers.SigningKey(OWNER_PRIVATE_KEY);
  const signature = signingKey.sign(userOpHash).serialized;
  packedUserOp.signature = signature;

  console.log("📝 UserOpHash:", userOpHash);

  // Submit transaction
  console.log("\n🚀 Submitting UserOp via EntryPoint.handleOps...");
  try {
    const tx = await entryPoint.handleOps([packedUserOp], signer.address, {
      gasLimit: 1000000n,
    });

    console.log("✅ Transaction submitted!");
    console.log("📦 Tx Hash:", tx.hash);
    console.log("🔗 Etherscan:", `https://sepolia.etherscan.io/tx/${tx.hash}`);

    console.log("\n⏳ Waiting for confirmation...");
    const receipt = await tx.wait();

    console.log("✅ UserOp executed!");
    console.log("📍 Block:", receipt.blockNumber);
    console.log("⛽ Gas used:", receipt.gasUsed.toString());

    // Check final balance
    const finalBalance = await pntContract.balanceOf(accountAddress);
    const pntSpent = pntBalance - finalBalance;

    console.log("\n💵 PNT Analysis:");
    console.log("  - Initial:", ethers.formatUnits(pntBalance, 18), "PNT");
    console.log("  - Final:", ethers.formatUnits(finalBalance, 18), "PNT");
    console.log("  - Spent:", ethers.formatUnits(pntSpent, 18), "PNT");

    return {
      success: true,
      txHash: tx.hash,
      blockNumber: receipt.blockNumber,
      gasUsed: receipt.gasUsed.toString(),
      pntSpent: ethers.formatUnits(pntSpent, 18),
    };
  } catch (error) {
    console.error("\n❌ Transaction failed:", error.message);
    return { success: false, error: error.message };
  }
}

async function main() {
  console.log("=".repeat(70));
  console.log("🎯 Send Test Transactions for Paymaster Analytics");
  console.log("=".repeat(70));
  console.log("📋 Paymaster:", PAYMASTER_V4);
  console.log("🪙 Gas Token:", PNT_TOKEN);
  console.log("👥 Accounts:", TEST_ACCOUNTS.length);
  console.log();

  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

  const results = [];

  // Send transaction for each account
  for (let i = 0; i < TEST_ACCOUNTS.length; i++) {
    try {
      const result = await sendTransaction(provider, signer, TEST_ACCOUNTS[i], i);
      results.push({
        account: TEST_ACCOUNTS[i],
        ...result,
      });

      // Wait 3 seconds between transactions
      if (i < TEST_ACCOUNTS.length - 1) {
        console.log("\n⏳ Waiting 3 seconds before next transaction...\n");
        await new Promise((resolve) => setTimeout(resolve, 3000));
      }
    } catch (error) {
      console.error(`\n❌ Account ${i + 1} failed:`, error.message);
      results.push({
        account: TEST_ACCOUNTS[i],
        success: false,
        error: error.message,
      });
    }
  }

  // Print summary
  console.log("\n\n" + "=".repeat(70));
  console.log("📊 SUMMARY");
  console.log("=".repeat(70));
  console.log(`✅ Successful: ${results.filter((r) => r.success).length}/${results.length}`);
  console.log(`❌ Failed: ${results.filter((r) => !r.success).length}/${results.length}`);

  if (results.some((r) => r.success)) {
    console.log("\n✅ Successful Transactions:");
    results
      .filter((r) => r.success)
      .forEach((r, i) => {
        console.log(`\n${i + 1}. Account: ${r.account.slice(0, 10)}...${r.account.slice(-8)}`);
        console.log(`   Tx: ${r.txHash}`);
        console.log(`   Block: ${r.blockNumber}`);
        console.log(`   Gas: ${r.gasUsed}`);
        console.log(`   PNT Spent: ${r.pntSpent}`);
      });
  }

  if (results.some((r) => !r.success)) {
    console.log("\n❌ Failed Transactions:");
    results
      .filter((r) => !r.success)
      .forEach((r, i) => {
        console.log(`\n${i + 1}. Account: ${r.account}`);
        console.log(`   Error: ${r.error}`);
      });
  }

  console.log("\n" + "=".repeat(70));
  console.log("🎉 Test transactions completed!");
  console.log("🔗 View analytics: http://localhost:5173/analytics");
  console.log(`🔗 Paymaster detail: http://localhost:5173/paymaster/${PAYMASTER_V4}`);
  console.log("=".repeat(70));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

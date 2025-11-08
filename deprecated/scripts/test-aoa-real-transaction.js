require("dotenv").config();
const { ethers } = require("ethers");

/**
 * Test real AOA mode transaction with PaymasterV4
 *
 * Architecture:
 * - PaymasterV4: Independent paymaster (AOA mode)
 * - xPNTs Token: Community gas token
 * - Gas calculation: gasCostWei → gasCostUSD → aPNTs → xPNTs
 */

// Contract Addresses (from .env)
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const PAYMASTER_V4 = process.env.PAYMASTER_V4_ADDRESS || "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
const XPNTS_FACTORY = process.env.XPNTS_FACTORY_ADDRESS || "0xC2AFEA0F736403E7e61D3F7C7c6b4E5E63B5cab6";

// Test accounts
const SIMPLE_ACCOUNT = process.env.SIMPLE_ACCOUNT_B || "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";
const RECIPIENT = process.env.OWNER2_ADDRESS || "0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA";
const OWNER_PRIVATE_KEY = process.env.OWNER_PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

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
  "function balanceOf(address account) external view returns (uint256)",
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function allowance(address owner, address spender) external view returns (uint256)",
];

const xPNTsFactoryABI = [
  "function getAPNTsPrice() external view returns (uint256)",
  "function getTokenAddress(address community) external view returns (address)",
  "function hasToken(address community) external view returns (bool)",
];

const xPNTsTokenABI = [
  "function exchangeRate() external view returns (uint256)",
  "function name() external view returns (string)",
  "function symbol() external view returns (string)",
  "function balanceOf(address account) external view returns (uint256)",
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function allowance(address owner, address spender) external view returns (uint256)",
];

async function main() {
  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║         Real AOA Mode Transaction Test                        ║");
  console.log("║         PaymasterV4 + xPNTs Token                             ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

  console.log("📋 Configuration:");
  console.log("   Signer:", signer.address);
  console.log("   SimpleAccount:", SIMPLE_ACCOUNT);
  console.log("   PaymasterV4:", PAYMASTER_V4);
  console.log("   xPNTsFactory:", XPNTS_FACTORY);
  console.log("   Recipient:", RECIPIENT);
  console.log("");

  // Initialize contracts
  const entryPoint = new ethers.Contract(ENTRYPOINT, EntryPointABI, signer);
  const accountContract = new ethers.Contract(SIMPLE_ACCOUNT, SimpleAccountABI, provider);
  const xpntsFactory = new ethers.Contract(XPNTS_FACTORY, xPNTsFactoryABI, provider);

  // Step 1: Check if operator has xPNTs token
  console.log("📊 Step 1: Check operator's xPNTs token");
  const hasToken = await xpntsFactory.hasToken(signer.address);

  if (!hasToken) {
    console.log("❌ Operator doesn't have xPNTs token deployed!");
    console.log("   Please deploy xPNTs token first via frontend:");
    console.log("   http://localhost:3001/get-xpnts");
    console.log("");
    console.log("   Or use Foundry script:");
    console.log("   forge script script/DeployOperatorXPNTsToken.s.sol --broadcast");
    return;
  }

  const xpntsTokenAddress = await xpntsFactory.getTokenAddress(signer.address);
  console.log("   ✅ xPNTs Token:", xpntsTokenAddress);

  const xpntsToken = new ethers.Contract(xpntsTokenAddress, xPNTsTokenABI, provider);
  const tokenName = await xpntsToken.name();
  const tokenSymbol = await xpntsToken.symbol();
  console.log("   Token Name:", tokenName);
  console.log("   Token Symbol:", tokenSymbol);

  // Step 2: Check xPNTs balance
  console.log("\n💰 Step 2: Check xPNTs balance");
  const xpntsBalance = await xpntsToken.balanceOf(SIMPLE_ACCOUNT);
  console.log("   SimpleAccount xPNTs balance:", ethers.formatUnits(xpntsBalance, 18), tokenSymbol);

  if (xpntsBalance === 0n) {
    console.log("   ⚠️  Warning: SimpleAccount has 0 xPNTs!");
    console.log("   Please mint some xPNTs to SimpleAccount first");
  }

  // Step 3: Check approval
  console.log("\n🔐 Step 3: Check PaymasterV4 approval");
  const allowance = await xpntsToken.allowance(SIMPLE_ACCOUNT, PAYMASTER_V4);
  console.log("   Current allowance:", ethers.formatUnits(allowance, 18), tokenSymbol);

  if (allowance === 0n) {
    console.log("   ⚠️  Warning: PaymasterV4 not approved!");
    console.log("   Note: If using AOA mode, you need to approve PaymasterV4");
    console.log("   For AOA+ mode, approval is automatic");
  }

  // Step 4: Check aPNTs price and exchange rate
  console.log("\n📈 Step 4: Check pricing");
  const aPNTsPrice = await xpntsFactory.getAPNTsPrice();
  const exchangeRate = await xpntsToken.exchangeRate();
  console.log("   aPNTs Price:", ethers.formatUnits(aPNTsPrice, 18), "USD");
  console.log("   Exchange Rate:", ethers.formatUnits(exchangeRate, 18), "(xPNTs per aPNTs)");

  // Step 5: Get nonce
  console.log("\n🔢 Step 5: Prepare UserOp");
  const nonce = await entryPoint.getNonce(SIMPLE_ACCOUNT, 0);
  console.log("   Nonce:", nonce.toString());

  // Step 6: Construct callData - Simple ETH transfer (0.001 ETH)
  const transferAmount = ethers.parseEther("0.001");
  console.log("   Action: Transfer", ethers.formatEther(transferAmount), "ETH to", RECIPIENT);

  const callData = accountContract.interface.encodeFunctionData("execute", [
    RECIPIENT,
    transferAmount,
    "0x",
  ]);

  // Step 7: Gas configuration
  console.log("\n⛽ Step 6: Configure gas");
  const callGasLimit = 100000n;
  const verificationGasLimit = 300000n;
  const preVerificationGas = 100000n;
  const maxPriorityFeePerGas = ethers.parseUnits("1", "gwei");

  const latestBlock = await provider.getBlock("latest");
  const baseFeePerGas = latestBlock.baseFeePerGas || ethers.parseUnits("1", "gwei");
  const maxFeePerGas = baseFeePerGas + maxPriorityFeePerGas;

  console.log("   callGasLimit:", callGasLimit.toString());
  console.log("   verificationGasLimit:", verificationGasLimit.toString());
  console.log("   preVerificationGas:", preVerificationGas.toString());
  console.log("   maxFeePerGas:", ethers.formatUnits(maxFeePerGas, "gwei"), "gwei");

  // Pack gas limits (v0.7 format)
  const accountGasLimits = ethers.solidityPacked(
    ["uint128", "uint128"],
    [verificationGasLimit, callGasLimit]
  );

  const gasFees = ethers.solidityPacked(
    ["uint128", "uint128"],
    [maxPriorityFeePerGas, maxFeePerGas]
  );

  // Step 8: Construct PaymasterAndData (AOA mode)
  console.log("\n🎯 Step 7: Construct PaymasterAndData (AOA mode)");
  const pmVerifyGasLimit = 200000n;
  const pmPostOpGasLimit = 100000n;

  const paymasterAndData = ethers.solidityPacked(
    ["address", "uint128", "uint128", "address"],
    [
      PAYMASTER_V4,
      pmVerifyGasLimit,
      pmPostOpGasLimit,
      xpntsTokenAddress, // Use operator's xPNTs token
    ]
  );

  console.log("   PaymasterV4:", PAYMASTER_V4);
  console.log("   pmVerifyGasLimit:", pmVerifyGasLimit.toString());
  console.log("   pmPostOpGasLimit:", pmPostOpGasLimit.toString());
  console.log("   gasToken:", xpntsTokenAddress);

  // Step 9: Build UserOp
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

  // Step 10: Sign UserOp
  console.log("\n✍️  Step 8: Sign UserOp");
  const userOpHash = await entryPoint.getUserOpHash(userOp);
  console.log("   UserOpHash:", userOpHash);

  const signingKey = new ethers.SigningKey(OWNER_PRIVATE_KEY);
  const signature = signingKey.sign(userOpHash).serialized;
  userOp.signature = signature;

  console.log("   Signature:", signature.slice(0, 20) + "...");

  // Step 11: Estimate gas cost in xPNTs
  console.log("\n💵 Step 9: Estimate gas cost");
  const totalGas = verificationGasLimit + callGasLimit + preVerificationGas + pmVerifyGasLimit + pmPostOpGasLimit;
  const gasCostWei = totalGas * maxFeePerGas;
  console.log("   Total gas:", totalGas.toString());
  console.log("   Gas cost (wei):", gasCostWei.toString());
  console.log("   Gas cost (ETH):", ethers.formatEther(gasCostWei));

  // Assuming ETH = $2000
  const ethPrice = 2000n * (10n ** 18n);
  const gasCostUSD = (gasCostWei * ethPrice) / (10n ** 18n);
  const aPNTsRequired = (gasCostUSD * (10n ** 18n)) / aPNTsPrice;
  const xPNTsRequired = (aPNTsRequired * exchangeRate) / (10n ** 18n);

  console.log("   Estimated cost (USD):", ethers.formatUnits(gasCostUSD, 18));
  console.log("   Estimated cost (aPNTs):", ethers.formatUnits(aPNTsRequired, 18));
  console.log("   Estimated cost (xPNTs):", ethers.formatUnits(xPNTsRequired, 18), tokenSymbol);

  if (xpntsBalance < xPNTsRequired) {
    console.log("\n   ⚠️  Warning: Insufficient xPNTs balance!");
    console.log("   Required:", ethers.formatUnits(xPNTsRequired, 18), tokenSymbol);
    console.log("   Balance:", ethers.formatUnits(xpntsBalance, 18), tokenSymbol);
  }

  // Step 12: Submit transaction
  console.log("\n🚀 Step 10: Submit to EntryPoint");
  console.log("   Target: handleOps([userOp], beneficiary)");
  console.log("   Beneficiary:", signer.address);
  console.log("");

  try {
    const tx = await entryPoint.handleOps([userOp], signer.address, {
      gasLimit: 3000000n,
    });

    console.log("✅ Transaction Submitted!");
    console.log("   Hash:", tx.hash);
    console.log("   Etherscan: https://sepolia.etherscan.io/tx/" + tx.hash);
    console.log("");

    console.log("⏳ Waiting for confirmation...");
    const receipt = await tx.wait();

    console.log("\n╔════════════════════════════════════════════════════════════════╗");
    console.log("║                  ✅ AOA MODE TEST PASSED                       ║");
    console.log("╚════════════════════════════════════════════════════════════════╝");
    console.log("");
    console.log("📊 Transaction Details:");
    console.log("   Status:", receipt.status === 1 ? "Success" : "Failed");
    console.log("   Block:", receipt.blockNumber);
    console.log("   Gas used:", receipt.gasUsed.toString());
    console.log("   Effective gas price:", ethers.formatUnits(receipt.gasPrice, "gwei"), "gwei");
    console.log("");
    console.log("🎉 PaymasterV4 successfully processed gas payment with xPNTs!");
    console.log("   Mode: AOA (Asset Oriented Abstraction)");
    console.log("   Token:", tokenSymbol);
    console.log("   Contract:", xpntsTokenAddress);

  } catch (error) {
    console.log("\n╔════════════════════════════════════════════════════════════════╗");
    console.log("║                  ❌ AOA MODE TEST FAILED                       ║");
    console.log("╚════════════════════════════════════════════════════════════════╝\n");
    console.error("❌ Transaction Failed:");
    console.error("   Error:", error.message.split('\n')[0]);

    if (error.data) {
      console.error("   Error data:", error.data);
    }

    if (error.receipt) {
      console.error("   Gas used:", error.receipt.gasUsed.toString());
      console.error("   Transaction:", error.receipt.hash);
    }

    console.log("\n🔍 Troubleshooting:");
    console.log("   1. Check xPNTs balance in SimpleAccount");
    console.log("   2. Ensure PaymasterV4 is approved to spend xPNTs");
    console.log("   3. Verify PaymasterV4 has ETH deposited in EntryPoint");
    console.log("   4. Check if SimpleAccount has enough ETH for the transfer");
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

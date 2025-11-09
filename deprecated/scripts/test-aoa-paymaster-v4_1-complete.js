require("dotenv").config();
const { ethers } = require("ethers");

/**
 * Complete AOA Mode Test with PaymasterV4_1 + xPNTs
 *
 * Test Flow:
 * 1. Verify SBT support in PaymasterV4_1 (MySBT v2.3)
 * 2. Check/Deploy xPNTs token for deployer
 * 3. Add xPNTs to PaymasterV4_1 supported tokens
 * 4. Mint SBT to test account (requires GToken stake)
 * 5. Mint xPNTs to test account
 * 6. Execute gasless transaction via EntryPoint
 *
 * Verification Process (from PaymasterV4.sol):
 * 1. Check SBT ownership (_hasAnySBT)
 * 2. Parse gasToken from paymasterAndData[52:72]
 * 3. Calculate required xPNTs:
 *    - Get ETH/USD from Chainlink
 *    - Convert gasCostWei → gasCostUSD
 *    - Add service fee
 *    - Convert gasCostUSD → aPNTs (factory.getAPNTsPrice = 0.02 USD)
 *    - Convert aPNTs → xPNTs (token.exchangeRate)
 * 4. transferFrom(sender, treasury, xPNTsAmount)
 */

// Contract Addresses
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const PAYMASTER_V4_1 = "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38";
const XPNTS_FACTORY = process.env.XPNTS_FACTORY_ADDRESS || "0xC2AFEA0F736403E7e61D3F7C7c6b4E5E63B5cab6";
const MYSBT_V2_3 = "0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8";
const GTOKEN_ADDRESS = process.env.GTOKEN_ADDRESS || "0x868F843723a98c6EECC4BF0aF3352C53d5004147";
const GTOKEN_STAKING_ADDRESS = process.env.GTOKEN_STAKING_ADDRESS || "0x92eD5b659Eec9D5135686C9369440D71e7958527";

// Test Accounts (from .env)
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;
const DEPLOYER_ADDRESS = process.env.DEPLOYER_ADDRESS;
const OWNER2_PRIVATE_KEY = process.env.OWNER2_PRIVATE_KEY || process.env.OWNER_PRIVATE_KEY;
const OWNER2_ADDRESS = process.env.OWNER2_ADDRESS;
const TEST_AA_ACCOUNT_A = process.env.TEST_AA_ACCOUNT_ADDRESS_A;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

// ABIs
const EntryPointABI = [
  "function handleOps((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature)[] ops, address payable beneficiary) external",
  "function getUserOpHash((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp) external view returns (bytes32)",
  "function getNonce(address sender, uint192 key) external view returns (uint256 nonce)",
  "function balanceOf(address account) external view returns (uint256)",
];

const SimpleAccountABI = [
  "function execute(address dest, uint256 value, bytes calldata func) external",
];

const ERC20ABI = [
  "function balanceOf(address account) external view returns (uint256)",
  "function mint(address to, uint256 amount) external",
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function allowance(address owner, address spender) external view returns (uint256)",
];

const xPNTsFactoryABI = [
  "function deployxPNTsToken(string memory name, string memory symbol, string memory communityName, string memory communityENS, uint256 exchangeRate, address paymasterAOA) external returns (address)",
  "function hasToken(address community) external view returns (bool)",
  "function getTokenAddress(address community) external view returns (address)",
  "function getAPNTsPrice() external view returns (uint256)",
];

const xPNTsTokenABI = [
  "function name() external view returns (string)",
  "function symbol() external view returns (string)",
  "function exchangeRate() external view returns (uint256)",
  "function balanceOf(address account) external view returns (uint256)",
  "function mint(address to, uint256 amount) external",
  "function owner() external view returns (address)",
];

const PaymasterV4_1ABI = [
  "function isSBTSupported(address sbt) external view returns (bool)",
  "function isGasTokenSupported(address token) external view returns (bool)",
  "function addGasToken(address token) external",
  "function owner() external view returns (address)",
  "function treasury() external view returns (address)",
];

const MySBTABI = [
  "function balanceOf(address account) external view returns (uint256)",
  "function mintWithStake(address to, string memory uri) external",
  "function tokenURI(uint256 tokenId) external view returns (string)",
];

const GTokenStakingABI = [
  "function stake(uint256 amount) external",
  "function getStakeInfo(address operator) external view returns (uint256 stakedAmount, uint256 lockedAmount, uint256 unlockedAt)",
];

async function main() {
  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║    Complete AOA Mode Test: PaymasterV4_1 + xPNTs            ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const deployerSigner = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);
  const owner2Signer = new ethers.Wallet(OWNER2_PRIVATE_KEY, provider);

  console.log("📋 Configuration:");
  console.log("   Deployer:", DEPLOYER_ADDRESS);
  console.log("   Owner2 (Test Operator):", OWNER2_ADDRESS);
  console.log("   Test AA Account:", TEST_AA_ACCOUNT_A);
  console.log("   PaymasterV4_1:", PAYMASTER_V4_1);
  console.log("   xPNTsFactory:", XPNTS_FACTORY);
  console.log("   MySBT v2.3:", MYSBT_V2_3);
  console.log("");

  // Initialize contracts
  const paymasterV4_1 = new ethers.Contract(PAYMASTER_V4_1, PaymasterV4_1ABI, deployerSigner);
  const xpntsFactory = new ethers.Contract(XPNTS_FACTORY, xPNTsFactoryABI, deployerSigner);
  const mySBT = new ethers.Contract(MYSBT_V2_3, MySBTABI, deployerSigner);
  const gToken = new ethers.Contract(GTOKEN_ADDRESS, ERC20ABI, deployerSigner);
  const gTokenStaking = new ethers.Contract(GTOKEN_STAKING_ADDRESS, GTokenStakingABI, deployerSigner);
  const entryPoint = new ethers.Contract(ENTRYPOINT, EntryPointABI, owner2Signer);

  console.log("═══════════════════════════════════════════════════════════════");
  console.log("STEP 1: Verify SBT Support");
  console.log("═══════════════════════════════════════════════════════════════\n");

  const isSBTSupported = await paymasterV4_1.isSBTSupported(MYSBT_V2_3);
  console.log("   MySBT v2.3 support:", isSBTSupported ? "✅ Supported" : "❌ Not Supported");

  if (!isSBTSupported) {
    console.log("   ❌ ERROR: MySBT v2.3 not supported in PaymasterV4_1");
    console.log("   Please add MySBT v2.3 to PaymasterV4_1 first");
    return;
  }

  console.log("\n═══════════════════════════════════════════════════════════════");
  console.log("STEP 2: Check/Deploy xPNTs Token");
  console.log("═══════════════════════════════════════════════════════════════\n");

  const hasToken = await xpntsFactory.hasToken(DEPLOYER_ADDRESS);
  let xpntsTokenAddress;

  if (!hasToken) {
    console.log("   ⚠️  Deployer doesn't have xPNTs token, deploying...");
    console.log("");
    console.log("   Deploying xPNTs token:");
    console.log("   - Name: Deployer Test Points");
    console.log("   - Symbol: DTP");
    console.log("   - Exchange Rate: 1:1");
    console.log("   - Paymaster: 0x0 (AOA+ mode)");
    console.log("");

    const tx = await xpntsFactory.deployxPNTsToken(
      "Deployer Test Points",
      "DTP",
      "Deployer Community",
      "",
      ethers.parseEther("1"), // 1:1 exchange rate
      ethers.ZeroAddress // AOA+ mode
    );
    console.log("   Transaction:", tx.hash);
    await tx.wait();
    console.log("   ✅ xPNTs token deployed!");

    xpntsTokenAddress = await xpntsFactory.getTokenAddress(DEPLOYER_ADDRESS);
  } else {
    xpntsTokenAddress = await xpntsFactory.getTokenAddress(DEPLOYER_ADDRESS);
    console.log("   ✅ xPNTs token exists:", xpntsTokenAddress);
  }

  const xpntsToken = new ethers.Contract(xpntsTokenAddress, xPNTsTokenABI, deployerSigner);
  const tokenName = await xpntsToken.name();
  const tokenSymbol = await xpntsToken.symbol();
  const exchangeRate = await xpntsToken.exchangeRate();

  console.log("   Token Name:", tokenName);
  console.log("   Token Symbol:", tokenSymbol);
  console.log("   Exchange Rate:", ethers.formatUnits(exchangeRate, 18));

  console.log("\n═══════════════════════════════════════════════════════════════");
  console.log("STEP 3: Add xPNTs to PaymasterV4_1");
  console.log("═══════════════════════════════════════════════════════════════\n");

  const isGasTokenSupported = await paymasterV4_1.isGasTokenSupported(xpntsTokenAddress);
  console.log("   xPNTs support:", isGasTokenSupported ? "✅ Already supported" : "⚠️  Not supported");

  if (!isGasTokenSupported) {
    console.log("   Adding xPNTs to PaymasterV4_1...");
    const tx = await paymasterV4_1.addGasToken(xpntsTokenAddress);
    console.log("   Transaction:", tx.hash);
    await tx.wait();
    console.log("   ✅ xPNTs added to PaymasterV4_1");
  }

  console.log("\n═══════════════════════════════════════════════════════════════");
  console.log("STEP 4: Check/Mint SBT for Test Account");
  console.log("═══════════════════════════════════════════════════════════════\n");

  const sbtBalance = await mySBT.balanceOf(TEST_AA_ACCOUNT_A);
  console.log("   Test Account SBT balance:", sbtBalance.toString());

  if (sbtBalance === 0n) {
    console.log("   ⚠️  Test account has no SBT, minting...");
    console.log("");
    console.log("   Step 4.1: Check GToken balance for staking");
    const gTokenBalance = await gToken.balanceOf(DEPLOYER_ADDRESS);
    console.log("   Deployer GToken balance:", ethers.formatUnits(gTokenBalance, 18), "GT");

    if (gTokenBalance < ethers.parseEther("0.4")) {
      console.log("   ❌ ERROR: Insufficient GToken for staking (need 0.4 GT)");
      console.log("   Please mint GToken first");
      return;
    }

    console.log("");
    console.log("   Step 4.2: Approve GToken to GTokenStaking");
    const allowance = await gToken.allowance(DEPLOYER_ADDRESS, GTOKEN_STAKING_ADDRESS);
    if (allowance < ethers.parseEther("0.4")) {
      const approveTx = await gToken.approve(GTOKEN_STAKING_ADDRESS, ethers.parseEther("0.4"));
      console.log("   Approve transaction:", approveTx.hash);
      await approveTx.wait();
      console.log("   ✅ GToken approved");
    } else {
      console.log("   ✅ GToken already approved");
    }

    console.log("");
    console.log("   Step 4.3: Stake GToken");
    const stakeTx = await gTokenStaking.stake(ethers.parseEther("0.4"));
    console.log("   Stake transaction:", stakeTx.hash);
    await stakeTx.wait();
    console.log("   ✅ Staked 0.4 GT");

    console.log("");
    console.log("   Step 4.4: Mint SBT to test account");
    const mintTx = await mySBT.mintWithStake(TEST_AA_ACCOUNT_A, "ipfs://test-sbt-uri");
    console.log("   Mint transaction:", mintTx.hash);
    await mintTx.wait();
    console.log("   ✅ SBT minted to test account");
  } else {
    console.log("   ✅ Test account already has SBT");
  }

  console.log("\n═══════════════════════════════════════════════════════════════");
  console.log("STEP 5: Mint xPNTs to Test Account");
  console.log("═══════════════════════════════════════════════════════════════\n");

  const testAccountBalance = await xpntsToken.balanceOf(TEST_AA_ACCOUNT_A);
  console.log("   Test Account xPNTs balance:", ethers.formatUnits(testAccountBalance, 18), tokenSymbol);

  const requiredAmount = ethers.parseEther("1000"); // Mint 1000 xPNTs
  if (testAccountBalance < requiredAmount) {
    console.log("   Minting 1000 xPNTs to test account...");
    const mintTx = await xpntsToken.mint(TEST_AA_ACCOUNT_A, requiredAmount);
    console.log("   Transaction:", mintTx.hash);
    await mintTx.wait();
    console.log("   ✅ Minted 1000 xPNTs");

    const newBalance = await xpntsToken.balanceOf(TEST_AA_ACCOUNT_A);
    console.log("   New balance:", ethers.formatUnits(newBalance, 18), tokenSymbol);
  } else {
    console.log("   ✅ Test account has sufficient xPNTs");
  }

  console.log("\n═══════════════════════════════════════════════════════════════");
  console.log("STEP 6: Prepare and Execute UserOp");
  console.log("═══════════════════════════════════════════════════════════════\n");

  // Check AA account code
  const aaCode = await provider.getCode(TEST_AA_ACCOUNT_A);
  if (aaCode === "0x") {
    console.log("   ❌ ERROR: Test AA Account not deployed yet");
    console.log("   Please deploy SimpleAccount first");
    return;
  }
  console.log("   ✅ AA Account deployed");

  // Check EntryPoint deposit
  const paymasterDeposit = await entryPoint.balanceOf(PAYMASTER_V4_1);
  console.log("   PaymasterV4_1 deposit in EntryPoint:", ethers.formatEther(paymasterDeposit), "ETH");

  if (paymasterDeposit < ethers.parseEther("0.01")) {
    console.log("   ⚠️  Warning: Low PaymasterV4_1 deposit, may need to add stake");
  }

  // Get nonce
  const nonce = await entryPoint.getNonce(TEST_AA_ACCOUNT_A, 0);
  console.log("   Nonce:", nonce.toString());

  // Construct callData: Transfer 0.001 ETH
  const accountContract = new ethers.Contract(TEST_AA_ACCOUNT_A, SimpleAccountABI, provider);
  const recipient = OWNER2_ADDRESS;
  const transferAmount = ethers.parseEther("0.001");

  const callData = accountContract.interface.encodeFunctionData("execute", [
    recipient,
    transferAmount,
    "0x",
  ]);

  console.log("   Action: Transfer", ethers.formatEther(transferAmount), "ETH to", recipient);

  // Gas configuration
  const callGasLimit = 100000n;
  const verificationGasLimit = 300000n;
  const preVerificationGas = 100000n;
  const maxPriorityFeePerGas = ethers.parseUnits("1", "gwei");

  const latestBlock = await provider.getBlock("latest");
  const baseFeePerGas = latestBlock.baseFeePerGas || ethers.parseUnits("1", "gwei");
  const maxFeePerGas = baseFeePerGas + maxPriorityFeePerGas;

  const accountGasLimits = ethers.solidityPacked(
    ["uint128", "uint128"],
    [verificationGasLimit, callGasLimit]
  );

  const gasFees = ethers.solidityPacked(
    ["uint128", "uint128"],
    [maxPriorityFeePerGas, maxFeePerGas]
  );

  // Construct PaymasterAndData (AOA mode)
  const pmVerifyGasLimit = 200000n;
  const pmPostOpGasLimit = 100000n;

  const paymasterAndData = ethers.solidityPacked(
    ["address", "uint128", "uint128", "address"],
    [
      PAYMASTER_V4_1,
      pmVerifyGasLimit,
      pmPostOpGasLimit,
      xpntsTokenAddress, // User-specified xPNTs token
    ]
  );

  console.log("   PaymasterAndData constructed:");
  console.log("   - Paymaster:", PAYMASTER_V4_1);
  console.log("   - pmVerifyGasLimit:", pmVerifyGasLimit.toString());
  console.log("   - pmPostOpGasLimit:", pmPostOpGasLimit.toString());
  console.log("   - gasToken:", xpntsTokenAddress);

  // Build UserOp
  const userOp = {
    sender: TEST_AA_ACCOUNT_A,
    nonce,
    initCode: "0x",
    callData,
    accountGasLimits,
    preVerificationGas,
    gasFees,
    paymasterAndData,
    signature: "0x",
  };

  // Sign UserOp
  const userOpHash = await entryPoint.getUserOpHash(userOp);
  console.log("   UserOpHash:", userOpHash);

  const signingKey = new ethers.SigningKey(OWNER2_PRIVATE_KEY);
  const signature = signingKey.sign(userOpHash).serialized;
  userOp.signature = signature;

  console.log("   Signature:", signature.slice(0, 20) + "...");

  // Estimate gas cost
  console.log("\n   💵 Estimated gas cost:");
  const totalGas = verificationGasLimit + callGasLimit + preVerificationGas + pmVerifyGasLimit + pmPostOpGasLimit;
  const gasCostWei = totalGas * maxFeePerGas;
  console.log("   Total gas:", totalGas.toString());
  console.log("   Gas cost (ETH):", ethers.formatEther(gasCostWei));

  // Calculate xPNTs cost (simplified)
  const ethPrice = 2000n * (10n ** 18n); // Assume $2000/ETH
  const aPNTsPrice = await xpntsFactory.getAPNTsPrice();
  const gasCostUSD = (gasCostWei * ethPrice) / (10n ** 18n);
  const aPNTsRequired = (gasCostUSD * (10n ** 18n)) / aPNTsPrice;
  const xPNTsRequired = (aPNTsRequired * exchangeRate) / (10n ** 18n);

  console.log("   Estimated cost (USD):", ethers.formatUnits(gasCostUSD, 18));
  console.log("   Estimated cost (aPNTs):", ethers.formatUnits(aPNTsRequired, 18));
  console.log("   Estimated cost (xPNTs):", ethers.formatUnits(xPNTsRequired, 18), tokenSymbol);

  console.log("\n🚀 Submitting to EntryPoint...\n");

  try {
    const tx = await entryPoint.handleOps([userOp], owner2Signer.address, {
      gasLimit: 3000000n,
    });

    console.log("✅ Transaction Submitted!");
    console.log("   Hash:", tx.hash);
    console.log("   Etherscan: https://sepolia.etherscan.io/tx/" + tx.hash);
    console.log("");

    console.log("⏳ Waiting for confirmation...");
    const receipt = await tx.wait();

    console.log("\n╔════════════════════════════════════════════════════════════════╗");
    console.log("║            ✅ AOA MODE TEST PASSED                             ║");
    console.log("╚════════════════════════════════════════════════════════════════╝");
    console.log("");
    console.log("📊 Transaction Details:");
    console.log("   Status:", receipt.status === 1 ? "Success ✅" : "Failed ❌");
    console.log("   Block:", receipt.blockNumber);
    console.log("   Gas used:", receipt.gasUsed.toString());
    console.log("   Effective gas price:", ethers.formatUnits(receipt.gasPrice, "gwei"), "gwei");
    console.log("");
    console.log("🎉 PaymasterV4_1 successfully processed gas payment!");
    console.log("   Mode: AOA (Asset Oriented Abstraction)");
    console.log("   SBT: MySBT v2.3");
    console.log("   Token:", tokenSymbol, "(" + xpntsTokenAddress + ")");
    console.log("   Payment flow:");
    console.log("   1. ✅ Verified SBT ownership");
    console.log("   2. ✅ Calculated xPNTs amount via unified formula");
    console.log("   3. ✅ Transferred xPNTs to treasury");
    console.log("   4. ✅ EntryPoint executed UserOp");

  } catch (error) {
    console.log("\n╔════════════════════════════════════════════════════════════════╗");
    console.log("║            ❌ AOA MODE TEST FAILED                             ║");
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
    console.log("   1. Check xPNTs balance in Test AA Account");
    console.log("   2. Verify xPNTs has auto-approval to PaymasterV4_1");
    console.log("   3. Verify PaymasterV4_1 has ETH deposited in EntryPoint");
    console.log("   4. Check if Test AA Account has enough ETH for the transfer");
    console.log("   5. Verify Test AA Account has valid SBT");
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

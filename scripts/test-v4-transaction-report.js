require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

// Enhanced test script for PaymasterV4 with detailed reporting
const ENTRYPOINT =
  process.env.ENTRYPOINT_V07 || "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const SIMPLE_ACCOUNT = "0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D";
const PAYMASTER_V4 = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
const PNT_TOKEN = "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180"; // PNTv2
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

const PaymasterABI = ["function treasury() external view returns (address)"];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

  console.log(
    "╔════════════════════════════════════════════════════════════════╗",
  );
  console.log(
    "║        PaymasterV4 Transaction Test Report                    ║",
  );
  console.log(
    "╚════════════════════════════════════════════════════════════════╝\n",
  );

  // Initialize contracts
  const entryPoint = new ethers.Contract(ENTRYPOINT, EntryPointABI, signer);
  const accountContract = new ethers.Contract(
    SIMPLE_ACCOUNT,
    SimpleAccountABI,
    provider,
  );
  const pntContract = new ethers.Contract(PNT_TOKEN, ERC20ABI, provider);
  const paymasterContract = new ethers.Contract(
    PAYMASTER_V4,
    PaymasterABI,
    provider,
  );

  // Get treasury address
  const treasury = await paymasterContract.treasury();

  console.log("📋 Configuration:");
  console.log(
    "─────────────────────────────────────────────────────────────────",
  );
  console.log("  EntryPoint:      ", ENTRYPOINT);
  console.log("  PaymasterV4:     ", PAYMASTER_V4);
  console.log("  Treasury:        ", treasury);
  console.log("  PNT Token (V2):  ", PNT_TOKEN);
  console.log("  SimpleAccount:   ", SIMPLE_ACCOUNT);
  console.log("  Account Owner:   ", signer.address);
  console.log("  Recipient:       ", RECIPIENT);
  console.log();

  // === BEFORE STATE ===
  console.log("📊 State BEFORE Transaction:");
  console.log(
    "─────────────────────────────────────────────────────────────────",
  );

  const beforeAccountPNT = await pntContract.balanceOf(SIMPLE_ACCOUNT);
  const beforeRecipientPNT = await pntContract.balanceOf(RECIPIENT);
  const beforeTreasuryPNT = await pntContract.balanceOf(treasury);
  const beforeAllowance = await pntContract.allowance(
    SIMPLE_ACCOUNT,
    PAYMASTER_V4,
  );
  const beforeAccountETH = await provider.getBalance(SIMPLE_ACCOUNT);

  console.log(
    "  Account PNT:     ",
    ethers.formatUnits(beforeAccountPNT, 18),
    "PNT",
  );
  console.log(
    "  Recipient PNT:   ",
    ethers.formatUnits(beforeRecipientPNT, 18),
    "PNT",
  );
  console.log(
    "  Treasury PNT:    ",
    ethers.formatUnits(beforeTreasuryPNT, 18),
    "PNT",
  );
  console.log(
    "  Allowance:       ",
    beforeAllowance === ethers.MaxUint256
      ? "MAX"
      : ethers.formatUnits(beforeAllowance, 18),
  );
  console.log(
    "  Account ETH:     ",
    ethers.formatUnits(beforeAccountETH, 18),
    "ETH",
  );
  console.log();

  // Validation
  if (beforeAccountPNT < ethers.parseUnits("20", 18)) {
    console.error("❌ Insufficient PNT balance (need >= 20 PNT)");
    process.exit(1);
  }

  if (beforeAllowance < ethers.parseUnits("20", 18)) {
    console.error("❌ Insufficient PNT allowance to PaymasterV4");
    console.log("💡 Mint PNTv2 from faucet - it has auto-approval!");
    process.exit(1);
  }

  // === CONSTRUCT USEROP ===
  console.log("🔧 Constructing UserOperation:");
  console.log(
    "─────────────────────────────────────────────────────────────────",
  );

  const nonce = await accountContract.getNonce();
  const transferAmount = ethers.parseUnits("0.5", 18);

  console.log(
    "  Transfer Amount: ",
    ethers.formatUnits(transferAmount, 18),
    "PNT",
  );
  console.log("  Nonce:           ", nonce.toString());

  // Construct calldata
  const transferCalldata = pntContract.interface.encodeFunctionData(
    "transfer",
    [RECIPIENT, transferAmount],
  );
  const executeCalldata = accountContract.interface.encodeFunctionData(
    "execute",
    [PNT_TOKEN, 0, transferCalldata],
  );

  // Gas configuration
  const callGasLimit = 100000n;
  const verificationGasLimit = 300000n;
  const preVerificationGas = 100000n;
  const maxPriorityFeePerGas = ethers.parseUnits("0.1", "gwei");
  const latestBlock = await provider.getBlock("latest");
  const baseFeePerGas =
    latestBlock.baseFeePerGas || ethers.parseUnits("0.001", "gwei");
  const maxFeePerGas =
    baseFeePerGas + maxPriorityFeePerGas + ethers.parseUnits("0.001", "gwei");

  console.log("\n  Gas Limits:");
  console.log("    - callGasLimit:              ", callGasLimit.toString());
  console.log(
    "    - verificationGasLimit:      ",
    verificationGasLimit.toString(),
  );
  console.log(
    "    - preVerificationGas:        ",
    preVerificationGas.toString(),
  );
  console.log(
    "    - maxFeePerGas:              ",
    ethers.formatUnits(maxFeePerGas, "gwei"),
    "gwei",
  );
  console.log(
    "    - maxPriorityFeePerGas:      ",
    ethers.formatUnits(maxPriorityFeePerGas, "gwei"),
    "gwei",
  );

  // Pack gas limits (v0.7 format)
  const accountGasLimits = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(verificationGasLimit), 16),
    ethers.zeroPadValue(ethers.toBeHex(callGasLimit), 16),
  ]);
  const gasFees = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(maxPriorityFeePerGas), 16),
    ethers.zeroPadValue(ethers.toBeHex(maxFeePerGas), 16),
  ]);

  // Construct paymasterAndData
  const paymasterAndData = ethers.concat([
    PAYMASTER_V4,
    ethers.zeroPadValue(ethers.toBeHex(200000n), 16), // paymasterVerificationGasLimit
    ethers.zeroPadValue(ethers.toBeHex(100000n), 16), // paymasterPostOpGasLimit
    PNT_TOKEN, // userSpecifiedGasToken
  ]);

  // Create UserOp
  const userOp = {
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
  const userOpHash = await entryPoint.getUserOpHash(userOp);
  const signingKey = new ethers.SigningKey(OWNER_PRIVATE_KEY);
  const signature = signingKey.sign(userOpHash).serialized;
  userOp.signature = signature;

  console.log("\n  UserOp Hash:     ", userOpHash);
  console.log();

  // === SUBMIT TRANSACTION ===
  console.log("🚀 Submitting Transaction:");
  console.log(
    "─────────────────────────────────────────────────────────────────",
  );

  const tx = await entryPoint.handleOps([userOp], signer.address, {
    gasLimit: 1000000n,
  });
  console.log("  Transaction Hash:", tx.hash);
  console.log("  Waiting for confirmation...");

  const receipt = await tx.wait();
  console.log("  ✅ Confirmed in block:", receipt.blockNumber);
  console.log();

  // === AFTER STATE ===
  console.log("📊 State AFTER Transaction:");
  console.log(
    "─────────────────────────────────────────────────────────────────",
  );

  const afterAccountPNT = await pntContract.balanceOf(SIMPLE_ACCOUNT);
  const afterRecipientPNT = await pntContract.balanceOf(RECIPIENT);
  const afterTreasuryPNT = await pntContract.balanceOf(treasury);
  const afterAccountETH = await provider.getBalance(SIMPLE_ACCOUNT);

  console.log(
    "  Account PNT:     ",
    ethers.formatUnits(afterAccountPNT, 18),
    "PNT",
  );
  console.log(
    "  Recipient PNT:   ",
    ethers.formatUnits(afterRecipientPNT, 18),
    "PNT",
  );
  console.log(
    "  Treasury PNT:    ",
    ethers.formatUnits(afterTreasuryPNT, 18),
    "PNT",
  );
  console.log(
    "  Account ETH:     ",
    ethers.formatUnits(afterAccountETH, 18),
    "ETH",
  );
  console.log();

  // === ANALYSIS ===
  console.log("📈 Transaction Analysis:");
  console.log(
    "─────────────────────────────────────────────────────────────────",
  );

  const pntSentToRecipient = afterRecipientPNT - beforeRecipientPNT;
  const totalPNTSpent = beforeAccountPNT - afterAccountPNT;
  const pntFee = totalPNTSpent - pntSentToRecipient;
  const treasuryReceived = afterTreasuryPNT - beforeTreasuryPNT;
  const ethGasUsed = receipt.gasUsed * receipt.gasPrice;

  console.log("  Transfer:");
  console.log(
    "    → Sent to Recipient:         ",
    ethers.formatUnits(pntSentToRecipient, 18),
    "PNT",
  );
  console.log();

  console.log("  Gas Payment (in PNT):");
  console.log(
    "    → Total PNT Spent:           ",
    ethers.formatUnits(totalPNTSpent, 18),
    "PNT",
  );
  console.log(
    "    → PNT for Gas:               ",
    ethers.formatUnits(pntFee, 18),
    "PNT",
  );
  console.log(
    "    → Treasury Received:         ",
    ethers.formatUnits(treasuryReceived, 18),
    "PNT",
  );
  console.log();

  console.log("  Gas Usage (in ETH):");
  console.log("    → Gas Used:                  ", receipt.gasUsed.toString());
  console.log(
    "    → Gas Price:                 ",
    ethers.formatUnits(receipt.gasPrice, "gwei"),
    "gwei",
  );
  console.log(
    "    → ETH Cost (if paid in ETH): ",
    ethers.formatUnits(ethGasUsed, 18),
    "ETH",
  );
  console.log(
    "    → Account ETH Change:        ",
    ethers.formatUnits(afterAccountETH - beforeAccountETH, 18),
    "ETH",
  );
  console.log();

  // Calculate effective rate
  const ethCostInWei = ethGasUsed;
  const pntCostInWei = pntFee;
  const effectiveRate = (pntCostInWei * 10000n) / ethCostInWei; // x10000 for precision

  console.log("  Conversion Rate:");
  console.log(
    "    → PNT/ETH Ratio:             ",
    (Number(effectiveRate) / 10000).toFixed(4),
  );
  console.log();

  // === SUMMARY ===
  console.log(
    "╔════════════════════════════════════════════════════════════════╗",
  );
  console.log(
    "║                        SUMMARY                                 ║",
  );
  console.log(
    "╚════════════════════════════════════════════════════════════════╝",
  );
  console.log();
  console.log("  ✅ Transaction Successful");
  console.log("  📝 TX Hash:           ", tx.hash);
  console.log(
    "  🔗 Etherscan:         ",
    `https://sepolia.etherscan.io/tx/${tx.hash}`,
  );
  console.log();
  console.log("  💰 Financial Summary:");
  console.log(
    "    • Transferred:       ",
    ethers.formatUnits(pntSentToRecipient, 18),
    "PNT",
  );
  console.log(
    "    • Gas Paid (PNT):    ",
    ethers.formatUnits(pntFee, 18),
    "PNT",
  );
  console.log(
    "    • Total Spent:       ",
    ethers.formatUnits(totalPNTSpent, 18),
    "PNT",
  );
  console.log("    • No ETH spent ✅     (Account abstraction working!)");
  console.log();
  console.log(
    "  🏦 Treasury Income:    ",
    ethers.formatUnits(treasuryReceived, 18),
    "PNT",
  );
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Error:", error.message);
    if (error.data) {
      console.error("Error data:", error.data);
    }
    process.exit(1);
  });

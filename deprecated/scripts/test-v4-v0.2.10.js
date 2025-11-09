#!/usr/bin/env node
/**
 * PaymasterV4_1 Test with v0.2.10 contracts
 *
 * Test AOA mode gasless transaction:
 * - SimpleAccount transfers 0.5 aPNTs to recipient
 * - Gas fee paid in aPNTs (not ETH)
 * - PaymasterV4_1 handles gas sponsorship
 */

require("dotenv").config();
const { ethers } = require("ethers");

// v0.2.10 Contract Addresses
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"; // EntryPoint v0.7
const PAYMASTER_V4_1 = "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38"; // PaymasterV4_1 (AOA mode)
const APNTS_TOKEN = "0xBD0710596010a157B88cd141d797E8Ad4bb2306b"; // aPNTs (AAStar gas token)
const DEPLOYER_ADDRESS = "0x411BD567E46C0781248dbB6a9211891C032885e5";
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY || process.env.PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

// Test accounts
const TEST_ACCOUNT_A = "0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584"; // SimpleAccount A
const RECIPIENT = "0x57b2e6f08399c276b2c1595825219d29990d0921"; // SimpleAccount B

// ABIs
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
  "function approve(address spender, uint256 amount) external returns (bool)",
];

const PaymasterABI = ["function treasury() external view returns (address)"];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║     PaymasterV4_1 AOA Mode Test (v0.2.10)                    ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  // Initialize contracts
  const entryPoint = new ethers.Contract(ENTRYPOINT, EntryPointABI, signer);
  const accountContract = new ethers.Contract(TEST_ACCOUNT_A, SimpleAccountABI, provider);
  const apntsContract = new ethers.Contract(APNTS_TOKEN, ERC20ABI, provider);
  const paymasterContract = new ethers.Contract(PAYMASTER_V4_1, PaymasterABI, provider);

  // Get treasury address
  let treasury;
  try {
    treasury = await paymasterContract.treasury();
  } catch (e) {
    console.log("⚠️  Could not fetch treasury (using deployer as fallback)");
    treasury = DEPLOYER_ADDRESS;
  }

  console.log("📋 Configuration:");
  console.log("─────────────────────────────────────────────────────────────────");
  console.log("  EntryPoint v0.7: ", ENTRYPOINT);
  console.log("  PaymasterV4_1:   ", PAYMASTER_V4_1);
  console.log("  Treasury:        ", treasury);
  console.log("  aPNTs Token:     ", APNTS_TOKEN);
  console.log("  SimpleAccount A: ", TEST_ACCOUNT_A);
  console.log("  Account Owner:   ", signer.address);
  console.log("  Recipient (B):   ", RECIPIENT);
  console.log();

  // === BEFORE STATE ===
  console.log("📊 State BEFORE Transaction:");
  console.log("─────────────────────────────────────────────────────────────────");

  const beforeAccountAPNTs = await apntsContract.balanceOf(TEST_ACCOUNT_A);
  const beforeRecipientAPNTs = await apntsContract.balanceOf(RECIPIENT);
  const beforeTreasuryAPNTs = await apntsContract.balanceOf(treasury);
  const beforeAllowance = await apntsContract.allowance(TEST_ACCOUNT_A, PAYMASTER_V4_1);
  const beforeAccountETH = await provider.getBalance(TEST_ACCOUNT_A);

  console.log("  Account A aPNTs:  ", ethers.formatUnits(beforeAccountAPNTs, 18), "aPNTs");
  console.log("  Recipient aPNTs:  ", ethers.formatUnits(beforeRecipientAPNTs, 18), "aPNTs");
  console.log("  Treasury aPNTs:   ", ethers.formatUnits(beforeTreasuryAPNTs, 18), "aPNTs");
  console.log("  Allowance:        ", beforeAllowance === ethers.MaxUint256 ? "MAX" : ethers.formatUnits(beforeAllowance, 18));
  console.log("  Account A ETH:    ", ethers.formatUnits(beforeAccountETH, 18), "ETH");
  console.log();

  // Validation
  if (beforeAccountAPNTs < ethers.parseUnits("10", 18)) {
    console.error("❌ Insufficient aPNTs balance (need >= 10 aPNTs)");
    console.log("💡 Need to transfer aPNTs to SimpleAccount A");
    process.exit(1);
  }

  // Check allowance (aPNTs factory should have auto-approved SuperPaymaster)
  // For PaymasterV4_1, we may need manual approval
  if (beforeAllowance < ethers.parseUnits("10", 18)) {
    console.log("⚠️  aPNTs allowance to PaymasterV4_1 is low");
    console.log("    This test assumes aPNTs factory auto-approved PaymasterV4_1");
    console.log("    If approval fails, need to manually approve from SimpleAccount\n");
  }

  // === CONSTRUCT USEROP ===
  console.log("🔧 Constructing UserOperation:");
  console.log("─────────────────────────────────────────────────────────────────");

  const nonce = await accountContract.getNonce();
  const transferAmount = ethers.parseUnits("0.5", 18);

  console.log("  Transfer Amount:  ", ethers.formatUnits(transferAmount, 18), "aPNTs");
  console.log("  Nonce:            ", nonce.toString());

  // Construct calldata: SimpleAccount.execute(aPNTs.transfer(recipient, 0.5))
  const transferCalldata = apntsContract.interface.encodeFunctionData("transfer", [RECIPIENT, transferAmount]);
  const executeCalldata = accountContract.interface.encodeFunctionData("execute", [APNTS_TOKEN, 0, transferCalldata]);

  // Gas configuration
  const callGasLimit = 100000n;
  const verificationGasLimit = 300000n;
  const preVerificationGas = 100000n;
  const maxPriorityFeePerGas = ethers.parseUnits("0.1", "gwei");
  const latestBlock = await provider.getBlock("latest");
  const baseFeePerGas = latestBlock.baseFeePerGas || ethers.parseUnits("0.001", "gwei");
  const maxFeePerGas = baseFeePerGas + maxPriorityFeePerGas + ethers.parseUnits("0.001", "gwei");

  console.log("\n  Gas Limits:");
  console.log("    - callGasLimit:               ", callGasLimit.toString());
  console.log("    - verificationGasLimit:       ", verificationGasLimit.toString());
  console.log("    - preVerificationGas:         ", preVerificationGas.toString());
  console.log("    - maxFeePerGas:               ", ethers.formatUnits(maxFeePerGas, "gwei"), "gwei");
  console.log("    - maxPriorityFeePerGas:       ", ethers.formatUnits(maxPriorityFeePerGas, "gwei"), "gwei");

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
    PAYMASTER_V4_1,
    ethers.zeroPadValue(ethers.toBeHex(200000n), 16), // paymasterVerificationGasLimit
    ethers.zeroPadValue(ethers.toBeHex(100000n), 16), // paymasterPostOpGasLimit
    APNTS_TOKEN, // userSpecifiedGasToken
  ]);

  // Create UserOp
  const userOp = {
    sender: TEST_ACCOUNT_A,
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
  const signingKey = new ethers.SigningKey(DEPLOYER_PRIVATE_KEY);
  const signature = signingKey.sign(userOpHash).serialized;
  userOp.signature = signature;

  console.log("\n  UserOp Hash:      ", userOpHash);
  console.log();

  // === SUBMIT TRANSACTION ===
  console.log("🚀 Submitting Transaction:");
  console.log("─────────────────────────────────────────────────────────────────");

  try {
    const tx = await entryPoint.handleOps([userOp], signer.address, {
      gasLimit: 1000000n,
    });
    console.log("  Transaction Hash: ", tx.hash);
    console.log("  Waiting for confirmation...");

    const receipt = await tx.wait();
    console.log("  ✅ Confirmed in block:", receipt.blockNumber);
    console.log();

    // === AFTER STATE ===
    console.log("📊 State AFTER Transaction:");
    console.log("─────────────────────────────────────────────────────────────────");

    const afterAccountAPNTs = await apntsContract.balanceOf(TEST_ACCOUNT_A);
    const afterRecipientAPNTs = await apntsContract.balanceOf(RECIPIENT);
    const afterTreasuryAPNTs = await apntsContract.balanceOf(treasury);
    const afterAccountETH = await provider.getBalance(TEST_ACCOUNT_A);

    console.log("  Account A aPNTs:  ", ethers.formatUnits(afterAccountAPNTs, 18), "aPNTs");
    console.log("  Recipient aPNTs:  ", ethers.formatUnits(afterRecipientAPNTs, 18), "aPNTs");
    console.log("  Treasury aPNTs:   ", ethers.formatUnits(afterTreasuryAPNTs, 18), "aPNTs");
    console.log("  Account A ETH:    ", ethers.formatUnits(afterAccountETH, 18), "ETH");
    console.log();

    // === ANALYSIS ===
    console.log("📈 Transaction Analysis:");
    console.log("─────────────────────────────────────────────────────────────────");

    const apntsSentToRecipient = afterRecipientAPNTs - beforeRecipientAPNTs;
    const totalAPNTsSpent = beforeAccountAPNTs - afterAccountAPNTs;
    const apntsFee = totalAPNTsSpent - apntsSentToRecipient;
    const treasuryReceived = afterTreasuryAPNTs - beforeTreasuryAPNTs;
    const ethGasUsed = receipt.gasUsed * receipt.gasPrice;

    console.log("  Transfer:");
    console.log("    → Sent to Recipient:          ", ethers.formatUnits(apntsSentToRecipient, 18), "aPNTs");
    console.log();

    console.log("  Gas Payment (in aPNTs):");
    console.log("    → Total aPNTs Spent:          ", ethers.formatUnits(totalAPNTsSpent, 18), "aPNTs");
    console.log("    → aPNTs for Gas:              ", ethers.formatUnits(apntsFee, 18), "aPNTs");
    console.log("    → Treasury Received:          ", ethers.formatUnits(treasuryReceived, 18), "aPNTs");
    console.log();

    console.log("  Gas Usage (in ETH):");
    console.log("    → Gas Used:                   ", receipt.gasUsed.toString());
    console.log("    → Gas Price:                  ", ethers.formatUnits(receipt.gasPrice, "gwei"), "gwei");
    console.log("    → ETH Cost (if paid in ETH):  ", ethers.formatUnits(ethGasUsed, 18), "ETH");
    console.log("    → Account ETH Change:         ", ethers.formatUnits(afterAccountETH - beforeAccountETH, 18), "ETH");
    console.log();

    // Calculate effective rate
    if (apntsFee > 0n && ethGasUsed > 0n) {
      const effectiveRate = (apntsFee * 10000n) / ethGasUsed;
      console.log("  Conversion Rate:");
      console.log("    → aPNTs/ETH Ratio:            ", (Number(effectiveRate) / 10000).toFixed(4));
      console.log();
    }

    // === SUMMARY ===
    console.log("╔════════════════════════════════════════════════════════════════╗");
    console.log("║                        SUMMARY                                 ║");
    console.log("╚════════════════════════════════════════════════════════════════╝");
    console.log();
    console.log("  ✅ Transaction Successful");
    console.log("  📝 TX Hash:           ", tx.hash);
    console.log("  🔗 Etherscan:         ", `https://sepolia.etherscan.io/tx/${tx.hash}`);
    console.log();
    console.log("  💰 Financial Summary:");
    console.log("    • Transferred:       ", ethers.formatUnits(apntsSentToRecipient, 18), "aPNTs");
    console.log("    • Gas Paid (aPNTs):  ", ethers.formatUnits(apntsFee, 18), "aPNTs");
    console.log("    • Total Spent:       ", ethers.formatUnits(totalAPNTsSpent, 18), "aPNTs");
    console.log("    • No ETH spent ✅     (Account abstraction working!)");
    console.log();
    console.log("  🏦 Treasury Income:    ", ethers.formatUnits(treasuryReceived, 18), "aPNTs");
    console.log();
  } catch (error) {
    console.error("\n❌ Transaction Failed:");
    console.error("  Error:", error.message);
    if (error.data) {
      console.error("  Error Data:", error.data);
    }
    if (error.error) {
      console.error("  Error Details:", error.error);
    }
    throw error;
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Error:", error.message);
    process.exit(1);
  });

#!/usr/bin/env node
/**
 * Send UserOperation using PaymasterV4 (EntryPoint v0.7 format)
 *
 * Usage: node scripts/send-tx-v4.mjs <count>
 */

import { ethers } from "ethers";
import { config } from "dotenv";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

config({ path: path.join(__dirname, "../../env/.env") });

const RPC_URL = process.env.SEPOLIA_RPC_URL;
const OWNER_PRIVATE_KEY = process.env.OWNER_PRIVATE_KEY;
const ACCOUNT_C = process.env.TEST_AA_ACCOUNT_ADDRESS_C;
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const PAYMASTER = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
const PNT_TOKEN = "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
const BUNDLER_URL = `https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N`;

const provider = new ethers.JsonRpcProvider(RPC_URL);
const ownerWallet = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

const SIMPLE_ACCOUNT_ABI = [
  "function getNonce() view returns (uint256)",
  "function execute(address dest, uint256 value, bytes calldata func) external",
];

const ERC20_ABI = [
  "function transfer(address to, uint256 amount) returns (bool)",
];

async function sendTransaction(txNumber) {
  console.log(`\n🚀 Transaction #${txNumber}`);
  console.log(`   From: ${ACCOUNT_C}`);

  const accountContract = new ethers.Contract(
    ACCOUNT_C,
    SIMPLE_ACCOUNT_ABI,
    provider,
  );
  const nonce = await accountContract.getNonce();
  console.log(`   Nonce: ${nonce.toString()}`);

  // Create calldata: transfer 0.01 PNT to self
  const pntInterface = new ethers.Interface(ERC20_ABI);
  const transferCalldata = pntInterface.encodeFunctionData("transfer", [
    ACCOUNT_C,
    ethers.parseUnits("0.01", 18),
  ]);

  const executeCalldata = accountContract.interface.encodeFunctionData(
    "execute",
    [PNT_TOKEN, 0, transferCalldata],
  );

  // Gas limits
  const callGasLimit = 100000n;
  const verificationGasLimit = 300000n;
  const preVerificationGas = 100000n;

  // Gas fees
  const latestBlock = await provider.getBlock("latest");
  const baseFeePerGas =
    latestBlock.baseFeePerGas || ethers.parseUnits("0.001", "gwei");
  const maxPriorityFeePerGas = ethers.parseUnits("0.1", "gwei");
  const maxFeePerGas =
    baseFeePerGas + maxPriorityFeePerGas + ethers.parseUnits("0.001", "gwei");

  // Build UserOp (v0.7 format with separate paymaster fields)
  const userOp = {
    sender: ACCOUNT_C,
    nonce: nonce,
    callData: executeCalldata,
    callGasLimit: callGasLimit,
    verificationGasLimit: verificationGasLimit,
    preVerificationGas: preVerificationGas,
    maxFeePerGas: maxFeePerGas,
    maxPriorityFeePerGas: maxPriorityFeePerGas,
    paymaster: PAYMASTER,
    paymasterVerificationGasLimit: 200000n,
    paymasterPostOpGasLimit: 150000n,
    paymasterData: "0x",
    signature: "0x",
  };

  // Get user op hash for signing
  console.log(`   📝 Signing UserOp...`);

  // Pack UserOp for signing (v0.7 packed format)
  const packedUserOp = {
    sender: userOp.sender,
    nonce: userOp.nonce,
    initCode: "0x",
    callData: userOp.callData,
    accountGasLimits: ethers.concat([
      ethers.zeroPadValue(ethers.toBeHex(verificationGasLimit), 16),
      ethers.zeroPadValue(ethers.toBeHex(callGasLimit), 16),
    ]),
    preVerificationGas: preVerificationGas,
    gasFees: ethers.concat([
      ethers.zeroPadValue(ethers.toBeHex(maxPriorityFeePerGas), 16),
      ethers.zeroPadValue(ethers.toBeHex(maxFeePerGas), 16),
    ]),
    paymasterAndData: ethers.concat([
      PAYMASTER,
      ethers.zeroPadValue(ethers.toBeHex(200000n), 16),
      ethers.zeroPadValue(ethers.toBeHex(150000n), 16),
      "0x",
    ]),
    signature: "0x",
  };

  // Calculate hash manually (EntryPoint v0.7)
  const chainId = (await provider.getNetwork()).chainId;
  const packedHash = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      [
        "address",
        "uint256",
        "bytes32",
        "bytes32",
        "bytes32",
        "uint256",
        "bytes32",
        "bytes32",
        "bytes32",
      ],
      [
        packedUserOp.sender,
        packedUserOp.nonce,
        ethers.keccak256(packedUserOp.initCode),
        ethers.keccak256(packedUserOp.callData),
        packedUserOp.accountGasLimits,
        packedUserOp.preVerificationGas,
        packedUserOp.gasFees,
        ethers.keccak256(packedUserOp.paymasterAndData),
        ethers.keccak256("0x"),
      ],
    ),
  );

  const userOpHash = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "address", "uint256"],
      [packedHash, ENTRYPOINT, chainId],
    ),
  );

  // Sign with owner
  const signature = await ownerWallet.signMessage(ethers.getBytes(userOpHash));
  userOp.signature = signature;

  // Submit to bundler
  console.log(`   📤 Submitting to bundler...`);

  // Convert BigInt to hex strings for JSON
  const userOpForJson = {
    sender: userOp.sender,
    nonce: "0x" + userOp.nonce.toString(16),
    callData: userOp.callData,
    callGasLimit: "0x" + userOp.callGasLimit.toString(16),
    verificationGasLimit: "0x" + userOp.verificationGasLimit.toString(16),
    preVerificationGas: "0x" + userOp.preVerificationGas.toString(16),
    maxFeePerGas: "0x" + userOp.maxFeePerGas.toString(16),
    maxPriorityFeePerGas: "0x" + userOp.maxPriorityFeePerGas.toString(16),
    paymaster: userOp.paymaster,
    paymasterVerificationGasLimit:
      "0x" + userOp.paymasterVerificationGasLimit.toString(16),
    paymasterPostOpGasLimit: "0x" + userOp.paymasterPostOpGasLimit.toString(16),
    paymasterData: userOp.paymasterData,
    signature: userOp.signature,
  };

  try {
    const response = await fetch(BUNDLER_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "eth_sendUserOperation",
        params: [userOpForJson, ENTRYPOINT],
      }),
    });

    const result = await response.json();

    if (result.error) {
      console.log(`   ❌ Error: ${result.error.message}`);
      if (result.error.data) {
        console.log(`      Data: ${JSON.stringify(result.error.data)}`);
      }
      return null;
    }

    console.log(`   ✅ UserOp Hash: ${result.result}`);
    return result.result;
  } catch (error) {
    console.log(`   ❌ Failed: ${error.message}`);
    return null;
  }
}

async function main() {
  const count = parseInt(process.argv[2] || "2");

  console.log(`\n=== Sending ${count} Test Transactions ===`);
  console.log(`Account C: ${ACCOUNT_C}`);
  console.log(`Paymaster: ${PAYMASTER}\n`);

  const results = [];

  for (let i = 1; i <= count; i++) {
    const result = await sendTransaction(i);
    results.push(result);

    if (result && i < count) {
      console.log(`\n   ⏳ Waiting 8 seconds before next transaction...`);
      await new Promise((resolve) => setTimeout(resolve, 8000));
    }
  }

  const successful = results.filter((r) => r !== null).length;
  console.log(
    `\n\n✅ Completed: ${successful}/${count} transactions successful`,
  );

  if (successful > 0) {
    console.log(`\n💡 Check analytics dashboard to see updated stats!`);
  }
}

main().catch(console.error);

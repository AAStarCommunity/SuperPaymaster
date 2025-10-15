#!/usr/bin/env node
/**
 * Send a simple UserOperation using PaymasterV4
 *
 * Usage: node scripts/send-simple-tx.mjs <accountAddress> <ownerPrivateKey> [count]
 */

import { ethers } from "ethers";
import { config } from "dotenv";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

config({ path: path.join(__dirname, "../.env.v3") });

const RPC_URL = process.env.SEPOLIA_RPC_URL;
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"; // v0.7
const PAYMASTER = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
const PNT_TOKEN = "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
const BUNDLER_URL = `https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N`;

const provider = new ethers.JsonRpcProvider(RPC_URL);

// ABIs
const SIMPLE_ACCOUNT_ABI = [
  "function getNonce() view returns (uint256)",
  "function execute(address dest, uint256 value, bytes calldata func) external"
];

const ERC20_ABI = [
  "function transfer(address to, uint256 amount) returns (bool)"
];

const ENTRYPOINT_ABI = [
  "function getUserOpHash(tuple(address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp) view returns (bytes32)"
];

async function sendTransaction(accountAddress, ownerPrivateKey, txNumber) {
  console.log(`\n🚀 Sending transaction #${txNumber} from ${accountAddress}...`);

  const ownerWallet = new ethers.Wallet(ownerPrivateKey, provider);
  const accountContract = new ethers.Contract(accountAddress, SIMPLE_ACCOUNT_ABI, provider);

  // Get nonce
  const nonce = await accountContract.getNonce();
  console.log(`   Nonce: ${nonce.toString()}`);

  // Create calldata: transfer 0.01 PNT to self (dummy operation)
  const pntInterface = new ethers.Interface(ERC20_ABI);
  const transferData = pntInterface.encodeFunctionData("transfer", [
    accountAddress,
    ethers.parseUnits("0.01", 18)
  ]);

  const accountInterface = new ethers.Interface(SIMPLE_ACCOUNT_ABI);
  const executeData = accountInterface.encodeFunctionData("execute", [
    PNT_TOKEN,
    0,
    transferData
  ]);

  // Build UserOperation
  const userOp = {
    sender: accountAddress,
    nonce: "0x" + nonce.toString(16),
    initCode: "0x",
    callData: executeData,
    accountGasLimits: "0x00000000000f424000000000000f4240", // 1M each
    preVerificationGas: "0x0186a0", // 100k
    gasFees: "0x00000000000186a000000000000186a0", // 100k gwei each
    paymasterAndData: PAYMASTER + "0".repeat(40), // Just paymaster address + 20 bytes padding
    signature: "0x" + "00".repeat(65)
  };

  // Sign UserOperation
  const entryPointContract = new ethers.Contract(ENTRYPOINT, ENTRYPOINT_ABI, provider);
  const userOpHash = await entryPointContract.getUserOpHash(userOp);

  const signature = await ownerWallet.signMessage(ethers.getBytes(userOpHash));
  userOp.signature = signature;

  // Send via bundler
  try {
    console.log(`   📤 Submitting to bundler...`);
    const response = await fetch(BUNDLER_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'eth_sendUserOperation',
        params: [userOp, ENTRYPOINT]
      })
    });

    const result = await response.json();

    if (result.error) {
      console.log(`   ❌ Error: ${result.error.message}`);
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
  const accountAddress = process.argv[2];
  const ownerPrivateKey = process.argv[3];
  const count = parseInt(process.argv[4] || "2");

  if (!accountAddress || !ownerPrivateKey) {
    console.error('Usage: node send-simple-tx.mjs <accountAddress> <ownerPrivateKey> [count]');
    process.exit(1);
  }

  console.log(`\n=== Sending ${count} Test Transactions ===`);
  console.log(`Account: ${accountAddress}`);

  const results = [];
  for (let i = 1; i <= count; i++) {
    const result = await sendTransaction(accountAddress, ownerPrivateKey, i);
    results.push(result);

    if (i < count) {
      console.log(`\n   ⏳ Waiting 5 seconds before next transaction...`);
      await new Promise(resolve => setTimeout(resolve, 5000));
    }
  }

  console.log(`\n\n✅ Completed ${count} transactions`);
  console.log(`Successful: ${results.filter(r => r !== null).length}`);
}

main().catch(console.error);

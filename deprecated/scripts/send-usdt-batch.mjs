#!/usr/bin/env node
/**
 * Send USDT transfer transactions for three accounts
 */

import { ethers } from "ethers";
import { config } from "dotenv";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

config({ path: path.join(__dirname, "../../env/.env") });

const RPC_URL = process.env.SEPOLIA_RPC_URL;
const OWNER2_PRIVATE_KEY = process.env.OWNER2_PRIVATE_KEY;
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const PAYMASTER = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
const USDT_TOKEN = "0x14EaC6C3D49AEDff3D59773A7d7bfb50182bCfDc";
const BUNDLER_URL = `https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N`;

const ACCOUNTS = [
  { name: "1", address: process.env.TEST_AA_ACCOUNT_ADDRESS_1 },
  { name: "2", address: process.env.TEST_AA_ACCOUNT_ADDRESS_2 },
  { name: "3", address: process.env.TEST_AA_ACCOUNT_ADDRESS_3 }
];

const provider = new ethers.JsonRpcProvider(RPC_URL);
const ownerWallet = new ethers.Wallet(OWNER2_PRIVATE_KEY, provider);

const SIMPLE_ACCOUNT_ABI = [
  "function getNonce() view returns (uint256)",
  "function execute(address dest, uint256 value, bytes calldata func) external"
];

const ERC20_ABI = ["function transfer(address to, uint256 amount) returns (bool)"];

const ENTRYPOINT_ABI = [
  "function getUserOpHash(tuple(address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp) view returns (bytes32)"
];

async function sendTransaction(account, txNumber) {
  console.log(`\n🚀 Account ${account.name} - Transaction #${txNumber}`);
  console.log(`   Address: ${account.address}`);

  const accountContract = new ethers.Contract(account.address, SIMPLE_ACCOUNT_ABI, provider);
  const nonce = await accountContract.getNonce();
  console.log(`   Nonce: ${nonce.toString()}`);

  // Create calldata: transfer 0.01 USDT to self
  const usdtInterface = new ethers.Interface(ERC20_ABI);
  const transferCalldata = usdtInterface.encodeFunctionData("transfer", [
    account.address,
    ethers.parseUnits("0.01", 6) // 0.01 USDT
  ]);

  const executeCalldata = accountContract.interface.encodeFunctionData("execute", [
    USDT_TOKEN,
    0,
    transferCalldata
  ]);

  // Gas limits
  const callGasLimit = 100000n;
  const verificationGasLimit = 300000n;
  const preVerificationGas = 100000n;

  // Gas fees
  const latestBlock = await provider.getBlock("latest");
  const baseFeePerGas = latestBlock.baseFeePerGas || ethers.parseUnits("0.001", "gwei");
  const maxPriorityFeePerGas = ethers.parseUnits("0.1", "gwei");
  const maxFeePerGas = baseFeePerGas + maxPriorityFeePerGas + ethers.parseUnits("0.001", "gwei");

  // Pack UserOp
  const packedAccountGasLimits = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(verificationGasLimit), 16),
    ethers.zeroPadValue(ethers.toBeHex(callGasLimit), 16)
  ]);

  const packedGasFees = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(maxPriorityFeePerGas), 16),
    ethers.zeroPadValue(ethers.toBeHex(maxFeePerGas), 16)
  ]);

  const packedPaymasterAndData = ethers.concat([
    PAYMASTER,
    ethers.zeroPadValue(ethers.toBeHex(200000n), 16),
    ethers.zeroPadValue(ethers.toBeHex(150000n), 16),
    "0x"
  ]);

  const packedUserOp = {
    sender: account.address,
    nonce: nonce,
    initCode: "0x",
    callData: executeCalldata,
    accountGasLimits: packedAccountGasLimits,
    preVerificationGas: preVerificationGas,
    gasFees: packedGasFees,
    paymasterAndData: packedPaymasterAndData,
    signature: "0x"
  };

  // Get userOpHash from EntryPoint
  console.log(`   📝 Signing...`);
  const entryPointContract = new ethers.Contract(ENTRYPOINT, ENTRYPOINT_ABI, provider);
  const userOpHash = await entryPointContract.getUserOpHash(packedUserOp);

  // Sign directly without EIP-191 prefix
  const signingKey = new ethers.SigningKey(OWNER2_PRIVATE_KEY);
  const signature = signingKey.sign(userOpHash).serialized;

  // Build UserOp for RPC
  const userOpForRPC = {
    sender: account.address,
    nonce: ethers.toBeHex(nonce),
    callData: executeCalldata,
    callGasLimit: ethers.toBeHex(callGasLimit),
    verificationGasLimit: ethers.toBeHex(verificationGasLimit),
    preVerificationGas: ethers.toBeHex(preVerificationGas),
    maxFeePerGas: ethers.toBeHex(maxFeePerGas),
    maxPriorityFeePerGas: ethers.toBeHex(maxPriorityFeePerGas),
    paymaster: PAYMASTER,
    paymasterVerificationGasLimit: ethers.toBeHex(200000n),
    paymasterPostOpGasLimit: ethers.toBeHex(150000n),
    paymasterData: "0x",
    signature: signature
  };

  // Submit
  console.log(`   📤 Submitting...`);
  try {
    const response = await fetch(BUNDLER_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'eth_sendUserOperation',
        params: [userOpForRPC, ENTRYPOINT]
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
  console.log("=== Sending USDT Transfer Transactions ===");
  console.log(`USDT Token: ${USDT_TOKEN}\n`);

  let totalSuccess = 0;
  let totalAttempts = 0;

  for (const account of ACCOUNTS) {
    console.log(`\n━━━ Account ${account.name}: ${account.address} ━━━`);

    for (let i = 1; i <= 2; i++) {
      totalAttempts++;
      const result = await sendTransaction(account, i);
      if (result) totalSuccess++;

      if (i < 2) {
        console.log(`\n   ⏳ Waiting 8 seconds...`);
        await new Promise(resolve => setTimeout(resolve, 8000));
      }
    }

    if (account.name !== "3") {
      console.log(`\n   ⏸️  Waiting 10 seconds before next account...`);
      await new Promise(resolve => setTimeout(resolve, 10000));
    }
  }

  console.log(`\n\n✅ Completed: ${totalSuccess}/${totalAttempts} transactions successful`);
  console.log(`\n💡 Check analytics dashboard to see updated stats!`);
}

main().catch(console.error);

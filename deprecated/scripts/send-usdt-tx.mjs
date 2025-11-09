#!/usr/bin/env node
/**
 * Send UserOperation to transfer fake USDT using PaymasterV4
 *
 * Usage: node scripts/send-usdt-tx.mjs <accountAddress> <ownerPrivateKey> <count>
 */

import { ethers } from "ethers";
import { config } from "dotenv";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

config({ path: path.join(__dirname, "../../env/.env") });

const RPC_URL = process.env.SEPOLIA_RPC_URL;
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const PAYMASTER = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
const USDT_TOKEN = process.env.USDT_CONTRACT_ADDRESS; // 0x14EaC6C3D49AEDff3D59773A7d7bfb50182bCfDc
const BUNDLER_URL = `https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N`;

const provider = new ethers.JsonRpcProvider(RPC_URL);

const SIMPLE_ACCOUNT_ABI = [
  "function getNonce() view returns (uint256)",
  "function execute(address dest, uint256 value, bytes calldata func) external"
];

const ERC20_ABI = ["function transfer(address to, uint256 amount) returns (bool)"];

async function sendTransaction(accountAddress, ownerPrivateKey, txNumber) {
  console.log(`\n🚀 Transaction #${txNumber}`);
  console.log(`   From: ${accountAddress}`);

  const ownerWallet = new ethers.Wallet(ownerPrivateKey, provider);
  const accountContract = new ethers.Contract(accountAddress, SIMPLE_ACCOUNT_ABI, provider);
  const nonce = await accountContract.getNonce();
  console.log(`   Nonce: ${nonce.toString()}`);

  // Create calldata: transfer 0.01 USDT to self
  const usdtInterface = new ethers.Interface(ERC20_ABI);
  const transferCalldata = usdtInterface.encodeFunctionData("transfer", [
    accountAddress, // Transfer to self
    ethers.parseUnits("0.01", 6) // 0.01 USDT (6 decimals)
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

  // Build UserOp (v0.7 format)
  const userOp = {
    sender: accountAddress,
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
    signature: "0x"
  };

  // Pack UserOp for signing
  const packedUserOp = {
    sender: userOp.sender,
    nonce: userOp.nonce,
    initCode: "0x",
    callData: userOp.callData,
    accountGasLimits: ethers.concat([
      ethers.zeroPadValue(ethers.toBeHex(verificationGasLimit), 16),
      ethers.zeroPadValue(ethers.toBeHex(callGasLimit), 16)
    ]),
    preVerificationGas: preVerificationGas,
    gasFees: ethers.concat([
      ethers.zeroPadValue(ethers.toBeHex(maxPriorityFeePerGas), 16),
      ethers.zeroPadValue(ethers.toBeHex(maxFeePerGas), 16)
    ]),
    paymasterAndData: ethers.concat([
      PAYMASTER,
      ethers.zeroPadValue(ethers.toBeHex(200000n), 16),
      ethers.zeroPadValue(ethers.toBeHex(150000n), 16),
      "0x"
    ]),
    signature: "0x"
  };

  // Calculate hash
  console.log(`   📝 Signing UserOp...`);
  const chainId = (await provider.getNetwork()).chainId;
  const packedHash = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "uint256", "bytes32", "bytes32", "bytes32", "uint256", "bytes32", "bytes32", "bytes32"],
      [
        packedUserOp.sender,
        packedUserOp.nonce,
        ethers.keccak256(packedUserOp.initCode),
        ethers.keccak256(packedUserOp.callData),
        packedUserOp.accountGasLimits,
        packedUserOp.preVerificationGas,
        packedUserOp.gasFees,
        ethers.keccak256(packedUserOp.paymasterAndData),
        ethers.keccak256("0x")
      ]
    )
  );

  const userOpHash = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "address", "uint256"],
      [packedHash, ENTRYPOINT, chainId]
    )
  );

  // Sign
  const signature = await ownerWallet.signMessage(ethers.getBytes(userOpHash));
  userOp.signature = signature;

  // Convert to JSON format
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
    paymasterVerificationGasLimit: "0x" + userOp.paymasterVerificationGasLimit.toString(16),
    paymasterPostOpGasLimit: "0x" + userOp.paymasterPostOpGasLimit.toString(16),
    paymasterData: userOp.paymasterData,
    signature: userOp.signature
  };

  // Submit
  console.log(`   📤 Submitting to bundler...`);
  try {
    const response = await fetch(BUNDLER_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'eth_sendUserOperation',
        params: [userOpForJson, ENTRYPOINT]
      })
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
  const accountAddress = process.argv[2];
  const ownerPrivateKey = process.argv[3];
  const count = parseInt(process.argv[4] || "2");

  if (!accountAddress || !ownerPrivateKey) {
    console.error('Usage: node send-usdt-tx.mjs <accountAddress> <ownerPrivateKey> [count]');
    process.exit(1);
  }

  console.log(`\n=== Sending ${count} USDT Transfer Transactions ===`);
  console.log(`Account: ${accountAddress}`);
  console.log(`USDT Token: ${USDT_TOKEN}\n`);

  const results = [];

  for (let i = 1; i <= count; i++) {
    const result = await sendTransaction(accountAddress, ownerPrivateKey, i);
    results.push(result);

    if (result && i < count) {
      console.log(`\n   ⏳ Waiting 8 seconds before next transaction...`);
      await new Promise(resolve => setTimeout(resolve, 8000));
    }
  }

  const successful = results.filter(r => r !== null).length;
  console.log(`\n\n✅ Completed: ${successful}/${count} transactions successful`);
}

main().catch(console.error);

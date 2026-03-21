#!/usr/bin/env node

/**
 * Gasless Transfer Test Case 1
 *
 * Tests gasless ERC20 token transfer using:
 * - PaymasterV4 (deployed via PaymasterFactory for deployer operator)
 * - aPNTs Token (deployer's xPNTs)
 * - EntryPoint v0.7
 *
 * Addresses are loaded from deployments/config.sepolia.json
 *
 * Prerequisites:
 * - AA Account must have tokens deposited in PaymasterV4 (via depositFor)
 * - AA Account must hold tokens to transfer
 * - PaymasterV4 must have ETH in EntryPoint
 *
 * Reads RPC URL and private keys from .env.sepolia in the project root
 */

const { ethers } = require('ethers');
const path = require('path');
const { loadConfig } = require('./load-config');
require('dotenv').config({ path: process.env.ENV_FILE || path.join(__dirname, '../../.env.sepolia') });

// ABIs (minimal for testing)
const ERC20_ABI = [
  "function transfer(address to, uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)"
];

const ENTRYPOINT_ABI = [
  "function handleOps((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature)[] calldata ops, address payable beneficiary) external",
  "function getUserOpHash((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) calldata userOp) view returns (bytes32)"
];

const SIMPLE_ACCOUNT_ABI = [
  "function execute(address dest, uint256 value, bytes calldata func) external",
  "function getNonce() view returns (uint256)",
  "function entryPoint() view returns (address)"
];

const FACTORY_ABI = [
  "function paymasterByOperator(address) view returns (address)"
];

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║     Gasless Transfer Test Case 1 - PaymasterV4           ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  const config = loadConfig();
  const ENTRYPOINT_ADDRESS = config.entryPoint;
  const XPNTS_TOKEN_ADDRESS = config.aPNTs;

  // Load config from env
  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  const senderPrivateKey = process.env.OWNER_PRIVATE_KEY || process.env.DEPLOYER_PRIVATE_KEY;
  const recipientAddress = process.env.OWNER2_ADDRESS || process.env.TEST_EOA_ADDRESS;

  if (!rpcUrl) throw new Error('SEPOLIA_RPC_URL not found in .env.sepolia');
  if (!senderPrivateKey) throw new Error('OWNER_PRIVATE_KEY not found in .env.sepolia');
  if (!recipientAddress) throw new Error('OWNER2_ADDRESS not found in .env.sepolia');

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const wallet = new ethers.Wallet(senderPrivateKey, provider);

  // Look up PaymasterV4 instance for deployer via factory
  const factory = new ethers.Contract(config.paymasterFactory, FACTORY_ABI, provider);
  const PAYMASTER_ADDRESS = await factory.paymasterByOperator(wallet.address);

  if (PAYMASTER_ADDRESS === ethers.ZeroAddress) {
    console.log('  No PaymasterV4 deployed for this operator yet.');
    console.log('  Run prepare-test sepolia first to set up test accounts.');
    process.exit(0);
  }

  console.log('📌 Configuration:');
  console.log(`  RPC: ${rpcUrl.substring(0, 50)}...`);
  console.log(`  PaymasterV4: ${PAYMASTER_ADDRESS}`);
  console.log(`  aPNTs Token: ${XPNTS_TOKEN_ADDRESS}`);
  console.log(`  EntryPoint: ${ENTRYPOINT_ADDRESS}\n`);

  const senderAAAccount = process.env.TEST_AA_ACCOUNT_ADDRESS_A || process.env.SIMPLE_ACCOUNT_A;
  if (!senderAAAccount) throw new Error('TEST_AA_ACCOUNT_ADDRESS_A not found in env');

  console.log(`  Sender AA Account: ${senderAAAccount}`);
  console.log(`  Sender EOA: ${wallet.address}`);
  console.log(`  Recipient: ${recipientAddress}\n`);

  const xPNTsToken = new ethers.Contract(XPNTS_TOKEN_ADDRESS, ERC20_ABI, provider);
  const simpleAccount = new ethers.Contract(senderAAAccount, SIMPLE_ACCOUNT_ABI, provider);
  const entryPoint = new ethers.Contract(ENTRYPOINT_ADDRESS, ENTRYPOINT_ABI, wallet);

  try {
    // Step 1: Check token balance
    console.log('📊 Step 1: Check aPNTs Balance');
    const balance = await xPNTsToken.balanceOf(senderAAAccount);
    const symbol = await xPNTsToken.symbol();
    const decimals = await xPNTsToken.decimals();
    console.log(`  Balance: ${ethers.formatUnits(balance, decimals)} ${symbol}`);

    if (balance === 0n) {
      console.log('  ⚠️  Warning: Zero balance, cannot test transfer\n');
      return;
    }

    // Step 2: Prepare transfer calldata
    console.log('\n📝 Step 2: Prepare Transfer CallData');
    const transferAmount = ethers.parseUnits('1', decimals);
    const transferCalldata = xPNTsToken.interface.encodeFunctionData('transfer', [recipientAddress, transferAmount]);
    const executeCalldata = simpleAccount.interface.encodeFunctionData('execute', [XPNTS_TOKEN_ADDRESS, 0, transferCalldata]);
    console.log(`  Transfer Amount: 1 ${symbol}`);

    // Step 3: Build UserOperation
    console.log('\n🔨 Step 3: Build UserOperation');
    const nonce = await simpleAccount.getNonce();
    console.log(`  Nonce: ${nonce}`);

    const pmVerificationGasLimit = 100000n;
    const pmPostOpGasLimit = 80000n;
    const paymasterAndData = ethers.solidityPacked(
      ['address', 'uint128', 'uint128', 'address'],
      [PAYMASTER_ADDRESS, pmVerificationGasLimit, pmPostOpGasLimit, XPNTS_TOKEN_ADDRESS]
    );

    const userOp = {
      sender: senderAAAccount,
      nonce: nonce,
      initCode: '0x',
      callData: executeCalldata,
      accountGasLimits: ethers.solidityPacked(['uint128', 'uint128'], [200000, 200000]),
      preVerificationGas: 100000n,
      gasFees: ethers.solidityPacked(['uint128', 'uint128'], [2000000000, 2000000000]),
      paymasterAndData: paymasterAndData,
      signature: '0x'
    };

    // Step 4: Sign UserOperation
    console.log('\n✍️  Step 4: Sign UserOperation');
    const userOpHash = await entryPoint.getUserOpHash(userOp);
    console.log(`  UserOp Hash: ${userOpHash}`);
    const signature = await wallet.signMessage(ethers.getBytes(userOpHash));
    userOp.signature = signature;

    // Step 5: Submit to EntryPoint
    console.log('\n🚀 Step 5: Submit UserOp to EntryPoint');
    const beneficiary = wallet.address;

    try {
      const gasEstimate = await entryPoint.handleOps.estimateGas([userOp], beneficiary);
      console.log(`  Estimated gas: ${gasEstimate}`);
    } catch (error) {
      console.log(`  Gas estimation failed: ${error.reason || error.message.substring(0, 120)}`);
      console.log('  Proceeding anyway...');
    }

    console.log('  Sending transaction...');
    const tx = await entryPoint.handleOps([userOp], beneficiary);
    console.log(`  TX Hash: ${tx.hash}`);
    console.log(`  Etherscan: https://sepolia.etherscan.io/tx/${tx.hash}`);

    const receipt = await tx.wait();
    if (receipt.status === 1) {
      console.log('  ✅ Transaction confirmed!\n');
      const newBalance = await xPNTsToken.balanceOf(senderAAAccount);
      const recipientBalance = await xPNTsToken.balanceOf(recipientAddress);
      console.log('📊 Final Balances:');
      console.log(`  Sender: ${ethers.formatUnits(newBalance, decimals)} ${symbol}`);
      console.log(`  Recipient: ${ethers.formatUnits(recipientBalance, decimals)} ${symbol}`);
    } else {
      console.log('  ❌ Transaction failed\n');
    }

  } catch (error) {
    console.error('\n❌ Error:', error.reason || error.message);
    if (error.data) console.error('  Error data:', error.data);
    process.exit(1);
  }

  console.log('\n╔═══════════════════════════════════════════════════════════╗');
  console.log('║                    Test Completed                         ║');
  console.log('╚═══════════════════════════════════════════════════════════╝');
}

main().then(() => process.exit(0)).catch((error) => { console.error(error); process.exit(1); });

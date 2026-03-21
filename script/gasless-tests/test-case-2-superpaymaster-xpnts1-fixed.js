#!/usr/bin/env node

/**
 * Gasless Transfer Test Case 2 - FIXED
 *
 * Tests gasless ERC20 token transfer using SuperPaymaster with proper
 * paymasterAndData format and allowance checking.
 *
 * Addresses are loaded from deployments/config.sepolia.json
 */

const { ethers } = require('ethers');
const path = require('path');
const { loadConfig } = require('./load-config');
require('dotenv').config({ path: process.env.ENV_FILE || path.join(__dirname, '../../.env.sepolia') });

const ERC20_ABI = [
  "function transfer(address to, uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)"
];

const ENTRYPOINT_ABI = [
  "function handleOps((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature)[] calldata ops, address payable beneficiary) external",
  "function getUserOpHash((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) calldata userOp) view returns (bytes32)"
];

const SIMPLE_ACCOUNT_ABI = [
  "function execute(address dest, uint256 value, bytes calldata func) external",
  "function getNonce() view returns (uint256)"
];

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║  Gasless Transfer Test Case 2 - FIXED Implementation     ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  const config = loadConfig();
  const SUPER_PAYMASTER_ADDRESS = config.superPaymaster;
  const XPNTS_TOKEN_ADDRESS = config.aPNTs;
  const ENTRYPOINT_ADDRESS = config.entryPoint;

  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  const senderPrivateKey = process.env.OWNER_PRIVATE_KEY || process.env.DEPLOYER_PRIVATE_KEY;
  const recipientAddress = process.env.OWNER2_ADDRESS || process.env.TEST_EOA_ADDRESS;
  const operatorAddress = process.env.OPERATOR_ADDRESS || '0xEcAACb915f7D92e9916f449F7ad42BD0408733c9';

  if (!rpcUrl || !senderPrivateKey || !recipientAddress || !operatorAddress) {
    throw new Error('Required env variables not found');
  }

  console.log('📌 Configuration:');
  console.log(`  SuperPaymaster: ${SUPER_PAYMASTER_ADDRESS}`);
  console.log(`  aPNTs Token: ${XPNTS_TOKEN_ADDRESS}`);
  console.log(`  EntryPoint: ${ENTRYPOINT_ADDRESS}`);
  console.log(`  Operator: ${operatorAddress}\n`);

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const wallet = new ethers.Wallet(senderPrivateKey, provider);

  const senderAAAccount = process.env.TEST_AA_ACCOUNT_ADDRESS_B || process.env.TEST_AA_ACCOUNT_ADDRESS_1;
  if (!senderAAAccount) throw new Error('TEST_AA_ACCOUNT_ADDRESS_B not found in env');

  console.log(`  Sender AA Account: ${senderAAAccount}`);
  console.log(`  Sender EOA: ${wallet.address}`);
  console.log(`  Recipient: ${recipientAddress}\n`);

  const xPNTsToken = new ethers.Contract(XPNTS_TOKEN_ADDRESS, ERC20_ABI, provider);
  const simpleAccount = new ethers.Contract(senderAAAccount, SIMPLE_ACCOUNT_ABI, provider);
  const entryPoint = new ethers.Contract(ENTRYPOINT_ADDRESS, ENTRYPOINT_ABI, wallet);

  try {
    console.log('📊 Step 1: Check aPNTs Balance and Approval');
    const balance = await xPNTsToken.balanceOf(senderAAAccount);
    const symbol = await xPNTsToken.symbol();
    const decimals = await xPNTsToken.decimals();
    console.log(`  Balance: ${ethers.formatUnits(balance, decimals)} ${symbol}`);

    const allowance = await xPNTsToken.allowance(senderAAAccount, SUPER_PAYMASTER_ADDRESS);
    console.log(`  Allowance: ${ethers.formatUnits(allowance, decimals)} ${symbol}`);

    if (balance === 0n) {
      console.log('  ⚠️  Warning: Zero balance, cannot test transfer\n');
      return;
    }

    console.log('\n📝 Step 2: Prepare Transfer CallData');
    const transferAmount = ethers.parseUnits('1', decimals);
    const transferCalldata = xPNTsToken.interface.encodeFunctionData('transfer', [recipientAddress, transferAmount]);
    const executeCalldata = simpleAccount.interface.encodeFunctionData('execute', [XPNTS_TOKEN_ADDRESS, 0, transferCalldata]);
    console.log(`  Transfer Amount: 1 ${symbol}`);

    console.log('\n🔨 Step 3: Build UserOperation');
    const nonce = await simpleAccount.getNonce();
    console.log(`  Nonce: ${nonce}`);

    const pmVerificationGasLimit = 150000n;
    const pmPostOpGasLimit = 100000n;
    const paymasterAndData = ethers.solidityPacked(
      ['address', 'uint128', 'uint128', 'address'],
      [SUPER_PAYMASTER_ADDRESS, pmVerificationGasLimit, pmPostOpGasLimit, operatorAddress]
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

    console.log('\n✍️  Step 4: Sign UserOperation');
    const userOpHash = await entryPoint.getUserOpHash(userOp);
    console.log(`  UserOp Hash: ${userOpHash.substring(0, 20)}...`);
    const signature = await wallet.signMessage(ethers.getBytes(userOpHash));
    userOp.signature = signature;

    console.log('\n🚀 Step 5: Submit UserOp to EntryPoint');
    const beneficiary = wallet.address;

    try {
      const gasEstimate = await entryPoint.handleOps.estimateGas([userOp], beneficiary);
      console.log(`  Estimated gas: ${gasEstimate}`);
    } catch (error) {
      console.log(`  Gas estimation: ${error.message.substring(0, 100)}...`);
      console.log('  Proceeding with transaction anyway...');
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
    console.error('\n❌ Error:', error.message);
    if (error.data) console.error('  Error data:', error.data);
    if (error.error) console.error('  Error reason:', error.error);
    process.exit(1);
  }

  console.log('\n╔═══════════════════════════════════════════════════════════╗');
  console.log('║                    Test Completed                         ║');
  console.log('╚═══════════════════════════════════════════════════════════╝');
}

main().then(() => process.exit(0)).catch((error) => { console.error(error); process.exit(1); });

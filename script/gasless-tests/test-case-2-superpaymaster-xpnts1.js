#!/usr/bin/env node

/**
 * Gasless Transfer Test Case 2
 *
 * Tests gasless ERC20 token transfer using:
 * - SuperPaymasterV2: 0xD6aa17587737C59cbb82986Afbac88Db75771857
 * - xPNTs1 Token: 0xfb56CB85C9a214328789D3C92a496d6AA185e3d3
 * - EntryPoint v0.7: 0x0000000071727De22E5E9d8BAf0edAc6f37da032
 *
 * Reads RPC URL and private keys from /Volumes/UltraDisk/Dev2/aastar/env/.env
 */

const { ethers } = require('ethers');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../../../env/.env') });

// Contract addresses
const SUPER_PAYMASTER_ADDRESS = '0xD6aa17587737C59cbb82986Afbac88Db75771857';
const XPNTS_TOKEN_ADDRESS = '0xfb56CB85C9a214328789D3C92a496d6AA185e3d3';
const ENTRYPOINT_ADDRESS = '0x0000000071727De22E5E9d8BAf0edAc6f37da032';

// ABIs (minimal for testing)
const ERC20_ABI = [
  "function transfer(address to, uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)"
];

const ENTRYPOINT_ABI = [
  "function handleOps((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature)[] calldata ops, address payable beneficiary) external"
];

const SIMPLE_ACCOUNT_ABI = [
  "function execute(address dest, uint256 value, bytes calldata func) external",
  "function getNonce() view returns (uint256)"
];

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║  Gasless Transfer Test Case 2 - SuperPaymasterV2 xPNTs1  ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  // Load config from env
  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  const senderPrivateKey = process.env.OWNER_PRIVATE_KEY || process.env.DEPLOYER_PRIVATE_KEY;
  const recipientAddress = process.env.OWNER2_ADDRESS || process.env.TEST_EOA_ADDRESS;

  if (!rpcUrl || !senderPrivateKey || !recipientAddress) {
    throw new Error('Required env variables not found in /Volumes/UltraDisk/Dev2/aastar/env/.env');
  }

  console.log('📌 Configuration:');
  console.log(`  RPC: ${rpcUrl.substring(0, 50)}...`);
  console.log(`  SuperPaymaster: ${SUPER_PAYMASTER_ADDRESS}`);
  console.log(`  xPNTs1 Token: ${XPNTS_TOKEN_ADDRESS}`);
  console.log(`  EntryPoint: ${ENTRYPOINT_ADDRESS}\n`);

  // Setup provider and signer
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const wallet = new ethers.Wallet(senderPrivateKey, provider);

  // Get sender's AA account address
  const senderAAAccount = process.env.TEST_AA_ACCOUNT_ADDRESS_B || process.env.TEST_AA_ACCOUNT_ADDRESS_1;
  if (!senderAAAccount) {
    throw new Error('TEST_AA_ACCOUNT_ADDRESS_B not found in env');
  }

  console.log(`  Sender AA Account: ${senderAAAccount}`);
  console.log(`  Sender EOA: ${wallet.address}`);
  console.log(`  Recipient: ${recipientAddress}\n`);

  // Connect to contracts
  const xPNTsToken = new ethers.Contract(XPNTS_TOKEN_ADDRESS, ERC20_ABI, provider);
  const simpleAccount = new ethers.Contract(senderAAAccount, SIMPLE_ACCOUNT_ABI, provider);
  const entryPoint = new ethers.Contract(ENTRYPOINT_ADDRESS, ENTRYPOINT_ABI, wallet);

  try {
    // Step 1: Check token balance
    console.log('📊 Step 1: Check xPNTs1 Balance');
    const balance = await xPNTsToken.balanceOf(senderAAAccount);
    const symbol = await xPNTsToken.symbol();
    const decimals = await xPNTsToken.decimals();
    const formattedBalance = ethers.formatUnits(balance, decimals);

    console.log(`  Balance: ${formattedBalance} ${symbol}`);

    if (balance === 0n) {
      console.log('  ⚠️  Warning: Zero balance, cannot test transfer\n');
      return;
    }

    // Step 2: Prepare transfer calldata
    console.log('\n📝 Step 2: Prepare Transfer CallData');
    const transferAmount = ethers.parseUnits('1', decimals);
    const transferCalldata = xPNTsToken.interface.encodeFunctionData('transfer', [
      recipientAddress,
      transferAmount
    ]);

    const executeCalldata = simpleAccount.interface.encodeFunctionData('execute', [
      XPNTS_TOKEN_ADDRESS,
      0,
      transferCalldata
    ]);

    console.log(`  Transfer Amount: 1 ${symbol}`);
    console.log(`  Calldata length: ${executeCalldata.length} bytes`);

    // Step 3: Build UserOperation
    console.log('\n🔨 Step 3: Build UserOperation');
    const nonce = await simpleAccount.getNonce();
    console.log(`  Nonce: ${nonce}`);

    const userOp = {
      sender: senderAAAccount,
      nonce: nonce,
      initCode: '0x',
      callData: executeCalldata,
      accountGasLimits: ethers.solidityPacked(['uint128', 'uint128'], [150000, 150000]),
      preVerificationGas: 100000n,
      gasFees: ethers.solidityPacked(['uint128', 'uint128'], [1000000000, 1000000000]),
      paymasterAndData: SUPER_PAYMASTER_ADDRESS, // SuperPaymaster
      signature: '0x'
    };

    console.log('  UserOp prepared');

    // Step 4: Sign UserOperation
    console.log('\n✍️  Step 4: Sign UserOperation');
    const network = await provider.getNetwork();
    console.log(`  Chain ID: ${network.chainId}`);

    const userOpHash = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'uint256', 'bytes32', 'bytes32', 'bytes32', 'uint256', 'bytes32', 'bytes32'],
        [
          userOp.sender,
          userOp.nonce,
          ethers.keccak256(userOp.initCode),
          ethers.keccak256(userOp.callData),
          userOp.accountGasLimits,
          userOp.preVerificationGas,
          userOp.gasFees,
          ethers.keccak256(userOp.paymasterAndData)
        ]
      )
    );

    const signature = await wallet.signMessage(ethers.getBytes(userOpHash));
    userOp.signature = signature;

    console.log(`  Signature: ${signature.substring(0, 20)}...`);

    // Step 5: Submit to EntryPoint
    console.log('\n🚀 Step 5: Submit UserOp to EntryPoint');
    console.log('  ⚠️  Note: This is a simplified test using SuperPaymasterV2');

    const beneficiary = wallet.address;

    try {
      const gasEstimate = await entryPoint.handleOps.estimateGas([userOp], beneficiary);
      console.log(`  Estimated gas: ${gasEstimate}`);
    } catch (error) {
      console.log(`  Gas estimation: ${error.message.substring(0, 100)}...`);
    }

    console.log('  Sending transaction...');
    const tx = await entryPoint.handleOps([userOp], beneficiary);
    console.log(`  TX Hash: ${tx.hash}`);
    console.log(`  Etherscan: https://sepolia.etherscan.io/tx/${tx.hash}`);

    console.log('  Waiting for confirmation...');
    const receipt = await tx.wait();

    if (receipt.status === 1) {
      console.log('  ✅ Transaction confirmed!\n');

      console.log('📊 Final Balances:');
      const newBalance = await xPNTsToken.balanceOf(senderAAAccount);
      const recipientBalance = await xPNTsToken.balanceOf(recipientAddress);
      console.log(`  Sender: ${ethers.formatUnits(newBalance, decimals)} ${symbol}`);
      console.log(`  Recipient: ${ethers.formatUnits(recipientBalance, decimals)} ${symbol}`);
    } else {
      console.log('  ❌ Transaction failed\n');
    }

  } catch (error) {
    console.error('\n❌ Error:', error.message);
    if (error.data) {
      console.error('  Error data:', error.data);
    }
    process.exit(1);
  }

  console.log('\n╔═══════════════════════════════════════════════════════════╗');
  console.log('║                    Test Completed                         ║');
  console.log('╚═══════════════════════════════════════════════════════════╝');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

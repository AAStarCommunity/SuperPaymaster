#!/usr/bin/env node
/**
 * Gasless Transfer Test using Viem
 * Tests SuperPaymaster V2.2 - Final Optimized Version
 * All 4 optimizations: Task 1.1 + 1.2 + 1.3 + 2.1
 */
const { createPublicClient, createWalletClient, http, parseUnits, encodeFunctionData, concat, pad } = require('viem');
const { sepolia } = require('viem/chains');
const { privateKeyToAccount } = require('viem/accounts');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../env/.env') });

const SUPER_PAYMASTER = '0x34671Bf95159bbDAb12Ac1DA8dbdfEc5D5dC1c24';
const XPNTS1_TOKEN = '0xfb56CB85C9a214328789D3C92a496d6AA185e3d3';
const ENTRYPOINT = '0x0000000071727De22E5E9d8BAf0edAc6f37da032';
const OPERATOR = '0x411BD567E46C0781248dbB6a9211891C032885e5';
const AA_ACCOUNT = '0x57b2e6f08399c276b2c1595825219d29990d0921';
const RECIPIENT = '0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA';

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║    ⚡ Gasless Test v2.2 - Final All Optimizations        ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  // Use OWNER2_PRIVATE_KEY - this is the actual owner of the AA account
  const privateKey = process.env.OWNER2_PRIVATE_KEY.startsWith('0x')
    ? process.env.OWNER2_PRIVATE_KEY
    : `0x${process.env.OWNER2_PRIVATE_KEY}`;
  const account = privateKeyToAccount(privateKey);

  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(process.env.SEPOLIA_RPC_URL)
  });

  const walletClient = createWalletClient({
    account,
    chain: sepolia,
    transport: http(process.env.SEPOLIA_RPC_URL)
  });

  console.log('📌 Configuration:');
  console.log(`  SuperPaymaster: ${SUPER_PAYMASTER}`);
  console.log(`  xPNTs1 Token: ${XPNTS1_TOKEN}`);
  console.log(`  Operator: ${OPERATOR}`);
  console.log(`  AA Account: ${AA_ACCOUNT}`);
  console.log(`  Sender EOA: ${account.address}`);
  console.log(`  Recipient: ${RECIPIENT}\n`);

  // Check balances
  const [balanceBefore, recipientBalanceBefore, symbol, decimals] = await Promise.all([
    publicClient.readContract({
      address: XPNTS1_TOKEN,
      abi: [{ type: 'function', name: 'balanceOf', inputs: [{type: 'address'}], outputs: [{type: 'uint256'}], stateMutability: 'view' }],
      functionName: 'balanceOf',
      args: [AA_ACCOUNT]
    }),
    publicClient.readContract({
      address: XPNTS1_TOKEN,
      abi: [{ type: 'function', name: 'balanceOf', inputs: [{type: 'address'}], outputs: [{type: 'uint256'}], stateMutability: 'view' }],
      functionName: 'balanceOf',
      args: [RECIPIENT]
    }),
    publicClient.readContract({
      address: XPNTS1_TOKEN,
      abi: [{ type: 'function', name: 'symbol', outputs: [{type: 'string'}], stateMutability: 'view' }],
      functionName: 'symbol'
    }),
    publicClient.readContract({
      address: XPNTS1_TOKEN,
      abi: [{ type: 'function', name: 'decimals', outputs: [{type: 'uint8'}], stateMutability: 'view' }],
      functionName: 'decimals'
    })
  ]);

  console.log('📊 Initial Balances:');
  console.log(`  Sender: ${Number(balanceBefore) / 10**Number(decimals)} ${symbol}`);
  console.log(`  Recipient: ${Number(recipientBalanceBefore) / 10**Number(decimals)} ${symbol}\n`);

  // Build callData
  const transferAmount = parseUnits('1', Number(decimals));
  const transferCalldata = encodeFunctionData({
    abi: [{ type: 'function', name: 'transfer', inputs: [{type: 'address', name: 'to'}, {type: 'uint256', name: 'amount'}] }],
    functionName: 'transfer',
    args: [RECIPIENT, transferAmount]
  });

  const executeData = encodeFunctionData({
    abi: [{ type: 'function', name: 'execute', inputs: [{type: 'address'}, {type: 'uint256'}, {type: 'bytes'}] }],
    functionName: 'execute',
    args: [XPNTS1_TOKEN, 0n, transferCalldata]
  });

  console.log('📝 Step 1: Build UserOperation');
  console.log(`  Transfer Amount: 1 ${symbol}`);

  // Get nonce
  const nonce = await publicClient.readContract({
    address: AA_ACCOUNT,
    abi: [{ type: 'function', name: 'getNonce', outputs: [{type: 'uint256'}], stateMutability: 'view' }],
    functionName: 'getNonce'
  });
  console.log(`  Nonce: ${nonce}`);

  // Build paymasterAndData (72 bytes: 20 + 16 + 16 + 20)
  // [0:20]   paymaster address
  // [20:36]  verificationGasLimit (uint128) for paymaster - 16 bytes
  // [36:52]  postOpGasLimit (uint128) - 16 bytes
  // [52:72]  operator address - 20 bytes
  // ⚡ OPTIMIZED v1.1: Precise gas limits based on actual consumption
  // Baseline actual: 312k total (account=12k, paymaster=120k, execution=50k, overhead=100k, postOp=10k)
  const paymasterVerificationGas = 160000n; // 160k (actual 120k × 1.33 safety)
  const paymasterPostOpGas = 10000n; // 10k (empty function, only call overhead)

  const paymasterAndData = concat([
    SUPER_PAYMASTER,
    pad(`0x${paymasterVerificationGas.toString(16)}`, { dir: 'left', size: 16 }),
    pad(`0x${paymasterPostOpGas.toString(16)}`, { dir: 'left', size: 16 }),
    OPERATOR
  ]);
  console.log(`  PaymasterAndData: ${paymasterAndData.length - 2} hex chars = ${(paymasterAndData.length - 2) / 2} bytes`);
  console.log(`  Paymaster gas limits: verification=${paymasterVerificationGas}, postOp=${paymasterPostOpGas}`);

  // ⚡ OPTIMIZED account gas limits
  const accountGasLimits = concat([
    pad(`0x${(90000).toString(16)}`, { dir: 'left', size: 16 }),  // 90k (actual 12k × 7.5x safety)
    pad(`0x${(80000).toString(16)}`, { dir: 'left', size: 16 })   // 80k (actual 50k × 1.6x safety)
  ]);

  // Pack gas fees: maxPriorityFeePerGas (2 gwei) + maxFeePerGas (2 gwei)
  const gasFees = concat([
    pad(`0x${(2000000000).toString(16)}`, { dir: 'left', size: 16 }),
    pad(`0x${(2000000000).toString(16)}`, { dir: 'left', size: 16 })
  ]);

  console.log('  ⚡ Optimized Gas limits (v1.1):');
  console.log('    accountVerificationGas: 90,000 (was 150k)');
  console.log('    callGasLimit: 80,000 (was 100k)');
  console.log('    preVerificationGas: 21,000');
  console.log('    Total: 341k (was 521k) → 35% reduction\n');

  // Build UserOperation
  const userOp = {
    sender: AA_ACCOUNT,
    nonce,
    initCode: '0x',
    callData: executeData,
    accountGasLimits,
    preVerificationGas: 21000n,
    gasFees,
    paymasterAndData,
    signature: '0x'
  };

  console.log('✍️  Step 2: Sign UserOperation');

  // Get UserOpHash from EntryPoint
  const userOpHash = await publicClient.readContract({
    address: ENTRYPOINT,
    abi: [{
      type: 'function',
      name: 'getUserOpHash',
      inputs: [{
        type: 'tuple',
        components: [
          {name: 'sender', type: 'address'},
          {name: 'nonce', type: 'uint256'},
          {name: 'initCode', type: 'bytes'},
          {name: 'callData', type: 'bytes'},
          {name: 'accountGasLimits', type: 'bytes32'},
          {name: 'preVerificationGas', type: 'uint256'},
          {name: 'gasFees', type: 'bytes32'},
          {name: 'paymasterAndData', type: 'bytes'},
          {name: 'signature', type: 'bytes'}
        ]
      }],
      outputs: [{type: 'bytes32'}],
      stateMutability: 'view'
    }],
    functionName: 'getUserOpHash',
    args: [userOp]
  });

  console.log(`  UserOpHash: ${userOpHash}`);

  // Sign with EIP-191
  const signature = await account.signMessage({
    message: { raw: userOpHash }
  });
  userOp.signature = signature;

  console.log(`  Signature: ${signature.substring(0, 20)}...`);
  console.log(`  Signature length: ${(signature.length - 2) / 2} bytes\n`);

  // Submit to EntryPoint
  console.log('🚀 Step 3: Submit to EntryPoint');

  try {
    // Send transaction
    console.log('  Sending transaction...');
    const hash = await walletClient.writeContract({
      address: ENTRYPOINT,
      abi: [{
        type: 'function',
        name: 'handleOps',
        inputs: [{
          type: 'tuple[]',
          components: [
            {name: 'sender', type: 'address'},
            {name: 'nonce', type: 'uint256'},
            {name: 'initCode', type: 'bytes'},
            {name: 'callData', type: 'bytes'},
            {name: 'accountGasLimits', type: 'bytes32'},
            {name: 'preVerificationGas', type: 'uint256'},
            {name: 'gasFees', type: 'bytes32'},
            {name: 'paymasterAndData', type: 'bytes'},
            {name: 'signature', type: 'bytes'}
          ]
        }, {name: 'beneficiary', type: 'address'}],
        outputs: [],
        stateMutability: 'nonpayable'
      }],
      functionName: 'handleOps',
      args: [[userOp], account.address],
      gas: 2000000n
    });

    console.log(`\n  ✅ Transaction sent!`);
    console.log(`  TX Hash: ${hash}`);
    console.log(`  Etherscan: https://sepolia.etherscan.io/tx/${hash}\n`);

    console.log('  Waiting for confirmation...');
    const receipt = await publicClient.waitForTransactionReceipt({ hash });

    if (receipt.status === 'success') {
      console.log(`  ✅ Transaction confirmed in block ${receipt.blockNumber}!\n`);

      // Check final balances
      const [balanceAfter, recipientBalanceAfter] = await Promise.all([
        publicClient.readContract({
          address: XPNTS1_TOKEN,
          abi: [{ type: 'function', name: 'balanceOf', inputs: [{type: 'address'}], outputs: [{type: 'uint256'}], stateMutability: 'view' }],
          functionName: 'balanceOf',
          args: [AA_ACCOUNT]
        }),
        publicClient.readContract({
          address: XPNTS1_TOKEN,
          abi: [{ type: 'function', name: 'balanceOf', inputs: [{type: 'address'}], outputs: [{type: 'uint256'}], stateMutability: 'view' }],
          functionName: 'balanceOf',
          args: [RECIPIENT]
        })
      ]);

      console.log('📊 Final Balances:');
      console.log(`  Sender: ${Number(balanceAfter) / 10**Number(decimals)} ${symbol}`);
      console.log(`  Recipient: ${Number(recipientBalanceAfter) / 10**Number(decimals)} ${symbol}`);

      const senderDiff = balanceBefore - balanceAfter;
      const recipientDiff = recipientBalanceAfter - recipientBalanceBefore;

      console.log('\n📈 Changes:');
      console.log(`  Sender: -${Number(senderDiff) / 10**Number(decimals)} ${symbol}`);
      console.log(`  Recipient: +${Number(recipientDiff) / 10**Number(decimals)} ${symbol}`);

      if (recipientDiff === transferAmount) {
        console.log('\n✅✅✅ GASLESS TRANSFER SUCCESSFUL! ✅✅✅');
        console.log('  Transfer completed without sender paying gas!');
      } else {
        console.log('\n⚠️  Transfer amount mismatch');
      }

      console.log(`\n💰 Gas paid by: ${receipt.from}`);
      console.log(`   Gas used: ${receipt.gasUsed}`);

    } else {
      console.log('  ❌ Transaction failed\n');
    }

  } catch (error) {
    console.error('\n❌ Error:', error.message);

    // Decode common errors
    const errorStr = error.message;
    if (errorStr.includes('AA93')) {
      console.error('\n  Issue: Paymaster validation failed (AA93)');
    } else if (errorStr.includes('AA33')) {
      console.error('\n  Issue: Paymaster internal validation failed (AA33)');
    } else if (errorStr.includes('AA31')) {
      console.error('\n  Issue: Paymaster deposit too low (AA31)');
    }

    process.exit(1);
  }

  console.log('\n╔═══════════════════════════════════════════════════════════╗');
  console.log('║                  Test Completed                           ║');
  console.log('╚═══════════════════════════════════════════════════════════╝');
}

main().catch(console.error);

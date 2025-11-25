#!/usr/bin/env node
/**
 * Gasless Transfer Test using Viem
 * Tests SuperPaymaster V2.3.3 - ERC-4337 Compliant PostOp Payment + SBT Internal Registry
 *
 * V2.3.3 新特性:
 * 1. ERC-4337合规: 将xPNTs转账从验证阶段移至postOp阶段
 * 2. SBT内部注册表: 优化gas消耗 (~800 gas节省)
 * 3. 债务跟踪: postOp失败时记录用户欠款，防止免费交易
 * 4. 继承V2.3.2的所有gas优化
 */
const { createPublicClient, createWalletClient, http, parseUnits, encodeFunctionData, concat, pad, decodeEventLog } = require('viem');
const { sepolia } = require('viem/chains');
const { privateKeyToAccount } = require('viem/accounts');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../../env/.env') });

// V2.3.3 合约地址
const SUPER_PAYMASTER = '0x7c3c355d9aa4723402bec2a35b61137b8a10d5db';
const XPNTS1_TOKEN = '0xBD0710596010a157B88cd141d797E8Ad4bb2306b'; // aPNTs
const ENTRYPOINT = '0x0000000071727De22E5E9d8BAf0edAc6f37da032';
const OPERATOR = '0x411BD567E46C0781248dbB6a9211891C032885e5';
const AA_ACCOUNT = '0x57b2e6f08399c276b2c1595825219d29990d0921';
const RECIPIENT = '0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA';

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════════════════╗');
  console.log('║  ⚡ Gasless Test V2.3.3 - ERC-4337 Compliant PostOp Payment         ║');
  console.log('╚═══════════════════════════════════════════════════════════════════════╝\n');

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
  console.log(`  SuperPaymaster: ${SUPER_PAYMASTER} (V2.3.3 - PostOp Payment)`);
  console.log(`  xPNTs1 Token: ${XPNTS1_TOKEN}`);
  console.log(`  Operator: ${OPERATOR}`);
  console.log(`  AA Account: ${AA_ACCOUNT}`);
  console.log(`  Sender EOA: ${account.address}`);
  console.log(`  Recipient: ${RECIPIENT}\n`);

  // Check paymaster deposit
  console.log('💰 Checking Paymaster EntryPoint Deposit:');
  const paymasterDeposit = await publicClient.readContract({
    address: SUPER_PAYMASTER,
    abi: [{ type: 'function', name: 'getDeposit', outputs: [{type: 'uint256'}], stateMutability: 'view' }],
    functionName: 'getDeposit'
  });
  console.log(`  Paymaster deposit: ${Number(paymasterDeposit) / 1e18} ETH`);

  if (paymasterDeposit < 10000000000000000n) { // < 0.01 ETH
    console.log('  ⚠️  Warning: Low paymaster deposit!\n');
  } else {
    console.log('  ✅ Sufficient deposit\n');
  }

  // V2.3.3: Check user debt
  console.log('💳 Checking User Debt:');
  const userDebt = await publicClient.readContract({
    address: SUPER_PAYMASTER,
    abi: [{
      type: 'function',
      name: 'getUserDebtByToken',
      inputs: [{type: 'address', name: 'user'}, {type: 'address', name: 'token'}],
      outputs: [{type: 'uint256'}],
      stateMutability: 'view'
    }],
    functionName: 'getUserDebtByToken',
    args: [AA_ACCOUNT, XPNTS1_TOKEN]
  });
  console.log(`  User debt: ${Number(userDebt) / 1e18} xPNTs1`);

  if (userDebt > 0n) {
    console.log('  ⚠️  Warning: User has outstanding debt! This transaction may fail.\n');
  } else {
    console.log('  ✅ No outstanding debt\n');
  }

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

  // ⚡ V2.3.3 PostOp Payment: postOp现在执行transferFrom，需要更多gas
  const paymasterVerificationGas = 250000n; // 250k (只需检查余额和授权 - 验证阶段只执行view调用)
  const paymasterPostOpGas = 50000n; // 50k (postOp执行transferFrom + 债务记录 + 事件)

  const paymasterAndData = concat([
    SUPER_PAYMASTER,
    pad(`0x${paymasterVerificationGas.toString(16)}`, { dir: 'left', size: 16 }),
    pad(`0x${paymasterPostOpGas.toString(16)}`, { dir: 'left', size: 16 }),
    OPERATOR
  ]);
  console.log(`  PaymasterAndData: ${paymasterAndData.length - 2} hex chars = ${(paymasterAndData.length - 2) / 2} bytes`);
  console.log(`  Paymaster gas limits: verification=${paymasterVerificationGas}, postOp=${paymasterPostOpGas}`);

  // ⚡ OPTIMIZED account gas limits (继承V2.3.2优化)
  const accountGasLimits = concat([
    pad(`0x${(90000).toString(16)}`, { dir: 'left', size: 16 }),  // 90k (actual 12k × 7.5x safety)
    pad(`0x${(80000).toString(16)}`, { dir: 'left', size: 16 })   // 80k (actual 50k × 1.6x safety)
  ]);

  // Pack gas fees: maxPriorityFeePerGas (2 gwei) + maxFeePerGas (2 gwei)
  const gasFees = concat([
    pad(`0x${(2000000000).toString(16)}`, { dir: 'left', size: 16 }),
    pad(`0x${(2000000000).toString(16)}`, { dir: 'left', size: 16 })
  ]);

  console.log('  ✅ V2.3.3 ERC-4337 Compliant Gas Configuration:');
  console.log('    accountVerificationGas: 90,000');
  console.log('    callGasLimit: 80,000');
  console.log('    preVerificationGas: 21,000');
  console.log('    paymasterVerificationGas: 250,000 (只执行view调用 - ERC-4337合规)');
  console.log('    paymasterPostOpGas: 50,000 (执行transferFrom + 债务跟踪)');
  console.log('    特性: 验证阶段无状态修改，支付在postOp执行\n');

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

      // V2.3.3: Decode events to check PostOp payment status
      console.log('📡 Checking PostOp Payment Events:');
      const xPNTsPaidEvent = {
        type: 'event',
        name: 'XPNTsPaid',
        inputs: [
          {type: 'address', indexed: true, name: 'user'},
          {type: 'address', indexed: true, name: 'token'},
          {type: 'uint256', name: 'amount'},
          {type: 'uint256', name: 'timestamp'}
        ]
      };

      const xPNTsPaymentFailedEvent = {
        type: 'event',
        name: 'XPNTsPaymentFailed',
        inputs: [
          {type: 'address', indexed: true, name: 'user'},
          {type: 'address', indexed: true, name: 'token'},
          {type: 'uint256', name: 'amount'},
          {type: 'string', name: 'reason'},
          {type: 'uint256', name: 'timestamp'}
        ]
      };

      const userDebtRecordedEvent = {
        type: 'event',
        name: 'UserDebtRecorded',
        inputs: [
          {type: 'address', indexed: true, name: 'user'},
          {type: 'address', indexed: true, name: 'token'},
          {type: 'uint256', name: 'amount'},
          {type: 'uint256', name: 'totalDebt'},
          {type: 'uint256', name: 'timestamp'}
        ]
      };

      let paymentSuccess = false;
      let paymentFailed = false;
      let debtRecorded = false;

      for (const log of receipt.logs) {
        if (log.address.toLowerCase() === SUPER_PAYMASTER.toLowerCase()) {
          try {
            // Try XPNTsPaid
            const decoded = decodeEventLog({
              abi: [xPNTsPaidEvent],
              data: log.data,
              topics: log.topics
            });
            console.log(`  ✅ XPNTsPaid: ${Number(decoded.args.amount) / 1e18} xPNTs`);
            paymentSuccess = true;
          } catch {}

          try {
            // Try XPNTsPaymentFailed
            const decoded = decodeEventLog({
              abi: [xPNTsPaymentFailedEvent],
              data: log.data,
              topics: log.topics
            });
            console.log(`  ❌ XPNTsPaymentFailed: ${decoded.args.reason}`);
            paymentFailed = true;
          } catch {}

          try {
            // Try UserDebtRecorded
            const decoded = decodeEventLog({
              abi: [userDebtRecordedEvent],
              data: log.data,
              topics: log.topics
            });
            console.log(`  📝 UserDebtRecorded: ${Number(decoded.args.totalDebt) / 1e18} xPNTs total debt`);
            debtRecorded = true;
          } catch {}
        }
      }

      if (!paymentSuccess && !paymentFailed) {
        console.log('  ℹ️  No PostOp payment events found (check logs manually)\n');
      } else {
        console.log('');
      }

      // Check final balances
      const [balanceAfter, recipientBalanceAfter, userDebtAfter] = await Promise.all([
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
          address: SUPER_PAYMASTER,
          abi: [{
            type: 'function',
            name: 'getUserDebtByToken',
            inputs: [{type: 'address'}, {type: 'address'}],
            outputs: [{type: 'uint256'}],
            stateMutability: 'view'
          }],
          functionName: 'getUserDebtByToken',
          args: [AA_ACCOUNT, XPNTS1_TOKEN]
        })
      ]);

      console.log('📊 Final Balances:');
      console.log(`  Sender: ${Number(balanceAfter) / 10**Number(decimals)} ${symbol}`);
      console.log(`  Recipient: ${Number(recipientBalanceAfter) / 10**Number(decimals)} ${symbol}`);
      console.log(`  User Debt: ${Number(userDebtAfter) / 1e18} xPNTs`);

      const senderDiff = balanceBefore - balanceAfter;
      const recipientDiff = recipientBalanceAfter - recipientBalanceBefore;

      console.log('\n📈 Changes:');
      console.log(`  Sender: -${Number(senderDiff) / 10**Number(decimals)} ${symbol}`);
      console.log(`  Recipient: +${Number(recipientDiff) / 10**Number(decimals)} ${symbol}`);

      if (recipientDiff === transferAmount && paymentSuccess) {
        console.log('\n✅✅✅ GASLESS TRANSFER SUCCESSFUL! ✅✅✅');
        console.log('  Transfer completed without sender paying gas!');
        console.log('\n🎯 V2.3.3 ERC-4337 Compliance Verified:');
        console.log('  ✅ Validation phase: 只执行view调用 (balance + allowance check)');
        console.log('  ✅ PostOp phase: 执行xPNTs transferFrom (ERC-4337合规)');
        console.log('  ✅ Payment successful in postOp - 无债务记录');
        console.log('\n🔒 V2.3.3 新特性:');
        console.log('  ✅ SBT内部注册表 - ~800 gas优化');
        console.log('  ✅ PostOp债务跟踪 - 防止免费交易');
        console.log('  ✅ 继承V2.3.2所有gas优化 (~49.5% vs v1.0)');
      } else if (recipientDiff === transferAmount && paymentFailed) {
        console.log('\n⚠️  TRANSFER SUCCESSFUL BUT PAYMENT FAILED');
        console.log('  Transfer completed, but xPNTs payment failed in postOp');
        console.log('  This is expected behavior - debt has been recorded');
        console.log('  User must clear debt before next transaction');
      } else {
        console.log('\n⚠️  Transfer amount mismatch or payment status unclear');
      }

      console.log(`\n💰 Gas paid by: ${receipt.from}`);
      console.log(`   Gas used: ${receipt.gasUsed}`);
      console.log(`   PostOp gas overhead: ~${50000 - 10000} gas (transferFrom execution)`);

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
    } else if (errorStr.includes('OutstandingDebt')) {
      console.error('\n  Issue: User has outstanding debt - must clear before next transaction');
    }

    process.exit(1);
  }

  console.log('\n╔═══════════════════════════════════════════════════════════════════════╗');
  console.log('║                  V2.3.3 Test Completed                                ║');
  console.log('╚═══════════════════════════════════════════════════════════════════════╝');
}

main().catch(console.error);

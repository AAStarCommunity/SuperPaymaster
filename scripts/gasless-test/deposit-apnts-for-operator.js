#!/usr/bin/env node
/**
 * Deposit aPNTs for Operator
 * Requires: DEPLOYER_PRIVATE_KEY (owner of aPNTs token contract to mint)
 *           or operator already has aPNTs tokens
 */
const { createPublicClient, createWalletClient, http, parseEther, formatEther } = require('viem');
const { sepolia } = require('viem/chains');
const { privateKeyToAccount } = require('viem/accounts');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../env/.env') });

const SUPER_PAYMASTER = '0xD6aa17587737C59cbb82986Afbac88Db75771857';
const APNTS_TOKEN = '0xBD0710596010a157B88cd141d797E8Ad4bb2306b';
const OPERATOR = '0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C';

// Read pk3 from registry/.env
const registryEnv = fs.readFileSync(path.join(__dirname, '../registry/.env'), 'utf-8');
const pk3Match = registryEnv.match(/pk3=([a-f0-9]+)/);
if (!pk3Match) {
  console.error('❌ pk3 not found in registry/.env');
  process.exit(1);
}

const operatorKey = `0x${pk3Match[1]}`;
const operatorAccount = privateKeyToAccount(operatorKey);

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║           Deposit aPNTs for Operator                     ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  console.log(`Operator: ${OPERATOR}`);
  console.log(`Operator EOA (from pk3): ${operatorAccount.address}`);
  console.log(`aPNTs Token: ${APNTS_TOKEN}\n`);

  if (operatorAccount.address.toLowerCase() !== OPERATOR.toLowerCase()) {
    console.log('⚠️  WARNING: pk3 address does not match OPERATOR constant!');
    console.log(`   Using pk3 address: ${operatorAccount.address}\n`);
  }

  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(process.env.SEPOLIA_RPC_URL)
  });

  const walletClient = createWalletClient({
    account: operatorAccount,
    chain: sepolia,
    transport: http(process.env.SEPOLIA_RPC_URL)
  });

  // Check operator's aPNTs balance
  const balance = await publicClient.readContract({
    address: APNTS_TOKEN,
    abi: [{type: 'function', name: 'balanceOf', inputs: [{type: 'address'}], outputs: [{type: 'uint256'}], stateMutability: 'view'}],
    functionName: 'balanceOf',
    args: [operatorAccount.address]
  });

  console.log(`Operator's aPNTs balance: ${formatEther(balance)} aPNTs\n`);

  const depositAmount = parseEther('6000'); // 6000 aPNTs

  if (balance < depositAmount) {
    console.log(`❌ Operator没有足够的aPNTs token！`);
    console.log(`   需要: 6000 aPNTs`);
    console.log(`   拥有: ${formatEther(balance)} aPNTs\n`);
    console.log('解决方法：');
    console.log('1. 如果aPNTs token有mint函数，owner可以mint给operator');
    console.log('2. 或者从其他账户转账aPNTs给operator');
    console.log('3. 或者调整aPNTsPriceUSD，提高aPNTs价格（减少所需数量）');
    return;
  }

  // Check allowance
  const allowance = await publicClient.readContract({
    address: APNTS_TOKEN,
    abi: [{type: 'function', name: 'allowance', inputs: [{type: 'address'}, {type: 'address'}], outputs: [{type: 'uint256'}], stateMutability: 'view'}],
    functionName: 'allowance',
    args: [operatorAccount.address, SUPER_PAYMASTER]
  });

  console.log(`Current allowance: ${formatEther(allowance)} aPNTs\n`);

  if (allowance < depositAmount) {
    console.log('Step 1: Approve SuperPaymaster to spend aPNTs...');
    try {
      const hash = await walletClient.writeContract({
        address: APNTS_TOKEN,
        abi: [{
          type: 'function',
          name: 'approve',
          inputs: [{type: 'address', name: 'spender'}, {type: 'uint256', name: 'amount'}],
          outputs: [{type: 'bool'}],
          stateMutability: 'nonpayable'
        }],
        functionName: 'approve',
        args: [SUPER_PAYMASTER, depositAmount]
      });

      console.log(`  TX Hash: ${hash}`);
      console.log(`  Waiting for confirmation...`);
      const receipt = await publicClient.waitForTransactionReceipt({ hash });

      if (receipt.status === 'success') {
        console.log(`  ✅ Approval confirmed!\n`);
      } else {
        console.log(`  ❌ Approval failed\n`);
        return;
      }
    } catch (error) {
      console.error('\n❌ Approval error:', error.message);
      return;
    }
  } else {
    console.log('✅ Allowance already sufficient, skipping approval\n');
  }

  // Deposit aPNTs
  console.log('Step 2: Deposit aPNTs to SuperPaymaster...');
  try {
    const hash = await walletClient.writeContract({
      address: SUPER_PAYMASTER,
      abi: [{
        type: 'function',
        name: 'depositAPNTs',
        inputs: [{type: 'uint256', name: 'amount'}],
        outputs: [],
        stateMutability: 'nonpayable'
      }],
      functionName: 'depositAPNTs',
      args: [depositAmount]
    });

    console.log(`  TX Hash: ${hash}`);
    console.log(`  Etherscan: https://sepolia.etherscan.io/tx/${hash}`);
    console.log(`  Waiting for confirmation...`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });

    if (receipt.status === 'success') {
      console.log(`  ✅ Deposit confirmed in block ${receipt.blockNumber}!\n`);
      console.log('✅✅✅ APNTS DEPOSITED SUCCESSFULLY! ✅✅✅');
      console.log('\nOperator现在有足够的aPNTs余额，可以重试gasless交易测试！');
    } else {
      console.log(`  ❌ Deposit failed\n`);
    }
  } catch (error) {
    console.error('\n❌ Deposit error:', error.message);
  }
}

main().catch(console.error);

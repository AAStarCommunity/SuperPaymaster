#!/usr/bin/env node
/**
 * Register Operator to SuperPaymaster V2.3.3 (New Deployment)
 * V2.3.3: ERC-4337 Compliant PostOp Payment + SBT Internal Registry
 * New Deployment: 0x7c3c355d9aa4723402bec2a35b61137b8a10d5db
 */
const { createPublicClient, createWalletClient, http, parseEther } = require('viem');
const { sepolia } = require('viem/chains');
const { privateKeyToAccount } = require('viem/accounts');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../../.env') });

const SUPER_PAYMASTER_V233 = '0x7c3c355d9aa4723402bec2a35b61137b8a10d5db';
const GTOKEN_STAKING = '0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0';
const GTOKEN = '0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc';
const XPNTS1_TOKEN = '0xfb56CB85C9a214328789D3C92a496d6AA185e3d3';

// Read from env
const cleanPrivateKey = process.env.PRIVATE_KEY.trim().replace(/^["']|["']$/g, '').replace(/^0x/, '');
const account = privateKeyToAccount(`0x${cleanPrivateKey}`);
const OPERATOR = account.address;

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║     Register Operator to SuperPaymaster V2.3.3            ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  console.log(`Operator: ${OPERATOR}`);
  console.log(`SuperPaymaster: ${SUPER_PAYMASTER_V233}`);
  console.log(`xPNTs Token: ${XPNTS1_TOKEN}\n`);

  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(process.env.SEPOLIA_RPC_URL)
  });

  const walletClient = createWalletClient({
    account,
    chain: sepolia,
    transport: http(process.env.SEPOLIA_RPC_URL)
  });

  // Check GT balance
  const gtBalance = await publicClient.readContract({
    address: GTOKEN,
    abi: [{type: 'function', name: 'balanceOf', inputs: [{type: 'address'}], outputs: [{type: 'uint256'}], stateMutability: 'view'}],
    functionName: 'balanceOf',
    args: [OPERATOR]
  });

  console.log(`GT Balance: ${Number(gtBalance) / 1e18} GT\n`);

  // Check minOperatorStake
  const minStake = await publicClient.readContract({
    address: SUPER_PAYMASTER_V233,
    abi: [{type: 'function', name: 'minOperatorStake', outputs: [{type: 'uint256'}], stateMutability: 'view'}],
    functionName: 'minOperatorStake'
  });

  console.log(`Min Operator Stake: ${Number(minStake) / 1e18} GT\n`);

  if (gtBalance < minStake) {
    console.error(`❌ Insufficient GT balance! Need ${Number(minStake) / 1e18} GT, have ${Number(gtBalance) / 1e18} GT`);
    process.exit(1);
  }

  const stakeAmount = minStake; // Use minimum stake
  const aPNTsAmount = 0n; // No initial aPNTs
  const treasury = OPERATOR; // Use operator address as treasury

  console.log('Parameters:');
  console.log(`  Stake: ${Number(minStake) / 1e18} GT`);
  console.log(`  xPNTs Token: ${XPNTS1_TOKEN}`);
  console.log(`  Treasury: ${treasury}\n`);

  try {
    // First approve GToken
    console.log('Step 1: Approving GT for SuperPaymaster...');
    const approveHash = await walletClient.writeContract({
      address: GTOKEN,
      abi: [{type: 'function', name: 'approve', inputs: [{type: 'address', name: 'spender'}, {type: 'uint256', name: 'amount'}]}],
      functionName: 'approve',
      args: [SUPER_PAYMASTER_V233, stakeAmount]
    });
    console.log(`  TX: ${approveHash}`);
    await publicClient.waitForTransactionReceipt({ hash: approveHash });
    console.log(`✅ Approved\n`);

    // Register operator
    console.log('Step 2: Registering operator...');
    const hash = await walletClient.writeContract({
      address: SUPER_PAYMASTER_V233,
      abi: [{
        type: 'function',
        name: 'registerOperatorWithAutoStake',
        inputs: [
          {type: 'uint256', name: 'stGTokenAmount'},
          {type: 'uint256', name: 'aPNTsAmount'},
          {type: 'address', name: 'xPNTsToken'},
          {type: 'address', name: 'treasury'}
        ],
        outputs: [],
        stateMutability: 'nonpayable'
      }],
      functionName: 'registerOperatorWithAutoStake',
      args: [stakeAmount, aPNTsAmount, XPNTS1_TOKEN, treasury]
    });

    console.log(`  TX: ${hash}`);
    console.log(`  Etherscan: https://sepolia.etherscan.io/tx/${hash}`);
    console.log('  Waiting for confirmation...\n');

    const receipt = await publicClient.waitForTransactionReceipt({ hash });

    if (receipt.status === 'success') {
      console.log(`✅ Operator registered in block ${receipt.blockNumber}!`);
      console.log(`   Gas used: ${receipt.gasUsed.toString()}\n`);
      console.log('═══════════════════════════════════════════════════════════');
      console.log('✅✅✅ REGISTRATION SUCCESSFUL! ✅✅✅');
      console.log('═══════════════════════════════════════════════════════════\n');
      console.log('Next steps:');
      console.log('1. Deposit aPNTs for gasless sponsorship');
      console.log('2. Test gasless transactions');
    } else {
      console.log('❌ Registration failed');
    }

  } catch (error) {
    console.error('\n❌ Error:', error.message);

    if (error.message.includes('AlreadyRegistered')) {
      console.error('   Operator is already registered!');
      console.error('   This means registration was successful before.');
    } else if (error.message.includes('InsufficientStake')) {
      console.error('   Insufficient stake amount!');
    } else if (error.message.includes('0x04d95544')) {
      console.error('   Error from GTokenStaking.lockStake');
      console.error('   Check if operator has sufficient availableBalance in staking contract');
    } else {
      console.error('   Details:', error);
    }
  }
}

main().catch(console.error);

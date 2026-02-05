#!/usr/bin/env node
/**
 * Register Operator to SuperPaymaster V2.3.3
 * V2.3.3: ERC-4337 Compliant PostOp Payment + SBT Internal Registry
 */
const { createPublicClient, createWalletClient, http, parseEther } = require('viem');
const { sepolia } = require('viem/chains');
const { privateKeyToAccount } = require('viem/accounts');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../../env/.env') });

const SUPER_PAYMASTER_V233 = '0xc7ac591476ccafe064f1e74cdbd1f70abad0ad9c';
const GTOKEN_STAKING = '0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0';
const GTOKEN = '0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc';
const XPNTS1_TOKEN = '0xfb56CB85C9a214328789D3C92a496d6AA185e3d3';
const OPERATOR = '0x411BD567E46C0781248dbB6a9211891C032885e5';

// Use operator's private key from environment
const privateKey = process.env.PRIVATE_KEY_SUPPLIER || process.env.TEST_PRIVATE_KEY;
if (!privateKey) {
  throw new Error('PRIVATE_KEY_SUPPLIER or TEST_PRIVATE_KEY not found in environment');
}
const account = privateKeyToAccount(privateKey);

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║     Register Operator to SuperPaymaster V2.3.3            ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  console.log(`Deployer: ${account.address}`);
  console.log(`Operator to register: ${OPERATOR}`);
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

  // Check minOperatorStake
  const minStake = await publicClient.readContract({
    address: SUPER_PAYMASTER_V233,
    abi: [{type: 'function', name: 'minOperatorStake', outputs: [{type: 'uint256'}], stateMutability: 'view'}],
    functionName: 'minOperatorStake'
  });

  console.log(`Min Operator Stake: ${Number(minStake) / 1e18} GToken\n`);

  // V2.3.3 signature (same as V2.3.2 - NO supportedSBTs parameter!)
  console.log('Using registerOperatorWithAutoStake (V2.3.3)\n');

  const stakeAmount = minStake; // Use minimum stake
  const aPNTsAmount = 0n; // No initial aPNTs
  const treasury = OPERATOR; // Use operator address as treasury

  console.log('Parameters:');
  console.log(`  Stake: ${Number(minStake) / 1e18} GToken`);
  console.log(`  xPNTs Token: ${XPNTS1_TOKEN}`);
  console.log(`  Treasury: ${treasury}\n`);

  try {
    // First approve GToken
    console.log('Approving GToken for paymaster...');
    const approveHash = await walletClient.writeContract({
      address: GTOKEN,
      abi: [{type: 'function', name: 'approve', inputs: [{type: 'address'}, {type: 'uint256'}]}],
      functionName: 'approve',
      args: [SUPER_PAYMASTER_V233, stakeAmount]
    });
    await publicClient.waitForTransactionReceipt({ hash: approveHash });
    console.log(`✅ Approved\n`);

    // Register operator
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

    console.log(`\n✅ Transaction sent!`);
    console.log(`TX Hash: ${hash}`);
    console.log(`Etherscan: https://sepolia.etherscan.io/tx/${hash}\n`);

    console.log('Waiting for confirmation...');
    const receipt = await publicClient.waitForTransactionReceipt({ hash });

    if (receipt.status === 'success') {
      console.log(`✅ Operator registered in block ${receipt.blockNumber}!\n`);
      console.log('✅✅✅ REGISTRATION SUCCESSFUL! ✅✅✅');
      console.log('\nNow you can test the gasless transfer!');
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
    }
  }
}

main().catch(console.error);

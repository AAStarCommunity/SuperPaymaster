#!/usr/bin/env node
/**
 * Register Operator to SuperPaymaster
 * Requires: pk3 from registry/.env
 */
const { createPublicClient, createWalletClient, http, parseEther } = require('viem');
const { sepolia } = require('viem/chains');
const { privateKeyToAccount } = require('viem/accounts');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../env/.env') });

const SUPER_PAYMASTER = '0xD6aa17587737C59cbb82986Afbac88Db75771857';
const GTOKEN_STAKING = '0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0';
const GTOKEN = '0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc';
const XPNTS1_TOKEN = '0xfb56CB85C9a214328789D3C92a496d6AA185e3d3';
const MYSBT = '0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C';

// Read pk3 from registry/.env
const registryEnv = fs.readFileSync(path.join(__dirname, '../registry/.env'), 'utf-8');
const pk3Match = registryEnv.match(/pk3=([a-f0-9]+)/);
if (!pk3Match) {
  console.error('❌ pk3 not found in registry/.env');
  process.exit(1);
}

const privateKey = `0x${pk3Match[1]}`;
const account = privateKeyToAccount(privateKey);

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║          Register Operator to SuperPaymaster              ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  console.log(`Operator: ${account.address}`);
  console.log(`MySBT to support: ${MYSBT}`);
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
    address: SUPER_PAYMASTER,
    abi: [{type: 'function', name: 'minOperatorStake', outputs: [{type: 'uint256'}], stateMutability: 'view'}],
    functionName: 'minOperatorStake'
  });

  console.log(`Min Operator Stake: ${Number(minStake) / 1e18} GToken\n`);

  // Use registerOperatorWithAutoStake (auto-handles staking)
  console.log('Using registerOperatorWithAutoStake (auto-stake + register)\n');

  const stakeAmount = minStake; // Use minimum stake
  const aPNTsAmount = 0n; // No initial aPNTs
  const supportedSBTs = [MYSBT];
  const treasury = account.address; // Use operator address as treasury

  console.log('Parameters:');
  console.log(`  Stake: ${Number(minStake) / 1e18} GToken`);
  console.log(`  SBTs: [${MYSBT}]`);
  console.log(`  Treasury: ${treasury}\n`);

  try {
    const hash = await walletClient.writeContract({
      address: SUPER_PAYMASTER,
      abi: [{
        type: 'function',
        name: 'registerOperatorWithAutoStake',
        inputs: [
          {type: 'uint256', name: 'stGTokenAmount'},
          {type: 'uint256', name: 'aPNTsAmount'},
          {type: 'address[]', name: 'supportedSBTs'},
          {type: 'address', name: 'xPNTsToken'},
          {type: 'address', name: 'treasury'}
        ],
        outputs: [],
        stateMutability: 'nonpayable'
      }],
      functionName: 'registerOperatorWithAutoStake',
      args: [stakeAmount, aPNTsAmount, supportedSBTs, XPNTS1_TOKEN, treasury]
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

#!/usr/bin/env node
/**
 * Check Operator Balances and Registration Status for V2.3.3
 */
const { createPublicClient, http } = require('viem');
const { sepolia } = require('viem/chains');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../../env/.env') });

const SUPER_PAYMASTER_V233 = '0xc7ac591476ccafe064f1e74cdbd1f70abad0ad9c';
const GTOKEN_STAKING = '0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0';
const GTOKEN = '0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc';
const OPERATOR = '0x411BD567E46C0781248dbB6a9211891C032885e5';

async function main() {
  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(process.env.SEPOLIA_RPC_URL)
  });

  console.log('╔══════════════════════════════════════════════════════╗');
  console.log('║  Operator Balance & Status Check - V2.3.3           ║');
  console.log('╚══════════════════════════════════════════════════════╝\n');

  console.log(`Operator: ${OPERATOR}\n`);

  // Check GToken balance
  const gtokenBalance = await publicClient.readContract({
    address: GTOKEN,
    abi: [{type: 'function', name: 'balanceOf', inputs: [{type: 'address'}], outputs: [{type: 'uint256'}], stateMutability: 'view'}],
    functionName: 'balanceOf',
    args: [OPERATOR]
  });

  console.log(`GToken Balance: ${Number(gtokenBalance) / 1e18} GT`);

  // Check staked balance in GTokenStaking
  try {
    const stakedBalance = await publicClient.readContract({
      address: GTOKEN_STAKING,
      abi: [{type: 'function', name: 'stakedBalance', inputs: [{type: 'address'}], outputs: [{type: 'uint256'}], stateMutability: 'view'}],
      functionName: 'stakedBalance',
      args: [OPERATOR]
    });
    console.log(`Staked Balance: ${Number(stakedBalance) / 1e18} stGT`);
  } catch (e) {
    console.log('Staked Balance: Unable to read');
  }

  // Check available balance in GTokenStaking
  try {
    const availableBalance = await publicClient.readContract({
      address: GTOKEN_STAKING,
      abi: [{type: 'function', name: 'availableBalance', inputs: [{type: 'address'}], outputs: [{type: 'uint256'}], stateMutability: 'view'}],
      functionName: 'availableBalance',
      args: [OPERATOR]
    });
    console.log(`Available Balance: ${Number(availableBalance) / 1e18} stGT`);
  } catch (e) {
    console.log('Available Balance: Unable to read');
  }

  // Check minOperatorStake
  const minStake = await publicClient.readContract({
    address: SUPER_PAYMASTER_V233,
    abi: [{type: 'function', name: 'minOperatorStake', outputs: [{type: 'uint256'}], stateMutability: 'view'}],
    functionName: 'minOperatorStake'
  });

  console.log(`\nMin Operator Stake Required: ${Number(minStake) / 1e18} GT`);

  // Check if operator is registered
  try {
    const account = await publicClient.readContract({
      address: SUPER_PAYMASTER_V233,
      abi: [{
        type: 'function',
        name: 'getOperatorAccount',
        inputs: [{type: 'address'}],
        outputs: [{
          type: 'tuple',
          components: [
            {type: 'address', name: 'xPNTsToken'},
            {type: 'address', name: 'treasury'},
            {type: 'bool', name: 'isPaused'},
            {type: 'uint256', name: 'aPNTsBalance'},
            {type: 'uint256', name: 'totalSpent'},
            {type: 'uint256', name: 'totalTxSponsored'},
            {type: 'uint256', name: 'stGTokenLocked'},
            {type: 'uint256', name: 'exchangeRate'},
            {type: 'uint256', name: 'reputationScore'},
            {type: 'uint256', name: 'reputationLevel'},
            {type: 'uint256', name: 'stakedAt'},
            {type: 'uint256', name: 'lastRefillTime'},
            {type: 'uint256', name: 'lastCheckTime'},
            {type: 'uint256', name: 'minBalanceThreshold'},
            {type: 'uint256', name: 'consecutiveDays'}
          ]
        }],
        stateMutability: 'view'
      }],
      functionName: 'getOperatorAccount',
      args: [OPERATOR]
    });

    if (account[10] > 0) { // stakedAt
      console.log(`\n✅ Operator is REGISTERED`);
      console.log(`   Locked Stake: ${Number(account[6]) / 1e18} stGT`);
      console.log(`   aPNTs Balance: ${Number(account[3]) / 1e18}`);
    } else {
      console.log(`\n❌ Operator is NOT registered`);
    }
  } catch (e) {
    console.log(`\n⚠️  Unable to check registration status`);
  }

  console.log('\n╚══════════════════════════════════════════════════════╝');
}

main().catch(console.error);

#!/usr/bin/env node
/**
 * Mint MySBT for AA Account
 */
const { createPublicClient, createWalletClient, http, parseEther } = require('viem');
const { sepolia } = require('viem/chains');
const { privateKeyToAccount } = require('viem/accounts');
require('dotenv').config({ path: require('path').join(__dirname, '../env/.env') });

const MYSBT_V240 = '0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C';
const AA_ACCOUNT = '0x57b2e6f08399c276b2c1595825219d29990d0921';
const GTOKEN_STAKING = '0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0';
const GTOKEN = '0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc';

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║          Mint MySBT for AA Account                        ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  // Use OWNER2_PRIVATE_KEY (AA account owner)
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

  console.log(`AA Account: ${AA_ACCOUNT}`);
  console.log(`Owner (Signer): ${account.address}`);
  console.log(`MySBT v2.4.0: ${MYSBT_V240}\n`);

  // Check current SBT balance
  const currentBalance = await publicClient.readContract({
    address: MYSBT_V240,
    abi: [{type: 'function', name: 'balanceOf', inputs: [{type: 'address'}], outputs: [{type: 'uint256'}], stateMutability: 'view'}],
    functionName: 'balanceOf',
    args: [AA_ACCOUNT]
  });

  console.log(`Current SBT balance: ${currentBalance.toString()}`);

  if (currentBalance > 0n) {
    console.log('✅ AA Account already has MySBT!');
    return;
  }

  console.log('❌ AA Account does NOT have MySBT\n');

  // Check mint fee
  const mintFee = await publicClient.readContract({
    address: MYSBT_V240,
    abi: [{type: 'function', name: 'mintFee', outputs: [{type: 'uint256'}], stateMutability: 'view'}],
    functionName: 'mintFee'
  });

  console.log(`Mint fee: ${mintFee.toString()} wei (${Number(mintFee) / 1e18} ETH)`);

  // Check minLockAmount
  const minLockAmount = await publicClient.readContract({
    address: MYSBT_V240,
    abi: [{type: 'function', name: 'minLockAmount', outputs: [{type: 'uint256'}], stateMutability: 'view'}],
    functionName: 'minLockAmount'
  });

  console.log(`Min lock amount: ${minLockAmount.toString()} (${Number(minLockAmount) / 1e18} GTOKEN)\n`);

  // Step 1: Approve GToken to MySBT
  console.log('Step 1: Approving GTOKEN to MySBT...');

  const approveTx = await walletClient.writeContract({
    address: GTOKEN,
    abi: [{type: 'function', name: 'approve', inputs: [{type: 'address', name: 'spender'}, {type: 'uint256', name: 'amount'}]}],
    functionName: 'approve',
    args: [MYSBT_V240, minLockAmount]
  });

  console.log(`  TX: ${approveTx}`);
  await publicClient.waitForTransactionReceipt({ hash: approveTx });
  console.log('  ✅ Approved\n');

  // Step 2: Mint SBT
  console.log('Step 2: Minting MySBT...');

  const mintTx = await walletClient.writeContract({
    address: MYSBT_V240,
    abi: [{type: 'function', name: 'mint', inputs: [{type: 'address', name: 'to'}]}],
    functionName: 'mint',
    args: [AA_ACCOUNT],
    value: mintFee
  });

  console.log(`  TX: ${mintTx}`);
  console.log(`  Etherscan: https://sepolia.etherscan.io/tx/${mintTx}\n`);

  console.log('  Waiting for confirmation...');
  const receipt = await publicClient.waitForTransactionReceipt({ hash: mintTx });

  if (receipt.status === 'success') {
    console.log(`  ✅ Minted in block ${receipt.blockNumber}!\n`);

    // Check new balance
    const newBalance = await publicClient.readContract({
      address: MYSBT_V240,
      abi: [{type: 'function', name: 'balanceOf', inputs: [{type: 'address'}], outputs: [{type: 'uint256'}], stateMutability: 'view'}],
      functionName: 'balanceOf',
      args: [AA_ACCOUNT]
    });

    console.log(`New SBT balance: ${newBalance.toString()}`);
    console.log('\n✅✅✅ MySBT MINTED SUCCESSFULLY! ✅✅✅');
    console.log('\nNow you can retry the gasless transfer test!');
  } else {
    console.log('  ❌ Mint failed');
  }
}

main().catch(console.error);

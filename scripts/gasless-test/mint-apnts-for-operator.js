#!/usr/bin/env node
/**
 * Mint aPNTs for Operator
 * Requires: DEPLOYER_PRIVATE_KEY (owner of aPNTs token)
 */
const { createPublicClient, createWalletClient, http, parseEther } = require('viem');
const { sepolia } = require('viem/chains');
const { privateKeyToAccount } = require('viem/accounts');
require('dotenv').config({ path: require('path').join(__dirname, '../env/.env') });

const APNTS_TOKEN = '0xBD0710596010a157B88cd141d797E8Ad4bb2306b';
const OPERATOR = '0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C';

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║              Mint aPNTs for Operator                     ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  const privateKey = process.env.DEPLOYER_PRIVATE_KEY.startsWith('0x')
    ? process.env.DEPLOYER_PRIVATE_KEY
    : `0x${process.env.DEPLOYER_PRIVATE_KEY}`;
  const account = privateKeyToAccount(privateKey);

  console.log(`Deployer (caller): ${account.address}`);
  console.log(`Operator (recipient): ${OPERATOR}`);
  console.log(`aPNTs Token: ${APNTS_TOKEN}\n`);

  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(process.env.SEPOLIA_RPC_URL)
  });

  const walletClient = createWalletClient({
    account,
    chain: sepolia,
    transport: http(process.env.SEPOLIA_RPC_URL)
  });

  const mintAmount = parseEther('10000'); // Mint 10000 aPNTs

  console.log('Attempting to mint 10000 aPNTs for operator...\n');

  try {
    const hash = await walletClient.writeContract({
      address: APNTS_TOKEN,
      abi: [{
        type: 'function',
        name: 'mint',
        inputs: [{type: 'address', name: 'to'}, {type: 'uint256', name: 'amount'}],
        outputs: [],
        stateMutability: 'nonpayable'
      }],
      functionName: 'mint',
      args: [OPERATOR, mintAmount]
    });

    console.log(`✅ Transaction sent!`);
    console.log(`TX Hash: ${hash}`);
    console.log(`Etherscan: https://sepolia.etherscan.io/tx/${hash}\n`);

    console.log('Waiting for confirmation...');
    const receipt = await publicClient.waitForTransactionReceipt({ hash });

    if (receipt.status === 'success') {
      console.log(`✅ Mint confirmed in block ${receipt.blockNumber}!\n`);
      console.log('✅✅✅ APNTS MINTED SUCCESSFULLY! ✅✅✅');
      console.log('\n下一步：运行 node deposit-apnts-for-operator.js 存入aPNTs');
    } else {
      console.log('❌ Mint failed');
    }
  } catch (error) {
    console.error('\n❌ Error:', error.message);

    if (error.message.includes('mint')) {
      console.error('\n  可能原因：');
      console.error('  1. aPNTs token合约没有mint函数');
      console.error('  2. 调用者不是owner');
      console.error('  3. mint函数被禁用或有其他限制\n');
      console.error('  建议：检查aPNTs token合约源代码');
    }
  }
}

main().catch(console.error);

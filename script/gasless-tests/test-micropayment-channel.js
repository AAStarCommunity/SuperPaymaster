#!/usr/bin/env node

/**
 * MicroPaymentChannel E2E Test
 *
 * Tests the full lifecycle of a streaming micropayment channel on Sepolia:
 *   1. Payer opens a channel with aPNTs deposit
 *   2. Payer signs cumulative vouchers (EIP-712)
 *   3. Payee settles partial amount
 *   4. Payee closes channel with final voucher
 *   5. Verify: payee received settled amount, payer got refund
 *
 * Prerequisites:
 *   - MicroPaymentChannel deployed on Sepolia
 *   - Payer (deployer) holds aPNTs
 *   - Payee (Anni) has an address
 */

const { ethers } = require('ethers');
const path = require('path');
require('dotenv').config({ path: process.env.ENV_FILE || path.join(__dirname, '../../.env.sepolia') });

// Constants
const MPC_ADDRESS = '0x5753e9675f68221cA901e495C1696e33F552ea36';
const APNTS_ADDRESS = '0xEA4b9d046285DC21484174C36BbFb58015Ad5E1f';
const CHAIN_ID = 11155111;

// ABIs
const ERC20_ABI = [
  'function approve(address spender, uint256 amount) returns (bool)',
  'function balanceOf(address account) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function decimals() view returns (uint8)',
];

const MPC_ABI = [
  'function openChannel(address payee, address token, uint128 deposit, bytes32 salt, address authorizedSigner) external returns (bytes32 channelId)',
  'function settleChannel(bytes32 channelId, uint128 cumulativeAmount, bytes signature) external',
  'function closeChannel(bytes32 channelId, uint128 cumulativeAmount, bytes signature) external',
  'function getChannel(bytes32 channelId) view returns (tuple(address payer, address payee, address token, address authorizedSigner, uint128 deposit, uint128 settled, uint64 closeRequestedAt, bool finalized))',
  'function version() view returns (string)',
  'function VOUCHER_TYPEHASH() view returns (bytes32)',
];

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║     MicroPaymentChannel E2E Test (Streaming Vouchers)    ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  // Setup
  const rpcUrl = process.env.RPC_URL;
  const provider = new ethers.JsonRpcProvider(rpcUrl);

  // Payer = deployer EOA
  const payerKey = process.env.PRIVATE_KEY;
  const payer = new ethers.Wallet(payerKey, provider);

  // Payee = Anni
  const anniKey = process.env.ANNI_PRIVATE_KEY || process.env.PRIVATE_KEY_ANNI;
  const payee = new ethers.Wallet(anniKey, provider);

  const mpc = new ethers.Contract(MPC_ADDRESS, MPC_ABI, payer);
  const mpcPayee = new ethers.Contract(MPC_ADDRESS, MPC_ABI, payee);
  const apnts = new ethers.Contract(APNTS_ADDRESS, ERC20_ABI, payer);

  console.log('📌 Configuration:');
  console.log(`  MicroPaymentChannel: ${MPC_ADDRESS}`);
  console.log(`  Version: ${await mpc.version()}`);
  console.log(`  aPNTs: ${APNTS_ADDRESS}`);
  console.log(`  Payer: ${payer.address}`);
  console.log(`  Payee: ${payee.address}`);
  console.log();

  // Step 1: Check balances and approve
  console.log('📊 Step 1: Check Balances & Approve');
  const decimals = await apnts.decimals();
  const payerBalance = await apnts.balanceOf(payer.address);
  console.log(`  Payer aPNTs: ${ethers.formatUnits(payerBalance, decimals)}`);

  const depositAmount = ethers.parseUnits('10', decimals); // 10 aPNTs
  if (payerBalance < depositAmount) {
    console.log('❌ Insufficient aPNTs for deposit');
    process.exit(1);
  }

  // Approve MPC to spend aPNTs
  const currentAllowance = await apnts.allowance(payer.address, MPC_ADDRESS);
  if (currentAllowance < depositAmount) {
    console.log('  Approving MPC to spend aPNTs...');
    const approveTx = await apnts.approve(MPC_ADDRESS, ethers.MaxUint256);
    await approveTx.wait();
    console.log('  ✅ Approved');
  } else {
    console.log('  ✅ Already approved');
  }

  // Step 2: Open channel
  console.log('\n🔓 Step 2: Open Channel (10 aPNTs deposit)');
  const salt = ethers.hexlify(ethers.randomBytes(32));

  const payeeBalanceBefore = await apnts.balanceOf(payee.address);

  const openTx = await mpc.openChannel(
    payee.address,
    APNTS_ADDRESS,
    depositAmount,
    salt,
    ethers.ZeroAddress, // no delegated signer
    { gasLimit: 300000 }
  );
  console.log(`  TX: ${openTx.hash}`);
  const openReceipt = await openTx.wait();
  console.log(`  ✅ Channel opened! Gas: ${openReceipt.gasUsed}`);

  // Get channelId from event
  const openEvent = openReceipt.logs.find(
    l => l.address.toLowerCase() === MPC_ADDRESS.toLowerCase() && l.topics.length === 4
  );
  const channelId = openEvent.topics[1];
  console.log(`  Channel ID: ${channelId}`);

  // Verify channel state
  const ch1 = await mpc.getChannel(channelId);
  console.log(`  Deposit: ${ethers.formatUnits(ch1.deposit, decimals)} aPNTs`);
  console.log(`  Settled: ${ethers.formatUnits(ch1.settled, decimals)} aPNTs`);

  // Step 3: Sign and settle partial voucher (3 aPNTs cumulative)
  console.log('\n✍️  Step 3: Settle Partial Voucher (3 aPNTs)');

  const cumulativeAmount1 = ethers.parseUnits('3', decimals);
  const sig1 = await signVoucher(payer, channelId, cumulativeAmount1);
  console.log(`  Voucher signed: cumulative = 3 aPNTs`);

  const settleTx = await mpcPayee.settleChannel(
    channelId, cumulativeAmount1, sig1, { gasLimit: 200000 }
  );
  const settleReceipt = await settleTx.wait();
  console.log(`  ✅ Settled! Gas: ${settleReceipt.gasUsed}`);
  console.log(`  TX: ${settleTx.hash}`);

  const ch2 = await mpc.getChannel(channelId);
  console.log(`  Settled so far: ${ethers.formatUnits(ch2.settled, decimals)} aPNTs`);

  // Step 4: Close channel with final voucher (7 aPNTs cumulative)
  console.log('\n🔒 Step 4: Close Channel (7 aPNTs final)');

  const cumulativeAmount2 = ethers.parseUnits('7', decimals);
  const sig2 = await signVoucher(payer, channelId, cumulativeAmount2);

  const closeTx = await mpcPayee.closeChannel(
    channelId, cumulativeAmount2, sig2, { gasLimit: 200000 }
  );
  const closeReceipt = await closeTx.wait();
  console.log(`  ✅ Channel closed! Gas: ${closeReceipt.gasUsed}`);
  console.log(`  TX: ${closeTx.hash}`);

  // Step 5: Verify results
  console.log('\n📊 Step 5: Verify Results');
  const ch3 = await mpc.getChannel(channelId);
  const payeeBalanceAfter = await apnts.balanceOf(payee.address);

  const payeeReceived = payeeBalanceAfter - payeeBalanceBefore;
  const expectedPayee = ethers.parseUnits('7', decimals);
  const expectedRefund = ethers.parseUnits('3', decimals); // 10 - 7

  console.log(`  Channel finalized: ${ch3.finalized}`);
  console.log(`  Total settled: ${ethers.formatUnits(ch3.settled, decimals)} aPNTs`);
  console.log(`  Payee received: ${ethers.formatUnits(payeeReceived, decimals)} aPNTs`);
  console.log(`  Expected payee: ${ethers.formatUnits(expectedPayee, decimals)} aPNTs`);
  console.log(`  Refund (10-7): ${ethers.formatUnits(expectedRefund, decimals)} aPNTs`);

  let pass = true;
  if (!ch3.finalized) { console.log('  ❌ FAIL: Channel not finalized!'); pass = false; }
  if (payeeReceived !== expectedPayee) { console.log('  ❌ FAIL: Payee amount mismatch!'); pass = false; }
  if (ch3.settled !== cumulativeAmount2) { console.log('  ❌ FAIL: Settled amount mismatch!'); pass = false; }
  if (pass) { console.log('  ✅ All assertions passed!'); }

  // Step 6: Verify channel is finalized (cannot settle again)
  console.log('\n🛡️  Step 6: Test Finalization Protection');
  try {
    const sig3 = await signVoucher(payer, channelId, ethers.parseUnits('8', decimals));
    await mpcPayee.settleChannel.staticCall(channelId, ethers.parseUnits('8', decimals), sig3);
    console.log('  ❌ FAIL: Should have reverted on finalized channel!');
  } catch (e) {
    console.log('  ✅ Finalized channel correctly rejects settlement');
  }

  console.log('\n╔═══════════════════════════════════════════════════════════╗');
  console.log('║                    Test Completed                         ║');
  console.log('╚═══════════════════════════════════════════════════════════╝');
}

async function signVoucher(signer, channelId, cumulativeAmount) {
  const domain = {
    name: 'MicroPaymentChannel',
    version: '1.0.0',
    chainId: CHAIN_ID,
    verifyingContract: MPC_ADDRESS,
  };

  const types = {
    Voucher: [
      { name: 'channelId', type: 'bytes32' },
      { name: 'cumulativeAmount', type: 'uint128' },
    ],
  };

  const value = {
    channelId: channelId,
    cumulativeAmount: cumulativeAmount,
  };

  return await signer.signTypedData(domain, types, value);
}

main().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});

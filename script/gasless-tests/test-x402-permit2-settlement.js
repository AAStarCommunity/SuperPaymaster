#!/usr/bin/env node

/**
 * x402 Payment Settlement E2E Test (Permit2)
 *
 * Tests settleX402PaymentPermit2 on SuperPaymaster V5.2.0
 *
 * Flow:
 *   1. Payer (deployer EOA) approves Permit2 for USDC
 *   2. Payer signs EIP-712 PermitWitnessTransferFrom with payee as witness
 *   3. Facilitator (Anni operator) calls settleX402PaymentPermit2
 *   4. Verify: payee received USDC - fee, facilitator earnings tracked
 *
 * Prerequisites:
 *   - Deployer EOA must hold USDC on Sepolia
 *   - Deployer must approve Permit2 for USDC
 *   - Anni must have ROLE_PAYMASTER_SUPER
 *   - facilitatorFeeBPS must be set (currently 200 = 2%)
 */

const { ethers } = require('ethers');
const path = require('path');
const { loadConfig } = require('./load-config');
require('dotenv').config({ path: process.env.ENV_FILE || path.join(__dirname, '../../.env.sepolia') });

// Constants
const PERMIT2_ADDRESS = '0x000000000022D473030F116dDEE9F6B43aC78BA3';
const USDC_SEPOLIA = '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238';
const CHAIN_ID = 11155111;

// ABIs
const ERC20_ABI = [
  'function approve(address spender, uint256 amount) returns (bool)',
  'function balanceOf(address account) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
];

const SUPERPAYMASTER_ABI = [
  'function settleX402PaymentPermit2(tuple(tuple(address token, uint256 amount) permitted, uint256 nonce, uint256 deadline) permit, tuple(address to, uint256 requestedAmount) transferDetails, address owner_, bytes signature) external returns (bytes32)',
  'function facilitatorFeeBPS() view returns (uint256)',
  'function facilitatorEarnings(address operator, address token) view returns (uint256)',
  'function x402SettlementNonces(bytes32 nonce) view returns (bool)',
  'function WITNESS_TYPE_STRING() view returns (string)',
  'function X402_SETTLEMENT_TYPEHASH() view returns (bytes32)',
];

const PERMIT2_ABI = [
  'function allowance(address owner, address token, address spender) view returns (uint160, uint48, uint48)',
];

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║  x402 Payment Settlement Test (Permit2 + Witness)       ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  // Setup
  const config = loadConfig();
  const rpcUrl = process.env.RPC_URL;
  const provider = new ethers.JsonRpcProvider(rpcUrl);

  // Payer = deployer EOA
  const payerKey = process.env.PRIVATE_KEY;
  const payer = new ethers.Wallet(payerKey, provider);

  // Facilitator = Anni operator (has ROLE_PAYMASTER_SUPER)
  const anniKey = process.env.ANNI_PRIVATE_KEY || process.env.PRIVATE_KEY_ANNI;
  const facilitator = new ethers.Wallet(anniKey, provider);

  // Payee = a third party receiving the payment (use a fixed test address)
  const payee = '0x000000000000000000000000000000000000dEaD'; // burn address as payee for testing

  const spAddr = config.superPaymaster;
  const superPaymaster = new ethers.Contract(spAddr, SUPERPAYMASTER_ABI, facilitator);
  const usdc = new ethers.Contract(USDC_SEPOLIA, ERC20_ABI, payer);
  const permit2 = new ethers.Contract(PERMIT2_ADDRESS, PERMIT2_ABI, provider);

  console.log('📌 Configuration:');
  console.log(`  SuperPaymaster: ${spAddr}`);
  console.log(`  Permit2: ${PERMIT2_ADDRESS}`);
  console.log(`  USDC: ${USDC_SEPOLIA}`);
  console.log(`  Payer: ${payer.address}`);
  console.log(`  Facilitator: ${facilitator.address}`);
  console.log(`  Payee: ${payee}`);
  console.log();

  // Step 1: Check USDC balance
  console.log('📊 Step 1: Check USDC Balance');
  const decimals = await usdc.decimals();
  const balance = await usdc.balanceOf(payer.address);
  const balanceFormatted = ethers.formatUnits(balance, decimals);
  console.log(`  Balance: ${balanceFormatted} USDC`);

  if (balance === 0n) {
    console.log('\n❌ No USDC balance. Please transfer USDC to:', payer.address);
    console.log('   Circle Sepolia USDC faucet: https://faucet.circle.com/');
    process.exit(1);
  }

  // Amount to settle: 1 USDC
  const amount = ethers.parseUnits('1', decimals); // 1 USDC
  if (balance < amount) {
    console.log(`\n❌ Insufficient USDC. Need 1 USDC, have ${balanceFormatted}`);
    process.exit(1);
  }

  // Step 2: Check facilitator fee
  console.log('\n📊 Step 2: Check Facilitator Fee');
  const feeBPS = await superPaymaster.facilitatorFeeBPS();
  console.log(`  facilitatorFeeBPS: ${feeBPS} (${Number(feeBPS) / 100}%)`);
  const expectedFee = (amount * feeBPS) / 10000n;
  console.log(`  Expected fee: ${ethers.formatUnits(expectedFee, decimals)} USDC`);

  // Step 3: Approve Permit2 for USDC (if not already)
  console.log('\n🔐 Step 3: Approve Permit2 for USDC');
  const currentAllowance = await usdc.allowance(payer.address, PERMIT2_ADDRESS);
  if (currentAllowance < amount) {
    console.log('  Approving Permit2...');
    const approveTx = await usdc.approve(PERMIT2_ADDRESS, ethers.MaxUint256);
    await approveTx.wait();
    console.log(`  ✅ Approved. TX: ${approveTx.hash}`);
  } else {
    console.log(`  ✅ Already approved (allowance: ${ethers.formatUnits(currentAllowance, decimals)})`);
  }

  // Step 4: Build Permit2 signature with witness
  console.log('\n✍️  Step 4: Sign Permit2 Transfer (with Witness)');

  const nonce = BigInt(Date.now()); // use timestamp as nonce
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600); // 1 hour

  // EIP-712 domain for Permit2
  const permit2Domain = {
    name: 'Permit2',
    chainId: CHAIN_ID,
    verifyingContract: PERMIT2_ADDRESS,
  };

  // EIP-712 types for PermitWitnessTransferFrom
  const types = {
    PermitWitnessTransferFrom: [
      { name: 'permitted', type: 'TokenPermissions' },
      { name: 'spender', type: 'address' },
      { name: 'nonce', type: 'uint256' },
      { name: 'deadline', type: 'uint256' },
      { name: 'witness', type: 'X402Settlement' },
    ],
    TokenPermissions: [
      { name: 'token', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    X402Settlement: [
      { name: 'payee', type: 'address' },
    ],
  };

  // The value to sign
  const value = {
    permitted: {
      token: USDC_SEPOLIA,
      amount: amount,
    },
    spender: spAddr, // SuperPaymaster is the spender
    nonce: nonce,
    deadline: deadline,
    witness: {
      payee: payee,
    },
  };

  const signature = await payer.signTypedData(permit2Domain, types, value);
  console.log(`  Nonce: ${nonce}`);
  console.log(`  Deadline: ${deadline}`);
  console.log(`  Signature: ${signature.slice(0, 20)}...`);

  // Step 5: Call settleX402PaymentPermit2 from facilitator
  console.log('\n🚀 Step 5: Execute Settlement');

  // Record pre-balances
  const payeeBalanceBefore = await usdc.balanceOf(payee);
  const earningsBefore = await superPaymaster.facilitatorEarnings(facilitator.address, USDC_SEPOLIA);

  const permit = {
    permitted: { token: USDC_SEPOLIA, amount: amount },
    nonce: nonce,
    deadline: deadline,
  };
  const transferDetails = {
    to: payee,
    requestedAmount: amount,
  };

  try {
    const tx = await superPaymaster.settleX402PaymentPermit2(
      permit,
      transferDetails,
      payer.address,
      signature,
      { gasLimit: 500000 }
    );
    console.log(`  TX Hash: ${tx.hash}`);
    console.log(`  Etherscan: https://sepolia.etherscan.io/tx/${tx.hash}`);

    const receipt = await tx.wait();
    console.log(`  ✅ Settlement confirmed! Gas used: ${receipt.gasUsed}`);

    // Step 6: Verify results
    console.log('\n📊 Step 6: Verify Results');

    const payeeBalanceAfter = await usdc.balanceOf(payee);
    const earningsAfter = await superPaymaster.facilitatorEarnings(facilitator.address, USDC_SEPOLIA);
    const nonceUsed = await superPaymaster.x402SettlementNonces(ethers.zeroPadValue(ethers.toBeHex(nonce), 32));

    const payeeReceived = payeeBalanceAfter - payeeBalanceBefore;
    const feeCollected = earningsAfter - earningsBefore;

    console.log(`  Payee received: ${ethers.formatUnits(payeeReceived, decimals)} USDC`);
    console.log(`  Fee collected: ${ethers.formatUnits(feeCollected, decimals)} USDC`);
    console.log(`  Nonce consumed: ${nonceUsed}`);
    console.log(`  Expected net: ${ethers.formatUnits(amount - expectedFee, decimals)} USDC`);
    console.log(`  Expected fee: ${ethers.formatUnits(expectedFee, decimals)} USDC`);

    // Assertions
    let pass = true;
    if (payeeReceived !== amount - expectedFee) {
      console.log('  ❌ FAIL: Payee amount mismatch!');
      pass = false;
    }
    if (feeCollected !== expectedFee) {
      console.log('  ❌ FAIL: Fee amount mismatch!');
      pass = false;
    }
    if (!nonceUsed) {
      console.log('  ❌ FAIL: Nonce not consumed!');
      pass = false;
    }
    if (pass) {
      console.log('  ✅ All assertions passed!');
    }

    // Step 7: Test replay protection
    console.log('\n🛡️  Step 7: Test Replay Protection');
    try {
      await superPaymaster.settleX402PaymentPermit2.staticCall(
        permit, transferDetails, payer.address, signature
      );
      console.log('  ❌ FAIL: Replay should have reverted!');
    } catch (e) {
      console.log('  ✅ Replay correctly rejected');
    }

  } catch (err) {
    console.log(`\n❌ Settlement failed: ${err.message}`);
    if (err.data) {
      console.log(`  Error data: ${err.data}`);
    }
    process.exit(1);
  }

  console.log('\n╔═══════════════════════════════════════════════════════════╗');
  console.log('║                    Test Completed                         ║');
  console.log('╚═══════════════════════════════════════════════════════════╝');
}

main().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});

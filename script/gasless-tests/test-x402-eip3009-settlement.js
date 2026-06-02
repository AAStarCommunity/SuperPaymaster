#!/usr/bin/env node

/**
 * x402 Payment Settlement E2E Test (EIP-3009)
 *
 * Tests settleX402Payment on SuperPaymaster V5.3.0
 *
 * C-03 (aastar-sdk#39): settleX402Payment binds the final recipient into the EIP-3009
 * nonce (on-chain nonce = keccak256(abi.encode(payee, salt))) and the call takes `salt`
 * instead of a raw nonce. The payer signs EIP-3009 over that derived nonce, so a
 * facilitator that swaps the recipient produces a different nonce and the signature no
 * longer recovers `from` — the transfer reverts. This script's signing step now derives
 * the nonce directly (Step 3); the @aastar/x402 SDK must expose the same salt scheme.
 *
 * Flow:
 *   1. Payer signs EIP-3009 transferWithAuthorization over nonce = keccak256(to, salt)
 *   2. Facilitator calls settleX402Payment(..., salt, signature)
 *   3. Verify: payee received USDC - fee, facilitator earnings tracked
 *   4. Test replay protection
 *
 * Prerequisites:
 *   - Deployer EOA must hold USDC on Sepolia
 *   - Anni must have ROLE_PAYMASTER_SUPER
 *   - facilitatorFeeBPS must be set (currently 200 = 2%)
 */

const { ethers } = require('ethers');
const path = require('path');
const { loadConfig } = require('./load-config');
require('dotenv').config({ path: process.env.ENV_FILE || path.join(__dirname, '../../.env.sepolia') });

// Constants
const USDC_SEPOLIA = '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238';
const CHAIN_ID = 11155111;

// ABIs
const ERC20_ABI = [
  'function approve(address spender, uint256 amount) returns (bool)',
  'function balanceOf(address account) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
  'function nonces(address owner) view returns (uint256)',
];

const SUPERPAYMASTER_ABI = [
  'function settleX402Payment(address from, address to, address asset, uint256 amount, uint256 validAfter, uint256 validBefore, bytes32 salt, bytes signature) external returns (bytes32)',
  'function facilitatorFeeBPS() view returns (uint256)',
  'function facilitatorEarnings(address operator, address token) view returns (uint256)',
  // P0-13: x402SettlementNonces is keyed by keccak256(abi.encode(asset, from, nonce)),
  // not the raw nonce alone. Use x402NonceKey() to derive the composite key.
  'function x402SettlementNonces(bytes32 key) view returns (bool)',
  'function x402NonceKey(address asset, address from, bytes32 nonce) pure returns (bytes32)',
  'function version() view returns (string)',
];

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║  x402 Payment Settlement Test (EIP-3009 — USDC Native)  ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  // Setup
  const config = loadConfig();
  const rpcUrl = process.env.RPC_URL;
  const provider = new ethers.JsonRpcProvider(rpcUrl);

  // Payer = deployer EOA (holds USDC)
  const payerKey = process.env.PRIVATE_KEY;
  const payer = new ethers.Wallet(payerKey, provider);

  // Facilitator = Anni operator (has ROLE_PAYMASTER_SUPER)
  const anniKey = process.env.ANNI_PRIVATE_KEY || process.env.PRIVATE_KEY_ANNI;
  const facilitator = new ethers.Wallet(anniKey, provider);

  // Payee = burn address for testing
  const payee = '0x000000000000000000000000000000000000dEaD';

  const spAddr = config.superPaymaster;
  const superPaymaster = new ethers.Contract(spAddr, SUPERPAYMASTER_ABI, facilitator);
  const usdc = new ethers.Contract(USDC_SEPOLIA, ERC20_ABI, payer);

  console.log('📌 Configuration:');
  console.log(`  SuperPaymaster: ${spAddr}`);
  console.log(`  Version: ${await superPaymaster.version()}`);
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
  console.log(`  Expected fee on 1 USDC: ${ethers.formatUnits(expectedFee, decimals)} USDC`);

  // Step 3: Sign EIP-3009 transferWithAuthorization
  console.log('\n✍️  Step 3: Sign EIP-3009 TransferWithAuthorization');

  // C-03: the final recipient (payee) is bound into the EIP-3009 nonce.
  // salt is random; the on-chain nonce = keccak256(abi.encode(payee, salt)),
  // and the payer signs the EIP-3009 authorization over that derived nonce.
  // settleX402Payment takes `salt` (not the raw nonce) and re-derives it.
  const salt = ethers.hexlify(ethers.randomBytes(32));
  const nonce = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(['address', 'bytes32'], [payee, salt])
  );
  const validAfter = 0n;
  const validBefore = BigInt(Math.floor(Date.now() / 1000) + 3600); // 1 hour

  // EIP-712 domain for USDC (Circle's implementation)
  const usdcDomain = {
    name: 'USDC',
    version: '2',
    chainId: CHAIN_ID,
    verifyingContract: USDC_SEPOLIA,
  };

  const types = {
    TransferWithAuthorization: [
      { name: 'from', type: 'address' },
      { name: 'to', type: 'address' },
      { name: 'value', type: 'uint256' },
      { name: 'validAfter', type: 'uint256' },
      { name: 'validBefore', type: 'uint256' },
      { name: 'nonce', type: 'bytes32' },
    ],
  };

  const value = {
    from: payer.address,
    to: spAddr,  // SuperPaymaster receives the USDC first
    value: amount,
    validAfter: validAfter,
    validBefore: validBefore,
    nonce: nonce,
  };

  const signature = await payer.signTypedData(usdcDomain, types, value);
  console.log(`  Nonce: ${nonce}`);
  console.log(`  ValidBefore: ${validBefore}`);
  console.log(`  Signature: ${signature.slice(0, 20)}...`);

  // Step 4: Call settleX402Payment from facilitator
  console.log('\n🚀 Step 4: Execute Settlement');

  const payeeBalanceBefore = await usdc.balanceOf(payee);
  const earningsBefore = await superPaymaster.facilitatorEarnings(facilitator.address, USDC_SEPOLIA);

  try {
    const tx = await superPaymaster.settleX402Payment(
      payer.address,
      payee,
      USDC_SEPOLIA,
      amount,
      validAfter,
      validBefore,
      salt,
      signature,
      { gasLimit: 500000 }
    );
    console.log(`  TX Hash: ${tx.hash}`);
    console.log(`  Etherscan: https://sepolia.etherscan.io/tx/${tx.hash}`);

    const receipt = await tx.wait();
    console.log(`  ✅ Settlement confirmed! Gas used: ${receipt.gasUsed}`);

    // Step 5: Verify results
    console.log('\n📊 Step 5: Verify Results');

    const payeeBalanceAfter = await usdc.balanceOf(payee);
    const earningsAfter = await superPaymaster.facilitatorEarnings(facilitator.address, USDC_SEPOLIA);
    // P0-13: derive composite key (asset, from, nonce) instead of using raw nonce
    const nonceKey = await superPaymaster.x402NonceKey(USDC_SEPOLIA, payer.address, nonce);
    const nonceUsed = await superPaymaster.x402SettlementNonces(nonceKey);

    const payeeReceived = payeeBalanceAfter - payeeBalanceBefore;
    const feeCollected = earningsAfter - earningsBefore;

    console.log(`  Payee received: ${ethers.formatUnits(payeeReceived, decimals)} USDC`);
    console.log(`  Fee collected: ${ethers.formatUnits(feeCollected, decimals)} USDC`);
    console.log(`  Nonce consumed: ${nonceUsed}`);
    console.log(`  Expected net: ${ethers.formatUnits(amount - expectedFee, decimals)} USDC`);
    console.log(`  Expected fee: ${ethers.formatUnits(expectedFee, decimals)} USDC`);

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

    // Step 6: Test replay protection
    console.log('\n🛡️  Step 6: Test Replay Protection');
    try {
      await superPaymaster.settleX402Payment.staticCall(
        payer.address, payee, USDC_SEPOLIA, amount,
        validAfter, validBefore, nonce, signature
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

#!/usr/bin/env node

/**
 * x402 Payment Settlement E2E Test (EIP-3009)
 *
 * Tests settleX402Payment on SuperPaymaster V5.3.0
 *
 * M-1 (audit): settleX402Payment now takes `maxFee` (the 5th arg, right after `amount`)
 * and binds BOTH the final recipient AND maxFee into the EIP-3009 nonce
 * (on-chain nonce = keccak256(abi.encode(payee, maxFee, salt))). The contract caps the
 * facilitator fee at `maxFee` (revert X402FeeExceedsMax if fee > maxFee) so the payer
 * consents to the fee ceiling. It also now calls the token's `receiveWithAuthorization`
 * (NOT `transferWithAuthorization`) to close a front-run grief vector, so the payer must
 * sign the token's **ReceiveWithAuthorization** EIP-712 struct (same fields, different
 * type name). An operator that swaps `payee` OR raises `maxFee` derives a different nonce
 * and the EIP-3009 signature no longer recovers `from` — the transfer reverts.
 *
 * Flow:
 *   1. Payer signs EIP-3009 ReceiveWithAuthorization over nonce = keccak256(payee, maxFee, salt)
 *   2. Facilitator calls settleX402Payment(..., maxFee, ..., salt, signature)
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
const { sendAndWait, makeProvider } = require('./tx-utils');
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

// v5.4 god-split: x402 settlement moved out of SuperPaymaster into the standalone
// X402Facilitator contract. Same function signatures, different target contract.
const X402_FACILITATOR_ABI = [
  // M-1: 9-arg form — `maxFee` inserted right after `amount`.
  'function settleX402Payment(address from, address to, address asset, uint256 amount, uint256 maxFee, uint256 validAfter, uint256 validBefore, bytes32 salt, bytes signature) external returns (bytes32)',
  'function facilitatorFeeBPS() view returns (uint256)',
  'function getEffectiveFacilitatorFee(address operator) view returns (uint256)',
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
  const provider = makeProvider(rpcUrl);

  // Payer = deployer EOA (holds USDC)
  const payerKey = process.env.PRIVATE_KEY;
  const payer = new ethers.Wallet(payerKey, provider);

  // Facilitator = Anni operator (has ROLE_PAYMASTER_SUPER)
  const anniKey = process.env.ANNI_PRIVATE_KEY || process.env.PRIVATE_KEY_ANNI;
  const facilitator = new ethers.Wallet(anniKey, provider);

  // Payee = burn address for testing
  const payee = '0x000000000000000000000000000000000000dEaD';

  // v5.4 god-split: settlement now targets X402Facilitator, not SuperPaymaster.
  // Address sourced from deployments/config.sepolia.json (key: x402Facilitator),
  // with an X402_FACILITATOR env override; populated at the v5.4 redeploy stage.
  const x402Addr = config.x402Facilitator || process.env.X402_FACILITATOR;
  if (!x402Addr) {
    console.log('⚠️  SKIP: X402Facilitator address not set (config.x402Facilitator / X402_FACILITATOR). Deploy v5.4 first.');
    process.exit(2);
  }
  const x402 = new ethers.Contract(x402Addr, X402_FACILITATOR_ABI, facilitator);
  const usdc = new ethers.Contract(USDC_SEPOLIA, ERC20_ABI, payer);

  console.log('📌 Configuration:');
  console.log(`  X402Facilitator: ${x402Addr}`);
  console.log(`  Version: ${await x402.version()}`);
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

  // Step 2: Check facilitator fee (per-operator override falls back to global default)
  console.log('\n📊 Step 2: Check Facilitator Fee');
  const globalFeeBPS = await x402.facilitatorFeeBPS();
  const feeBPS = await x402.getEffectiveFacilitatorFee(facilitator.address);
  console.log(`  facilitatorFeeBPS (global): ${globalFeeBPS} (${Number(globalFeeBPS) / 100}%)`);
  console.log(`  effective fee for facilitator: ${feeBPS} (${Number(feeBPS) / 100}%)`);
  const expectedFee = (amount * feeBPS) / 10000n;
  console.log(`  Expected fee on 1 USDC: ${ethers.formatUnits(expectedFee, decimals)} USDC`);

  // M-1: maxFee is the payer-consented fee ceiling. The contract reverts with
  // X402FeeExceedsMax if (amount * effectiveFeeBPS / 10000) > maxFee. We set
  // maxFee = amount: it is always >= the actual fee (fee <= MAX_FACILITATOR_FEE = 5%
  // of amount) so the cap never trips, while still proving the maxFee binding works
  // end-to-end (nonce + on-chain check + signature recovery).
  const maxFee = amount;

  // Step 3: Sign EIP-3009 ReceiveWithAuthorization
  console.log('\n✍️  Step 3: Sign EIP-3009 ReceiveWithAuthorization');

  // M-1: the final recipient (payee) AND maxFee are bound into the EIP-3009 nonce.
  // salt is random; the on-chain nonce = keccak256(abi.encode(payee, maxFee, salt)),
  // and the payer signs the EIP-3009 authorization over that derived nonce.
  // settleX402Payment takes `salt` (not the raw nonce) and re-derives it.
  const salt = ethers.hexlify(ethers.randomBytes(32));
  const nonce = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ['address', 'uint256', 'bytes32'], [payee, maxFee, salt]
    )
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

  // M-1: the contract calls token.receiveWithAuthorization (not transferWithAuthorization),
  // so the payer must sign the ReceiveWithAuthorization typehash. Same fields; only the
  // struct (primaryType) name differs from Transfer -> Receive. Same domain.
  const types = {
    ReceiveWithAuthorization: [
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
    to: x402Addr,  // X402Facilitator receives the USDC first (receiveWithAuthorization → address(this))
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
  const earningsBefore = await x402.facilitatorEarnings(facilitator.address, USDC_SEPOLIA);

  try {
    const receipt = await sendAndWait(
      x402, 'settleX402Payment',
      [payer.address, payee, USDC_SEPOLIA, amount, maxFee, validAfter, validBefore, salt, signature],
      'settleX402Payment', { gasLimit: 500000 }
    );
    console.log(`  TX Hash: ${receipt.hash}`);
    console.log(`  Etherscan: https://sepolia.etherscan.io/tx/${receipt.hash}`);
    console.log(`  ✅ Settlement confirmed! Gas used: ${receipt.gasUsed}`);

    // Step 5: Verify results
    console.log('\n📊 Step 5: Verify Results');

    const payeeBalanceAfter = await usdc.balanceOf(payee);
    const earningsAfter = await x402.facilitatorEarnings(facilitator.address, USDC_SEPOLIA);
    // P0-13: derive composite key (asset, from, nonce) instead of using raw nonce
    const nonceKey = await x402.x402NonceKey(USDC_SEPOLIA, payer.address, nonce);
    const nonceUsed = await x402.x402SettlementNonces(nonceKey);

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
      // Replay the SAME (payee, maxFee, salt) -> re-derives the consumed nonce.
      await x402.settleX402Payment.staticCall(
        payer.address, payee, USDC_SEPOLIA, amount, maxFee,
        validAfter, validBefore, salt, signature
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

#!/usr/bin/env node

/**
 * Gasless Transfer Test Case 3
 *
 * Tests gasless ERC20 token transfer using:
 * - SuperPaymaster (UUPS Proxy)
 * - PNTs Token (Mycelium community token, operator = Anni)
 * - EntryPoint v0.7
 *
 * Addresses are loaded from deployments/config.sepolia.json
 *
 * EXIT CODES — LESSON LEARNED (2026-05-13):
 *   0 = PASS  — UserOp submitted and confirmed on-chain
 *   1 = FAIL  — Script ran but test failed (TX reverted, assertion failed)
 *   2 = SKIP  — Precondition not met (zero balance, network error, etc.)
 *
 * Root cause of the old bug: zero-balance path used `return` inside main(), which
 * caused main().then(() => process.exit(0)) to execute — giving the test runner
 * exit 0 (PASS) even though no UserOp was submitted. Fix: always use process.exit(2)
 * for skipped / precondition-not-met cases, NEVER bare `return` from main().
 */

const { ethers } = require('ethers');
const path = require('path');
const { loadConfig } = require('./load-config');
const { makeProvider } = require('./tx-utils');
require('dotenv').config({ path: process.env.ENV_FILE || path.join(__dirname, '../../.env.sepolia') });

const ERC20_ABI = [
  "function transfer(address to, uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)"
];

const ENTRYPOINT_ABI = [
  "function handleOps((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature)[] calldata ops, address payable beneficiary) external",
  "function getUserOpHash((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) calldata userOp) view returns (bytes32)"
];

const SIMPLE_ACCOUNT_ABI = [
  "function execute(address dest, uint256 value, bytes calldata func) external",
  "function getNonce() view returns (uint256)"
];

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║  Gasless Transfer Test Case 3 - SuperPaymaster + PNTs    ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  const config = loadConfig();
  const SUPER_PAYMASTER_ADDRESS = config.superPaymaster;
  // SP PNTs path: this test exercises the operator whose xPNTsToken == PNTs
  // (Mycelium/Anni). The token being transferred AND used in postOp burn/debt
  // is the SAME token, so the operator must match the token.
  const XPNTS_TOKEN_ADDRESS = config.pnts;
  const ENTRYPOINT_ADDRESS = config.entryPoint;

  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  const senderPrivateKey = process.env.OWNER_PRIVATE_KEY || process.env.DEPLOYER_PRIVATE_KEY;
  const recipientAddress = process.env.OWNER2_ADDRESS || process.env.TEST_EOA_ADDRESS;

  // Default operator is Anni (whose SP-configured xPNTsToken == PNTs).
  // Override with OPERATOR_ADDRESS_PNTS env if the deployment has a different PNTs operator.
  const operatorAddress = process.env.OPERATOR_ADDRESS_PNTS || process.env.OPERATOR_ADDRESS || '0xEcAACb915f7D92e9916f449F7ad42BD0408733c9';

  if (!rpcUrl || !senderPrivateKey || !recipientAddress) {
    throw new Error('Required env variables not found in .env.sepolia');
  }
  if (!XPNTS_TOKEN_ADDRESS) {
    throw new Error('config.pnts missing — Mycelium PNTs token must be deployed and recorded in deployments/config.<network>.json');
  }

  console.log('📌 Configuration:');
  console.log(`  RPC: ${rpcUrl.substring(0, 50)}...`);
  console.log(`  SuperPaymaster: ${SUPER_PAYMASTER_ADDRESS}`);
  console.log(`  PNTs Token: ${XPNTS_TOKEN_ADDRESS}`);
  console.log(`  EntryPoint: ${ENTRYPOINT_ADDRESS}`);
  console.log(`  Operator: ${operatorAddress}\n`);

  const provider = makeProvider(rpcUrl);
  const wallet = new ethers.Wallet(senderPrivateKey, provider);

  const senderAAAccount = process.env.TEST_AA_ACCOUNT_ADDRESS_C || process.env.TEST_AA_ACCOUNT_ADDRESS_2;
  if (!senderAAAccount) throw new Error('TEST_AA_ACCOUNT_ADDRESS_C not found in env');

  console.log(`  Sender AA Account: ${senderAAAccount}`);
  console.log(`  Sender EOA: ${wallet.address}`);
  console.log(`  Recipient: ${recipientAddress}\n`);

  const xPNTsToken = new ethers.Contract(XPNTS_TOKEN_ADDRESS, ERC20_ABI, provider);
  const simpleAccount = new ethers.Contract(senderAAAccount, SIMPLE_ACCOUNT_ABI, provider);
  const entryPoint = new ethers.Contract(ENTRYPOINT_ADDRESS, ENTRYPOINT_ABI, wallet);

  // Retry helper for transient RPC errors
  async function retryCall(fn, retries = 3) {
    for (let i = 1; i <= retries; i++) {
      try { return await fn(); } catch (err) {
        const msg = (err.message || '').toLowerCase();
        const isNet = msg.includes('timeout') || msg.includes('econnreset') || msg.includes('socket hang up') || msg.includes('etimedout');
        if (isNet && i < retries) { await new Promise(r => setTimeout(r, 4000)); continue; }
        throw err;
      }
    }
  }

  // Note: retryCall exhaustion throws, which is caught by the outer catch block below.
  // The outer catch distinguishes network errors (exit 2 SKIP) from logic errors (exit 1 FAIL).
  try {
    console.log('📊 Step 1: Check PNTs Balance');
    const balance = await retryCall(() => xPNTsToken.balanceOf(senderAAAccount));
    const symbol = await retryCall(() => xPNTsToken.symbol());
    const decimals = await retryCall(() => xPNTsToken.decimals());
    console.log(`  Balance: ${ethers.formatUnits(balance, decimals)} ${symbol}`);

    if (balance === 0n) {
      console.log('  ⚠️  SKIP: Zero token balance — fund TEST_AA_ACCOUNT_ADDRESS_C with PNTs first.');
      console.log('  Use: PRIVATE_KEY_ANNI=<key> node transfer-tokens.js\n');
      process.exit(2);
    }

    console.log('\n📝 Step 2: Prepare Transfer CallData');
    const transferAmount = ethers.parseUnits('1', decimals);
    const transferCalldata = xPNTsToken.interface.encodeFunctionData('transfer', [recipientAddress, transferAmount]);
    const executeCalldata = simpleAccount.interface.encodeFunctionData('execute', [XPNTS_TOKEN_ADDRESS, 0, transferCalldata]);
    console.log(`  Transfer Amount: 1 ${symbol}`);

    console.log('\n🔨 Step 3: Build UserOperation');
    const nonce = await simpleAccount.getNonce();
    console.log(`  Nonce: ${nonce}`);

    const pmVerificationGasLimit = 150000n;
    // SP's postOp runs the burn → recordDebt → pendingDebts fallback chain
    // (~120K gas with xPNTsToken._update + event emits). 100K was OOG on Sepolia,
    // surfacing as `PostOpReverted("")` with empty inner bytes.
    const pmPostOpGasLimit = 200000n;
    const paymasterAndData = ethers.solidityPacked(
      ['address', 'uint128', 'uint128', 'address'],
      [SUPER_PAYMASTER_ADDRESS, pmVerificationGasLimit, pmPostOpGasLimit, operatorAddress]
    );

    const userOp = {
      sender: senderAAAccount,
      nonce: nonce,
      initCode: '0x',
      callData: executeCalldata,
      accountGasLimits: ethers.solidityPacked(['uint128', 'uint128'], [200000, 200000]),
      preVerificationGas: 100000n,
      gasFees: ethers.solidityPacked(['uint128', 'uint128'], [2000000000, 2000000000]),
      paymasterAndData: paymasterAndData,
      signature: '0x'
    };

    console.log('\n✍️  Step 4: Sign UserOperation');
    const userOpHash = await entryPoint.getUserOpHash(userOp);
    console.log(`  UserOp Hash: ${userOpHash.substring(0, 20)}...`);
    const signature = await wallet.signMessage(ethers.getBytes(userOpHash));
    userOp.signature = signature;

    console.log('\n🚀 Step 5: Submit UserOp to EntryPoint');
    const beneficiary = wallet.address;

    try {
      const gasEstimate = await entryPoint.handleOps.estimateGas([userOp], beneficiary);
      console.log(`  Estimated gas: ${gasEstimate}`);
    } catch (error) {
      console.log(`  Gas estimation: ${error.message.substring(0, 100)}...`);
    }

    console.log('  Sending transaction...');
    const tx = await entryPoint.handleOps([userOp], beneficiary);
    console.log(`  TX Hash: ${tx.hash}`);
    console.log(`  Etherscan: https://sepolia.etherscan.io/tx/${tx.hash}`);

    const receipt = await tx.wait();
    if (receipt.status === 1) {
      console.log('  ✅ Transaction confirmed!\n');
      const newBalance = await xPNTsToken.balanceOf(senderAAAccount);
      const recipientBalance = await xPNTsToken.balanceOf(recipientAddress);
      console.log('📊 Final Balances:');
      console.log(`  Sender: ${ethers.formatUnits(newBalance, decimals)} ${symbol}`);
      console.log(`  Recipient: ${ethers.formatUnits(recipientBalance, decimals)} ${symbol}`);
    } else {
      // FALSE-GREEN FIX: a status==0 receipt means the on-chain UserOp reverted.
      // Previously this only logged and fell through to exit 0; now FAIL loudly.
      console.log('  ❌ Transaction failed (receipt.status=0 — UserOp reverted on-chain)\n');
      process.exit(1);
    }

  } catch (error) {
    const msg = (error.message || '').toLowerCase();
    const isNet = msg.includes('timeout') || msg.includes('econnreset') || msg.includes('socket hang up') || msg.includes('etimedout');
    if (isNet) {
      console.warn('\n⚠️  SKIP: Network error (transient RPC issue):', error.message);
      console.warn('  Not a contract logic failure — re-run manually.\n');
      process.exit(2);
    }
    console.error('\n❌ Error:', error.message);
    if (error.data) console.error('  Error data:', error.data);
    process.exit(1);
  }

  console.log('\n╔═══════════════════════════════════════════════════════════╗');
  console.log('║                    Test Completed                         ║');
  console.log('╚═══════════════════════════════════════════════════════════╝');
}

main().then(() => process.exit(0)).catch((error) => { console.error(error); process.exit(1); });

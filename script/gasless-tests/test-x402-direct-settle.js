#!/usr/bin/env node

/**
 * x402 Direct Settlement E2E Test (C-02 — xPNTs transferFrom path)
 *
 * Covers settleX402PaymentDirect, the xPNTs-only path the C-02 fix hardened.
 * xPNTs carry no token-level authorization (the SuperPaymaster holds an auto-allowance
 * over every holder), so the payer's consent gate lives at the SP level: the payer must
 * sign an EIP-712 `X402PaymentAuthorization(from,to,asset,amount,maxFee,validBefore,nonce)`
 * bound to THIS proxy's domain. Without it, a community-approved facilitator could pull any
 * holder's xPNTs to a caller-chosen recipient. This test proves, on-chain:
 *   1. Positive  — a correctly-signed authorization settles (recipient receives amount-fee)
 *   2. Replay    — the same nonce cannot be reused (NonceAlreadyUsed)
 *   3. Tamper    — swapping the recipient invalidates the signature (InvalidX402Signature)
 *                  → this is the C-02 drain-prevention guarantee
 *
 * Payer is a FRESH random EOA (not the 7702-delegated deployer): SignatureCheckerLib routes
 * code-bearing accounts to ERC-1271, so a plain-EOA payer keeps the ecrecover path. The payer
 * signs off-chain only and never sends a tx, so it needs no ETH — just an xPNTs balance
 * (minted by the community owner) and the SP's automatic allowance.
 *
 * Exit: 0 = PASS, 1 = FAIL, 2 = SKIP (precondition not met / network)
 *
 * Prerequisites:
 *   - PRIVATE_KEY is the xPNTs community owner (can mint + addApprovedFacilitator)
 *   - ANNI_PRIVATE_KEY (facilitator) holds ROLE_PAYMASTER_SUPER
 */

const { ethers } = require('ethers');
const path = require('path');
const { loadConfig } = require('./load-config');
const { sendAndWait, makeProvider } = require('./tx-utils');
require('dotenv').config({ path: process.env.ENV_FILE || path.join(__dirname, '../../.env.sepolia') });

const CHAIN_ID = 11155111;

const XPNTS_ABI = [
  'function balanceOf(address account) view returns (uint256)',
  'function decimals() view returns (uint8)',
  'function symbol() view returns (string)',
  'function mint(address to, uint256 amount)',
  'function communityOwner() view returns (address)',
  'function approvedFacilitators(address) view returns (bool)',
  'function addApprovedFacilitator(address facilitator)',
  'function autoApprovedSpenders(address) view returns (bool)',
];

const SUPERPAYMASTER_ABI = [
  'function settleX402PaymentDirect(address from, address to, address asset, uint256 amount, uint256 maxFee, uint256 validBefore, bytes32 nonce, bytes signature) external returns (bytes32)',
  'function facilitatorFeeBPS() view returns (uint256)',
  'function operatorFacilitatorFees(address operator) view returns (uint256)',
  'function facilitatorEarnings(address operator, address token) view returns (uint256)',
  'function x402SettlementNonces(bytes32 key) view returns (bool)',
  'function x402NonceKey(address asset, address from, bytes32 nonce) pure returns (bytes32)',
  'function version() view returns (string)',
  'error InvalidX402Signature()',
  'error NonceAlreadyUsed()',
];

let failures = 0;
const pass = (m) => console.log(`  ✅ PASS: ${m}`);
const fail = (m) => { console.log(`  ❌ FAIL: ${m}`); failures++; };

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║  x402 Direct Settlement Test (C-02 — xPNTs transferFrom) ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  const config = loadConfig();
  const provider = makeProvider(process.env.RPC_URL);

  const ownerKey = process.env.PRIVATE_KEY;            // xPNTs community owner (mint + facilitator approve)
  const owner = new ethers.Wallet(ownerKey, provider);
  const anniKey = process.env.ANNI_PRIVATE_KEY || process.env.PRIVATE_KEY_ANNI;
  if (!anniKey) { console.log('⚠️  SKIP: ANNI_PRIVATE_KEY not set'); process.exit(2); }
  const facilitator = new ethers.Wallet(anniKey, provider);

  // Fresh plain-EOA payer (avoids 7702 code → ERC-1271 routing in SignatureCheckerLib)
  const payer = ethers.Wallet.createRandom().connect(provider);
  const payee = '0x000000000000000000000000000000000000dEaD';

  const spAddr = config.superPaymaster;
  const asset = config.aPNTs;
  const sp = new ethers.Contract(spAddr, SUPERPAYMASTER_ABI, facilitator);
  const xpntsOwner = new ethers.Contract(asset, XPNTS_ABI, owner);

  console.log('📌 Configuration:');
  console.log(`  SuperPaymaster: ${spAddr}  (${await sp.version()})`);
  console.log(`  xPNTs (asset):  ${asset}`);
  console.log(`  Community owner:${owner.address}`);
  console.log(`  Facilitator:    ${facilitator.address}`);
  console.log(`  Payer (fresh):  ${payer.address}`);
  console.log(`  Payee:          ${payee}\n`);

  const decimals = await xpntsOwner.decimals();
  const amount = ethers.parseUnits('1', decimals); // settle 1 xPNTs

  // Step 1: Provision — community owner mints payer balance + approves facilitator
  console.log('🔧 Step 1: Provision payer balance + facilitator approval');
  const co = await xpntsOwner.communityOwner();
  if (co.toLowerCase() !== owner.address.toLowerCase()) {
    console.log(`⚠️  SKIP: PRIVATE_KEY (${owner.address}) is not the xPNTs communityOwner (${co})`);
    process.exit(2);
  }
  // Mint generous balance to the fresh payer (await each tx → safe under 7702 in-flight cap)
  await sendAndWait(xpntsOwner, 'mint', [payer.address, amount * 10n], 'mint');
  const payerBal = await xpntsOwner.balanceOf(payer.address);
  console.log(`  Payer xPNTs balance: ${ethers.formatUnits(payerBal, decimals)}`);

  if (!(await xpntsOwner.approvedFacilitators(facilitator.address))) {
    await sendAndWait(xpntsOwner, 'addApprovedFacilitator', [facilitator.address], 'addApprovedFacilitator');
    console.log(`  Added facilitator to approvedFacilitators`);
  } else {
    console.log(`  Facilitator already approved`);
  }
  const spAutoApproved = await xpntsOwner.autoApprovedSpenders(spAddr);
  console.log(`  SP autoApprovedSpender: ${spAutoApproved}`);

  // Step 2: Compute fee + maxFee, build EIP-712 authorization
  console.log('\n✍️  Step 2: Sign EIP-712 X402PaymentAuthorization');
  let effBps = await sp.operatorFacilitatorFees(facilitator.address);
  if (effBps === 0n) effBps = await sp.facilitatorFeeBPS();
  const expectedFee = (amount * effBps) / 10000n;
  const maxFee = expectedFee;                        // exact cap — proves fee <= maxFee gate
  const validBefore = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const nonce = ethers.hexlify(ethers.randomBytes(32));

  const domain = { name: 'SuperPaymaster', version: '1', chainId: CHAIN_ID, verifyingContract: spAddr };
  const types = {
    X402PaymentAuthorization: [
      { name: 'from', type: 'address' },
      { name: 'to', type: 'address' },
      { name: 'asset', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'maxFee', type: 'uint256' },
      { name: 'validBefore', type: 'uint256' },
      { name: 'nonce', type: 'bytes32' },
    ],
  };
  const authValue = { from: payer.address, to: payee, asset, amount, maxFee, validBefore, nonce };
  const signature = await payer.signTypedData(domain, types, authValue);
  console.log(`  effectiveFeeBPS: ${effBps}  expectedFee: ${ethers.formatUnits(expectedFee, decimals)}`);
  console.log(`  Nonce: ${nonce}`);

  // Step 3: Positive — facilitator settles with the valid authorization
  console.log('\n🚀 Step 3: settleX402PaymentDirect (valid signature)');
  const payeeBefore = await xpntsOwner.balanceOf(payee);
  const earningsBefore = await sp.facilitatorEarnings(facilitator.address, asset);
  const tx = await sendAndWait(
    sp, 'settleX402PaymentDirect',
    [payer.address, payee, asset, amount, maxFee, validBefore, nonce, signature],
    'settleX402PaymentDirect', { gasLimit: 500000 }
  );
  console.log(`  TX: https://sepolia.etherscan.io/tx/${tx.hash}`);

  const payeeReceived = (await xpntsOwner.balanceOf(payee)) - payeeBefore;
  const feeCollected = (await sp.facilitatorEarnings(facilitator.address, asset)) - earningsBefore;
  const nonceKey = await sp.x402NonceKey(asset, payer.address, nonce);
  const nonceUsed = await sp.x402SettlementNonces(nonceKey);
  console.log(`  Payee received: ${ethers.formatUnits(payeeReceived, decimals)} xPNTs`);
  console.log(`  Fee collected:  ${ethers.formatUnits(feeCollected, decimals)} xPNTs`);
  payeeReceived === amount - expectedFee
    ? pass(`payee received amount - fee (${ethers.formatUnits(amount - expectedFee, decimals)})`)
    : fail(`payee received ${payeeReceived}, expected ${amount - expectedFee}`);
  feeCollected === expectedFee ? pass(`facilitator earnings += fee`) : fail(`fee ${feeCollected} != ${expectedFee}`);
  nonceUsed ? pass('nonce consumed') : fail('nonce not marked consumed');

  // Helper: run a settle that must revert, and return the revert reason (or 'settled' if it did not).
  const expectRevert = async (to, n, sig) => {
    try {
      await sp.settleX402PaymentDirect.staticCall(payer.address, to, asset, amount, maxFee, validBefore, n, sig);
      return 'settled';
    } catch (e) {
      return e?.revert?.name || e?.shortMessage || String(e?.message || e);
    }
  };

  // Step 4: Replay — the original (valid) signature passes _verifyX402Auth but the consumed
  //         nonce must reject it. Assert the SPECIFIC error, not "any revert".
  console.log('\n🛡️  Step 4: Replay protection (reuse same nonce)');
  const replayReason = await expectRevert(payee, nonce, signature);
  if (replayReason === 'settled') fail('replay was NOT rejected');
  else if (replayReason.includes('NonceAlreadyUsed')) pass(`replay rejected with NonceAlreadyUsed`);
  else fail(`replay reverted for the WRONG reason (${replayReason}) — expected NonceAlreadyUsed`);

  // Step 5: Recipient binding (C-02 core). Sign a FRESH authorization for `payee`, then:
  //   5a — redirect the SAME signature to a different recipient → must revert *specifically*
  //        InvalidX402Signature (any other revert reason fails: it would not prove binding).
  //   5b — settle the SAME signature to the AUTHORIZED recipient → must succeed. This isolates
  //        the cause of 5a to the recipient swap (the signature is otherwise valid), so a
  //        false pass (revert for an unrelated reason) cannot masquerade as recipient binding.
  console.log('\n🛡️  Step 5: Recipient binding (C-02 drain prevention)');
  const attacker = '0x00000000000000000000000000000000DeaDBeef';
  const bindNonce = ethers.hexlify(ethers.randomBytes(32));
  const bindSig = await payer.signTypedData(
    domain, types, { from: payer.address, to: payee, asset, amount, maxFee, validBefore, nonce: bindNonce }
  ); // authorizes payee ONLY

  const tamperReason = await expectRevert(attacker, bindNonce, bindSig);
  if (tamperReason === 'settled') fail('redirect to attacker SETTLED — C-02 BROKEN (drain possible)');
  else if (tamperReason.includes('InvalidX402Signature')) pass('redirect to attacker → InvalidX402Signature');
  else fail(`redirect reverted for the WRONG reason (${tamperReason}) — does not prove recipient binding`);

  // 5b positive control: same signature, AUTHORIZED recipient → must settle.
  const payeeBefore2 = await xpntsOwner.balanceOf(payee);
  await sendAndWait(
    sp, 'settleX402PaymentDirect',
    [payer.address, payee, asset, amount, maxFee, validBefore, bindNonce, bindSig],
    'settleX402PaymentDirect(5b)', { gasLimit: 500000 }
  );
  const got2 = (await xpntsOwner.balanceOf(payee)) - payeeBefore2;
  got2 === amount - expectedFee
    ? pass('same signature settles to the AUTHORIZED recipient — binding isolated, C-02 verified')
    : fail(`authorized settle returned ${ethers.formatUnits(got2, decimals)}, expected ${ethers.formatUnits(amount - expectedFee, decimals)}`);

  console.log('\n╔═══════════════════════════════════════════════════════════╗');
  if (failures === 0) {
    console.log('║                    Test Completed                         ║');
    console.log('╚═══════════════════════════════════════════════════════════╝');
    process.exit(0);
  } else {
    console.log(`║              Test FAILED — ${failures} assertion(s)              ║`);
    console.log('╚═══════════════════════════════════════════════════════════╝');
    process.exit(1);
  }
}

main().catch((e) => {
  const msg = String(e?.message || e);
  if (/network|timeout|ECONNRESET|could not detect|SERVER_ERROR|503|429/i.test(msg)) {
    console.log(`\n⚠️  SKIP: network error — ${msg.slice(0, 120)}`);
    process.exit(2);
  }
  console.error(`\n❌ FAIL: ${msg}`);
  process.exit(1);
});

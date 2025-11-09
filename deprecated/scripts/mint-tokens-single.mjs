#!/usr/bin/env node
/**
 * Mint SBT and PNT for a single account
 *
 * Usage: node scripts/mint-tokens-single.mjs <accountAddress>
 */

const FAUCET_API = "https://faucet.aastar.io/api";

async function mintTokens(accountAddress) {
  console.log(`\n🔄 Minting tokens for ${accountAddress}...\n`);

  // Step 1: Mint SBT
  console.log(`⏳ Step 1: Minting SBT...`);
  try {
    const controller1 = new AbortController();
    const timeout1 = setTimeout(() => controller1.abort(), 60000);

    const sbtResponse = await fetch(`${FAUCET_API}/mint-sbt`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ accountAddress }),
      signal: controller1.signal
    });

    clearTimeout(timeout1);

    if (sbtResponse.ok) {
      const sbtResult = await sbtResponse.json();
      console.log(`✅ SBT minted successfully`);
      if (sbtResult.txHash || sbtResult.transactionHash) {
        console.log(`   Tx: ${sbtResult.txHash || sbtResult.transactionHash}`);
      }
    } else {
      const error = await sbtResponse.text();
      console.log(`❌ SBT mint failed: ${sbtResponse.status} ${error}`);
    }
  } catch (error) {
    console.log(`❌ SBT mint error: ${error.message}`);
  }

  // Wait 3 seconds
  await new Promise(resolve => setTimeout(resolve, 3000));

  // Step 2: Mint PNT
  console.log(`\n⏳ Step 2: Minting PNT (100 tokens)...`);
  try {
    const controller2 = new AbortController();
    const timeout2 = setTimeout(() => controller2.abort(), 60000);

    const pntResponse = await fetch(`${FAUCET_API}/mint-pnt`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        accountAddress,
        amount: "100000000000000000000" // 100 PNT
      }),
      signal: controller2.signal
    });

    clearTimeout(timeout2);

    if (pntResponse.ok) {
      const pntResult = await pntResponse.json();
      console.log(`✅ PNT minted successfully`);
      if (pntResult.txHash || pntResult.transactionHash) {
        console.log(`   Tx: ${pntResult.txHash || pntResult.transactionHash}`);
      }
    } else {
      const error = await pntResponse.text();
      console.log(`❌ PNT mint failed: ${pntResponse.status} ${error}`);
    }
  } catch (error) {
    console.log(`❌ PNT mint error: ${error.message}`);
  }

  // Wait 3 seconds
  await new Promise(resolve => setTimeout(resolve, 3000));

  // Step 3: Approve PNT to Paymaster
  console.log(`\n⏳ Step 3: Approving PNT for Paymaster...`);
  try {
    const controller3 = new AbortController();
    const timeout3 = setTimeout(() => controller3.abort(), 60000);

    const approveResponse = await fetch(`${FAUCET_API}/approve-pnt`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ accountAddress }),
      signal: controller3.signal
    });

    clearTimeout(timeout3);

    if (approveResponse.ok) {
      const approveResult = await approveResponse.json();
      console.log(`✅ PNT approved successfully`);
      if (approveResult.txHash || approveResult.transactionHash) {
        console.log(`   Tx: ${approveResult.txHash || approveResult.transactionHash}`);
      }
    } else {
      const error = await approveResponse.text();
      console.log(`❌ Approve failed: ${approveResponse.status} ${error}`);
    }
  } catch (error) {
    console.log(`❌ Approve error: ${error.message}`);
  }

  console.log(`\n✅ Token minting process completed for ${accountAddress}\n`);
}

// Get account address from arguments
const accountAddress = process.argv[2];

if (!accountAddress) {
  console.error('Usage: node mint-tokens-single.mjs <accountAddress>');
  process.exit(1);
}

mintTokens(accountAddress);

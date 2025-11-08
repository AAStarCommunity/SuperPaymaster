#!/usr/bin/env node
/**
 * Create a single SimpleAccount V1 using Faucet API
 *
 * Usage: node scripts/create-single-account.mjs <ownerAddress> <salt>
 */

const FAUCET_API = "https://faucet.aastar.io/api";
const FACTORY_ADDRESS = "0x9bD66892144FCf0BAF5B6946AEAFf38B0d967881"; // SimpleAccount V1 Factory

async function createAccount(ownerAddress, salt) {
  console.log(`\n🔄 Creating SimpleAccount V1...`);
  console.log(`   Owner: ${ownerAddress}`);
  console.log(`   Salt: ${salt}`);
  console.log(`   Factory: ${FACTORY_ADDRESS}\n`);

  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 90000); // 90s timeout

    console.log(`⏳ Sending request to Faucet API...`);
    const response = await fetch(`${FAUCET_API}/create-account`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        factoryAddress: FACTORY_ADDRESS,
        ownerAddress: ownerAddress,
        salt: salt
      }),
      signal: controller.signal
    });

    clearTimeout(timeout);

    if (!response.ok) {
      const error = await response.text();
      throw new Error(`HTTP ${response.status}: ${error}`);
    }

    const result = await response.json();
    console.log(`\n✅ Account created successfully!`);
    console.log(`   Account Address: ${result.accountAddress || result.address}`);
    if (result.transactionHash) {
      console.log(`   Transaction: ${result.transactionHash}`);
    }
    console.log(JSON.stringify(result, null, 2));

    return result;
  } catch (error) {
    if (error.name === 'AbortError') {
      console.error(`\n❌ Request timed out after 90 seconds`);
    } else {
      console.error(`\n❌ Failed to create account: ${error.message}`);
    }
    return null;
  }
}

// Get arguments
const ownerAddress = process.argv[2];
const salt = process.argv[3] || Math.floor(Math.random() * 1000000).toString();

if (!ownerAddress) {
  console.error('Usage: node create-single-account.mjs <ownerAddress> [salt]');
  process.exit(1);
}

createAccount(ownerAddress, salt);

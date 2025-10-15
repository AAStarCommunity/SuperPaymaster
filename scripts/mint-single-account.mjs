#!/usr/bin/env node
/**
 * Mint SBT and PNT for a single account (for testing)
 */

const FAUCET_API = "https://faucet.aastar.io/api";
const ACCOUNT = "0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584"; // Account A

async function mintSBT() {
  console.log("⏳ Minting SBT...");
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 30000); // 30s timeout

    const response = await fetch(`${FAUCET_API}/mint-sbt`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ accountAddress: ACCOUNT }),
      signal: controller.signal
    });

    clearTimeout(timeout);

    if (!response.ok) {
      const error = await response.text();
      throw new Error(`HTTP ${response.status}: ${error}`);
    }

    const result = await response.json();
    console.log("✅ SBT minted:", result);
    return result;
  } catch (error) {
    console.error("❌ Failed:", error.message);
    return null;
  }
}

mintSBT();

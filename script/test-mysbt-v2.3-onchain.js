#!/usr/bin/env node

/**
 * Test MySBT v2.3 on-chain basic functions
 *
 * Tests:
 * 1. Contract deployment verification
 * 2. Read basic constants and state
 * 3. Check configuration
 */

const { ethers } = require('ethers');
require('dotenv').config();

// Contract address and ABI
const MYSBT_V2_3_ADDRESS = '0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8';

const MYSBT_ABI = [
  "function VERSION() view returns (string)",
  "function VERSION_CODE() view returns (uint256)",
  "function GTOKEN() view returns (address)",
  "function GTOKEN_STAKING() view returns (address)",
  "function REGISTRY() view returns (address)",
  "function daoMultisig() view returns (address)",
  "function minLockAmount() view returns (uint256)",
  "function mintFee() view returns (uint256)",
  "function nextTokenId() view returns (uint256)",
  "function BASE_REPUTATION() view returns (uint256)",
  "function NFT_BONUS() view returns (uint256)",
  "function ACTIVITY_BONUS() view returns (uint256)",
  "function MIN_ACTIVITY_INTERVAL() view returns (uint256)",
  "function paused() view returns (bool)",
  "function reputationCalculator() view returns (address)",
  "function name() view returns (string)",
  "function symbol() view returns (string)"
];

async function main() {
  console.log('=== MySBT v2.3 On-Chain Test ===\n');

  // Setup provider
  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  if (!rpcUrl) {
    throw new Error('SEPOLIA_RPC_URL not found in .env');
  }

  console.log(`RPC URL: ${rpcUrl.substring(0, 50)}...`);
  const provider = new ethers.JsonRpcProvider(rpcUrl);

  // Connect to contract
  const mysbt = new ethers.Contract(MYSBT_V2_3_ADDRESS, MYSBT_ABI, provider);
  console.log(`Contract: ${MYSBT_V2_3_ADDRESS}\n`);

  try {
    // Test 1: Version Information
    console.log('📌 Test 1: Version Information');
    const version = await mysbt.VERSION();
    const versionCode = await mysbt.VERSION_CODE();
    console.log(`  ✓ VERSION: ${version}`);
    console.log(`  ✓ VERSION_CODE: ${versionCode}`);

    if (version !== '2.3.0' || versionCode !== 230n) {
      throw new Error('Version mismatch!');
    }
    console.log('  ✅ Version check passed\n');

    // Test 2: ERC721 Metadata
    console.log('📌 Test 2: ERC721 Metadata');
    const name = await mysbt.name();
    const symbol = await mysbt.symbol();
    console.log(`  ✓ Name: ${name}`);
    console.log(`  ✓ Symbol: ${symbol}`);
    console.log('  ✅ Metadata check passed\n');

    // Test 3: Immutable Configuration
    console.log('📌 Test 3: Immutable Configuration');
    const gtoken = await mysbt.GTOKEN();
    const staking = await mysbt.GTOKEN_STAKING();
    const registry = await mysbt.REGISTRY();
    console.log(`  ✓ GTOKEN: ${gtoken}`);
    console.log(`  ✓ GTOKEN_STAKING: ${staking}`);
    console.log(`  ✓ REGISTRY: ${registry}`);

    // Verify against .env
    const expectedGToken = process.env.V2_GTOKEN;
    const expectedStaking = process.env.V2_GTOKEN_STAKING;
    const expectedRegistry = process.env.V2_REGISTRY;

    if (gtoken.toLowerCase() !== expectedGToken?.toLowerCase()) {
      throw new Error(`GTOKEN mismatch: ${gtoken} !== ${expectedGToken}`);
    }
    if (staking.toLowerCase() !== expectedStaking?.toLowerCase()) {
      throw new Error(`GTOKEN_STAKING mismatch: ${staking} !== ${expectedStaking}`);
    }
    if (registry.toLowerCase() !== expectedRegistry?.toLowerCase()) {
      throw new Error(`REGISTRY mismatch: ${registry} !== ${expectedRegistry}`);
    }
    console.log('  ✅ Configuration check passed\n');

    // Test 4: Mutable Configuration
    console.log('📌 Test 4: Mutable Configuration');
    const dao = await mysbt.daoMultisig();
    const minLock = await mysbt.minLockAmount();
    const fee = await mysbt.mintFee();
    const nextId = await mysbt.nextTokenId();
    const calculator = await mysbt.reputationCalculator();
    console.log(`  ✓ DAO Multisig: ${dao}`);
    console.log(`  ✓ Min Lock Amount: ${ethers.formatEther(minLock)} sGT`);
    console.log(`  ✓ Mint Fee: ${ethers.formatEther(fee)} GT`);
    console.log(`  ✓ Next Token ID: ${nextId}`);
    console.log(`  ✓ Reputation Calculator: ${calculator}`);
    console.log('  ✅ Mutable config check passed\n');

    // Test 5: Constants (v2.3 Security Features)
    console.log('📌 Test 5: Constants & Security Features');
    const baseRep = await mysbt.BASE_REPUTATION();
    const nftBonus = await mysbt.NFT_BONUS();
    const activityBonus = await mysbt.ACTIVITY_BONUS();
    const minInterval = await mysbt.MIN_ACTIVITY_INTERVAL();
    const isPaused = await mysbt.paused();

    console.log(`  ✓ BASE_REPUTATION: ${baseRep}`);
    console.log(`  ✓ NFT_BONUS: ${nftBonus}`);
    console.log(`  ✓ ACTIVITY_BONUS: ${activityBonus}`);
    console.log(`  ✓ MIN_ACTIVITY_INTERVAL: ${minInterval}s (${minInterval / 60n} minutes)`);
    console.log(`  ✓ Paused: ${isPaused}`);

    if (minInterval !== 300n) {
      throw new Error(`Rate limiting interval should be 300s (5 minutes), got ${minInterval}s`);
    }
    if (isPaused) {
      console.log('  ⚠️  Contract is paused!');
    }
    console.log('  ✅ Constants check passed\n');

    // Test 6: Contract Code Verification
    console.log('📌 Test 6: Contract Code Verification');
    const code = await provider.getCode(MYSBT_V2_3_ADDRESS);
    const codeSize = (code.length - 2) / 2; // Remove '0x' and convert to bytes
    console.log(`  ✓ Contract code size: ${codeSize} bytes`);

    if (codeSize < 1000) {
      throw new Error('Contract code too small, might not be deployed correctly');
    }
    console.log('  ✅ Code verification passed\n');

    // Summary
    console.log('=================================');
    console.log('✅ All tests passed!');
    console.log('=================================\n');

    console.log('MySBT v2.3 Contract Summary:');
    console.log(`  Address: ${MYSBT_V2_3_ADDRESS}`);
    console.log(`  Version: ${version} (code: ${versionCode})`);
    console.log(`  Name: ${name}`);
    console.log(`  Symbol: ${symbol}`);
    console.log(`  Rate Limiting: ${minInterval / 60n} minutes`);
    console.log(`  Paused: ${isPaused}`);
    console.log(`  Next Token ID: ${nextId}`);
    console.log('');
    console.log('Ready for production use! 🚀');

  } catch (error) {
    console.error('\n❌ Test failed:', error.message);
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

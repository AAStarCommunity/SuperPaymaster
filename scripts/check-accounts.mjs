#!/usr/bin/env node

/**
 * Check if accounts are SimpleAccount V1 and have required tokens
 */

import { ethers } from 'ethers';
import dotenv from 'dotenv';

dotenv.config({ path: '.env.v3' });

const RPC_URL = process.env.SEPOLIA_RPC_URL;
const PNT_TOKEN = process.env.PNT_TOKEN_ADDRESS;
const SBT_CONTRACT = process.env.SBT_CONTRACT_ADDRESS;
const PAYMASTER_V4 = process.env.PAYMASTER_V4_ADDRESS;

const ACCOUNTS_TO_CHECK = [
  "0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584",
  "0xc2701F12eE436cD300B889FBC0B979e6E97623C8",
  "0x57b2e6f08399c276b2c1595825219d29990d0921"
];

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)"
];

const ERC721_ABI = [
  "function balanceOf(address) view returns (uint256)"
];

async function checkAccount(address) {
  console.log(`\n🔍 Checking ${address}...`);

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const pntToken = new ethers.Contract(PNT_TOKEN, ERC20_ABI, provider);
  const sbtContract = new ethers.Contract(SBT_CONTRACT, ERC721_ABI, provider);

  try {
    // Check if it's a contract
    const code = await provider.getCode(address);
    const isContract = code !== '0x';

    console.log(`  Contract: ${isContract ? '✅' : '❌'}`);

    if (!isContract) {
      console.log(`  ⚠️  Not a contract - likely an EOA, not SimpleAccount`);
      return { address, isValid: false, reason: 'Not a contract' };
    }

    // Check PNT balance
    const pntBalance = await pntToken.balanceOf(address);
    const pntFormatted = ethers.formatUnits(pntBalance, 18);
    console.log(`  PNT Balance: ${pntFormatted}`);

    // Check SBT balance
    const sbtBalance = await sbtContract.balanceOf(address);
    console.log(`  SBT Balance: ${sbtBalance.toString()}`);

    // Check PNT allowance to PaymasterV4
    const allowance = await pntToken.allowance(address, PAYMASTER_V4);
    const allowanceFormatted = ethers.formatUnits(allowance, 18);
    console.log(`  PNT Allowance to Paymaster: ${allowanceFormatted}`);

    // Check ETH balance (for verification gas)
    const ethBalance = await provider.getBalance(address);
    console.log(`  ETH Balance: ${ethers.formatEther(ethBalance)} ETH`);

    // Validation
    const hasPNT = pntBalance > 0n;
    const hasSBT = sbtBalance > 0n;
    const hasAllowance = allowance > ethers.parseUnits("10", 18); // At least 10 PNT

    const isValid = hasPNT && hasSBT && hasAllowance;

    if (isValid) {
      console.log(`  ✅ READY - Can send transactions!`);
    } else {
      console.log(`  ❌ NOT READY:`);
      if (!hasPNT) console.log(`     - Need PNT tokens`);
      if (!hasSBT) console.log(`     - Need SBT NFT`);
      if (!hasAllowance) console.log(`     - Need to approve Paymaster`);
    }

    return {
      address,
      isValid,
      isContract,
      pntBalance: pntFormatted,
      sbtBalance: sbtBalance.toString(),
      allowance: allowanceFormatted,
      ethBalance: ethers.formatEther(ethBalance)
    };

  } catch (error) {
    console.log(`  ❌ ERROR: ${error.message}`);
    return { address, isValid: false, reason: error.message };
  }
}

async function main() {
  console.log("🔍 Checking SimpleAccount V1 Accounts\n");
  console.log(`PNT Token: ${PNT_TOKEN}`);
  console.log(`SBT Contract: ${SBT_CONTRACT}`);
  console.log(`PaymasterV4: ${PAYMASTER_V4}`);

  const results = [];
  for (const address of ACCOUNTS_TO_CHECK) {
    const result = await checkAccount(address);
    results.push(result);
  }

  console.log("\n\n📊 Summary:");
  console.log("=" .repeat(80));

  const validAccounts = results.filter(r => r.isValid);
  console.log(`\n✅ Valid Accounts: ${validAccounts.length}/${results.length}`);

  if (validAccounts.length > 0) {
    console.log("\nReady for testing:");
    validAccounts.forEach(acc => {
      console.log(`  - ${acc.address} (PNT: ${acc.pntBalance}, SBT: ${acc.sbtBalance})`);
    });
  }

  const invalidAccounts = results.filter(r => !r.isValid);
  if (invalidAccounts.length > 0) {
    console.log("\n❌ Need setup:");
    invalidAccounts.forEach(acc => {
      console.log(`  - ${acc.address}: ${acc.reason || 'Missing requirements'}`);
    });
  }
}

main().catch(console.error);

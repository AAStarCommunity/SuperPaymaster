#!/usr/bin/env node
/**
 * Mint xPNTs tokens to AA accounts for testing
 */
const { ethers } = require('ethers');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../../../env/.env') });

const ERC20_ABI = [
  "function mint(address to, uint256 amount) external",
  "function balanceOf(address) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function owner() view returns (address)"
];

async function main() {
  console.log("╔═══════════════════════════════════════════════════════════╗");
  console.log("║            Mint xPNTs Tokens for Testing                 ║");
  console.log("╚═══════════════════════════════════════════════════════════╝\n");

  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  const privateKey = process.env.OWNER_PRIVATE_KEY || process.env.DEPLOYER_PRIVATE_KEY;
  
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const wallet = new ethers.Wallet(privateKey, provider);

  console.log(`Signer: ${wallet.address}\n`);

  const tokens = [
    { name: "xPNTs (ZUCOFFEE)", address: "0x31a8c3046864F8aa7ADF0B3D3e16934F122Fe215" },
    { name: "xPNTs1 (AAA)", address: "0xfb56CB85C9a214328789D3C92a496d6AA185e3d3" },
    { name: "xPNTs2 (TEA)", address: "0x311580CC1dF2dE49f9FCebB57f97c5182a57964f" }
  ];

  const recipients = [
    { name: "AA Account A", address: "0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584" },
    { name: "AA Account B", address: "0x57b2e6f08399c276b2c1595825219d29990d0921" },
    { name: "AA Account C", address: "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce" }
  ];

  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    const recipient = recipients[i];

    console.log(`\n📝 ${token.name}`);
    console.log(`   Token: ${token.address}`);
    console.log(`   Recipient: ${recipient.name} (${recipient.address})`);

    try {
      const tokenContract = new ethers.Contract(token.address, ERC20_ABI, wallet);
      
      const [symbol, decimals, owner] = await Promise.all([
        tokenContract.symbol(),
        tokenContract.decimals(),
        tokenContract.owner()
      ]);

      console.log(`   Symbol: ${symbol}`);
      console.log(`   Owner: ${owner}`);

      // Check if we can mint (must be owner)
      if (owner.toLowerCase() !== wallet.address.toLowerCase()) {
        console.log(`   ⚠️  Skipping: Not token owner`);
        continue;
      }

      // Mint 1000 tokens
      const mintAmount = ethers.parseUnits("1000", decimals);
      console.log(`   Minting: 1000 ${symbol}...`);

      const tx = await tokenContract.mint(recipient.address, mintAmount);
      console.log(`   TX: ${tx.hash}`);
      
      const receipt = await tx.wait();
      if (receipt.status === 1) {
        const balance = await tokenContract.balanceOf(recipient.address);
        console.log(`   ✅ Minted! New balance: ${ethers.formatUnits(balance, decimals)} ${symbol}`);
      } else {
        console.log(`   ❌ Transaction failed`);
      }

    } catch (err) {
      console.log(`   ❌ Error: ${err.message.substring(0, 100)}`);
    }
  }

  console.log("\n╔═══════════════════════════════════════════════════════════╗");
  console.log("║                   Minting Complete                        ║");
  console.log("╚═══════════════════════════════════════════════════════════╝");
}

main().catch(console.error);

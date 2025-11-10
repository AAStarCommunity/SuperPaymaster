#!/usr/bin/env node
/**
 * Transfer xPNTs tokens from deployer to AA accounts for testing
 */
const { ethers } = require('ethers');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../../../env/.env') });

const ERC20_ABI = [
  "function transfer(address to, uint256 amount) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)"
];

async function main() {
  console.log("╔═══════════════════════════════════════════════════════════╗");
  console.log("║       Transfer xPNTs Tokens to AA Accounts               ║");
  console.log("╚═══════════════════════════════════════════════════════════╝\n");

  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  const deployerPrivateKey = process.env.DEPLOYER_PRIVATE_KEY;
  
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const deployer = new ethers.Wallet(deployerPrivateKey, provider);

  console.log(`Deployer: ${deployer.address}\n`);

  // Define transfers: [token, recipient, amount]
  const transfers = [
    {
      tokenName: "xPNTs (ZUCOFFEE)",
      tokenAddress: "0x31a8c3046864F8aa7ADF0B3D3e16934F122Fe215",
      recipient: "0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584", // AA Account A
      recipientName: "AA Account A",
      amount: "100" // Transfer 100 tokens
    },
    {
      tokenName: "xPNTs1 (AAA)",
      tokenAddress: "0xfb56CB85C9a214328789D3C92a496d6AA185e3d3",
      recipient: "0x57b2e6f08399c276b2c1595825219d29990d0921", // AA Account B
      recipientName: "AA Account B",
      amount: "100"
    },
    {
      tokenName: "xPNTs2 (TEA)",
      tokenAddress: "0x311580CC1dF2dE49f9FCebB57f97c5182a57964f",
      recipient: "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce", // AA Account C
      recipientName: "AA Account C",
      amount: "100"
    }
  ];

  for (const transfer of transfers) {
    console.log(`\n📝 ${transfer.tokenName}`);
    console.log(`   Token: ${transfer.tokenAddress}`);
    console.log(`   To: ${transfer.recipientName} (${transfer.recipient})`);

    try {
      const token = new ethers.Contract(transfer.tokenAddress, ERC20_ABI, deployer);
      
      const [symbol, decimals, deployerBalance] = await Promise.all([
        token.symbol(),
        token.decimals(),
        token.balanceOf(deployer.address)
      ]);

      console.log(`   Symbol: ${symbol}`);
      console.log(`   Deployer Balance: ${ethers.formatUnits(deployerBalance, decimals)} ${symbol}`);

      // Check if deployer has enough balance
      const transferAmountWei = ethers.parseUnits(transfer.amount, decimals);
      
      if (deployerBalance < transferAmountWei) {
        console.log(`   ⚠️  Insufficient balance. Need ${transfer.amount}, have ${ethers.formatUnits(deployerBalance, decimals)}`);
        continue;
      }

      // Check recipient current balance
      const recipientBalanceBefore = await token.balanceOf(transfer.recipient);
      console.log(`   Recipient Balance Before: ${ethers.formatUnits(recipientBalanceBefore, decimals)} ${symbol}`);

      // Transfer
      console.log(`   Transferring ${transfer.amount} ${symbol}...`);
      const tx = await token.transfer(transfer.recipient, transferAmountWei);
      console.log(`   TX: ${tx.hash}`);
      console.log(`   Etherscan: https://sepolia.etherscan.io/tx/${tx.hash}`);
      
      const receipt = await tx.wait();
      
      if (receipt.status === 1) {
        // Check new balances
        const [deployerBalanceAfter, recipientBalanceAfter] = await Promise.all([
          token.balanceOf(deployer.address),
          token.balanceOf(transfer.recipient)
        ]);
        
        console.log(`   ✅ Transfer successful!`);
        console.log(`   Deployer Balance After: ${ethers.formatUnits(deployerBalanceAfter, decimals)} ${symbol}`);
        console.log(`   Recipient Balance After: ${ethers.formatUnits(recipientBalanceAfter, decimals)} ${symbol}`);
      } else {
        console.log(`   ❌ Transaction failed`);
      }

    } catch (err) {
      console.log(`   ❌ Error: ${err.message}`);
      if (err.code) console.log(`   Error code: ${err.code}`);
    }
  }

  console.log("\n╔═══════════════════════════════════════════════════════════╗");
  console.log("║                  Transfers Complete                       ║");
  console.log("╚═══════════════════════════════════════════════════════════╝");
}

main().catch(console.error);

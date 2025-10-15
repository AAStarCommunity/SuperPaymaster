require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

const PAYMASTER_V4 = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
const FROM_BLOCK = 9408600; // Historical start
const TO_BLOCK = 9415100; // Recent end

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  
  const paymasterABI = [
    "event GasPaymentProcessed(address indexed user, address indexed gasToken, uint256 pntAmount, uint256 gasCostWei, uint256 actualGasCost)"
  ];
  
  const paymaster = new ethers.Contract(PAYMASTER_V4, paymasterABI, provider);
  
  console.log(`\n📊 Counting ALL PaymasterV4 Transactions`);
  console.log(`Paymaster: ${PAYMASTER_V4}`);
  console.log(`Block range: ${FROM_BLOCK} → ${TO_BLOCK}\n`);
  
  let allEvents = [];
  
  // Query in chunks of 10 blocks (Alchemy free tier limit)
  for (let start = FROM_BLOCK; start <= TO_BLOCK; start += 10) {
    const end = Math.min(start + 9, TO_BLOCK);
    
    try {
      const events = await paymaster.queryFilter(
        paymaster.filters.GasPaymentProcessed(),
        start,
        end
      );
      
      if (events.length > 0) {
        console.log(`  Blocks ${start}-${end}: ${events.length} events`);
        allEvents.push(...events);
      }
    } catch (error) {
      console.error(`  Blocks ${start}-${end}: Error - ${error.message}`);
    }
  }
  
  console.log(`\n✅ Total transactions found: ${allEvents.length}`);
  
  // Group by user
  const byUser = {};
  allEvents.forEach(event => {
    const user = event.args.user;
    if (!byUser[user]) {
      byUser[user] = [];
    }
    byUser[user].push(event);
  });
  
  console.log(`\n📋 Transactions by User:`);
  Object.keys(byUser).forEach(user => {
    console.log(`  ${user}: ${byUser[user].length} transactions`);
  });
}

main().then(() => process.exit(0)).catch(error => {
  console.error(error);
  process.exit(1);
});

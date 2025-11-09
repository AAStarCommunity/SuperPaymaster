const { ethers } = require("ethers");
require("dotenv").config({ path: "../env/.env" });

const PAYMASTER_V4 = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
const RPC_URL = process.env.SEPOLIA_RPC_URL;

const PAYMASTER_ABI = [
  "event GasPaymentProcessed(address indexed user, address indexed gasToken, uint256 pntAmount, uint256 gasCostWei, uint256 actualGasCost)",
];

async function testQuery() {
  console.log("🔍 Testing PaymasterV4 Event Query");
  console.log("=".repeat(70));
  console.log(`Paymaster: ${PAYMASTER_V4}`);
  console.log(`RPC: ${RPC_URL}`);

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const contract = new ethers.Contract(PAYMASTER_V4, PAYMASTER_ABI, provider);

  // Test small chunk (10 blocks) where we know transactions exist
  const fromBlock = 9408619;
  const toBlock = 9408628; // Only 10 blocks

  console.log(`\nQuerying blocks ${fromBlock} → ${toBlock} (10 blocks)...`);

  try {
    const filter = contract.filters.GasPaymentProcessed();
    const events = await contract.queryFilter(filter, fromBlock, toBlock);

    console.log(`\n✅ Found ${events.length} events`);

    if (events.length > 0) {
      console.log("\nFirst 3 events:");
      events.slice(0, 3).forEach((e, i) => {
        console.log(`\nEvent ${i + 1}:`);
        console.log(`  Block: ${e.blockNumber}`);
        console.log(`  TxHash: ${e.transactionHash}`);
        console.log(`  User: ${e.args.user}`);
        console.log(`  GasToken: ${e.args.gasToken}`);
        console.log(
          `  ActualGasCost: ${ethers.formatEther(e.args.actualGasCost)} ETH`,
        );
        console.log(
          `  PNT Amount: ${ethers.formatUnits(e.args.pntAmount, 18)} PNT`,
        );
      });
    } else {
      console.log("\n⚠️ No events found in this range");
    }
  } catch (error) {
    console.error("❌ Query failed:", error.message);
  }
}

testQuery();

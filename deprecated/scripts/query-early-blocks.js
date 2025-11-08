const ethers = require('ethers');
require('dotenv').config({ path: '../env/.env' });

const PAYMASTER_V4_ABI = [
  "event GasPaymentProcessed(address indexed user, address indexed gasToken, uint256 actualGasCost, uint256 pntAmount)"
];

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  const paymasterAddress = process.env.PAYMASTER_V4_ADDRESS;
  const contract = new ethers.Contract(paymasterAddress, PAYMASTER_V4_ABI, provider);
  
  // Query around block 9381512 mentioned in summary
  const fromBlock = 9381500;
  const toBlock = 9381600;
  const CHUNK_SIZE = 10;
  
  console.log(`🔍 Searching blocks ${fromBlock} to ${toBlock} for early transactions...\n`);
  
  const allEvents = [];
  
  for (let start = fromBlock; start <= toBlock; start += CHUNK_SIZE) {
    const end = Math.min(start + CHUNK_SIZE - 1, toBlock);
    try {
      const events = await contract.queryFilter(
        contract.filters.GasPaymentProcessed(),
        start,
        end
      );
      if (events.length > 0) {
        console.log(`✅ [${start}, ${end}]: ${events.length} events`);
        allEvents.push(...events);
      }
      await new Promise(resolve => setTimeout(resolve, 200));
    } catch (error) {
      console.error(`❌ [${start}, ${end}]:`, error.message.substring(0, 100));
    }
  }
  
  console.log(`\n📊 Total events found: ${allEvents.length}\n`);
  
  for (const event of allEvents) {
    const block = await provider.getBlock(event.blockNumber);
    console.log(`Block ${event.blockNumber} | ${new Date(block.timestamp * 1000).toISOString()}`);
    console.log(`  User: ${event.args.user}`);
    console.log(`  Tx: ${event.transactionHash}\n`);
  }
}

main().catch(console.error);

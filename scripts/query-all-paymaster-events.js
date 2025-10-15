const ethers = require('ethers');
require('dotenv').config({ path: '../env/.env' });

const PAYMASTER_V4_ABI = [
  "event GasPaymentProcessed(address indexed user, address indexed gasToken, uint256 actualGasCost, uint256 pntAmount)"
];

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  const paymasterAddress = process.env.PAYMASTER_V4_ADDRESS;
  
  console.log('🔍 Querying ALL GasPaymentProcessed events from PaymasterV4...');
  console.log(`Paymaster: ${paymasterAddress}\n`);
  
  const contract = new ethers.Contract(paymasterAddress, PAYMASTER_V4_ABI, provider);
  
  // Query from deployment block to current
  const currentBlock = await provider.getBlockNumber();
  const fromBlock = 9381500; // Earlier than any known transaction
  const toBlock = currentBlock;
  
  console.log(`Querying blocks ${fromBlock} to ${toBlock} (${toBlock - fromBlock + 1} blocks)...\n`);
  
  // Query in chunks of 100 blocks to avoid rate limits
  const CHUNK_SIZE = 100;
  const allEvents = [];
  
  for (let start = fromBlock; start <= toBlock; start += CHUNK_SIZE) {
    const end = Math.min(start + CHUNK_SIZE - 1, toBlock);
    try {
      const events = await contract.queryFilter(
        contract.filters.GasPaymentProcessed(),
        start,
        end
      );
      allEvents.push(...events);
      if (events.length > 0) {
        console.log(`✅ Chunk [${start}, ${end}]: found ${events.length} events`);
      }
      // Small delay to avoid rate limiting
      await new Promise(resolve => setTimeout(resolve, 100));
    } catch (error) {
      console.error(`❌ Error querying chunk [${start}, ${end}]:`, error.message);
    }
  }
  
  console.log(`\n📊 Total events found: ${allEvents.length}\n`);
  
  // Get detailed info for each event
  const results = [];
  for (const event of allEvents) {
    const block = await provider.getBlock(event.blockNumber);
    results.push({
      blockNumber: event.blockNumber,
      transactionHash: event.transactionHash,
      user: event.args.user,
      gasToken: event.args.gasToken,
      actualGasCost: ethers.formatEther(event.args.actualGasCost),
      pntAmount: ethers.formatUnits(event.args.pntAmount, 18),
      timestamp: block.timestamp,
      date: new Date(block.timestamp * 1000).toISOString()
    });
  }
  
  // Sort by block number
  results.sort((a, b) => a.blockNumber - b.blockNumber);
  
  console.log('═══════════════════════════════════════════════════════════════════════');
  results.forEach((r, i) => {
    console.log(`${i + 1}. Block ${r.blockNumber} | ${r.date}`);
    console.log(`   User: ${r.user}`);
    console.log(`   Tx: ${r.transactionHash}`);
    console.log(`   Gas: ${r.actualGasCost} ETH | PNT: ${r.pntAmount}`);
    console.log('');
  });
  
  if (results.length > 0) {
    console.log('📈 Summary:');
    console.log(`   Earliest: Block ${results[0].blockNumber} (${results[0].date})`);
    console.log(`   Latest: Block ${results[results.length - 1].blockNumber} (${results[results.length - 1].date})`);
    console.log(`   Total Transactions: ${results.length}`);
    
    // Count unique users
    const uniqueUsers = new Set(results.map(r => r.user.toLowerCase()));
    console.log(`   Unique Users: ${uniqueUsers.size}`);
  }
}

main().catch(console.error);

const ethers = require('ethers');
require('dotenv').config({ path: '../env/.env' });

const PAYMASTER_V4_ABI = [
  "event GasPaymentProcessed(address indexed user, address indexed gasToken, uint256 actualGasCost, uint256 pntAmount)"
];

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  const paymasterAddress = process.env.PAYMASTER_V4_ADDRESS;
  
  console.log('🔍 Querying ALL GasPaymentProcessed events');
  console.log(`Paymaster: ${paymasterAddress}\n`);
  
  const contract = new ethers.Contract(paymasterAddress, PAYMASTER_V4_ABI, provider);
  
  const fromBlock = 9408600;
  const toBlock = 9408800;
  const CHUNK_SIZE = 10;
  
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
      console.error(`❌ [${start}, ${end}]:`, error.message);
    }
  }
  
  console.log(`\n📊 Total: ${allEvents.length} events\n`);
  
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
  
  results.sort((a, b) => a.blockNumber - b.blockNumber);
  
  console.log('═══════════════════════════════════════════════════════════════════════');
  results.forEach((r, i) => {
    console.log(`${i + 1}. Block ${r.blockNumber} | ${r.date}`);
    console.log(`   User: ${r.user}`);
    console.log(`   Tx: ${r.transactionHash}`);
    console.log(`   Gas: ${r.actualGasCost} ETH | PNT: ${r.pntAmount}`);
    console.log('');
  });
  
  console.log('📈 Summary:');
  if (results.length > 0) {
    console.log(`   Block Range: ${results[0].blockNumber} → ${results[results.length - 1].blockNumber}`);
    console.log(`   Total Transactions: ${results.length}`);
    const uniqueUsers = new Set(results.map(r => r.user.toLowerCase()));
    console.log(`   Unique Users: ${uniqueUsers.size}`);
  }
}

main().catch(console.error);

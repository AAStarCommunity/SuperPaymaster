const ethers = require('ethers');
require('dotenv').config({ path: '../env/.env' });

const PAYMASTER_V4_ABI = [
  "event GasPaymentProcessed(address indexed user, address indexed gasToken, uint256 actualGasCost, uint256 pntAmount)"
];

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  const paymasterAddress = process.env.PAYMASTER_V4_ADDRESS;
  
  console.log('🔍 Querying GasPaymentProcessed events from PaymasterV4');
  console.log(`Paymaster: ${paymasterAddress}\n`);
  
  const contract = new ethers.Contract(paymasterAddress, PAYMASTER_V4_ABI, provider);
  
  // Query focused range where we know transactions exist
  const fromBlock = 9408600; // Start before earliest known transaction
  const toBlock = 9408800;   // End after latest known transaction
  
  console.log(`Querying blocks ${fromBlock} to ${toBlock}...\n`);
  
  const events = await contract.queryFilter(
    contract.filters.GasPaymentProcessed(),
    fromBlock,
    toBlock
  );
  
  console.log(`📊 Total events found: ${events.length}\n`);
  
  // Get detailed info
  const results = [];
  for (const event of events) {
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
  console.log(`   Earliest: Block ${results[0].blockNumber}`);
  console.log(`   Latest: Block ${results[results.length - 1].blockNumber}`);
  console.log(`   Total Transactions: ${results.length}`);
  
  const uniqueUsers = new Set(results.map(r => r.user.toLowerCase()));
  console.log(`   Unique Users: ${uniqueUsers.size}`);
}

main().catch(console.error);

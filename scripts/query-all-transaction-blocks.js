const ethers = require('ethers');
require('dotenv').config({ path: '../env/.env' });

// All known transaction hashes from our tests
const TRANSACTION_HASHES = [
  // Account C (0x8135...a9Ce) - old transactions
  '0x51f26f19217bc0ae427255be4b8895d8c8706f34bbb50221dc07ef0c626cedf5',
  '0x9fe60bec6094bd4cdf627f70d6865cc0f4c1b6aacda4abcb55b14b88320f6a55',
  
  // Account 1 (0xc06D...7F61) - new transactions
  '0xe0a9c7e92ea1d07e8be5d330ee2d58e44d41e337b71bac345c1b1e7e5617c2dd',
  '0x0dc501df91c5c653c34c36782387d95a22825bbb8fe7938731abede9bd462bab',
  
  // Account 2 (0x60D7...b997) - new transactions
  '0x85789ac13728208cbc14ee68983186857e28b561cd8c0debf4f32b52d8e93845',
  '0xf9a57b0e4410ada3dbf1db4ab015aca39f177e2c0654c28c96725c6caca8aaea',
  
  // Account 3 (0x5522...d81a) - new transaction
  '0x08dd48e0fcc31413b4d04bfa31980bee199aa4ee7bbd4d0beaed6329ac0caaa1',
];

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  
  console.log('🔍 Querying exact block heights for all transactions...\n');
  
  const results = [];
  
  for (const txHash of TRANSACTION_HASHES) {
    try {
      const receipt = await provider.getTransactionReceipt(txHash);
      if (receipt) {
        const block = await provider.getBlock(receipt.blockNumber);
        const tx = await provider.getTransaction(txHash);
        
        results.push({
          txHash,
          blockNumber: receipt.blockNumber,
          timestamp: block.timestamp,
          date: new Date(block.timestamp * 1000).toISOString(),
          from: tx.from,
          status: receipt.status === 1 ? '✅ Success' : '❌ Failed'
        });
        
        console.log(`Tx: ${txHash}`);
        console.log(`   Block: ${receipt.blockNumber}`);
        console.log(`   Time: ${new Date(block.timestamp * 1000).toISOString()}`);
        console.log(`   From: ${tx.from}`);
        console.log(`   Status: ${receipt.status === 1 ? '✅ Success' : '❌ Failed'}`);
        console.log('');
      } else {
        console.log(`❌ Transaction ${txHash} not found`);
      }
    } catch (error) {
      console.error(`Error querying ${txHash}:`, error.message);
    }
  }
  
  // Sort by block number
  results.sort((a, b) => a.blockNumber - b.blockNumber);
  
  console.log('\n📊 Summary (sorted by block):');
  console.log('════════════════════════════════════════════════════════════');
  results.forEach((r, i) => {
    console.log(`${i + 1}. Block ${r.blockNumber} | ${r.date}`);
    console.log(`   Tx: ${r.txHash}`);
    console.log(`   From: ${r.from}`);
  });
  
  console.log('\n📈 Block Range:');
  console.log(`   Earliest: ${results[0].blockNumber} (${results[0].date})`);
  console.log(`   Latest: ${results[results.length - 1].blockNumber} (${results[results.length - 1].date})`);
  console.log(`   Total Transactions: ${results.length}`);
}

main().catch(console.error);

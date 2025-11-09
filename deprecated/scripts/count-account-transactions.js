const ethers = require('ethers');
require('dotenv').config({ path: '../env/.env' });

const ACCOUNTS = [
  { name: 'Account C', address: '0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce' },
  { name: 'Account 1', address: '0xc06D99e32c6BAE8FFCb2C269Fe76B34fE6547F61' },
  { name: 'Account 2', address: '0x60D70Cb25A0d412F4C01B723dD676d9B2237b997' },
  { name: 'Account 3', address: '0x552257eb48685b694EEF5532Dd4DC6bfA61eD81A' }
];

const PAYMASTER_V4_ABI = [
  "event GasPaymentProcessed(address indexed user, address indexed gasToken, uint256 actualGasCost, uint256 pntAmount)"
];

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  const paymasterAddress = process.env.PAYMASTER_V4_ADDRESS;
  const contract = new ethers.Contract(paymasterAddress, PAYMASTER_V4_ABI, provider);
  
  console.log('🔍 统计4个账户在Paymaster的交易记录\n');
  console.log(`Paymaster: ${paymasterAddress}\n`);
  
  // 查询大范围的区块
  const fromBlock = 9400000; // 更早的起始区块
  const toBlock = 9410000;   // 更晚的结束区块
  const CHUNK_SIZE = 10;
  
  console.log(`查询区块范围: ${fromBlock} → ${toBlock} (${toBlock - fromBlock}个区块)\n`);
  
  const accountTxMap = new Map();
  ACCOUNTS.forEach(acc => accountTxMap.set(acc.address.toLowerCase(), []));
  
  let totalEvents = 0;
  
  // 分块查询
  for (let start = fromBlock; start <= toBlock; start += CHUNK_SIZE) {
    const end = Math.min(start + CHUNK_SIZE - 1, toBlock);
    
    try {
      const events = await contract.queryFilter(
        contract.filters.GasPaymentProcessed(),
        start,
        end
      );
      
      if (events.length > 0) {
        totalEvents += events.length;
        console.log(`✅ [${start}, ${end}]: ${events.length} events`);
        
        // 分类到各个账户
        for (const event of events) {
          const userAddr = event.args.user.toLowerCase();
          if (accountTxMap.has(userAddr)) {
            const block = await provider.getBlock(event.blockNumber);
            accountTxMap.get(userAddr).push({
              hash: event.transactionHash,
              blockNumber: event.blockNumber,
              timestamp: block.timestamp,
              gasToken: event.args.gasToken,
              actualGasCost: ethers.formatEther(event.args.actualGasCost),
              pntAmount: ethers.formatUnits(event.args.pntAmount, 18)
            });
          }
        }
      }
      
      await new Promise(resolve => setTimeout(resolve, 200));
    } catch (error) {
      console.error(`❌ [${start}, ${end}]:`, error.message.substring(0, 80));
    }
  }
  
  console.log(`\n📊 总共找到 ${totalEvents} 笔交易\n`);
  
  // 统计每个账户
  console.log('='.repeat(80));
  let totalUserTx = 0;
  
  for (const account of ACCOUNTS) {
    const txs = accountTxMap.get(account.address.toLowerCase());
    console.log(`\n${account.name} (${account.address}):`);
    console.log(`   交易数: ${txs.length}笔`);
    totalUserTx += txs.length;
    
    if (txs.length > 0) {
      // 排序
      txs.sort((a, b) => a.blockNumber - b.blockNumber);
      
      txs.forEach((tx, i) => {
        console.log(`\n   ${i + 1}. Block ${tx.blockNumber} | ${new Date(tx.timestamp * 1000).toISOString()}`);
        console.log(`      Tx: ${tx.hash}`);
        console.log(`      Gas: ${tx.actualGasCost} ETH | PNT: ${tx.pntAmount}`);
      });
    }
  }
  
  console.log('\n' + '='.repeat(80));
  console.log('📊 汇总统计:');
  console.log(`   总交易数: ${totalUserTx}笔`);
  console.log(`   账户数: ${ACCOUNTS.length}个`);
  console.log(`   每账户平均: ${(totalUserTx / ACCOUNTS.length).toFixed(1)}笔`);
  
  // 找出所有交易的区块范围
  const allTxs = [];
  accountTxMap.forEach(txs => allTxs.push(...txs));
  if (allTxs.length > 0) {
    allTxs.sort((a, b) => a.blockNumber - b.blockNumber);
    console.log(`\n   区块范围: ${allTxs[0].blockNumber} → ${allTxs[allTxs.length - 1].blockNumber}`);
    console.log(`   时间跨度: ${new Date(allTxs[0].timestamp * 1000).toISOString()} → ${new Date(allTxs[allTxs.length - 1].timestamp * 1000).toISOString()}`);
  }
}

main().catch(console.error);

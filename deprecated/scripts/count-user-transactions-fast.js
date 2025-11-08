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
  
  console.log('🔍 直接查询每个用户的GasPaymentProcessed事件\n');
  
  // 精确的区块范围
  const fromBlock = 9408600;
  const toBlock = 9408800;
  
  console.log(`区块范围: ${fromBlock} → ${toBlock}\n`);
  
  let totalTx = 0;
  const allTxs = [];
  
  for (const account of ACCOUNTS) {
    console.log(`\n${'='.repeat(70)}`);
    console.log(`${account.name}: ${account.address}`);
    console.log('='.repeat(70));
    
    // 使用indexed参数过滤user地址
    const filter = contract.filters.GasPaymentProcessed(account.address);
    const events = await contract.queryFilter(filter, fromBlock, toBlock);
    
    console.log(`交易数: ${events.length}笔\n`);
    totalTx += events.length;
    
    for (const event of events) {
      const block = await provider.getBlock(event.blockNumber);
      const tx = {
        account: account.name,
        address: account.address,
        hash: event.transactionHash,
        blockNumber: event.blockNumber,
        timestamp: block.timestamp,
        date: new Date(block.timestamp * 1000).toISOString(),
        gasToken: event.args.gasToken,
        actualGasCost: ethers.formatEther(event.args.actualGasCost),
        pntAmount: ethers.formatUnits(event.args.pntAmount, 18)
      };
      
      allTxs.push(tx);
      
      console.log(`  Block ${tx.blockNumber} | ${tx.date}`);
      console.log(`  Tx: ${tx.hash}`);
      console.log(`  Gas: ${tx.actualGasCost} ETH | PNT: ${tx.pntAmount}\n`);
    }
  }
  
  console.log('\n' + '='.repeat(70));
  console.log('📊 总结统计');
  console.log('='.repeat(70));
  console.log(`总交易数: ${totalTx}笔`);
  console.log(`账户数: ${ACCOUNTS.length}个`);
  
  // 按账户分组统计
  const accountCounts = {};
  ACCOUNTS.forEach(acc => accountCounts[acc.name] = 0);
  allTxs.forEach(tx => accountCounts[tx.account]++);
  
  console.log('\n各账户交易数:');
  Object.entries(accountCounts).forEach(([name, count]) => {
    console.log(`  ${name}: ${count}笔`);
  });
  
  // 按区块排序显示所有交易
  allTxs.sort((a, b) => a.blockNumber - b.blockNumber);
  
  console.log('\n📋 所有交易列表 (按区块时间排序):');
  console.log('='.repeat(70));
  allTxs.forEach((tx, i) => {
    console.log(`${i + 1}. Block ${tx.blockNumber} | ${tx.date}`);
    console.log(`   ${tx.account} (${tx.address.substring(0, 10)}...)`);
    console.log(`   ${tx.hash}`);
  });
  
  if (allTxs.length > 0) {
    console.log(`\n区块跨度: ${allTxs[0].blockNumber} → ${allTxs[allTxs.length - 1].blockNumber}`);
  }
}

main().catch(console.error);

const ethers = require('ethers');
require('dotenv').config({ path: '../env/.env' });

const ACCOUNTS = [
  { name: 'Account C', address: '0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce' },
  { name: 'Account 1', address: '0xc06D99e32c6BAE8FFCb2C269Fe76B34fE6547F61' },
  { name: 'Account 2', address: '0x60D70Cb25A0d412F4C01B723dD676d9B2237b997' },
  { name: 'Account 3', address: '0x552257eb48685b694EEF5532Dd4DC6bfA61eD81A' }
];

const PAYMASTER_ADDRESS = process.env.PAYMASTER_V4_ADDRESS.toLowerCase();

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  
  console.log('🔍 查询4个账户的所有历史交易...\n');
  console.log(`Paymaster地址: ${PAYMASTER_ADDRESS}\n`);
  
  let totalTransactions = 0;
  const allTxDetails = [];
  
  for (const account of ACCOUNTS) {
    console.log(`\n${'='.repeat(80)}`);
    console.log(`📍 ${account.name}: ${account.address}`);
    console.log('='.repeat(80));
    
    // 获取账户的交易历史
    const history = await provider.getHistory(account.address);
    console.log(`   总交易数: ${history.length}`);
    
    // 过滤出与Paymaster相关的交易
    let paymasterTxCount = 0;
    
    for (const tx of history) {
      // 检查是否是发送给Paymaster的交易
      const to = tx.to?.toLowerCase();
      const from = tx.from?.toLowerCase();
      
      if (to === PAYMASTER_ADDRESS || from === PAYMASTER_ADDRESS) {
        paymasterTxCount++;
        
        const receipt = await provider.getTransactionReceipt(tx.hash);
        const block = await provider.getBlock(tx.blockNumber);
        
        console.log(`\n   ✅ Tx #${paymasterTxCount}:`);
        console.log(`      Hash: ${tx.hash}`);
        console.log(`      Block: ${tx.blockNumber}`);
        console.log(`      Time: ${new Date(block.timestamp * 1000).toISOString()}`);
        console.log(`      From: ${tx.from}`);
        console.log(`      To: ${tx.to}`);
        console.log(`      Status: ${receipt.status === 1 ? '✅ Success' : '❌ Failed'}`);
        
        allTxDetails.push({
          account: account.name,
          accountAddress: account.address,
          hash: tx.hash,
          blockNumber: tx.blockNumber,
          timestamp: block.timestamp,
          from: tx.from,
          to: tx.to,
          status: receipt.status
        });
      }
    }
    
    console.log(`\n   📊 与Paymaster相关的交易: ${paymasterTxCount}笔`);
    totalTransactions += paymasterTxCount;
  }
  
  console.log('\n' + '='.repeat(80));
  console.log('📊 总结');
  console.log('='.repeat(80));
  console.log(`总交易数: ${totalTransactions}笔`);
  console.log(`账户数: ${ACCOUNTS.length}个`);
  console.log(`每账户平均: ${(totalTransactions / ACCOUNTS.length).toFixed(1)}笔`);
  
  // 按区块排序
  allTxDetails.sort((a, b) => a.blockNumber - b.blockNumber);
  
  console.log('\n📋 所有交易列表 (按区块排序):');
  console.log('='.repeat(80));
  allTxDetails.forEach((tx, i) => {
    console.log(`${i + 1}. Block ${tx.blockNumber} | ${new Date(tx.timestamp * 1000).toISOString()}`);
    console.log(`   ${tx.account} (${tx.accountAddress})`);
    console.log(`   Tx: ${tx.hash}`);
    console.log('');
  });
  
  if (allTxDetails.length > 0) {
    console.log('📈 区块范围:');
    console.log(`   最早: ${allTxDetails[0].blockNumber}`);
    console.log(`   最晚: ${allTxDetails[allTxDetails.length - 1].blockNumber}`);
    console.log(`   跨度: ${allTxDetails[allTxDetails.length - 1].blockNumber - allTxDetails[0].blockNumber}个区块`);
  }
}

main().catch(console.error);

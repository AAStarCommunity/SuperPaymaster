const ethers = require('ethers');
require('dotenv').config({ path: '../env/.env' });

const REGISTRY_ABI = [
  "function getActivePaymasters() external view returns (address[])"
];

const PAYMASTER_ABI = [
  "event GasPaymentProcessed(address indexed user, address indexed gasToken, uint256 actualGasCost, uint256 pntAmount)"
];

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  const registryAddress = '0x838da93c815a6E45Aa50429529da9106C0621eF0';
  
  console.log('🔍 正确的查询流程:\n');
  console.log('Step 1: 从Registry获取所有Paymaster地址\n');
  
  const registry = new ethers.Contract(registryAddress, REGISTRY_ABI, provider);
  const paymasters = await registry.getActivePaymasters();
  
  console.log(`找到 ${paymasters.length} 个Paymaster:\n`);
  paymasters.forEach((pm, i) => console.log(`  ${i + 1}. ${pm}`));
  
  console.log('\n\nStep 2: 为每个Paymaster查询GasPaymentProcessed事件\n');
  console.log('='.repeat(70));
  
  const fromBlock = 9408600;
  const toBlock = 9408800;
  const CHUNK_SIZE = 10;
  
  const allEvents = [];
  const paymasterStats = {};
  
  for (const pmAddress of paymasters) {
    console.log(`\n查询Paymaster: ${pmAddress}`);
    console.log('-'.repeat(70));
    
    const contract = new ethers.Contract(pmAddress, PAYMASTER_ABI, provider);
    let pmEvents = [];
    
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
          console.log(`  ✅ [${start}, ${end}]: ${events.length} events`);
          pmEvents.push(...events);
        }
        
        await new Promise(resolve => setTimeout(resolve, 200));
      } catch (error) {
        console.log(`  ❌ [${start}, ${end}]: ${error.message.substring(0, 60)}`);
      }
    }
    
    paymasterStats[pmAddress] = pmEvents.length;
    allEvents.push(...pmEvents);
    
    console.log(`  📊 该Paymaster共 ${pmEvents.length} 笔交易`);
  }
  
  console.log('\n\n' + '='.repeat(70));
  console.log('📊 汇总统计');
  console.log('='.repeat(70));
  
  console.log(`\n总交易数: ${allEvents.length}笔\n`);
  
  console.log('各Paymaster交易数:');
  Object.entries(paymasterStats).forEach(([pm, count]) => {
    if (count > 0) {
      console.log(`  ${pm}: ${count}笔`);
    }
  });
  
  const activeCount = Object.values(paymasterStats).filter(c => c > 0).length;
  console.log(`\n有交易的Paymaster: ${activeCount}/${paymasters.length}个`);
}

main().catch(console.error);

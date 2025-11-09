const ethers = require('ethers');
require('dotenv').config({ path: '../env/.env' });

// SuperPaymaster Registry ABI (minimal)
const REGISTRY_ABI = [
  "function getAllPaymasters() external view returns (address[])",
  "function getPaymasterInfo(address paymaster) external view returns (string memory name, string memory version, bool isActive)",
  "event PaymasterRegistered(address indexed paymaster, string name, string version)"
];

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  const registryAddress = process.env.REGISTRY_ADDRESS || '0x838da93c815a6E45Aa50429529da9106C0621eF0';
  
  console.log('🔍 查询SuperPaymaster Registry注册的所有Paymaster\n');
  console.log(`Registry地址: ${registryAddress}\n`);
  
  const registry = new ethers.Contract(registryAddress, REGISTRY_ABI, provider);
  
  try {
    // 尝试调用getAllPaymasters
    const paymasters = await registry.getAllPaymasters();
    
    console.log(`📊 找到 ${paymasters.length} 个注册的Paymaster:\n`);
    
    for (const [index, address] of paymasters.entries()) {
      console.log(`${index + 1}. ${address}`);
      
      try {
        const info = await registry.getPaymasterInfo(address);
        console.log(`   名称: ${info.name}`);
        console.log(`   版本: ${info.version}`);
        console.log(`   状态: ${info.isActive ? '✅ Active' : '❌ Inactive'}`);
      } catch (e) {
        console.log(`   (无法获取详细信息)`);
      }
      console.log('');
    }
    
  } catch (error) {
    console.log('❌ getAllPaymasters调用失败,尝试通过事件查询...\n');
    console.log(`错误: ${error.message}\n`);
    
    // 如果方法不存在,通过PaymasterRegistered事件查询
    console.log('📡 通过PaymasterRegistered事件查询...\n');
    
    const fromBlock = 0;
    const currentBlock = await provider.getBlockNumber();
    const CHUNK_SIZE = 10000; // 大块查询事件
    
    const allPaymasters = new Set();
    
    for (let start = fromBlock; start <= currentBlock; start += CHUNK_SIZE) {
      const end = Math.min(start + CHUNK_SIZE - 1, currentBlock);
      
      try {
        const events = await registry.queryFilter(
          registry.filters.PaymasterRegistered(),
          start,
          end
        );
        
        if (events.length > 0) {
          console.log(`✅ [${start}, ${end}]: 找到 ${events.length} 个注册事件`);
          events.forEach(event => {
            allPaymasters.add(event.args.paymaster.toLowerCase());
          });
        }
        
        await new Promise(resolve => setTimeout(resolve, 300));
      } catch (e) {
        console.error(`❌ [${start}, ${end}]: ${e.message.substring(0, 80)}`);
      }
    }
    
    console.log(`\n📊 通过事件找到 ${allPaymasters.size} 个Paymaster:\n`);
    Array.from(allPaymasters).forEach((addr, i) => {
      console.log(`${i + 1}. ${addr}`);
    });
  }
}

main().catch(console.error);

const ethers = require('ethers');
require('dotenv').config({ path: '../env/.env' });

const REGISTRY_ABI = [
  "function getActivePaymasters() external view returns (address[])",
  "function getPaymasterCount() external view returns (uint256)",
  "function paymasters(address) external view returns (address paymasterAddress, string name, uint256 feeRate, uint256 stakedAmount, uint256 reputation, bool isActive, uint256 successCount, uint256 totalAttempts, uint256 registeredAt, uint256 lastActiveAt)"
];

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  const registryAddress = '0x838da93c815a6E45Aa50429529da9106C0621eF0';
  
  console.log('🔍 查询SuperPaymaster Registry\n');
  console.log(`Registry: ${registryAddress}\n`);
  
  const registry = new ethers.Contract(registryAddress, REGISTRY_ABI, provider);
  
  // 1. 获取注册的Paymaster数量
  const count = await registry.getPaymasterCount();
  console.log(`📊 注册的Paymaster总数: ${count}\n`);
  
  // 2. 获取活跃的Paymaster列表
  const activePaymasters = await registry.getActivePaymasters();
  console.log(`✅ 活跃的Paymaster: ${activePaymasters.length}个\n`);
  
  // 3. 获取每个Paymaster的详细信息
  for (const [index, address] of activePaymasters.entries()) {
    console.log(`${index + 1}. Paymaster: ${address}`);
    
    const info = await registry.paymasters(address);
    console.log(`   名称: ${info.name}`);
    console.log(`   费率: ${info.feeRate / 100}%`);
    console.log(`   质押: ${ethers.formatEther(info.stakedAmount)} ETH`);
    console.log(`   信誉: ${info.reputation / 100}/100`);
    console.log(`   成功率: ${info.totalAttempts > 0 ? (info.successCount * 100 / info.totalAttempts).toFixed(2) : 0}%`);
    console.log(`   注册时间: ${new Date(Number(info.registeredAt) * 1000).toISOString()}`);
    console.log('');
  }
  
  return activePaymasters;
}

main()
  .then(paymasters => {
    console.log('\n✅ 查询完成');
    console.log(`找到 ${paymasters.length} 个活跃的Paymaster`);
  })
  .catch(console.error);

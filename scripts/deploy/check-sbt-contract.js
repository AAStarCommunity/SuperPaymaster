const { createPublicClient, http } = require('viem');
const { sepolia } = require('viem/chains');
require('dotenv').config({ path: '../../env/.env' });

const SBT_ADDRESS = '0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C';

async function main() {
  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(process.env.SEPOLIA_RPC_URL)
  });

  console.log(`检查地址: ${SBT_ADDRESS}\n`);

  // Check if contract exists
  const code = await publicClient.getBytecode({ address: SBT_ADDRESS });

  if (!code || code === '0x') {
    console.log('❌ 地址没有合约代码（可能是EOA或未部署）');
    return;
  }

  console.log('✅ 地址有合约代码');
  console.log(`代码长度: ${code.length} 字符\n`);

  // Try to call common SBT/ERC721 functions
  const erc721Abi = [
    { type: 'function', name: 'name', outputs: [{type: 'string'}], stateMutability: 'view' },
    { type: 'function', name: 'symbol', outputs: [{type: 'string'}], stateMutability: 'view' },
    { type: 'function', name: 'VERSION', outputs: [{type: 'string'}], stateMutability: 'view' },
  ];

  try {
    const [name, symbol] = await Promise.all([
      publicClient.readContract({
        address: SBT_ADDRESS,
        abi: erc721Abi,
        functionName: 'name'
      }),
      publicClient.readContract({
        address: SBT_ADDRESS,
        abi: erc721Abi,
        functionName: 'symbol'
      })
    ]);

    console.log('合约信息:');
    console.log(`  Name: ${name}`);
    console.log(`  Symbol: ${symbol}`);

    try {
      const version = await publicClient.readContract({
        address: SBT_ADDRESS,
        abi: erc721Abi,
        functionName: 'VERSION'
      });
      console.log(`  VERSION: ${version}`);
    } catch (e) {
      console.log('  VERSION: (无VERSION函数)');
    }

  } catch (error) {
    console.log('⚠️  无法读取ERC721函数，可能不是SBT合约');
    console.log(`错误: ${error.message}`);
  }
}

main().catch(console.error);

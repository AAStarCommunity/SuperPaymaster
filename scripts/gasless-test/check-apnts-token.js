const { createPublicClient, http } = require('viem');
const { sepolia } = require('viem/chains');
require('dotenv').config({ path: require('path').join(__dirname, '../env/.env') });

const SUPER_PAYMASTER = '0xD6aa17587737C59cbb82986Afbac88Db75771857';

const publicClient = createPublicClient({
  chain: sepolia,
  transport: http(process.env.SEPOLIA_RPC_URL)
});

async function check() {
  console.log('检查SuperPaymaster的aPNTs token配置...\n');

  const aPNTsToken = await publicClient.readContract({
    address: SUPER_PAYMASTER,
    abi: [{
      type: 'function',
      name: 'aPNTsToken',
      outputs: [{type: 'address'}],
      stateMutability: 'view'
    }],
    functionName: 'aPNTsToken'
  });

  const aPNTsPriceUSD = await publicClient.readContract({
    address: SUPER_PAYMASTER,
    abi: [{
      type: 'function',
      name: 'aPNTsPriceUSD',
      outputs: [{type: 'uint256'}],
      stateMutability: 'view'
    }],
    functionName: 'aPNTsPriceUSD'
  });

  console.log('aPNTs Token:', aPNTsToken);
  console.log('aPNTs Price USD:', Number(aPNTsPriceUSD) / 1e18, 'USD');
  console.log();

  if (aPNTsToken === '0x0000000000000000000000000000000000000000') {
    console.log('❌ aPNTs token未配置！');
    console.log('   这是之前测试中提到的aPNTs token：0xBD07a1B6BAEE635Ea7Bd655d6896b5aD03Ac6DE6');
    console.log('   需要owner调用setAPNTsToken()函数设置。');
  } else {
    console.log('✅ aPNTs token已配置');
    console.log('\nOperator需要：');
    console.log('1. 持有足够的aPNTs token（约6000 aPNTs）');
    console.log('2. 授权SuperPaymaster使用aPNTs token');
    console.log('3. 调用depositAPNTs(6000e18)存入');
  }
}

check().catch(console.error);

const { createPublicClient, http, formatEther } = require('viem');
const { sepolia } = require('viem/chains');
require('dotenv').config({ path: require('path').join(__dirname, '../env/.env') });

const SUPER_PAYMASTER = '0xD6aa17587737C59cbb82986Afbac88Db75771857';
const OPERATOR = '0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C';

const publicClient = createPublicClient({
  chain: sepolia,
  transport: http(process.env.SEPOLIA_RPC_URL)
});

async function check() {
  console.log('检查operator的aPNTs余额...\n');

  try {
    // Read operator account using getOperatorInfo
    const account = await publicClient.readContract({
      address: SUPER_PAYMASTER,
      abi: [{
        type: 'function',
        name: 'getOperatorInfo',
        inputs: [{type: 'address'}],
        outputs: [{
          type: 'tuple',
          components: [
            {name: 'stGTokenStaked', type: 'uint256'},
            {name: 'stakedAt', type: 'uint256'},
            {name: 'lastUpdated', type: 'uint256'},
            {name: 'totalSpent', type: 'uint256'},
            {name: 'totalTxSponsored', type: 'uint256'},
            {name: 'aPNTsBalance', type: 'uint256'},
            {name: 'reputation', type: 'uint256'},
            {name: 'isPaused', type: 'bool'}
          ]
        }],
        stateMutability: 'view'
      }],
      functionName: 'getOperatorInfo',
      args: [OPERATOR]
    });

    console.log('Operator:', OPERATOR);
    console.log('aPNTs Balance:', formatEther(account.aPNTsBalance), 'aPNTs');
    console.log('Total Spent:', formatEther(account.totalSpent), 'aPNTs');
    console.log('Total TX Sponsored:', account.totalTxSponsored.toString());
    console.log('Reputation:', account.reputation.toString());
    console.log('Is Paused:', account.isPaused);
    console.log();

    if (account.aPNTsBalance === 0n) {
      console.log('❌ Operator的aPNTs余额为0！');
      console.log('   这就是gasless交易失败的根本原因。');
      console.log('   Operator需要convertToAPNTs来获得aPNTs余额。\n');
      console.log('解决方法：');
      console.log('   1. 找到xPNTsFactory合约地址');
      console.log('   2. 调用settle()函数，将待结算的xPNTs转换为aPNTs');
      console.log('   3. 或者等待自动结算流程');
    } else {
      console.log('✅ Operator有aPNTs余额');
    }
  } catch (error) {
    console.error('Error:', error.message);
  }
}

check().catch(console.error);

const { createPublicClient, http, formatEther } = require('viem');
const { sepolia } = require('viem/chains');
require('dotenv').config({ path: require('path').join(__dirname, '../env/.env') });

const ENTRYPOINT = '0x0000000071727De22E5E9d8BAf0edAc6f37da032';
const SUPER_PAYMASTER = '0xD6aa17587737C59cbb82986Afbac88Db75771857';

const publicClient = createPublicClient({
  chain: sepolia,
  transport: http(process.env.SEPOLIA_RPC_URL)
});

async function check() {
  console.log('检查SuperPaymaster在EntryPoint的存款...\n');

  const balance = await publicClient.readContract({
    address: ENTRYPOINT,
    abi: [{
      type: 'function',
      name: 'balanceOf',
      inputs: [{type: 'address'}],
      outputs: [{type: 'uint256'}],
      stateMutability: 'view'
    }],
    functionName: 'balanceOf',
    args: [SUPER_PAYMASTER]
  });

  console.log('SuperPaymaster:', SUPER_PAYMASTER);
  console.log('EntryPoint deposit:', formatEther(balance), 'ETH\n');

  if (balance === 0n) {
    console.log('❌ SuperPaymaster没有在EntryPoint存款！');
    console.log('   这是paymaster验证失败的根本原因。');
    console.log('   Paymaster需要有足够的ETH存款来支付gas费用。\n');
    console.log('解决方法：');
    console.log('   cast send ' + ENTRYPOINT);
    console.log('   "depositTo(address)" ' + SUPER_PAYMASTER);
    console.log('   --value 0.1ether');
    console.log('   --rpc-url $SEPOLIA_RPC_URL');
    console.log('   --private-key $DEPLOYER_PRIVATE_KEY');
  } else {
    console.log('✅ SuperPaymaster有足够的存款');
  }
}

check().catch(console.error);

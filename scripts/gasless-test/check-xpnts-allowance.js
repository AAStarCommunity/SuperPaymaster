const { createPublicClient, http } = require('viem');
const { sepolia } = require('viem/chains');
require('dotenv').config({ path: require('path').join(__dirname, '../env/.env') });

const SUPER_PAYMASTER = '0xD6aa17587737C59cbb82986Afbac88Db75771857';
const AA_ACCOUNT = '0x57b2e6f08399c276b2c1595825219d29990d0921';
const XPNTS1_TOKEN = '0xfb56CB85C9a214328789D3C92a496d6AA185e3d3';

const publicClient = createPublicClient({
  chain: sepolia,
  transport: http(process.env.SEPOLIA_RPC_URL)
});

async function estimate() {
  console.log('检查xPNTs余额和授权...\n');

  // Check xPNTs balance and allowance
  const balance = await publicClient.readContract({
    address: XPNTS1_TOKEN,
    abi: [{type: 'function', name: 'balanceOf', inputs: [{type: 'address'}], outputs: [{type: 'uint256'}], stateMutability: 'view'}],
    functionName: 'balanceOf',
    args: [AA_ACCOUNT]
  });

  const allowance = await publicClient.readContract({
    address: XPNTS1_TOKEN,
    abi: [{type: 'function', name: 'allowance', inputs: [{type: 'address'}, {type: 'address'}], outputs: [{type: 'uint256'}], stateMutability: 'view'}],
    functionName: 'allowance',
    args: [AA_ACCOUNT, SUPER_PAYMASTER]
  });

  console.log('AA Account xPNTs balance:', Number(balance) / 1e18);
  console.log('Allowance to SuperPaymaster:', Number(allowance) / 1e18, '\n');

  if (allowance === 0n) {
    console.log('❌ Need to approve SuperPaymaster to spend xPNTs!');
    console.log('   This is required for validatePaymasterUserOp to work.');
    console.log('   The paymaster needs to transferFrom xPNTs from AA account to treasury.');
  } else {
    console.log('✅ Allowance is sufficient');
  }
}

estimate().catch(console.error);

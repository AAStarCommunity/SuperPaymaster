const { createPublicClient, http } = require('viem');
const { sepolia } = require('viem/chains');

const txHash = process.argv[2] || '0x5cf33adaa293aacadc76e9e627268c6ecaced411fdee88e06f89c63262a37ce8';

const publicClient = createPublicClient({
  chain: sepolia,
  transport: http('https://rpc2.sepolia.org')
});

async function check() {
  console.log('Checking transaction:', txHash, '\n');

  try {
    const receipt = await publicClient.waitForTransactionReceipt({
      hash: txHash,
      timeout: 30000
    });

    console.log('Status:', receipt.status);
    console.log('Gas used:', receipt.gasUsed.toString());
    console.log('Block:', receipt.blockNumber.toString());
    console.log('Logs:', receipt.logs.length);
    console.log('\nEtherscan:', `https://sepolia.etherscan.io/tx/${txHash}`);

  } catch (error) {
    console.error('Error:', error.message);
  }
}

check();

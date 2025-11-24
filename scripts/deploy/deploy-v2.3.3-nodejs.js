const { createPublicClient, createWalletClient, http } = require('viem');
const { sepolia } = require('viem/chains');
const { privateKeyToAccount } = require('viem/accounts');
const fs = require('fs');
const path = require('path');
require('dotenv').config();

async function main() {
  console.log('================================');
  console.log('Deploy SuperPaymaster V2.3.3 (Node.js)');
  console.log('================================\n');

  // Clean private key - remove any quotes, spaces, 0x prefix
  const cleanPrivateKey = process.env.PRIVATE_KEY.trim().replace(/^["']|["']$/g, '').replace(/^0x/, '');
  const account = privateKeyToAccount(`0x${cleanPrivateKey}`);

  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(process.env.SEPOLIA_RPC_URL),
  });

  const walletClient = createWalletClient({
    account,
    chain: sepolia,
    transport: http(process.env.SEPOLIA_RPC_URL),
  });

  console.log(`Deployer: ${account.address}\n`);

  // Read compiled contract
  const artifactPath = path.join(__dirname, '../../out/SuperPaymasterV2_3_3.sol/SuperPaymasterV2_3_3.json');

  if (!fs.existsSync(artifactPath)) {
    console.error('Error: Contract artifact not found. Run forge build first.');
    process.exit(1);
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));

  // Constructor args
  const ENTRY_POINT = '0x0000000071727De22E5E9d8BAf0edAc6f37da032';
  const GTOKEN = '0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc';
  const GTOKEN_STAKING = '0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0';
  const REGISTRY = '0x49245E1f3c2dD99b3884ffeD410d0605Cf4dC696';
  const CHAINLINK = '0x694AA1769357215DE4FAC081bf1f309aDC325306';
  const DEFAULT_SBT = '0xa4eda5d023ea94a60b1d4b5695f022e1972858e7'; // MySBT v2.4.5

  console.log('Step 1: Deploying SuperPaymasterV2_3_3...');

  const { abi } = artifact;
  const constructorAbi = abi.find(item => item.type === 'constructor');

  // Encode constructor args
  const { encodeAbiParameters } = require('viem');
  const encodedArgs = encodeAbiParameters(
    constructorAbi.inputs,
    [ENTRY_POINT, GTOKEN, GTOKEN_STAKING, REGISTRY, CHAINLINK, DEFAULT_SBT]
  );

  // Ensure bytecode doesn't have 0x prefix before combining
  const cleanBytecode = artifact.bytecode.object.replace(/^0x/, '');
  const bytecode = `0x${cleanBytecode}${encodedArgs.slice(2)}`;

  const hash = await walletClient.deployContract({
    abi,
    bytecode,
    args: [],
    gasPrice: 1000000n, // 0.001 gwei for legacy tx
  });

  console.log(`Transaction hash: ${hash}`);
  console.log('Waiting for confirmation...');

  const receipt = await publicClient.waitForTransactionReceipt({ hash });

  if (receipt.status === 'success') {
    console.log(`✅ SuperPaymasterV2_3_3 deployed to: ${receipt.contractAddress}\n`);

    // Save address
    fs.writeFileSync(
      '/tmp/v233_address.txt',
      `SuperPaymasterV2_3_3=${receipt.contractAddress}\n`,
      'utf8'
    );

    console.log('================================');
    console.log('Deployment Complete!');
    console.log('================================');
    console.log(`\nSuperPaymasterV2_3_3: ${receipt.contractAddress}`);
    console.log(`\nEtherscan: https://sepolia.etherscan.io/address/${receipt.contractAddress}`);
  } else {
    console.error('❌ Deployment failed');
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

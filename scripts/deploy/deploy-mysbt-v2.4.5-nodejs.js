import { createWalletClient, createPublicClient, http, parseEther, encodeAbiParameters } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { sepolia } from 'viem/chains';
import { readFileSync, writeFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, resolve } from 'path';
import dotenv from 'dotenv';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// Load environment variables
dotenv.config({ path: resolve(__dirname, '../../env/.env') });

// Contract addresses on Sepolia
const GTOKEN = '0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc';
const GTOKEN_STAKING = '0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0';
const REGISTRY = '0x49245E1f3c2dD99b3884ffeD410d0605Cf4dC696';
// Note: Using deployer as DAO for easier configuration. Can transfer later via setDAOMultisig
const DAO = null; // Will be set to deployer address

async function main() {
    console.log('=== MySBT v2.4.5 Deployment ===\n');

    // Setup account
    const cleanPrivateKey = process.env.PRIVATE_KEY.trim()
        .replace(/^["']|["']$/g, '')
        .replace(/^0x/, '');

    const account = privateKeyToAccount(`0x${cleanPrivateKey}`);
    console.log('Deployer address:', account.address);

    // Use deployer as DAO for easier initial configuration
    const DAO_ADDRESS = account.address;

    // Setup clients
    const publicClient = createPublicClient({
        chain: sepolia,
        transport: http(process.env.SEPOLIA_RPC_URL)
    });

    const walletClient = createWalletClient({
        account,
        chain: sepolia,
        transport: http(process.env.SEPOLIA_RPC_URL)
    });

    // Check balance
    const balance = await publicClient.getBalance({ address: account.address });
    console.log('Deployer balance:', balance.toString(), 'wei\n');

    if (balance < parseEther('0.1')) {
        console.error('❌ Insufficient balance for deployment');
        process.exit(1);
    }

    // Load contract artifacts
    console.log('Loading MySBT_v2_4_5 artifacts...');
    const artifactPath = resolve(__dirname, '../../out/MySBT_v2_4_5.sol/MySBT_v2_4_5.json');
    const artifact = JSON.parse(readFileSync(artifactPath, 'utf8'));

    console.log('ABI loaded:', artifact.abi.length, 'functions');
    console.log('Bytecode size:', artifact.bytecode.object.length / 2 - 1, 'bytes\n');

    console.log('Constructor arguments:');
    console.log('  GTOKEN:', GTOKEN);
    console.log('  GTOKEN_STAKING:', GTOKEN_STAKING);
    console.log('  REGISTRY:', REGISTRY);
    console.log('  DAO:', DAO_ADDRESS);
    console.log();

    // Encode constructor arguments
    const { abi } = artifact;
    const constructorAbi = abi.find(item => item.type === 'constructor');

    const encodedArgs = encodeAbiParameters(
        constructorAbi.inputs,
        [GTOKEN, GTOKEN_STAKING, REGISTRY, DAO_ADDRESS]
    );

    // Deploy contract
    console.log('Deploying MySBT_v2_4_5...');

    const cleanBytecode = artifact.bytecode.object.replace(/^0x/, '');
    const bytecode = `0x${cleanBytecode}${encodedArgs.slice(2)}`;

    try {
        const hash = await walletClient.deployContract({
            abi: artifact.abi,
            bytecode: bytecode,
            args: [],
            gasPrice: 1000000n, // 0.001 gwei (legacy transaction)
        });

        console.log('Transaction hash:', hash);
        console.log('Waiting for confirmation...\n');

        const receipt = await publicClient.waitForTransactionReceipt({
            hash,
            confirmations: 2
        });

        if (receipt.status === 'success') {
            console.log('✅ MySBT_v2_4_5 deployed successfully!');
            console.log('Contract address:', receipt.contractAddress);
            console.log('Block number:', receipt.blockNumber.toString());
            console.log('Gas used:', receipt.gasUsed.toString());
            console.log();

            // Save deployment info
            const deploymentInfo = {
                contract: 'MySBT_v2_4_5',
                version: '2.4.5-optimized',
                address: receipt.contractAddress,
                deployer: account.address,
                txHash: hash,
                blockNumber: receipt.blockNumber.toString(),
                gasUsed: receipt.gasUsed.toString(),
                timestamp: new Date().toISOString(),
                network: 'sepolia',
                constructorArgs: {
                    GTOKEN,
                    GTOKEN_STAKING,
                    REGISTRY,
                    DAO: DAO_ADDRESS
                }
            };

            const deploymentPath = resolve(__dirname, '../../deployment-mysbt-v2.4.5.json');
            writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));
            console.log('Deployment info saved to:', deploymentPath);

            // Next steps
            console.log('\n=== Next Steps ===');
            console.log('1. Verify contract on Etherscan:');
            console.log(`   forge verify-contract ${receipt.contractAddress} contracts/src/paymasters/v2/tokens/MySBT_v2_4_5.sol:MySBT_v2_4_5 --chain sepolia --constructor-args $(cast abi-encode "constructor(address,address,address,address)" ${GTOKEN} ${GTOKEN_STAKING} ${REGISTRY} ${DAO_ADDRESS})`);
            console.log();
            console.log('2. Configure SuperPaymaster integration:');
            console.log(`   cast send ${receipt.contractAddress} "setSuperPaymaster(address)" 0xc7ac591476ccafe064f1e74cdbd1f70abad0ad9c --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY`);
            console.log();
            console.log('3. Register operator for testing');
            console.log('4. Test gasless transactions');
            console.log('5. Update shared-config repository with new ABI and address');

        } else {
            console.error('❌ Deployment failed');
            console.error('Receipt:', receipt);
            process.exit(1);
        }

    } catch (error) {
        console.error('❌ Deployment error:', error.message);
        if (error.cause) {
            console.error('Cause:', error.cause);
        }
        process.exit(1);
    }
}

main().catch(console.error);

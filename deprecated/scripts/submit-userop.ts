/**
 * SuperPaymaster V3 - Submit UserOperation via Alchemy Bundler
 * 参考: https://www.alchemy.com/docs/wallets/low-level-infra/quickstart
 */

import { ethers } from 'ethers';
import axios from 'axios';

// 环境变量配置
const config = {
    // RPC URLs
    rpcUrl: process.env.SEPOLIA_RPC_URL!,
    bundlerUrl: process.env.ALCHEMY_BUNDLER_URL ||
                `https://eth-sepolia.g.alchemy.com/v2/${process.env.SEPOLIA_RPC_URL!.split('/').pop()}`,

    // Contract addresses
    entryPoint: '0x0000000071727De22E5E9d8BAf0edAc6f37da032',
    paymaster: process.env.PAYMASTER_V3_ADDRESS!,
    settlement: process.env.SETTLEMENT_ADDRESS!,

    // User addresses
    sender: process.env.TEST_USER_ADDRESS!,  // User1 (has SBT and PNT)
    recipient: process.env.TEST_USER_ADDRESS2!,  // User2

    // Private key (User1)
    privateKey: process.env.TEST_USER_PRIVATE_KEY!,  // 需要用户提供
};

interface UserOperation {
    sender: string;
    nonce: string;
    factory: string;
    factoryData: string;
    callData: string;
    callGasLimit: string;
    verificationGasLimit: string;
    preVerificationGas: string;
    maxFeePerGas: string;
    maxPriorityFeePerGas: string;
    paymaster: string;
    paymasterVerificationGasLimit: string;
    paymasterPostOpGasLimit: string;
    paymasterData: string;
    signature: string;
}

/**
 * 获取账户的 nonce
 */
async function getNonce(provider: ethers.Provider, sender: string, entryPoint: string): Promise<string> {
    const entryPointContract = new ethers.Contract(
        entryPoint,
        ['function getNonce(address,uint192) view returns (uint256)'],
        provider
    );

    const nonce = await entryPointContract.getNonce(sender, 0);
    return '0x' + nonce.toString(16);
}

/**
 * 构造简单转账的 callData
 * 转 0.001 ETH 到 recipient
 */
function encodeTransferCallData(recipient: string, amount: string): string {
    // 假设使用 SimpleAccount
    // execute(address dest, uint256 value, bytes calldata func)
    const iface = new ethers.Interface([
        'function execute(address dest, uint256 value, bytes calldata func)'
    ]);

    return iface.encodeFunctionData('execute', [
        recipient,
        ethers.parseEther(amount),
        '0x'
    ]);
}

/**
 * 签名 UserOperation
 */
async function signUserOp(
    userOp: Partial<UserOperation>,
    entryPoint: string,
    chainId: number,
    wallet: ethers.Wallet
): Promise<string> {
    // 构造 UserOp hash
    const packedData = ethers.AbiCoder.defaultAbiCoder().encode(
        [
            'address', 'uint256', 'bytes32', 'bytes32',
            'uint256', 'uint256', 'uint256',
            'uint256', 'uint256',
            'bytes32'
        ],
        [
            userOp.sender,
            userOp.nonce,
            ethers.keccak256(userOp.factoryData || '0x'),
            ethers.keccak256(userOp.callData || '0x'),
            userOp.callGasLimit,
            userOp.verificationGasLimit,
            userOp.preVerificationGas,
            userOp.maxFeePerGas,
            userOp.maxPriorityFeePerGas,
            ethers.keccak256(
                ethers.AbiCoder.defaultAbiCoder().encode(
                    ['address', 'uint256', 'uint256', 'bytes32'],
                    [
                        userOp.paymaster,
                        userOp.paymasterVerificationGasLimit,
                        userOp.paymasterPostOpGasLimit,
                        ethers.keccak256(userOp.paymasterData || '0x')
                    ]
                )
            )
        ]
    );

    const userOpHash = ethers.keccak256(packedData);
    const message = ethers.getBytes(
        ethers.keccak256(
            ethers.AbiCoder.defaultAbiCoder().encode(
                ['bytes32', 'address', 'uint256'],
                [userOpHash, entryPoint, chainId]
            )
        )
    );

    return await wallet.signMessage(message);
}

/**
 * 通过 Bundler 提交 UserOperation
 */
async function submitUserOp(userOp: UserOperation): Promise<string> {
    console.log('\n📡 Submitting UserOperation to Bundler...\n');
    console.log('Bundler URL:', config.bundlerUrl);
    console.log('EntryPoint:', config.entryPoint);

    try {
        const response = await axios.post(config.bundlerUrl, {
            jsonrpc: '2.0',
            id: 1,
            method: 'eth_sendUserOperation',
            params: [userOp, config.entryPoint]
        }, {
            headers: {
                'Content-Type': 'application/json'
            }
        });

        if (response.data.error) {
            throw new Error(`Bundler error: ${JSON.stringify(response.data.error)}`);
        }

        const userOpHash = response.data.result;
        console.log('✅ UserOperation submitted!');
        console.log('UserOp Hash:', userOpHash);

        return userOpHash;
    } catch (error: any) {
        console.error('❌ Failed to submit UserOperation');
        console.error('Error:', error.response?.data || error.message);
        throw error;
    }
}

/**
 * 等待 UserOperation 执行
 */
async function waitForUserOp(userOpHash: string): Promise<any> {
    console.log('\n⏳ Waiting for UserOperation execution...\n');

    let attempts = 0;
    const maxAttempts = 30;

    while (attempts < maxAttempts) {
        try {
            const response = await axios.post(config.bundlerUrl, {
                jsonrpc: '2.0',
                id: 1,
                method: 'eth_getUserOperationReceipt',
                params: [userOpHash]
            });

            const receipt = response.data.result;
            if (receipt) {
                console.log('✅ UserOperation executed!');
                console.log('Transaction Hash:', receipt.receipt.transactionHash);
                console.log('Block Number:', receipt.receipt.blockNumber);
                console.log('Gas Used:', receipt.actualGasUsed);
                return receipt;
            }
        } catch (error) {
            // Continue waiting
        }

        await new Promise(resolve => setTimeout(resolve, 2000));
        attempts++;
        process.stdout.write('.');
    }

    throw new Error('Timeout waiting for UserOperation execution');
}

/**
 * 主函数
 */
async function main() {
    console.log('\n🚀 SuperPaymaster V3 - E2E Test');
    console.log('=====================================\n');

    // 验证配置
    if (!config.privateKey) {
        throw new Error('TEST_USER_PRIVATE_KEY not set! Please export TEST_USER_PRIVATE_KEY=0x...');
    }

    console.log('📋 Configuration:');
    console.log('  Sender (User1):', config.sender);
    console.log('  Recipient (User2):', config.recipient);
    console.log('  Paymaster:', config.paymaster);
    console.log('  Settlement:', config.settlement);
    console.log('  EntryPoint:', config.entryPoint);

    // 初始化 provider 和 wallet
    const provider = new ethers.JsonRpcProvider(config.rpcUrl);
    const wallet = new ethers.Wallet(config.privateKey, provider);
    const chainId = (await provider.getNetwork()).chainId;

    console.log('\n🔑 Wallet:', await wallet.getAddress());
    console.log('Chain ID:', chainId);

    // 获取 nonce
    console.log('\n📝 Fetching nonce...');
    const nonce = await getNonce(provider, config.sender, config.entryPoint);
    console.log('Nonce:', nonce);

    // 获取 gas price
    const feeData = await provider.getFeeData();
    const maxFeePerGas = '0x' + (feeData.maxFeePerGas! * 2n).toString(16);
    const maxPriorityFeePerGas = '0x' + (feeData.maxPriorityFeePerGas! * 2n).toString(16);

    console.log('Max Fee Per Gas:', maxFeePerGas);
    console.log('Max Priority Fee:', maxPriorityFeePerGas);

    // 构造 callData (转 0.001 ETH)
    const callData = encodeTransferCallData(config.recipient, '0.001');

    // 构造 UserOperation
    const userOp: Partial<UserOperation> = {
        sender: config.sender,
        nonce,
        factory: ethers.ZeroAddress,
        factoryData: '0x',
        callData,
        callGasLimit: '0x' + (100000).toString(16),
        verificationGasLimit: '0x' + (200000).toString(16),
        preVerificationGas: '0x' + (50000).toString(16),
        maxFeePerGas,
        maxPriorityFeePerGas,
        paymaster: config.paymaster,
        paymasterVerificationGasLimit: '0x' + (150000).toString(16),
        paymasterPostOpGasLimit: '0x' + (80000).toString(16),
        paymasterData: '0x'
    };

    // 签名
    console.log('\n✍️  Signing UserOperation...');
    const signature = await signUserOp(userOp, config.entryPoint, Number(chainId), wallet);
    userOp.signature = signature;

    console.log('\n📦 UserOperation:');
    console.log(JSON.stringify(userOp, null, 2));

    // 提交
    const userOpHash = await submitUserOp(userOp as UserOperation);

    // 等待执行
    const receipt = await waitForUserOp(userOpHash);

    console.log('\n✅ Test Complete!');
    console.log('\n📊 Next Steps:');
    console.log('1. Check pending balance: ./check-settlement.sh');
    console.log('2. Execute settlement: ./settle-fees.sh');

    return receipt;
}

// 执行
if (require.main === module) {
    main()
        .then(() => process.exit(0))
        .catch((error) => {
            console.error('\n❌ Error:', error.message);
            process.exit(1);
        });
}

export { main };

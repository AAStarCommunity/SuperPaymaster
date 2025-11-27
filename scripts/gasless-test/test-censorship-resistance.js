#!/usr/bin/env node
/**
 * Censorship Resistance Simulation Test
 * 
 * Scenario:
 * 1. User constructs a valid UserOp with a valid Gas Card (MySBT).
 * 2. User attempts to send UserOp via "Relayer A" (Hostile).
 * 3. Relayer A checks a local blacklist, finds the user, and rejects the request (403 Forbidden).
 * 4. User client catches the error and automatically switches to "Relayer B" (Honest).
 * 5. Relayer B submits the UserOp to the EntryPoint.
 * 6. Transaction is successfully mined on-chain.
 * 
 * Objective: Demonstrate that off-chain censorship cannot stop on-chain asset verification.
 */

const { createPublicClient, createWalletClient, http, parseUnits, encodeFunctionData, concat, pad } = require('viem');
const { sepolia } = require('viem/chains');
const { generatePrivateKey, privateKeyToAccount } = require('viem/accounts');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../../.env') }); // Try root .env first
require('dotenv').config({ path: path.join(__dirname, '../../env/.env') }); // Try env/.env

// Mock Mode Flag
const MOCK_MODE = !process.env.OWNER2_PRIVATE_KEY;

if (MOCK_MODE) {
    console.log("⚠️  WARNING: OWNER2_PRIVATE_KEY not found. Running in MOCK MODE.");
    console.log("   (Transactions will be simulated, not sent to chain)");
}

// Configuration
const SUPER_PAYMASTER = '0x7c3c355d9aa4723402bec2a35b61137b8a10d5db';
const XPNTS1_TOKEN = '0xBD0710596010a157B88cd141d797E8Ad4bb2306b'; // aPNTs
const ENTRYPOINT = '0x0000000071727De22E5E9d8BAf0edAc6f37da032';
const OPERATOR = '0x411BD567E46C0781248dbB6a9211891C032885e5';
const AA_ACCOUNT = '0x57b2e6f08399c276b2c1595825219d29990d0921';
const RECIPIENT = '0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA';

// Mock Relayer Class
class MockRelayer {
    constructor(name, isHostile = false) {
        this.name = name;
        this.isHostile = isHostile;
        this.blacklist = new Set();
    }

    addToBlacklist(address) {
        this.blacklist.add(address.toLowerCase());
    }

    async sendUserOp(userOp, client) {
        console.log(`\n[${this.name}] Receiving UserOp from ${userOp.sender}...`);
        
        // Simulate processing delay
        await new Promise(r => setTimeout(r, 500));

        if (this.isHostile && this.blacklist.has(userOp.sender.toLowerCase())) {
            console.log(`[${this.name}] ❌ REJECTED: Sender is blacklisted (Simulated Censorship)`);
            throw new Error(`[${this.name}] 403 Forbidden: Sender blacklisted`);
        }

        console.log(`[${this.name}] ✅ ACCEPTED: Forwarding to EntryPoint...`);
        return this.submitToChain(userOp, client);
    }

    async submitToChain(userOp, client) {
        if (MOCK_MODE) {
            console.log(`[${this.name}] 🔗 (Mock) Submitting to chain...`);
            await new Promise(r => setTimeout(r, 1000)); // Simulate mining
            return "0x" + "a".repeat(64); // Mock Hash
        }

        // In a real scenario, this would be a bundler call. 
        // Here we use the wallet client to call handleOps directly for simulation.
        try {
            const hash = await client.writeContract({
                address: ENTRYPOINT,
                abi: [{
                    type: 'function',
                    name: 'handleOps',
                    inputs: [{
                        type: 'tuple[]',
                        components: [
                            {name: 'sender', type: 'address'},
                            {name: 'nonce', type: 'uint256'},
                            {name: 'initCode', type: 'bytes'},
                            {name: 'callData', type: 'bytes'},
                            {name: 'accountGasLimits', type: 'bytes32'},
                            {name: 'preVerificationGas', type: 'uint256'},
                            {name: 'gasFees', type: 'bytes32'},
                            {name: 'paymasterAndData', type: 'bytes'},
                            {name: 'signature', type: 'bytes'}
                        ]
                    }, {name: 'beneficiary', type: 'address'}],
                    outputs: [],
                    stateMutability: 'nonpayable'
                }],
                functionName: 'handleOps',
                args: [[userOp], process.env.OWNER2_ADDRESS || '0x0000000000000000000000000000000000000000'], // Using OWNER2 as beneficiary
                gas: 2000000n
            });
            return hash;
        } catch (error) {
            throw new Error(`Chain submission failed: ${error.message}`);
        }
    }
}

async function main() {
    console.log('╔═══════════════════════════════════════════════════════════════════════╗');
    console.log('║  🛡️  Censorship Resistance Simulation Experiment                    ║');
    console.log('╚═══════════════════════════════════════════════════════════════════════╝\n');

    // Setup Client
    let account;
    if (MOCK_MODE) {
        const privateKey = generatePrivateKey();
        account = privateKeyToAccount(privateKey);
    } else {
        const privateKey = process.env.OWNER2_PRIVATE_KEY.startsWith('0x') ? process.env.OWNER2_PRIVATE_KEY : `0x${process.env.OWNER2_PRIVATE_KEY}`;
        account = privateKeyToAccount(privateKey);
    }
    
    const publicClient = createPublicClient({ chain: sepolia, transport: http(process.env.SEPOLIA_RPC_URL || 'https://rpc.sepolia.org') });
    const walletClient = createWalletClient({ account, chain: sepolia, transport: http(process.env.SEPOLIA_RPC_URL || 'https://rpc.sepolia.org') });

    // Setup Relayers
    const relayerA = new MockRelayer("Relayer A (Hostile)", true);
    const relayerB = new MockRelayer("Relayer B (Honest)", false);

    // Configure Censorship
    console.log('🔧 Configuration:');
    console.log(`  Target User: ${AA_ACCOUNT}`);
    console.log(`  Relayer A: Hostile (Blacklisting User)`);
    console.log(`  Relayer B: Honest (Permissionless)`);
    
    relayerA.addToBlacklist(AA_ACCOUNT);
    console.log('  ✅ User added to Relayer A blacklist\n');

    // Prepare UserOp (Simplified for simulation - reusing V2.3.3 logic)
    console.log('📝 Preparing UserOperation...');
    
    // 1. Get Nonce (Mock if needed)
    let nonce = 0n;
    if (!MOCK_MODE) {
        nonce = await publicClient.readContract({
            address: AA_ACCOUNT,
            abi: [{ type: 'function', name: 'getNonce', outputs: [{type: 'uint256'}], stateMutability: 'view' }],
            functionName: 'getNonce'
        });
    }

    // 2. Build CallData (Transfer 0.1 xPNTs)
    const transferCalldata = encodeFunctionData({
        abi: [{ type: 'function', name: 'transfer', inputs: [{type: 'address', name: 'to'}, {type: 'uint256', name: 'amount'}] }],
        functionName: 'transfer',
        args: [RECIPIENT, parseUnits('0.1', 18)]
    });
    const executeData = encodeFunctionData({
        abi: [{ type: 'function', name: 'execute', inputs: [{type: 'address'}, {type: 'uint256'}, {type: 'bytes'}] }],
        functionName: 'execute',
        args: [XPNTS1_TOKEN, 0n, transferCalldata]
    });

    // 3. Build PaymasterData
    const paymasterAndData = concat([
        SUPER_PAYMASTER,
        pad(`0x${(250000).toString(16)}`, { dir: 'left', size: 16 }),
        pad(`0x${(50000).toString(16)}`, { dir: 'left', size: 16 }),
        OPERATOR
    ]);

    // 4. Assemble UserOp
    const userOp = {
        sender: AA_ACCOUNT,
        nonce,
        initCode: '0x',
        callData: executeData,
        accountGasLimits: concat([pad(`0x${(90000).toString(16)}`, { dir: 'left', size: 16 }), pad(`0x${(80000).toString(16)}`, { dir: 'left', size: 16 })]),
        preVerificationGas: 21000n,
        gasFees: concat([pad(`0x${(2000000000).toString(16)}`, { dir: 'left', size: 16 }), pad(`0x${(2000000000).toString(16)}`, { dir: 'left', size: 16 })]),
        paymasterAndData,
        signature: '0x' // Placeholder
    };

    // 5. Sign UserOp
    const userOpHash = await publicClient.readContract({
        address: ENTRYPOINT,
        abi: [{
             type: 'function', name: 'getUserOpHash', 
             inputs: [{ type: 'tuple', components: [
                 {name: 'sender', type: 'address'}, {name: 'nonce', type: 'uint256'}, {name: 'initCode', type: 'bytes'},
                 {name: 'callData', type: 'bytes'}, {name: 'accountGasLimits', type: 'bytes32'}, {name: 'preVerificationGas', type: 'uint256'},
                 {name: 'gasFees', type: 'bytes32'}, {name: 'paymasterAndData', type: 'bytes'}, {name: 'signature', type: 'bytes'}
             ]}], outputs: [{type: 'bytes32'}], stateMutability: 'view'
        }],
        functionName: 'getUserOpHash',
        args: [userOp]
    });
    userOp.signature = await account.signMessage({ message: { raw: userOpHash } });

    console.log('  ✅ UserOp Signed\n');

    // --- EXPERIMENT EXECUTION ---
    console.log('🚀 Starting Experiment Execution...\n');
    const startTime = Date.now();

    try {
        // Attempt 1: Relayer A
        console.log('👉 Attempt 1: Submitting to Relayer A...');
        await relayerA.sendUserOp(userOp, walletClient);
    } catch (error) {
        console.log(`  ⚠️  Caught Error: ${error.message}`);
        console.log('  🔄 Failover triggered: Switching to Relayer B...\n');

        try {
            // Attempt 2: Relayer B
            console.log('👉 Attempt 2: Submitting to Relayer B...');
            const txHash = await relayerB.sendUserOp(userOp, walletClient);
            
            const endTime = Date.now();
            const failoverTime = endTime - startTime;

            console.log(`\n✅ SUCCESS: Transaction submitted via Relayer B!`);
            console.log(`  TX Hash: ${txHash}`);
            console.log(`  Total Time (incl. failover): ${failoverTime}ms`);
            
            if (MOCK_MODE) {
                console.log('\n[MOCK] Skipping chain confirmation...');
                console.log(`  ✅ Transaction confirmed in block 12345678 (Mock)`);
                console.log('\n🏆 EXPERIMENT RESULT: PASSED');
                console.log('  Conclusion: Censorship by Relayer A was successfully bypassed.');
                return;
            }

            console.log('\nWaiting for confirmation...');
            const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
            
            if (receipt.status === 'success') {
                console.log(`  ✅ Transaction confirmed in block ${receipt.blockNumber}`);
                console.log('\n🏆 EXPERIMENT RESULT: PASSED');
                console.log('  Conclusion: Censorship by Relayer A was successfully bypassed.');
            } else {
                console.log('  ❌ Transaction failed on-chain');
            }

        } catch (retryError) {
            console.error('❌ Retry failed:', retryError);
        }
    }
}

main().catch(console.error);

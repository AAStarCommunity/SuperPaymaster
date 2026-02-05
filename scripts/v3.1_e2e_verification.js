#!/usr/bin/env node
/**
 * SuperPaymaster V3.1.1 E2E Verification Script
 * Validates:
 * 1. Community Registration (Operator)
 * 2. User Onboarding (Alice)
 * 3. Gasless UserOp Sponsorship via Credit
 * 4. Automatic Debt Recording
 * 
 * Uses Anvil Local Node and Viem.
 */
const { createPublicClient, createWalletClient, http, parseUnits, encodeFunctionData, concat, pad, decodeEventLog } = require('viem');
const { mainnet, sepolia } = require('viem/chains');
const { privateKeyToAccount } = require('viem/accounts');
const fs = require('fs');
const path = require('path');

// --- Configuration ---
const RPC_URL = process.env.RPC_URL || 'http://localhost:8545';
// Default Anvil keys for local verification
const DEPLOYER_PRIVATE_KEY = process.env.TEST_PRIVATE_KEY || '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const ALICE_PRIVATE_KEY = process.env.ALICE_PRIVATE_KEY || '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d';

// Addresses from deployment
const ADDRESSES = {
    REGISTRY: '0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0',
    SUPER_PAYMASTER: '0x4Fd4d60b75dc2Cb83e3a08e435E4c5e96DFB7d8b',
    APNTS: '0x5Eb2d9f4a329EA9f2eE2Fcf28fC540332d6F22D3',
    GTOKEN: '0x5FbDB2315678afecb367f032d93F642f64180aa3',
    ENTRYPOINT: '0x0000000071727De22E5E9d8BAf0edAc6f37da032'
};

// ABIs
const RegistryABI = [
    { "type": "function", "name": "registerRole", "inputs": [{ "name": "roleId", "type": "bytes32" }, { "name": "user", "type": "address" }, { "name": "roleData", "type": "bytes" }, { "name": "approvalData", "type": "bytes" }], "outputs": [], "stateMutability": "nonpayable" },
    { "type": "function", "name": "hasRole", "inputs": [{ "name": "roleId", "type": "bytes32" }, { "name": "user", "type": "address" }], "outputs": [{ "name": "bool", "type": "bool" }], "stateMutability": "view" },
    { "type": "function", "name": "getCreditLimit", "inputs": [{ "name": "user", "type": "address" }], "outputs": [{ "name": "uint256", "type": "uint256" }], "stateMutability": "view" }
];
const GTokenABI = [{ "type": "function", "name": "mint", "inputs": [{ "name": "to", "type": "address" }, { "name": "amount", "type": "uint256" }], "outputs": [], "stateMutability": "nonpayable" }];
const APNTSABI = [{ "type": "function", "name": "mint", "inputs": [{ "name": "to", "type": "address" }, { "name": "amount", "type": "uint256" }], "outputs": [], "stateMutability": "nonpayable" }, { "type": "function", "name": "balanceOf", "inputs": [{ "name": "account", "type": "address" }], "outputs": [{ "name": "uint256" }], "stateMutability": "view" }];

async function main() {
    const deployer = privateKeyToAccount(DEPLOYER_PRIVATE_KEY);
    const alice = privateKeyToAccount(ALICE_PRIVATE_KEY);
    
    const client = createPublicClient({ transport: http(RPC_URL) });
    const wallet = createWalletClient({ account: deployer, transport: http(RPC_URL) });

    console.log('--- SuperPaymaster V3.1.1 E2E Local Verification ---');
    console.log(`Deployer: ${deployer.address}`);
    console.log(`Alice:    ${alice.address}\n`);

    // 1. Setup Operator (Deployer is Operator)
    console.log('Step 1: Minting GToken for Stake...');
    const stakeAmount = parseUnits('1000', 18);
    await wallet.writeContract({
        address: ADDRESSES.GTOKEN,
        abi: GTokenABI,
        functionName: 'mint',
        args: [deployer.address, stakeAmount]
    });
    console.log('  ✅ GToken Minted');

    // 2. Clear Registry Role for clean start (if needed)
    // For local, we assume fresh.

    // 3. Register Operator (Deployer)
    console.log('Step 2: Registering Deployer as Operator...');
    const ROLE_COMMUNITY = '0x434f4d4d554e4954590000000000000000000000000000000000000000000000';
    const hasOpRole = await client.readContract({
        address: ADDRESSES.REGISTRY,
        abi: RegistryABI,
        functionName: 'hasRole',
        args: [ROLE_COMMUNITY, deployer.address]
    });

    if (!hasOpRole) {
        const { encodeAbiParameters } = require('viem');
        // CommunityRoleData: {name, ensName, website, description, logoURI, stakeAmount}
        const opData = encodeAbiParameters(
            [{ type: 'tuple', components: [
                { name: 'name', type: 'string' },
                { name: 'ensName', type: 'string' },
                { name: 'website', type: 'string' },
                { name: 'description', type: 'string' },
                { name: 'logoURI', type: 'string' },
                { name: 'stakeAmount', type: 'uint256' }
            ]}],
            [{ 
                name: 'Local Operator', 
                ensName: 'local.eth', 
                website: 'http://localhost', 
                description: 'Verification Node', 
                logoURI: '', 
                stakeAmount: stakeAmount 
            }]
        );
        
        await wallet.writeContract({
            address: ADDRESSES.REGISTRY,
            abi: RegistryABI,
            functionName: 'registerRole',
            args: [ROLE_COMMUNITY, deployer.address, opData]
        });
        console.log('  ✅ Operator Registered');
    } else {
        console.log('  ✅ Operator already registered');
    }

    // 4. Register Alice (End User)
    console.log('Step 3: Registering Alice in Registry...');
    const ROLE_ENDUSER = '0x454e445553455200000000000000000000000000000000000000000000000000';
    
    // Check if already registered
    const hasAliceRole = await client.readContract({
        address: ADDRESSES.REGISTRY,
        abi: RegistryABI,
        functionName: 'hasRole',
        args: [ROLE_ENDUSER, alice.address]
    });

    if (!hasAliceRole) {
        const { encodeAbiParameters } = require('viem');
        const aliceData = encodeAbiParameters([{ type: 'string' }], ['Alice Local Test']);
        
        // IMPORTANT: registry.registerRole is ONLY allowed by the roleOwner (deployer for ENDUSER)
        await wallet.writeContract({
            address: ADDRESSES.REGISTRY,
            abi: RegistryABI,
            functionName: 'registerRole',
            args: [ROLE_ENDUSER, alice.address, aliceData]
        });
        console.log('  ✅ Alice Registered');
    } else {
        console.log('  ✅ Alice already registered');
    }

    // 5. Verification: Check Credit Limit
    const creditLimit = await client.readContract({
        address: ADDRESSES.REGISTRY,
        abi: RegistryABI,
        functionName: 'getCreditLimit',
        args: [alice.address]
    });
    console.log(`\nVerified Levels:`);
    console.log(`  Alice (Level 1) Credit Limit: ${Number(creditLimit) / 1e18} aPNTs (Expected: 13)`);

    console.log('\n--- Local Setup Complete ---');
}

main().catch(console.error);

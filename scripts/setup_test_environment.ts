import { createPublicClient, createWalletClient, http, parseEther, formatEther } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { sepolia } from 'viem/chains';
import dotenv from 'dotenv';
import fs from 'fs';

dotenv.config();

const SEPOLIA_RPC = process.env.SEPOLIA_RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY as `0x${string}`;

async function main() {
    console.log("Setting up Test Environment...");
    
    if (!PRIVATE_KEY) {
        throw new Error("PRIVATE_KEY not found in .env");
    }

    const account = privateKeyToAccount(PRIVATE_KEY);
    const client = createWalletClient({
        account,
        chain: sepolia,
        transport: http(SEPOLIA_RPC)
    });
    const publicClient = createPublicClient({
        chain: sepolia,
        transport: http(SEPOLIA_RPC)
    });

    console.log(`Using Account: ${account.address}`);
    
    const balance = await publicClient.getBalance({ address: account.address });
    console.log(`ETH Balance: ${formatEther(balance)} ETH`);

    if (balance < parseEther('0.01')) {
        console.warn("⚠️ Low Balance! Please fund account.");
    }

    // TODO: Add specific contract interactions (Mint GToken, etc.)
    // For now, this confirms connectivity and account readiness.
    // If contracts are deployed, we could interact.
    
    console.log("Test Environment Setup Complete (Basic Check).");
}

main().catch(console.error);

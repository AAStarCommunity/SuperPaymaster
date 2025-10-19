#!/usr/bin/env node

require("dotenv").config({ path: "./.env.v3" });
const { ethers } = require("ethers");

const GTOKEN_ADDRESS = "0x868F843723a98c6EECC4BF0aF3352C53d5004147";
const NEW_OWNER_ADDRESS = "0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA";
const RPC_URL = process.env.SEPOLIA_RPC_URL;
const CURRENT_OWNER_PK = process.env.OWNER_PRIVATE_KEY;

const GTOKEN_ABI = ["function transferOwnership(address newOwner) external"];

async function main() {
    if (!CURRENT_OWNER_PK || !RPC_URL) {
        throw new Error("Missing OWNER_PRIVATE_KEY or SEPOLIA_RPC_URL in .env.v3 file");
    }

    const provider = new ethers.JsonRpcProvider(RPC_URL);
    const currentOwnerWallet = new ethers.Wallet(CURRENT_OWNER_PK, provider);

    console.log(`Attempting to transfer ownership of GToken...`);
    console.log(`Contract: ${GTOKEN_ADDRESS}`);
    console.log(`Current Owner (Signer): ${currentOwnerWallet.address}`);
    console.log(`New Owner: ${NEW_OWNER_ADDRESS}`);
    console.log('---');

    const gtokenContract = new ethers.Contract(GTOKEN_ADDRESS, GTOKEN_ABI, currentOwnerWallet);

    console.log("Sending transaction...");
    const tx = await gtokenContract.transferOwnership(NEW_OWNER_ADDRESS);
    console.log(`Transaction sent! Hash: ${tx.hash}`);

    console.log("Waiting for confirmation...");
    const receipt = await tx.wait();
    console.log(`✅ Transaction confirmed in block: ${receipt.blockNumber}`);
    console.log(`Ownership of GToken has been transferred to ${NEW_OWNER_ADDRESS}.`);
}

main().catch((error) => {
    console.error("❌ Error:", error.message);
    process.exit(1);
});

#!/usr/bin/env node

require("dotenv").config({ path: "./.env.v3" });
const { ethers } = require("ethers");

const SBT_ADDRESS = "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f";
// Using the recipient address from your error log
const RECIPIENT_EOA = "0x92a30ef64b0b750220b2b3bafe4f3121263d45b3";
const RPC_URL = process.env.SEPOLIA_RPC_URL;
const OWNER_PK = process.env.OWNER_PRIVATE_KEY;

const SBT_ABI = ["function safeMint(address to) external"];

async function main() {
    if (!OWNER_PK || !RPC_URL) {
        throw new Error("Missing OWNER_PRIVATE_KEY or SEPOLIA_RPC_URL in .env.v3 file");
    }

    const provider = new ethers.JsonRpcProvider(RPC_URL);
    const ownerWallet = new ethers.Wallet(OWNER_PK, provider);

    console.log("--- Direct Mint Test ---");
    console.log(`Contract: ${SBT_ADDRESS}`);
    console.log(`Signer (Owner): ${ownerWallet.address}`);
    console.log(`Recipient (EOA): ${RECIPIENT_EOA}`);
    console.log("------------------------");

    const sbtContract = new ethers.Contract(SBT_ADDRESS, SBT_ABI, ownerWallet);

    try {
        console.log("Estimating gas for safeMint...");
        const gasEstimate = await sbtContract.safeMint.estimateGas(RECIPIENT_EOA);
        console.log(`Gas estimate successful: ${gasEstimate.toString()}`);

        console.log("Sending transaction...");
        const tx = await sbtContract.safeMint(RECIPIENT_EOA);
        console.log(`Transaction sent! Hash: ${tx.hash}`);

        console.log("Waiting for confirmation...");
        const receipt = await tx.wait();
        console.log(`✅ Transaction confirmed in block: ${receipt.blockNumber}`);
        console.log(`SBT successfully minted to ${RECIPIENT_EOA}.`);

    } catch (error) {
        console.error("❌ Direct mint test failed!");
        console.error("Full error object:");
        console.log(error); // Log the entire error object
    }
}

main();

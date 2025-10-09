// Vercel Serverless Function for Minting Mock USDT
// Mints 10 USDT to user addresses

const { ethers } = require("ethers");

// Mock USDT ABI
const USDT_ABI = [
  "function faucet(address to) external",
  "function balanceOf(address owner) external view returns (uint256)",
  "function decimals() external view returns (uint8)",
];

// Configuration
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;
const OWNER_PRIVATE_KEY = (
  process.env.SEPOLIA_PRIVATE_KEY_NEW ||
  process.env.SEPOLIA_PRIVATE_KEY ||
  ""
).trim();
const USDT_ADDRESS = process.env.USDT_CONTRACT_ADDRESS || "0x14EaC6C3D49AEDff3D59773A7d7bfb50182bCfDc";

// Rate limiting (simple in-memory cache for demo)
const rateLimitCache = new Map();
const RATE_LIMIT_WINDOW = 60 * 60 * 1000; // 1 hour
const MAX_REQUESTS_PER_WINDOW = 5; // 5 requests per hour per address

function checkRateLimit(address) {
  const key = `usdt-${address}`;
  const now = Date.now();

  if (!rateLimitCache.has(key)) {
    rateLimitCache.set(key, [now]);
    return true;
  }

  const timestamps = rateLimitCache
    .get(key)
    .filter((ts) => now - ts < RATE_LIMIT_WINDOW);

  if (timestamps.length >= MAX_REQUESTS_PER_WINDOW) {
    return false;
  }

  timestamps.push(now);
  rateLimitCache.set(key, timestamps);
  return true;
}

export default async function handler(req, res) {
  // CORS headers
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");

  // Handle OPTIONS request
  if (req.method === "OPTIONS") {
    return res.status(200).end();
  }

  // Only accept POST requests
  if (req.method !== "POST") {
    return res.status(405).json({ error: "Method not allowed" });
  }

  try {
    const { address } = req.body;

    // Validate input
    if (!address) {
      return res.status(400).json({ error: "Missing address parameter" });
    }

    if (!/^0x[a-fA-F0-9]{40}$/.test(address)) {
      return res.status(400).json({ error: "Invalid Ethereum address" });
    }

    // Check rate limit
    if (!checkRateLimit(address)) {
      return res.status(429).json({
        error: "Rate limit exceeded. Please try again later (max 5 requests per hour)",
      });
    }

    // Validate environment variables
    if (!SEPOLIA_RPC_URL || !OWNER_PRIVATE_KEY) {
      console.error("Missing environment variables");
      return res.status(500).json({ error: "Server configuration error" });
    }

    // Initialize provider and signer
    const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
    const signer = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

    // Mint Mock USDT (10 USDT with 6 decimals)
    const usdtContract = new ethers.Contract(USDT_ADDRESS, USDT_ABI, signer);
    const tx = await usdtContract.faucet(address);
    const receipt = await tx.wait();

    // Get balance after mint
    const balance = await usdtContract.balanceOf(address);
    const decimals = await usdtContract.decimals();
    const balanceFormatted = ethers.formatUnits(balance, decimals);

    // Return success response
    return res.status(200).json({
      success: true,
      txHash: receipt.hash,
      blockNumber: receipt.blockNumber,
      amount: "10 USDT",
      recipient: address,
      balance: balanceFormatted,
      network: "Sepolia",
    });
  } catch (error) {
    console.error("Mint USDT error:", error);

    // Handle specific errors
    let errorMessage = error.message;
    let statusCode = 500;

    if (errorMessage.includes("insufficient funds")) {
      errorMessage = "Faucet is out of funds. Please contact the administrator.";
    } else if (errorMessage.includes("nonce")) {
      errorMessage = "Transaction conflict. Please try again.";
    }

    return res.status(statusCode).json({
      success: false,
      error: errorMessage,
    });
  }
}

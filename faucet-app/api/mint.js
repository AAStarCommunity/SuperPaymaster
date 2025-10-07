// Vercel Serverless Function for Faucet Minting
// Mints SBT or PNT tokens to user addresses

const { ethers } = require("ethers");

// Contract ABIs
const SBT_ABI = [
  "function safeMint(address to) external",
  "function balanceOf(address owner) external view returns (uint256)",
];

const PNT_ABI = [
  "function mint(address to, uint256 amount) external",
  "function balanceOf(address owner) external view returns (uint256)",
];

// Configuration
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;
const OWNER_PRIVATE_KEY = (
  process.env.SEPOLIA_PRIVATE_KEY_NEW ||
  process.env.SEPOLIA_PRIVATE_KEY ||
  ""
).trim();
const SBT_ADDRESS =
  process.env.SBT_CONTRACT_ADDRESS ||
  "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f";
const PNT_ADDRESS =
  process.env.PNT_TOKEN_ADDRESS || "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180"; // GasTokenV2 (PNTv2)

// Mint amounts
const PNT_MINT_AMOUNT = ethers.parseUnits("100", 18); // 100 PNT

// Rate limiting (simple in-memory cache for demo)
const rateLimitCache = new Map();
const RATE_LIMIT_WINDOW = 60 * 60 * 1000; // 1 hour
const MAX_REQUESTS_PER_WINDOW = 2; // 2 requests per hour per address

function checkRateLimit(address, type) {
  const key = `${address}-${type}`;
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

async function mintSBT(address, provider, signer) {
  const sbtContract = new ethers.Contract(SBT_ADDRESS, SBT_ABI, signer);

  // Check if user already has SBT
  const balance = await sbtContract.balanceOf(address);
  if (balance > 0n) {
    throw new Error("Address already owns an SBT");
  }

  // Mint SBT (using safeMint which requires owner)
  const tx = await sbtContract.safeMint(address);
  const receipt = await tx.wait();

  return {
    txHash: receipt.hash,
    blockNumber: receipt.blockNumber,
    amount: "1 SBT",
  };
}

async function mintPNT(address, provider, signer) {
  const pntContract = new ethers.Contract(PNT_ADDRESS, PNT_ABI, signer);

  // Mint PNT
  const tx = await pntContract.mint(address, PNT_MINT_AMOUNT);
  const receipt = await tx.wait();

  return {
    txHash: receipt.hash,
    blockNumber: receipt.blockNumber,
    amount: "100 PNT",
  };
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
    const { address, type } = req.body;

    // Validate input
    if (!address || !type) {
      return res
        .status(400)
        .json({ error: "Missing address or type parameter" });
    }

    if (!/^0x[a-fA-F0-9]{40}$/.test(address)) {
      return res.status(400).json({ error: "Invalid Ethereum address" });
    }

    if (!["sbt", "pnt"].includes(type)) {
      return res
        .status(400)
        .json({ error: 'Invalid type. Must be "sbt" or "pnt"' });
    }

    // Check rate limit
    if (!checkRateLimit(address, type)) {
      return res.status(429).json({
        error:
          "Rate limit exceeded. Please try again later (max 2 requests per hour)",
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

    // Mint token
    let result;
    if (type === "sbt") {
      result = await mintSBT(address, provider, signer);
    } else {
      result = await mintPNT(address, provider, signer);
    }

    // Return success response
    return res.status(200).json({
      success: true,
      txHash: result.txHash,
      blockNumber: result.blockNumber,
      amount: result.amount,
      recipient: address,
      type: type,
      network: "Sepolia",
    });
  } catch (error) {
    console.error("Mint error:", error);

    // Handle specific errors
    let errorMessage = error.message;
    let statusCode = 500;

    if (errorMessage.includes("already owns")) {
      statusCode = 400;
    } else if (errorMessage.includes("insufficient funds")) {
      errorMessage =
        "Faucet is out of funds. Please contact the administrator.";
    } else if (errorMessage.includes("nonce")) {
      errorMessage = "Transaction conflict. Please try again.";
    }

    return res.status(statusCode).json({
      success: false,
      error: errorMessage,
    });
  }
}

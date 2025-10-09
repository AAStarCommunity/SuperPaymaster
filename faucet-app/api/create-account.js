// Vercel Serverless Function for Creating SimpleAccount via Factory
// Creates a new SimpleAccount using SimpleAccountFactory

const { ethers } = require("ethers");

// SimpleAccountFactory ABI
const FACTORY_ABI = [
  "function createAccount(address owner, uint256 salt) external returns (address)",
  "function getAddress(address owner, uint256 salt) external view returns (address)",
];

// Configuration
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;
const OWNER_PRIVATE_KEY = (
  process.env.SEPOLIA_PRIVATE_KEY_NEW ||
  process.env.SEPOLIA_PRIVATE_KEY ||
  ""
).trim();
const FACTORY_ADDRESS =
  process.env.SIMPLE_ACCOUNT_FACTORY_ADDRESS ||
  "0x9bD66892144FCf0BAF5B6946AEAFf38B0d967881";

// Rate limiting (simple in-memory cache for demo)
const rateLimitCache = new Map();
const RATE_LIMIT_WINDOW = 60 * 60 * 1000; // 1 hour
const MAX_REQUESTS_PER_WINDOW = 3; // 3 requests per hour per owner

function checkRateLimit(owner) {
  const key = `account-${owner}`;
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
    const { owner, salt } = req.body;

    // Validate input
    if (!owner) {
      return res.status(400).json({ error: "Missing owner parameter" });
    }

    if (!/^0x[a-fA-F0-9]{40}$/.test(owner)) {
      return res
        .status(400)
        .json({ error: "Invalid Ethereum address for owner" });
    }

    // Use provided salt or random salt
    const accountSalt =
      salt !== undefined ? salt : Math.floor(Math.random() * 1000000);

    // Check rate limit
    if (!checkRateLimit(owner)) {
      return res.status(429).json({
        error:
          "Rate limit exceeded. Please try again later (max 3 requests per hour)",
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

    // Create SimpleAccount via Factory
    const factoryContract = new ethers.Contract(
      FACTORY_ADDRESS,
      FACTORY_ABI,
      signer,
    );

    // First, get the counterfactual address
    // NOTE: Cannot use factoryContract.getAddress() because it's a built-in ethers method
    // Use callStatic or direct interface call instead
    const accountAddress = await factoryContract["getAddress(address,uint256)"](
      owner,
      accountSalt,
    );

    // Check if account already exists
    const code = await provider.getCode(accountAddress);
    if (code !== "0x") {
      return res.status(200).json({
        success: true,
        accountAddress,
        owner,
        salt: accountSalt,
        alreadyDeployed: true,
        network: "Sepolia",
      });
    }

    // Create the account
    const tx = await factoryContract.createAccount(owner, accountSalt);
    const receipt = await tx.wait();

    // Return success response
    return res.status(200).json({
      success: true,
      txHash: receipt.hash,
      blockNumber: receipt.blockNumber,
      accountAddress,
      owner,
      salt: accountSalt,
      alreadyDeployed: false,
      network: "Sepolia",
    });
  } catch (error) {
    console.error("Create account error:", error);

    // Handle specific errors
    let errorMessage = error.message;
    let statusCode = 500;

    if (errorMessage.includes("insufficient funds")) {
      errorMessage =
        "Faucet is out of funds. Please contact the administrator.";
    } else if (errorMessage.includes("nonce")) {
      errorMessage = "Transaction conflict. Please try again.";
    } else if (errorMessage.includes("only callable from SenderCreator")) {
      errorMessage = "Factory can only be called through EntryPoint";
      statusCode = 400;
    }

    return res.status(statusCode).json({
      success: false,
      error: errorMessage,
    });
  }
}

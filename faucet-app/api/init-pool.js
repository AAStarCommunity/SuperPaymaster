// Vercel Serverless Function for Initializing PaymasterV4 Pool
// Deposits USDT and native ETH into PaymasterV4 to create liquidity pool

const { ethers } = require("ethers");

// Contract ABIs
const PAYMASTER_ABI = [
  "function deposit() external payable",
  "function addToken(address token, uint256 priceMarkup) external",
  "function getBalance() external view returns (uint256)",
];

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function balanceOf(address owner) external view returns (uint256)",
  "function transfer(address to, uint256 amount) external returns (bool)",
];

// Configuration
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;
const OWNER_PRIVATE_KEY = (
  process.env.SEPOLIA_PRIVATE_KEY_NEW ||
  process.env.SEPOLIA_PRIVATE_KEY ||
  ""
).trim();
const PAYMASTER_ADDRESS = process.env.PAYMASTER_V4_ADDRESS || "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
const USDT_ADDRESS = process.env.USDT_CONTRACT_ADDRESS || "0x14EaC6C3D49AEDff3D59773A7d7bfb50182bCfDc";

// Pool initialization amounts
const ETH_DEPOSIT_AMOUNT = ethers.parseEther("0.01"); // 0.01 ETH
const USDT_TRANSFER_AMOUNT = ethers.parseUnits("100", 6); // 100 USDT (6 decimals)
const PRICE_MARKUP = 11000; // 1.1x markup (10000 = 1.0x)

// Rate limiting (simple in-memory cache for demo)
const rateLimitCache = new Map();
const RATE_LIMIT_WINDOW = 24 * 60 * 60 * 1000; // 24 hours
const MAX_REQUESTS_PER_WINDOW = 1; // 1 request per day

function checkRateLimit() {
  const key = "init-pool-global";
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
    const { ethAmount, usdtAmount, priceMarkup } = req.body;

    // Use provided amounts or defaults
    const ethDeposit = ethAmount ? ethers.parseEther(ethAmount.toString()) : ETH_DEPOSIT_AMOUNT;
    const usdtTransfer = usdtAmount ? ethers.parseUnits(usdtAmount.toString(), 6) : USDT_TRANSFER_AMOUNT;
    const markup = priceMarkup !== undefined ? priceMarkup : PRICE_MARKUP;

    // Check rate limit (allow admins to bypass with special header)
    const adminKey = req.headers["x-admin-key"];
    const isAdmin = adminKey === process.env.ADMIN_KEY;

    if (!isAdmin && !checkRateLimit()) {
      return res.status(429).json({
        error: "Rate limit exceeded. Pool initialization is limited to once per 24 hours",
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

    const paymasterContract = new ethers.Contract(PAYMASTER_ADDRESS, PAYMASTER_ABI, signer);
    const usdtContract = new ethers.Contract(USDT_ADDRESS, ERC20_ABI, signer);

    // Check balances
    const ethBalance = await provider.getBalance(signer.address);
    const usdtBalance = await usdtContract.balanceOf(signer.address);

    if (ethBalance < ethDeposit) {
      return res.status(400).json({
        error: "Insufficient ETH balance",
        required: ethers.formatEther(ethDeposit),
        available: ethers.formatEther(ethBalance),
      });
    }

    if (usdtBalance < usdtTransfer) {
      return res.status(400).json({
        error: "Insufficient USDT balance",
        required: ethers.formatUnits(usdtTransfer, 6),
        available: ethers.formatUnits(usdtBalance, 6),
      });
    }

    const results = [];

    // Step 1: Deposit ETH to Paymaster
    const depositTx = await paymasterContract.deposit({ value: ethDeposit });
    const depositReceipt = await depositTx.wait();
    results.push({
      step: "deposit_eth",
      txHash: depositReceipt.hash,
      blockNumber: depositReceipt.blockNumber,
      amount: ethers.formatEther(ethDeposit) + " ETH",
    });

    // Step 2: Transfer USDT to Paymaster
    const transferTx = await usdtContract.transfer(PAYMASTER_ADDRESS, usdtTransfer);
    const transferReceipt = await transferTx.wait();
    results.push({
      step: "transfer_usdt",
      txHash: transferReceipt.hash,
      blockNumber: transferReceipt.blockNumber,
      amount: ethers.formatUnits(usdtTransfer, 6) + " USDT",
    });

    // Step 3: Add USDT as supported token (optional, may require owner)
    try {
      const addTokenTx = await paymasterContract.addToken(USDT_ADDRESS, markup);
      const addTokenReceipt = await addTokenTx.wait();
      results.push({
        step: "add_token",
        txHash: addTokenReceipt.hash,
        blockNumber: addTokenReceipt.blockNumber,
        token: USDT_ADDRESS,
        priceMarkup: markup,
      });
    } catch (error) {
      // If addToken fails (e.g., not owner), just log it
      results.push({
        step: "add_token",
        error: "Failed (may require owner): " + error.message,
      });
    }

    // Get final balances
    const paymasterBalance = await paymasterContract.getBalance();
    const paymasterUsdtBalance = await usdtContract.balanceOf(PAYMASTER_ADDRESS);

    // Return success response
    return res.status(200).json({
      success: true,
      results,
      finalBalances: {
        paymasterEth: ethers.formatEther(paymasterBalance),
        paymasterUsdt: ethers.formatUnits(paymasterUsdtBalance, 6),
      },
      network: "Sepolia",
    });
  } catch (error) {
    console.error("Init pool error:", error);

    // Handle specific errors
    let errorMessage = error.message;
    let statusCode = 500;

    if (errorMessage.includes("insufficient funds")) {
      errorMessage = "Insufficient funds for pool initialization";
    } else if (errorMessage.includes("nonce")) {
      errorMessage = "Transaction conflict. Please try again.";
    } else if (errorMessage.includes("Ownable")) {
      errorMessage = "Only owner can perform this operation";
      statusCode = 403;
    }

    return res.status(statusCode).json({
      success: false,
      error: errorMessage,
    });
  }
}

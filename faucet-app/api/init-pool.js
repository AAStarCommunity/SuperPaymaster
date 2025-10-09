// Vercel Serverless Function for Initializing Test Account Pool
// Generates 20 pre-configured test accounts with SBT + 100 PNT + 10 USDT each
// Outputs to test-accounts-pool.json

const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

// Contract ABIs
const FACTORY_ABI = [
  "function createAccount(address owner, uint256 salt) external returns (address)",
  "function getAddress(address owner, uint256 salt) external view returns (address)",
];

const SBT_ABI = [
  "function safeMint(address to) external",
  "function balanceOf(address owner) external view returns (uint256)",
];

const PNT_ABI = [
  "function mint(address to, uint256 amount) external",
  "function balanceOf(address owner) external view returns (uint256)",
];

const USDT_ABI = [
  "function faucet(address to) external",
  "function balanceOf(address owner) external view returns (uint256)",
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
const SBT_ADDRESS =
  process.env.SBT_CONTRACT_ADDRESS ||
  "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f";
const PNT_ADDRESS =
  process.env.PNT_TOKEN_ADDRESS || "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
const USDT_ADDRESS =
  process.env.USDT_CONTRACT_ADDRESS ||
  "0x14EaC6C3D49AEDff3D59773A7d7bfb50182bCfDc";

const PNT_MINT_AMOUNT = ethers.parseUnits("100", 18); // 100 PNT
const POOL_SIZE = 20;

// Generate deterministic test account
function generateTestAccount(index) {
  // Use deterministic seed for reproducible accounts
  const seed = ethers.id(`test-account-${index}`);
  const wallet = new ethers.Wallet(seed);
  return {
    index,
    address: wallet.address,
    privateKey: wallet.privateKey,
  };
}

async function createAccountForOwner(owner, salt, factoryContract, provider) {
  // Get counterfactual address
  const accountAddress = await factoryContract["getAddress(address,uint256)"](
    owner,
    salt,
  );

  // Check if already deployed
  const code = await provider.getCode(accountAddress);
  if (code !== "0x") {
    return { accountAddress, alreadyDeployed: true };
  }

  // Deploy account
  const tx = await factoryContract.createAccount(owner, salt);
  const receipt = await tx.wait();

  return {
    accountAddress,
    alreadyDeployed: false,
    txHash: receipt.hash,
  };
}

async function mintTokensToAccount(
  accountAddress,
  sbtContract,
  pntContract,
  usdtContract,
) {
  const results = {
    sbt: null,
    pnt: null,
    usdt: null,
  };

  try {
    // Mint SBT
    const sbtBalance = await sbtContract.balanceOf(accountAddress);
    if (sbtBalance === 0n) {
      const sbtTx = await sbtContract.safeMint(accountAddress);
      const sbtReceipt = await sbtTx.wait();
      results.sbt = { success: true, txHash: sbtReceipt.hash };
    } else {
      results.sbt = { success: true, alreadyMinted: true };
    }
  } catch (error) {
    results.sbt = { success: false, error: error.message };
  }

  try {
    // Mint PNT
    const pntTx = await pntContract.mint(accountAddress, PNT_MINT_AMOUNT);
    const pntReceipt = await pntTx.wait();
    results.pnt = { success: true, txHash: pntReceipt.hash };
  } catch (error) {
    results.pnt = { success: false, error: error.message };
  }

  try {
    // Mint USDT
    const usdtTx = await usdtContract.faucet(accountAddress);
    const usdtReceipt = await usdtTx.wait();
    results.usdt = { success: true, txHash: usdtReceipt.hash };
  } catch (error) {
    results.usdt = { success: false, error: error.message };
  }

  return results;
}

export default async function handler(req, res) {
  // CORS headers
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, GET, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");

  // Handle OPTIONS request
  if (req.method === "OPTIONS") {
    return res.status(200).end();
  }

  // Only accept POST or GET requests
  if (!["POST", "GET"].includes(req.method)) {
    return res.status(405).json({ error: "Method not allowed" });
  }

  try {
    // Validate environment variables
    if (!SEPOLIA_RPC_URL || !OWNER_PRIVATE_KEY) {
      console.error("Missing environment variables");
      return res.status(500).json({ error: "Server configuration error" });
    }

    // Initialize provider and signer
    const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
    const signer = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

    // Initialize contracts
    const factoryContract = new ethers.Contract(
      FACTORY_ADDRESS,
      FACTORY_ABI,
      signer,
    );
    const sbtContract = new ethers.Contract(SBT_ADDRESS, SBT_ABI, signer);
    const pntContract = new ethers.Contract(PNT_ADDRESS, PNT_ABI, signer);
    const usdtContract = new ethers.Contract(USDT_ADDRESS, USDT_ABI, signer);

    const accounts = [];
    const startTime = Date.now();

    console.log(
      `🚀 Starting test pool initialization (${POOL_SIZE} accounts)...`,
    );

    // Generate and configure accounts
    for (let i = 0; i < POOL_SIZE; i++) {
      const testAccount = generateTestAccount(i);
      const salt = i; // Use index as salt for simplicity

      console.log(
        `\n📦 [${i + 1}/${POOL_SIZE}] Processing ${testAccount.address}...`,
      );

      try {
        // Step 1: Create AA account
        const accountResult = await createAccountForOwner(
          testAccount.address,
          salt,
          factoryContract,
          provider,
        );

        console.log(`  ✓ AA Account: ${accountResult.accountAddress}`);

        // Step 2: Mint tokens
        const tokenResults = await mintTokensToAccount(
          accountResult.accountAddress,
          sbtContract,
          pntContract,
          usdtContract,
        );

        console.log(`  ✓ SBT: ${tokenResults.sbt.success ? "✓" : "✗"}`);
        console.log(`  ✓ PNT: ${tokenResults.pnt.success ? "✓" : "✗"}`);
        console.log(`  ✓ USDT: ${tokenResults.usdt.success ? "✓" : "✗"}`);

        // Add to results
        accounts.push({
          index: i,
          owner: testAccount.address,
          ownerPrivateKey: testAccount.privateKey,
          aaAccount: accountResult.accountAddress,
          salt,
          tokens: tokenResults,
          deployed: !accountResult.alreadyDeployed,
        });
      } catch (error) {
        console.error(`  ✗ Error processing account ${i}:`, error.message);
        accounts.push({
          index: i,
          owner: testAccount.address,
          error: error.message,
        });
      }

      // Add delay to avoid rate limits
      if (i < POOL_SIZE - 1) {
        await new Promise((resolve) => setTimeout(resolve, 2000));
      }
    }

    const endTime = Date.now();
    const duration = ((endTime - startTime) / 1000).toFixed(2);

    // Generate output
    const output = {
      timestamp: new Date().toISOString(),
      network: "Sepolia",
      configuration: {
        factoryAddress: FACTORY_ADDRESS,
        sbtAddress: SBT_ADDRESS,
        pntAddress: PNT_ADDRESS,
        usdtAddress: USDT_ADDRESS,
        poolSize: POOL_SIZE,
      },
      statistics: {
        totalAccounts: accounts.length,
        successfulAccounts: accounts.filter((a) => !a.error).length,
        failedAccounts: accounts.filter((a) => a.error).length,
        durationSeconds: parseFloat(duration),
      },
      accounts,
    };

    console.log(`\n✅ Pool initialization complete in ${duration}s`);
    console.log(
      `   Success: ${output.statistics.successfulAccounts}/${POOL_SIZE}`,
    );
    console.log(`   Failed: ${output.statistics.failedAccounts}/${POOL_SIZE}`);

    // Return JSON response
    return res.status(200).json(output);
  } catch (error) {
    console.error("Init pool error:", error);

    return res.status(500).json({
      success: false,
      error: error.message,
    });
  }
}

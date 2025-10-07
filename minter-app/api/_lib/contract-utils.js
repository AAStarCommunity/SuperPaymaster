const { ethers } = require("ethers");

// Configuration
const getConfig = () => ({
  alchemyRpcUrl: process.env.ALCHEMY_RPC_URL,
  serverPrivateKey: process.env.SEPOLIA_PRIVATE_KEY,
  nftContractAddress: process.env.NFT_CONTRACT_ADDRESS,
  sbtContractAddress: process.env.SBT_CONTRACT_ADDRESS,
  pntsContractAddress: process.env.PNTS_CONTRACT_ADDRESS,
});

// ABIs
const ABIs = {
  nft: ["function safeMint(address to)"],
  sbt: ["function safeMint(address to)"],
  pnts: ["function mint(address to, uint256 amount)"],
};

// Create provider and wallet
const createWallet = () => {
  const config = getConfig();

  if (!config.alchemyRpcUrl || !config.serverPrivateKey) {
    throw new Error("Missing RPC URL or private key");
  }

  const provider = new ethers.JsonRpcProvider(config.alchemyRpcUrl);
  return new ethers.Wallet(config.serverPrivateKey, provider);
};

// Create contract instance
const createContract = (type, wallet) => {
  const config = getConfig();
  const addresses = {
    nft: config.nftContractAddress,
    sbt: config.sbtContractAddress,
    pnts: config.pntsContractAddress,
  };

  if (!addresses[type]) {
    throw new Error(`Invalid contract type: ${type}`);
  }

  return new ethers.Contract(addresses[type], ABIs[type], wallet);
};

// Generic mint function
const handleMint = async (contract, mintFunction, args) => {
  try {
    console.log(
      `Minting request for ${contract.target} with function ${mintFunction}`,
    );
    // Convert BigInt values to strings for logging
    const argsForLogging = args.map((arg) =>
      typeof arg === "bigint" ? arg.toString() : arg,
    );
    console.log(`Arguments: ${JSON.stringify(argsForLogging)}`);

    const txResponse = await contract[mintFunction](...args, {
      gasLimit: 300000,
    });
    console.log(`Transaction sent! Hash: ${txResponse.hash}`);
    return { success: true, txHash: txResponse.hash };
  } catch (error) {
    console.error("--- Minting Error ---");
    console.error(`Contract: ${contract.target}`);
    console.error(`Function: ${mintFunction}`);
    // Convert BigInt to string for error logging
    const argsForLogging = args.map((arg) =>
      typeof arg === "bigint" ? arg.toString() : arg,
    );
    console.error(`Arguments: ${JSON.stringify(argsForLogging)}`);
    console.error(error);
    console.error("--- End Minting Error ---");
    return {
      success: false,
      error: "Failed to send minting transaction",
      details: error.reason || error.message,
    };
  }
};

// Validate Ethereum address
const isValidAddress = (address) => {
  return ethers.isAddress(address);
};

// Parse amount for tokens
const parseAmount = (amount) => {
  try {
    return ethers.parseUnits(amount.toString(), 18);
  } catch (error) {
    throw new Error("Invalid amount format");
  }
};

module.exports = {
  createWallet,
  createContract,
  handleMint,
  isValidAddress,
  parseAmount,
};

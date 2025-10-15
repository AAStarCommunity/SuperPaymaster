require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  const owner = new ethers.Wallet(process.env.OWNER_PRIVATE_KEY, provider);
  
  const FACTORY_ADDRESS = "0x9bD66892144FCf0BAF5B6946AEAFf38B0d967881";
  const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
  
  const FactoryABI = [
    "function createAccount(address owner, uint256 salt) external returns (address)",
    "function getAddress(address owner, uint256 salt) external view returns (address)"
  ];
  
  const factory = new ethers.Contract(FACTORY_ADDRESS, FactoryABI, owner);
  
  console.log("Owner address:", owner.address);
  console.log("Factory address:", FACTORY_ADDRESS);
  
  // Use salt = 0 for first account
  const salt = 0;
  
  // Get the predicted address
  const predictedAddress = await factory.getAddress(owner.address, salt);
  console.log("\nPredicted SimpleAccount V1 address:", predictedAddress);
  
  // Check if already deployed
  const code = await provider.getCode(predictedAddress);
  if (code !== "0x") {
    console.log("✅ Account already deployed at:", predictedAddress);
  } else {
    console.log("Creating new SimpleAccount V1...");
    const tx = await factory.createAccount(owner.address, salt);
    console.log("Transaction hash:", tx.hash);
    
    await tx.wait();
    console.log("✅ Account created at:", predictedAddress);
  }
}

main().catch(console.error);

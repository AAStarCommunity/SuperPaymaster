require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  const owner = new ethers.Wallet(process.env.OWNER_PRIVATE_KEY, provider);
  
  const FACTORY_ADDRESS = "0x9bD66892144FCf0BAF5B6946AEAFf38B0d967881";
  
  // Check if factory is deployed
  const factoryCode = await provider.getCode(FACTORY_ADDRESS);
  console.log("Factory deployed:", factoryCode !== "0x");
  
  if (factoryCode === "0x") {
    console.log("❌ Factory not deployed!");
    return;
  }
  
  const FactoryABI = [
    "function createAccount(address owner, uint256 salt) external returns (address)",
    "function getAddress(address owner, uint256 salt) external view returns (address)",
    "function accountImplementation() external view returns (address)"
  ];
  
  const factory = new ethers.Contract(FACTORY_ADDRESS, FactoryABI, provider);
  
  try {
    const implementation = await factory.accountImplementation();
    console.log("Account Implementation:", implementation);
  } catch (e) {
    console.log("Cannot read implementation:", e.message);
  }
  
  console.log("\nOwner address:", owner.address);
  
  // Try different salts
  for (let salt = 0; salt < 3; salt++) {
    try {
      const addr = await factory.getAddress(owner.address, salt);
      const code = await provider.getCode(addr);
      console.log(`\nSalt ${salt}:`);
      console.log("  Address:", addr);
      console.log("  Deployed:", code !== "0x");
    } catch (e) {
      console.log(`Salt ${salt} error:`, e.message);
    }
  }
  
  // Create account with salt 100
  console.log("\n\n=== Creating account with salt 100 ===");
  const salt = 100;
  const predictedAddr = await factory.getAddress(owner.address, salt);
  console.log("Predicted address:", predictedAddr);
  
  const factoryWithSigner = factory.connect(owner);
  const tx = await factoryWithSigner.createAccount(owner.address, salt);
  console.log("Transaction hash:", tx.hash);
  
  const receipt = await tx.wait();
  console.log("✅ Account created in block:", receipt.blockNumber);
  
  const code = await provider.getCode(predictedAddr);
  console.log("Account deployed:", code !== "0x");
  console.log("\n✅ SimpleAccount V1 address:", predictedAddr);
}

main().catch(console.error);

require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  const owner = new ethers.Wallet(process.env.OWNER_PRIVATE_KEY, provider);
  
  const FACTORY_V1 = "0x9bD66892144FCf0BAF5B6946AEAFf38B0d967881";
  
  const FactoryABI = [
    "function createAccount(address owner, uint256 salt) external returns (address)",
    "function getAddress(address owner, uint256 salt) external view returns (address)",
    "function accountImplementation() external view returns (address)"
  ];
  
  const factory = new ethers.Contract(FACTORY_V1, FactoryABI, provider);
  
  console.log("=== Creating SimpleAccount V1 ===\n");
  console.log("Factory:", FACTORY_V1);
  console.log("Owner:", owner.address);
  
  // Check implementation
  try {
    const impl = await factory.accountImplementation();
    console.log("Implementation:", impl);
  } catch (e) {
    console.log("Cannot get implementation");
  }
  
  // Use a random salt for new account
  const salt = Date.now();
  console.log("\nUsing salt:", salt);
  
  // Get predicted address
  const predictedAddr = await factory.getAddress(owner.address, salt);
  console.log("Predicted address:", predictedAddr);
  
  // Check if already deployed
  const code = await provider.getCode(predictedAddr);
  if (code !== "0x") {
    console.log("❌ Account already exists!");
    console.log("\n✅ Using existing account:", predictedAddr);
    return;
  }
  
  // Create account
  console.log("\nCreating new account...");
  const factoryWithSigner = factory.connect(owner);
  const tx = await factoryWithSigner.createAccount(owner.address, salt);
  console.log("Transaction hash:", tx.hash);
  
  const receipt = await tx.wait();
  console.log("✅ Account created in block:", receipt.blockNumber);
  
  console.log("\n✅ New SimpleAccount V1:", predictedAddr);
  console.log("\nAdd this to .env.v3:");
  console.log(`SIMPLE_ACCOUNT_V1_TEST="${predictedAddr}"`);
}

main().catch(console.error);

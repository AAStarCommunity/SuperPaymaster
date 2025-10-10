require("dotenv").config({ path: "./contracts/.env" });
const { ethers } = require("ethers");

// Deploy SimpleAccountFactoryV2
// This factory creates V2 accounts directly (no upgrade needed)

const ENTRYPOINT_V07 = process.env.ENTRYPOINT_V07 || "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY || process.env.PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const deployer = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

  console.log("=== Deploy SimpleAccountFactoryV2 ===\n");
  console.log("Deployer:", deployer.address);
  console.log("EntryPoint:", ENTRYPOINT_V07);

  // Read the contract artifact
  const fs = require("fs");
  const path = require("path");
  const artifactPath = path.join(
    __dirname,
    "../contracts/out/SimpleAccountFactoryV2.sol/SimpleAccountFactoryV2.json"
  );

  if (!fs.existsSync(artifactPath)) {
    console.error("❌ SimpleAccountFactoryV2 artifact not found!");
    console.error("   Please run: forge build");
    process.exit(1);
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));

  console.log("\n📦 Deploying SimpleAccountFactoryV2...");

  const factory = new ethers.ContractFactory(
    artifact.abi,
    artifact.bytecode.object,
    deployer
  );

  const factoryV2 = await factory.deploy(ENTRYPOINT_V07);
  await factoryV2.waitForDeployment();

  const factoryAddress = await factoryV2.getAddress();

  console.log("✅ SimpleAccountFactoryV2 deployed at:", factoryAddress);

  // Get the implementation address
  const implAddress = await factoryV2.accountImplementation();
  console.log("   Implementation:", implAddress);

  // Verify implementation version
  const SimpleAccountV2ABI = [
    "function version() public view returns (string)"
  ];
  const impl = new ethers.Contract(implAddress, SimpleAccountV2ABI, provider);
  const version = await impl.version();
  console.log("   Version:", version);

  // Save deployment info
  const deploymentInfo = {
    network: "sepolia",
    simpleAccountFactoryV2: factoryAddress,
    simpleAccountV2Implementation: implAddress,
    entryPoint: ENTRYPOINT_V07,
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    version: version,
  };

  const deploymentPath = path.join(
    __dirname,
    "../deployments/simple-account-factory-v2-sepolia.json"
  );

  fs.mkdirSync(path.dirname(deploymentPath), { recursive: true });
  fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));

  console.log("\n📝 Deployment info saved to:", deploymentPath);
  console.log("\n✅ Done!");
  console.log("\nNext steps:");
  console.log("1. Update demo .env with:");
  console.log("   VITE_SIMPLE_ACCOUNT_FACTORY=" + factoryAddress);
  console.log("2. Deploy demo");
  console.log("3. Test creating new V2 accounts (no upgrade needed!)");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

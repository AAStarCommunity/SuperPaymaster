require("dotenv").config({ path: "./contracts/.env" });
const { ethers } = require("ethers");

// Deploy SimpleAccountV2 implementation contract
// This is the new implementation that supports personal_sign

const ENTRYPOINT_V07 =
  process.env.ENTRYPOINT_V07 || "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const DEPLOYER_PRIVATE_KEY =
  process.env.DEPLOYER_PRIVATE_KEY || process.env.PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const deployer = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

  console.log("=== Deploy SimpleAccountV2 Implementation ===\n");
  console.log("Deployer:", deployer.address);
  console.log("EntryPoint:", ENTRYPOINT_V07);

  // Read the contract artifact
  const fs = require("fs");
  const path = require("path");
  const artifactPath = path.join(
    __dirname,
    "../contracts/out/SimpleAccountV2.sol/SimpleAccountV2.json",
  );

  if (!fs.existsSync(artifactPath)) {
    console.error("❌ SimpleAccountV2 artifact not found!");
    console.error("   Please run: forge build");
    process.exit(1);
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));

  console.log("\n📦 Deploying SimpleAccountV2 implementation...");

  const factory = new ethers.ContractFactory(
    artifact.abi,
    artifact.bytecode.object,
    deployer,
  );

  const simpleAccountV2 = await factory.deploy(ENTRYPOINT_V07);
  await simpleAccountV2.waitForDeployment();

  const address = await simpleAccountV2.getAddress();

  console.log("✅ SimpleAccountV2 deployed at:", address);

  // Verify the version
  const version = await simpleAccountV2.version();
  console.log("   Version:", version);

  // Save deployment info
  const deploymentInfo = {
    network: "sepolia",
    simpleAccountV2Implementation: address,
    entryPoint: ENTRYPOINT_V07,
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    version: version,
  };

  const deploymentPath = path.join(
    __dirname,
    "../deployments/simple-account-v2-sepolia.json",
  );

  fs.mkdirSync(path.dirname(deploymentPath), { recursive: true });
  fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));

  console.log("\n📝 Deployment info saved to:", deploymentPath);
  console.log("\n✅ Done!");
  console.log("\nNext steps:");
  console.log("1. Update .env with: SIMPLE_ACCOUNT_V2_IMPL=" + address);
  console.log("2. Run upgrade script to upgrade existing accounts");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

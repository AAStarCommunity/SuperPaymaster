const { ethers } = require("ethers");
const fs = require("fs");

async function main() {
  // Setup provider and wallet
  const provider = new ethers.JsonRpcProvider(
    "https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N",
  );
  const privateKey = process.env.PRIVATE_KEY || process.env.SEPOLIA_PRIVATE_KEY;
  if (!privateKey) {
    throw new Error(
      "PRIVATE_KEY or SEPOLIA_PRIVATE_KEY environment variable not set",
    );
  }
  const wallet = new ethers.Wallet(privateKey, provider);

  console.log("Deploying from:", wallet.address);
  console.log(
    "Balance:",
    ethers.formatEther(await provider.getBalance(wallet.address)),
    "ETH",
  );

  // Load Settlement contract artifact
  const settlementArtifact = JSON.parse(
    fs.readFileSync("out/Settlement.sol/Settlement.json", "utf8"),
  );

  // Deploy Settlement
  console.log("\n[1/2] Deploying Settlement...");
  const SettlementFactory = new ethers.ContractFactory(
    settlementArtifact.abi,
    settlementArtifact.bytecode.object,
    wallet,
  );

  const settlement = await SettlementFactory.deploy(
    "0x411BD567E46C0781248dbB6a9211891C032885e5", // initialOwner
    "0x4e67678AF714f6B5A8882C2e5a78B15B08a79575", // registryAddress
    "100000000000000000000", // initialThreshold (100 PNT)
    { gasLimit: 3000000 },
  );

  console.log(
    "Settlement deployment tx:",
    settlement.deploymentTransaction().hash,
  );
  await settlement.waitForDeployment();
  const settlementAddress = await settlement.getAddress();
  console.log("Settlement deployed to:", settlementAddress);

  // Load PaymasterV3 contract artifact
  const paymasterArtifact = JSON.parse(
    fs.readFileSync("out/PaymasterV3.sol/PaymasterV3.json", "utf8"),
  );

  // Deploy PaymasterV3
  console.log("\n[2/2] Deploying PaymasterV3...");
  const PaymasterFactory = new ethers.ContractFactory(
    paymasterArtifact.abi,
    paymasterArtifact.bytecode.object,
    wallet,
  );

  const paymaster = await PaymasterFactory.deploy(
    "0x411BD567E46C0781248dbB6a9211891C032885e5", // initialOwner
    "0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789", // entryPoint v0.6
    settlementAddress, // settlement
    "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f", // sbtContract
    "0x090e34709a592210158aa49a969e4a04e3a29ebd", // gasToken
    "10000000000000000000", // minTokenBalance (10 PNT)
    { gasLimit: 3000000 },
  );

  console.log(
    "PaymasterV3 deployment tx:",
    paymaster.deploymentTransaction().hash,
  );
  await paymaster.waitForDeployment();
  const paymasterAddress = await paymaster.getAddress();
  console.log("PaymasterV3 deployed to:", paymasterAddress);

  // Save addresses
  const addresses = {
    settlement: settlementAddress,
    paymasterV3: paymasterAddress,
    timestamp: new Date().toISOString(),
  };

  fs.writeFileSync(
    "deployments/v3-sepolia-latest.json",
    JSON.stringify(addresses, null, 2),
  );
  console.log("\n✅ Deployment complete!");
  console.log("Addresses saved to deployments/v3-sepolia-latest.json");

  console.log("\nNext steps:");
  console.log(`1. Register PaymasterV3: ${paymasterAddress}`);
  console.log(`2. Deposit ETH to PaymasterV3`);
  console.log(`3. Update .env.v3 with new addresses`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const NEW_SETTLEMENT = "0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5";

// Load compiled artifacts
const CONTRACTS_PATH = "../../gemini-minter/contracts/out";
const factoryArtifact = JSON.parse(
  fs.readFileSync(
    path.join(__dirname, CONTRACTS_PATH, "GasTokenFactory.sol/GasTokenFactory.json"),
    "utf8"
  )
);

async function deployFactory() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log("=== 部署 GasTokenFactory ===\n");
  console.log("Deployer:", signer.address);
  console.log("Network:", (await provider.getNetwork()).name);
  console.log("Chain ID:", (await provider.getNetwork()).chainId.toString());

  // Deploy factory
  const Factory = new ethers.ContractFactory(
    factoryArtifact.abi,
    factoryArtifact.bytecode.object,
    signer
  );

  console.log("\nDeploying GasTokenFactory...");
  const factory = await Factory.deploy();
  await factory.waitForDeployment();

  const factoryAddress = await factory.getAddress();
  console.log("✅ GasTokenFactory deployed:", factoryAddress);

  return factoryAddress;
}

async function deployNewPNT(factoryAddress) {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log("\n=== 通过 Factory 部署新 PNT ===\n");
  console.log("Factory:", factoryAddress);
  console.log("Settlement:", NEW_SETTLEMENT);

  const factory = new ethers.Contract(
    factoryAddress,
    [
      "function createToken(string memory name, string memory symbol, address settlement, uint256 exchangeRate) external returns (address)",
      "event TokenDeployed(address indexed token, string name, string symbol, address settlement, uint256 exchangeRate)",
    ],
    signer
  );

  // Deploy new PNT
  console.log("\nCreating new PNT token...");
  const tx = await factory.createToken(
    "Points Token V2",
    "PNTv2",
    NEW_SETTLEMENT,
    ethers.parseUnits("1", 18)
  );

  console.log("Transaction hash:", tx.hash);
  const receipt = await tx.wait();
  console.log("✅ Deployed in block:", receipt.blockNumber);

  // Get new PNT address from event
  const event = receipt.logs
    .map((log) => {
      try {
        return factory.interface.parseLog({
          topics: log.topics,
          data: log.data,
        });
      } catch (e) {
        return null;
      }
    })
    .find((e) => e && e.name === "TokenDeployed");

  if (!event) {
    throw new Error("TokenDeployed event not found");
  }

  const newPNT = event.args.token;
  console.log("\n=== 新 PNT Token ===");
  console.log("Address:", newPNT);

  // Verify
  const pntContract = new ethers.Contract(
    newPNT,
    [
      "function name() view returns (string)",
      "function symbol() view returns (string)",
      "function settlement() view returns (address)",
      "function owner() view returns (address)",
    ],
    provider
  );

  const name = await pntContract.name();
  const symbol = await pntContract.symbol();
  const settlement = await pntContract.settlement();
  const owner = await pntContract.owner();

  console.log("Name:", name);
  console.log("Symbol:", symbol);
  console.log("Settlement:", settlement);
  console.log(
    settlement === NEW_SETTLEMENT
      ? "✅ Settlement 地址正确"
      : "❌ Settlement 地址错误"
  );
  console.log("Owner:", owner);

  console.log("\n=== 下一步 ===");
  console.log("\n1. 更新 PaymasterV3.gasToken:");
  console.log(
    `cast send 0x1568da4ea1E2C34255218b6DaBb2458b57B35805 "setGasToken(address)" ${newPNT} --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL`
  );
  console.log("\n2. Mint 400 PNT 给测试账户:");
  console.log(
    `cast send ${newPNT} "mint(address,uint256)" 0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D 400000000000000000000 --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL`
  );
  console.log("\n3. 更新 .env.v3:");
  console.log(`PNTS_TOKEN="${newPNT}"`);
  console.log(`GAS_TOKEN_ADDRESS="${newPNT}"`);
  console.log("\n4. 运行 E2E 测试:");
  console.log("node scripts/submit-via-entrypoint.js");

  return { factoryAddress, newPNT };
}

async function main() {
  try {
    // Step 1: Deploy factory
    const factoryAddress = await deployFactory();

    // Step 2: Deploy new PNT through factory
    const { newPNT } = await deployNewPNT(factoryAddress);

    console.log("\n=== 部署完成 ===");
    console.log("Factory:", factoryAddress);
    console.log("New PNT:", newPNT);
  } catch (error) {
    console.error("部署失败:", error);
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

// 使用 GasTokenFactory 部署新的 PNT
const FACTORY_ADDRESS = ""; // TODO: 如果没有,先部署 GasTokenFactory
const NEW_SETTLEMENT = "0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5";
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;

const GasTokenFactoryABI = [
  "function createToken(string memory name, string memory symbol, address settlement, uint256 exchangeRate) external returns (address)",
  "function getTokenInfo(address token) external view returns (string memory name, string memory symbol, address settlement, uint256 exchangeRate, uint256 totalSupply)",
  "function getAllTokens() external view returns (address[])",
];

const GasTokenABI = [
  "function name() external view returns (string)",
  "function symbol() external view returns (string)",
  "function settlement() external view returns (address)",
  "function owner() external view returns (address)",
  "function mint(address to, uint256 amount) external",
];

async function deployFactory() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log("=== 部署 GasTokenFactory ===\n");
  console.log("Deployer:", signer.address);

  // GasTokenFactory bytecode (从 forge build 获取)
  const GasTokenFactory = await ethers.getContractFactory(
    GasTokenFactoryABI,
    // bytecode here - 太长了,使用 forge create 更简单
    signer,
  );

  console.log(
    "\n⚠️  请使用 forge create 部署 GasTokenFactory:",
  );
  console.log(
    "cd /path/to/gemini-minter/contracts && forge create src/GasTokenFactory.sol:GasTokenFactory --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY",
  );
}

async function deployNewPNT(factoryAddress) {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log("=== 通过 Factory 部署新 PNT ===\n");
  console.log("Deployer:", signer.address);
  console.log("Factory:", factoryAddress);
  console.log("Settlement:", NEW_SETTLEMENT, "\n");

  const factory = new ethers.Contract(
    factoryAddress,
    GasTokenFactoryABI,
    signer,
  );

  // 部署新 PNT
  console.log("Creating new PNT token...");
  const tx = await factory.createToken(
    "Points Token V2", // name
    "PNTv2", // symbol
    NEW_SETTLEMENT, // settlement (正确地址)
    ethers.parseUnits("1", 18), // exchangeRate (1:1)
  );

  console.log("Transaction hash:", tx.hash);
  const receipt = await tx.wait();
  console.log("✅ Deployed in block:", receipt.blockNumber);

  // 从事件中获取新 token 地址
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
  console.log("\n=== 新 PNT Token 信息 ===");
  console.log("Address:", newPNT);

  // 验证配置
  const pntContract = new ethers.Contract(newPNT, GasTokenABI, provider);
  const name = await pntContract.name();
  const symbol = await pntContract.symbol();
  const settlement = await pntContract.settlement();
  const owner = await pntContract.owner();

  console.log("Name:", name);
  console.log("Symbol:", symbol);
  console.log("Settlement:", settlement);
  console.log(
    settlement === NEW_SETTLEMENT ? "✅ Settlement 正确" : "❌ Settlement 错误",
  );
  console.log("Owner:", owner);

  console.log("\n=== 下一步 ===");
  console.log("1. 更新 .env.v3:");
  console.log(`   PNT_TOKEN=${newPNT}`);
  console.log("\n2. 更新 PaymasterV3.gasToken:");
  console.log(
    `   cast send 0x1568da4ea1E2C34255218b6DaBb2458b57B35805 "setGasToken(address)" ${newPNT} --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL`,
  );
  console.log("\n3. Mint PNT 给测试账户:");
  console.log(
    `   cast send ${newPNT} "mint(address,uint256)" 0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D 400000000000000000000 --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL`,
  );
  console.log("\n4. 运行 E2E 测试:");
  console.log("   node scripts/submit-via-entrypoint.js");

  return newPNT;
}

async function main() {
  if (!FACTORY_ADDRESS) {
    console.log("⚠️  GasTokenFactory 地址未设置");
    console.log("\n请先部署 GasTokenFactory:");
    console.log(
      "cd projects/gemini-minter/contracts && forge create src/GasTokenFactory.sol:GasTokenFactory --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --verify",
    );
    console.log("\n然后更新此脚本中的 FACTORY_ADDRESS");
    return;
  }

  await deployNewPNT(FACTORY_ADDRESS);
}

// 如果提供了 factory 地址作为参数,直接部署
if (process.argv[2]) {
  const factoryAddress = process.argv[2];
  deployNewPNT(factoryAddress)
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
} else {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}

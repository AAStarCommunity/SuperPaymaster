// [MIGRATED TO V3]: This file has been updated to use Mycelium Protocol v3 API
// Migration Date: 2025-11-28
// Changes: registerCommunity() -> registerRole(ROLE_COMMUNITY, ...)
//          exitCommunity() -> exitRole(ROLE_COMMUNITY)
//          See FRONTEND_MIGRATION_EXAMPLES_V3.md for details

/**
 * 配置文件 - 基于 @aastar/shared-config v0.2.10
 * 集中管理合约地址、测试账户、网络配置
 */
const { ethers } = require("ethers");
require("dotenv").config();

// ============= 网络配置 =============
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL || "https://rpc.sepolia.org";
const CHAIN_ID = 11155111; // Sepolia

// ============= 账户配置 =============
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;
const OWNER2_PRIVATE_KEY = process.env.OWNER2_PRIVATE_KEY;

if (!DEPLOYER_PRIVATE_KEY || !OWNER2_PRIVATE_KEY) {
  throw new Error("Missing required private keys in .env file");
}

const DEPLOYER_ADDRESS = "0x411BD567E46C0781248dbB6a9211891C032885e5";
const OWNER2_ADDRESS = "0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA";

// Simple Account 地址（预期地址）
const ACCOUNT_A = "0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584";
const ACCOUNT_B = "0x57b2e6f08399c276b2c1595825219d29990d0921";
const ACCOUNT_C = "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";

// ============= V2 核心系统合约地址 (@aastar/shared-config v0.2.10) =============
const CONTRACTS = {
  // 核心系统
  SUPER_PAYMASTER_V2: "0x95B20d8FdF173a1190ff71e41024991B2c5e58eF",
  REGISTRY: "0xb6286F53d8ff25eF99e6a43b2907B8e6BD0f019A",
  GTOKEN: "0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc",
  GTOKEN_STAKING: "0x60Bd54645b0fDabA1114B701Df6f33C4ecE87fEa",
  PAYMASTER_FACTORY: "0x65Cf6C4ab3d40f3C919b6F3CADC09Efb72817920",
  XPNTS_FACTORY: "0x9dD72cB42427fC9F7Bf0c949DB7def51ef29D6Bd",
  MYSBT: "0x73E635Fc9eD362b7061495372B6eDFF511D9E18F",

  // AOA 模式
  PAYMASTER_V4_1: "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38",

  // 官方依赖
  ENTRYPOINT: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",

  // 测试代币（需要部署）
  APNTS: process.env.APNTS_ADDRESS || "",
  BPNTS: process.env.APNTS_ADDRESS || "",  // 暂时使用 aPNTs 代替 bPNTs (deployer 拥有 aPNTs)
};

// ============= ABI 配置 =============
// 辅助函数：安全加载 ABI，如果失败则返回 null
function loadABI(path) {
  try {
    return require(path).abi;

// Role IDs for v3
const ROLE_ENDUSER = '0x454e445553455200000000000000000000000000000000000000000000000000';
const ROLE_COMMUNITY = '0x434f4d4d554e4954590000000000000000000000000000000000000000000000';
const ROLE_PAYMASTER = '0x5041594d41535445520000000000000000000000000000000000000000000000';
const ROLE_SUPER = '0x5355504552000000000000000000000000000000000000000000000000000000';
  } catch (error) {
    console.warn(`⚠️  无法加载 ABI: ${path}，将使用通用接口`);
    return null;
  }
}

const ABIS = {
  GTOKEN: loadABI("../../../out/GToken.sol/GToken.json"),
  GTOKEN_STAKING: loadABI("../../../abis/IGTokenStakingV3.json"),
  SUPER_PAYMASTER_V2: loadABI("../../../out/SuperPaymasterV2.sol/SuperPaymasterV2.json"),
  REGISTRY: loadABI("../../../abis/Registry_v3.json"),
  MYSBT: loadABI("../../../abis/MySBT_v3.json"),
  XPNTS_FACTORY: loadABI("../../../out/xPNTsFactory.sol/xPNTsFactory.json"),
  XPNTS: loadABI("../../../out/xPNTsToken.sol/xPNTsToken.json"),
  PAYMASTER_V4_1: loadABI("../../../out/PaymasterV4_1.sol/PaymasterV4_1.json"),
  // EntryPoint v0.7 - PackedUserOperation
  ENTRYPOINT: [
    "function getUserOpHash(tuple(address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes) userOp) view returns (bytes32)",
    "function handleOps(tuple(address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)[] ops, address beneficiary)",
    "function getNonce(address sender, uint192 key) view returns (uint256)",
  ],
  SIMPLE_ACCOUNT: [
    "function execute(address dest, uint256 value, bytes calldata func) external",
    "function owner() view returns (address)",
    "function entryPoint() view returns (address)",
  ],
  SIMPLE_ACCOUNT_FACTORY: [
    "function createAccount(address owner, uint256 salt) returns (address)",
    "function getAddress(address owner, uint256 salt) view returns (address)",
  ],
  ERC20: [
    "function balanceOf(address account) view returns (uint256)",
    "function transfer(address to, uint256 amount) returns (bool)",
    "function approve(address spender, uint256 amount) returns (bool)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function mint(address to, uint256 amount)",
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
  ],
  ERC721: [
    "function balanceOf(address owner) view returns (uint256)",
    "function ownerOf(uint256 tokenId) view returns (address)",
    "function tokenURI(uint256 tokenId) view returns (string)",
  ],
};

// ============= 辅助函数 =============
function getProvider() {
  return new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
}

function getDeployerSigner() {
  const provider = getProvider();
  return new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);
}

function getOwner2Signer() {
  const provider = getProvider();
  return new ethers.Wallet(OWNER2_PRIVATE_KEY, provider);
}

function getContract(contractName, address, signerOrProvider) {
  let abi = ABIS[contractName];

  // 如果 ABI 为 null，尝试使用通用接口
  if (!abi) {
    // GTOKEN, XPNTS_FACTORY, XPNTS 都可以使用 ERC20 接口
    if (["GTOKEN", "XPNTS", "XPNTS_FACTORY"].includes(contractName)) {
      console.warn(`⚠️  使用 ERC20 通用接口for ${contractName}`);
      abi = ABIS.ERC20;
    }
    // MYSBT 使用 ERC721 接口
    else if (contractName === "MYSBT") {
      console.warn(`⚠️  使用 ERC721 通用接口 for ${contractName}`);
      abi = ABIS.ERC721;
    }
    else {
      throw new Error(`ABI not found for contract: ${contractName}`);
    }
  }

  return new ethers.Contract(address, abi, signerOrProvider);
}

// ============= 导出 =============
module.exports = {
  // 网络
  SEPOLIA_RPC_URL,
  CHAIN_ID,

  // 账户
  DEPLOYER_ADDRESS,
  OWNER2_ADDRESS,
  ACCOUNT_A,
  ACCOUNT_B,
  ACCOUNT_C,

  // 合约地址
  CONTRACTS,

  // ABI
  ABIS,

  // 辅助函数
  getProvider,
  getDeployerSigner,
  getOwner2Signer,
  getContract,
};

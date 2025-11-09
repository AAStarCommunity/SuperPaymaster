# ERC-4337 无 Gas 交易完整测试流程 v2.0

> 基于 @aastar/shared-config v0.2.10 (2025-11-01)
> 测试两种 Paymaster 模式：AOA (PaymasterV4.1) 和 AOA+ (SuperPaymasterV2)

## 📋 测试目标

使用两种 Paymaster 模式完成 Simple Account 之间的无 gas 转账：
1. **AOA 模式** - PaymasterV4.1 独立部署，社区自主运营
2. **AOA+ 模式** - SuperPaymasterV2 共享 paymaster，运营方托管

## 🏗️ 核心合约地址（v0.2.10）

### V2 核心系统
| 合约 | 版本 | 地址 | 部署日期 |
|------|------|------|----------|
| SuperPaymasterV2 | 2.0.0 | `0x95B20d8FdF173a1190ff71e41024991B2c5e58eF` | 2025-11-01 |
| Registry | 2.1.3 | `0xb6286F53d8ff25eF99e6a43b2907B8e6BD0f019A` | 2025-11-01 |
| GToken | 2.0.0 | `0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc` | 2025-11-01 |
| GTokenStaking | 2.0.0 | `0x60Bd54645b0fDabA1114B701Df6f33C4ecE87fEa` | 2025-11-01 |
| PaymasterFactory | 1.0.0 | `0x65Cf6C4ab3d40f3C919b6F3CADC09Efb72817920` | 2025-11-01 |
| xPNTsFactory | 2.0.0 | `0x9dD72cB42427fC9F7Bf0c949DB7def51ef29D6Bd` | 2025-11-01 |
| MySBT | 2.4.0 | `0x73E635Fc9eD362b7061495372B6eDFF511D9E18F` | 2025-11-01 |

### AOA 模式
| 合约 | 版本 | 地址 | 部署日期 |
|------|------|------|----------|
| PaymasterV4_1 | 4.1 | `0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38` | 2025-10-15 |

### 官方依赖
| 合约 | 地址 |
|------|------|
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |

### 测试代币（开发测试用）
| 合约 | 版本 | 地址 | 所属社区 |
|------|------|------|----------|
| aPNTs | 2.0.0 | `0xBD0710596010a157B88cd141d797E8Ad4bb2306b` | AAStar Community |
| bPNTs | 2.0.0 | `0xF223660d24c436B5BfadFEF68B5051bf45E7C995` | BuilderDAO Community |

## 👥 测试账户配置

### EOA 账户（有私钥）
```bash
# Deployer（系统部署者）
DEPLOYER_ADDRESS="0x411BD567E46C0781248dbB6a9211891C032885e5"
# 从 .env 获取 DEPLOYER_PRIVATE_KEY

# Test User（测试用户 OWNER2）
OWNER2_ADDRESS="0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA"
# 从 .env 获取 OWNER2_PRIVATE_KEY
```

### Simple Account（ERC-4337 智能合约账户）
```bash
# 由 OWNER2 使用 SimpleAccountFactory 创建
ACCOUNT_A="0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584"
ACCOUNT_B="0x57b2e6f08399c276b2c1595825219d29990d0921"
ACCOUNT_C="0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce"
```

---

## 🔍 前置检查（Pre-Test Validation）

### ✅ 检查 1：确认测试账户类型

```bash
# 检查 ABC 是否是合约账户（Simple Account）
cast code $ACCOUNT_A --rpc-url $SEPOLIA_RPC_URL
cast code $ACCOUNT_B --rpc-url $SEPOLIA_RPC_URL
cast code $ACCOUNT_C --rpc-url $SEPOLIA_RPC_URL

# 如果返回 0x 或很短的 bytecode，说明不是合约账户，需要创建
# 如果返回较长的 bytecode，说明已部署，继续下一步
```

### ✅ 检查 2：合约部署状态验证

#### 2.1 检查 GToken 和 GTokenStaking 绑定

```bash
# 检查 GTokenStaking 是否正确绑定 GToken
cast call 0x60Bd54645b0fDabA1114B701Df6f33C4ecE87fEa "gToken()(address)" \
  --rpc-url $SEPOLIA_RPC_URL

# 预期输出: 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc (GToken 地址)
```

#### 2.2 检查 GTokenStaking Locker 配置

```bash
# 检查 SuperPaymasterV2 是否被配置为 locker
cast call 0x60Bd54645b0fDabA1114B701Df6f33C4ecE87fEa \
  "lockerConfigs(address)(bool,uint256,uint256,uint256,uint256[],uint256[],address)" \
  0x95B20d8FdF173a1190ff71e41024991B2c5e58eF \
  --rpc-url $SEPOLIA_RPC_URL

# 预期输出第一个字段为 true（isActive）

# 检查 Registry 是否被配置为 locker
cast call 0x60Bd54645b0fDabA1114B701Df6f33C4ecE87fEa \
  "lockerConfigs(address)(bool,uint256,uint256,uint256,uint256[],uint256[],address)" \
  0xb6286F53d8ff25eF99e6a43b2907B8e6BD0f019A \
  --rpc-url $SEPOLIA_RPC_URL

# 预期输出第一个字段为 true（isActive）
```

#### 2.3 检查 SuperPaymasterV2 配置

```bash
# 检查最小运营方质押要求
cast call 0x95B20d8FdF173a1190ff71e41024991B2c5e58eF \
  "minOperatorStake()(uint256)" \
  --rpc-url $SEPOLIA_RPC_URL

# 预期输出: 30000000000000000000 (30 ether)

# 检查 aPNTs 的 USD 价格
cast call 0x95B20d8FdF173a1190ff71e41024991B2c5e58eF \
  "aPNTsPriceUSD()(uint256)" \
  --rpc-url $SEPOLIA_RPC_URL

# 预期输出: 20000000000000000 (0.02 ether，即 0.02 USD)
```

### ✅ 检查 3：MySBT 注册到 Paymaster

#### 3.1 检查 MySBT 是否注册到 PaymasterV4.1

```bash
# 检查 PaymasterV4.1 支持的 SBT 列表
cast call 0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38 \
  "supportedSBTs(uint256)(address)" \
  0 \
  --rpc-url $SEPOLIA_RPC_URL

# 预期输出: 0x73E635Fc9eD362b7061495372B6eDFF511D9E18F (MySBT 地址)
# 或者检查是否有 isSBTSupported 函数
```

#### 3.2 检查 MySBT 是否注册到 SuperPaymasterV2

```bash
# 检查 operator 配置的 supportedSBTs
# 需要先知道 operator 地址（deployer）
cast call 0x95B20d8FdF173a1190ff71e41024991B2c5e58eF \
  "operators(address)" \
  0x411BD567E46C0781248dbB6a9211891C032885e5 \
  --rpc-url $SEPOLIA_RPC_URL

# 从返回值解析 supportedSBTs 数组
```

### ✅ 检查 4：xPNTs 预 Approve 验证

#### 4.1 检查 aPNTs 预 approve SuperPaymasterV2

```bash
# 检查 aPNTs 的 auto-approved spenders
cast call 0xBD0710596010a157B88cd141d797E8Ad4bb2306b \
  "autoApprovedSpenders(uint256)(address)" \
  0 \
  --rpc-url $SEPOLIA_RPC_URL

# 预期输出: 0x95B20d8FdF173a1190ff71e41024991B2c5e58eF (SuperPaymasterV2)
```

#### 4.2 检查 bPNTs 预 approve PaymasterV4.1 和 SuperPaymasterV2

```bash
# 检查 bPNTs 的 auto-approved spenders（第一个）
cast call 0xF223660d24c436B5BfadFEF68B5051bf45E7C995 \
  "autoApprovedSpenders(uint256)(address)" \
  0 \
  --rpc-url $SEPOLIA_RPC_URL

# 预期输出: 0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38 (PaymasterV4.1)

# 检查 bPNTs 的 auto-approved spenders（第二个）
cast call 0xF223660d24c436B5BfadFEF68B5051bf45E7C995 \
  "autoApprovedSpenders(uint256)(address)" \
  1 \
  --rpc-url $SEPOLIA_RPC_URL

# 预期输出: 0x95B20d8FdF173a1190ff71e41024991B2c5e58eF (SuperPaymasterV2)
```

### ✅ 检查 5：xPNTs 汇率配置

#### 5.1 检查 PaymasterV4.1 的汇率

```bash
# 检查 bPNTs 对 aPNTs 的汇率
cast call 0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38 \
  "xPNTsToAPNTsRate(address)(uint256)" \
  0xF223660d24c436B5BfadFEF68B5051bf45E7C995 \
  --rpc-url $SEPOLIA_RPC_URL

# 预期输出: 1000000000000000000 (1 ether，即 1:1 汇率)
```

#### 5.2 检查 SuperPaymasterV2 的汇率

```bash
# 检查 operator 设置的 aPNTs 汇率
cast call 0x95B20d8FdF173a1190ff71e41024991B2c5e58eF \
  "operators(address)" \
  0x411BD567E46C0781248dbB6a9211891C032885e5 \
  --rpc-url $SEPOLIA_RPC_URL

# 从返回值解析 xPNTsToAPNTsRate 字段
```

---

## 🚀 测试准备流程（3 阶段）

### 阶段 1：初始化测试账户（创建 Simple Account）

#### 1.1 部署 Simple Account Factory（如果未部署）

```javascript
// 使用官方 SimpleAccountFactory 或自定义工厂
const SimpleAccountFactory = await ethers.getContractAt(
  "SimpleAccountFactory",
  SIMPLE_ACCOUNT_FACTORY_ADDRESS
);
```

#### 1.2 创建 Simple Account A/B/C

```javascript
// 使用 OWNER2 作为 owner 创建 Simple Account
const owner2Signer = new ethers.Wallet(OWNER2_PRIVATE_KEY, provider);

// 创建 Account A
const accountA_tx = await SimpleAccountFactory.createAccount(
  owner2Signer.address,  // owner
  0                      // salt
);
await accountA_tx.wait();

// 获取 Account A 地址
const accountA_address = await SimpleAccountFactory.getAddress(
  owner2Signer.address,
  0
);
console.log("Account A:", accountA_address);
// 预期: 0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584

// 创建 Account B（salt = 1）
const accountB_tx = await SimpleAccountFactory.createAccount(
  owner2Signer.address,
  1
);
await accountB_tx.wait();
const accountB_address = await SimpleAccountFactory.getAddress(
  owner2Signer.address,
  1
);
console.log("Account B:", accountB_address);

// 创建 Account C（salt = 2）
const accountC_tx = await SimpleAccountFactory.createAccount(
  owner2Signer.address,
  2
);
await accountC_tx.wait();
const accountC_address = await SimpleAccountFactory.getAddress(
  owner2Signer.address,
  2
);
console.log("Account C:", accountC_address);
```

#### 1.3 验证 Simple Account 部署

```bash
# 验证 Account A 是合约
cast code 0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584 --rpc-url $SEPOLIA_RPC_URL

# 验证 owner 是 OWNER2
cast call 0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584 \
  "owner()(address)" \
  --rpc-url $SEPOLIA_RPC_URL

# 预期输出: 0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA (OWNER2)
```

---

### 阶段 2：初始化社区和 xPNTs 实例合约

#### 2.1 准备 Deployer 和社区 Owner 的 GToken

```bash
# 检查 deployer 的 GToken 余额
cast call 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc \
  "balanceOf(address)(uint256)" \
  0x411BD567E46C0781248dbB6a9211891C032885e5 \
  --rpc-url $SEPOLIA_RPC_URL

# 如果余额不足，mint GToken
cast send 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc \
  "mint(address,uint256)" \
  0x411BD567E46C0781248dbB6a9211891C032885e5 \
  100000000000000000000 \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL

# 假设有第二个社区 owner（BuilderDAO）
# BUILDER_DAO_OWNER="0x3c053322AfBEB5B2C9917A6Cbda590f1736590cd"
# 同样 mint GToken 给 BuilderDAO owner
```

#### 2.2 注册 AAStar 社区到 Registry

```javascript
// 使用 deployer 注册 AAStar 社区
const registry = await ethers.getContractAt(
  "Registry",
  "0xb6286F53d8ff25eF99e6a43b2907B8e6BD0f019A"
);

const gToken = await ethers.getContractAt(
  "GToken",
  "0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc"
);

// Deployer approve Registry
await gToken.connect(deployerSigner).approve(
  registry.address,
  ethers.parseEther("50")
);

// 注册社区
await registry.connect(deployerSigner).registerCommunity(
  "AAStar",                    // communityName
  "aastar.eth",                // ensName
  ethers.parseEther("50")      // initialStake (50 GT)
);

// 获取社区 ID
const communityId_AAStar = await registry.getCommunityId("aastar.eth");
console.log("AAStar Community ID:", communityId_AAStar);
```

#### 2.3 部署 aPNTs（AAStar 社区 Gas Token）

```javascript
// 使用 xPNTsFactory 部署 aPNTs
const xPNTsFactory = await ethers.getContractAt(
  "xPNTsFactory",
  "0x9dD72cB42427fC9F7Bf0c949DB7def51ef29D6Bd"
);

// 部署 aPNTs
await xPNTsFactory.connect(deployerSigner).deployToken(
  communityId_AAStar,            // communityId
  "AAStar Points",               // name
  "aPNTs",                       // symbol
  [
    "0x95B20d8FdF173a1190ff71e41024991B2c5e58eF"  // SuperPaymasterV2（预 approve）
  ]
);

// 获取部署的 aPNTs 地址
const aPNTs_address = await xPNTsFactory.getCommunityToken(communityId_AAStar);
console.log("aPNTs deployed at:", aPNTs_address);
// 预期: 0xBD0710596010a157B88cd141d797E8Ad4bb2306b
```

#### 2.4 注册 BuilderDAO 社区并部署 bPNTs

```javascript
// 使用 BuilderDAO owner 注册社区
const builderDAOSigner = new ethers.Wallet(BUILDER_DAO_PRIVATE_KEY, provider);

await gToken.connect(builderDAOSigner).approve(
  registry.address,
  ethers.parseEther("50")
);

await registry.connect(builderDAOSigner).registerCommunity(
  "BuilderDAO",
  "builderdao.eth",
  ethers.parseEther("50")
);

const communityId_BuilderDAO = await registry.getCommunityId("builderdao.eth");

// 部署 bPNTs
await xPNTsFactory.connect(builderDAOSigner).deployToken(
  communityId_BuilderDAO,
  "BuilderDAO Points",
  "bPNTs",
  [
    "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38",  // PaymasterV4.1
    "0x95B20d8FdF173a1190ff71e41024991B2c5e58eF"   // SuperPaymasterV2
  ]
);

const bPNTs_address = await xPNTsFactory.getCommunityToken(communityId_BuilderDAO);
console.log("bPNTs deployed at:", bPNTs_address);
// 预期: 0xF223660d24c436B5BfadFEF68B5051bf45E7C995
```

#### 2.5 验证社区和 xPNTs 部署

```bash
# 检查 AAStar 社区信息
cast call 0xb6286F53d8ff25eF99e6a43b2907B8e6BD0f019A \
  "communities(uint256)" \
  $COMMUNITY_ID_AASTAR \
  --rpc-url $SEPOLIA_RPC_URL

# 检查 aPNTs 的 autoApprovedSpenders
cast call 0xBD0710596010a157B88cd141d797E8Ad4bb2306b \
  "autoApprovedSpenders(uint256)(address)" \
  0 \
  --rpc-url $SEPOLIA_RPC_URL

# 预期输出: 0x95B20d8FdF173a1190ff71e41024991B2c5e58eF (SuperPaymasterV2)
```

---

### 阶段 3：初始化测试账户资产

#### 3.1 Mint GToken 给 OWNER2 和 Simple Accounts

```javascript
// Mint 1000 GToken 给 OWNER2
await gToken.connect(deployerSigner).mint(
  OWNER2_ADDRESS,
  ethers.parseEther("1000")
);

// Mint 1000 GToken 给 Account A
await gToken.connect(deployerSigner).mint(
  ACCOUNT_A,
  ethers.parseEther("1000")
);

// Mint 1000 GToken 给 Account B
await gToken.connect(deployerSigner).mint(
  ACCOUNT_B,
  ethers.parseEther("1000")
);

// Mint 1000 GToken 给 Account C
await gToken.connect(deployerSigner).mint(
  ACCOUNT_C,
  ethers.parseEther("1000")
);
```

#### 3.2 Mint SBT 给测试账户

```javascript
// MySBT 合约
const mySBT = await ethers.getContractAt(
  "MySBT",
  "0x73E635Fc9eD362b7061495372B6eDFF511D9E18F"
);

// Mint SBT 给 OWNER2（需要支付 GToken mint fee）
// 先 approve MySBT 使用 GToken
await gToken.connect(owner2Signer).approve(
  mySBT.address,
  ethers.parseEther("1")  // mint fee
);

await mySBT.connect(owner2Signer).mintSBT(communityId_AAStar);

// Mint SBT 给 Account A/B/C（通过 OWNER2 作为 operator 执行）
// 注意：Simple Account 需要通过 execute 调用
const mintSBTCallData = mySBT.interface.encodeFunctionData("mintSBT", [
  communityId_AAStar
]);

// 通过 OWNER2 签名 UserOp 让 Account A mint SBT
// 这里需要构建完整的 UserOperation（见下方 AOA 测试部分）
```

#### 3.3 Mint xPNTs 给测试账户

```javascript
// aPNTs 合约
const aPNTs = await ethers.getContractAt(
  "xPNTs",
  "0xBD0710596010a157B88cd141d797E8Ad4bb2306b"
);

// Deployer 作为 aPNTs owner mint 给 OWNER2
await aPNTs.connect(deployerSigner).mint(
  OWNER2_ADDRESS,
  ethers.parseEther("1000")
);

// Mint 给 Account A
await aPNTs.connect(deployerSigner).mint(
  ACCOUNT_A,
  ethers.parseEther("1000")
);

// Mint 给 Account B
await aPNTs.connect(deployerSigner).mint(
  ACCOUNT_B,
  ethers.parseEther("1000")
);

// Mint 给 Account C
await aPNTs.connect(deployerSigner).mint(
  ACCOUNT_C,
  ethers.parseEther("1000")
);
```

#### 3.4 验证资产余额

```bash
# 检查 OWNER2 的 GToken 余额
cast call 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc \
  "balanceOf(address)(uint256)" \
  0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA \
  --rpc-url $SEPOLIA_RPC_URL

# 检查 Account A 的 SBT 余额
cast call 0x73E635Fc9eD362b7061495372B6eDFF511D9E18F \
  "balanceOf(address)(uint256)" \
  0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584 \
  --rpc-url $SEPOLIA_RPC_URL

# 检查 Account A 的 aPNTs 余额
cast call 0xBD0710596010a157B88cd141d797E8Ad4bb2306b \
  "balanceOf(address)(uint256)" \
  0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584 \
  --rpc-url $SEPOLIA_RPC_URL
```

---

## 🎯 核心交易流程（Paymaster 验证详解）

### Paymaster 验证流程（Step by Step）

```
用户构建 UserOp
    ↓
EntryPoint.handleOps([userOp])
    ↓
Paymaster.validatePaymasterUserOp()
    ↓
[验证步骤 1-9]
    ↓
EntryPoint 执行 callData（实际交易）
    ↓
Paymaster.postOp()（如有需要）
    ↓
完成
```

#### Step 1: 检查 SBT

```solidity
// Paymaster 验证用户是否持有支持的 SBT
bool hasSBT = false;
address[] memory supportedSBTs = getSupportedSBTs(operator);

for (uint i = 0; i < supportedSBTs.length; i++) {
    if (IERC721(supportedSBTs[i]).balanceOf(userOp.sender) > 0) {
        hasSBT = true;
        break;
    }
}
require(hasSBT, "No valid SBT");
```

#### Step 2: 解析用户指定的 Gas Token

```solidity
// paymasterAndData 格式:
// [paymaster地址(20字节)][xPNTs地址(20字节)][validUntil(6字节)][validAfter(6字节)][signature(动态)]
address userSpecifiedGasToken = address(bytes20(paymasterAndData[20:40]));
```

#### Step 3: 计算 Gas 费用

```solidity
// 从 UserOp 获取 gas limits
uint256 requiredGas = userOp.callGasLimit +
                      userOp.verificationGasLimit +
                      userOp.preVerificationGas;

// 或使用实际消耗（在 postOp 中）
uint256 actualGasUsed = initialGas - gasleft();
```

#### Step 4: 获取 ETH/USD 实时价格（Chainlink）

```solidity
// Chainlink ETH/USD price feed
AggregatorV3Interface priceFeed = AggregatorV3Interface(ETH_USD_PRICE_FEED);
(, int256 price, , ,) = priceFeed.latestRoundData();
uint256 ethUsdPrice = uint256(price);  // 例如 2000_00000000 (8 decimals)
```

#### Step 5: 转换为 aPNTs 成本

```solidity
// 计算 ETH 成本
uint256 ethCost = requiredGas * maxFeePerGas;

// 转换为 USD（Chainlink 返回 8 decimals）
uint256 usdCost = (ethCost * ethUsdPrice) / 1e8;

// 转换为 aPNTs（假设 aPNTs = 0.02 USD，18 decimals）
uint256 aPNTsPriceUSD = 0.02e18;  // 0.02 USD
uint256 aPNTsCost = (usdCost * 1e18) / aPNTsPriceUSD;
```

#### Step 6: 转换为 xPNTs 成本

```solidity
// 获取 operator 设置的汇率（xPNTs : aPNTs）
uint256 exchangeRate = operators[operatorAddress].xPNTsToAPNTsRate;

// 转换为 xPNTs
uint256 xPNTsCost = (aPNTsCost * 1e18) / exchangeRate;  // 如果 1:1，则相等
```

#### Step 7: 检查 xPNTs 余额

```solidity
IERC20 xPNTs = IERC20(userSpecifiedGasToken);
uint256 userBalance = xPNTs.balanceOf(userOp.sender);
require(userBalance >= xPNTsCost, "Insufficient xPNTs balance");
```

#### Step 8: 扣除 Gas Token

**PaymasterV4.1 (AOA 模式):**
```solidity
// 直接从用户账户扣除 xPNTs 到 treasury
bool success = xPNTs.transferFrom(
    userOp.sender,
    treasury,
    xPNTsCost
);
require(success, "xPNTs transfer failed");
```

**SuperPaymasterV2 (AOA+ 模式):**
```solidity
// 1. 从用户账户扣除 xPNTs
xPNTs.transferFrom(userOp.sender, address(this), xPNTsCost);

// 2. 从 operator 内部账户扣除 aPNTs
require(
    operators[operatorAddress].aPNTsBalance >= aPNTsCost,
    "Operator insufficient aPNTs"
);
operators[operatorAddress].aPNTsBalance -= aPNTsCost;

// 3. 记录 operator 消费
operators[operatorAddress].totalSpent += aPNTsCost;

// 4. aPNTs 进入 SuperPaymaster treasury
treasuryAPNTs += aPNTsCost;
```

#### Step 9: 返回验证成功

```solidity
// context: 传递给 postOp 的数据
// validationData: 0 表示验证成功
return (abi.encode(userOp.sender, xPNTsCost), 0);
```

---

## 🧪 测试执行

### 测试 1：AOA 模式（PaymasterV4.1 + bPNTs）

**测试场景：** Simple Account A 向 B 转账 0.5 bPNTs

```javascript
// 1. 构建 callData（转账 0.5 bPNTs）
const bPNTs = await ethers.getContractAt("xPNTs", BPNTS_ADDRESS);
const transferCallData = bPNTs.interface.encodeFunctionData("transfer", [
    ACCOUNT_B,
    ethers.parseEther("0.5")
]);

const accountA = await ethers.getContractAt("SimpleAccount", ACCOUNT_A);
const executeCallData = accountA.interface.encodeFunctionData("execute", [
    BPNTS_ADDRESS,  // dest
    0,              // value
    transferCallData
]);

// 2. 构建 UserOperation
const userOp = {
    sender: ACCOUNT_A,
    nonce: await entryPoint.getNonce(ACCOUNT_A, 0),
    initCode: "0x",  // 已部署，无需 initCode
    callData: executeCallData,
    callGasLimit: 100000,
    verificationGasLimit: 150000,
    preVerificationGas: 21000,
    maxFeePerGas: ethers.parseUnits("10", "gwei"),
    maxPriorityFeePerGas: ethers.parseUnits("1", "gwei"),
    paymasterAndData: ethers.concat([
        PAYMASTER_V4_ADDRESS,         // PaymasterV4.1
        BPNTS_ADDRESS,                // 用户指定 bPNTs
        ethers.zeroPadValue("0x", 6), // validUntil (0 = 无限期)
        ethers.zeroPadValue("0x", 6), // validAfter (0 = 立即生效)
    ]),
    signature: "0x"
};

// 3. 签名 UserOp（OWNER2 签名）
const chainId = (await provider.getNetwork()).chainId;
const userOpHash = await entryPoint.getUserOpHash(userOp);

const domain = {
    name: "SimpleAccount",
    version: "1",
    chainId: chainId,
    verifyingContract: ACCOUNT_A
};

const types = {
    UserOperation: [
        { name: "sender", type: "address" },
        { name: "nonce", type: "uint256" },
        // ... 其他字段
    ]
};

const signature = await owner2Signer.signTypedData(domain, types, userOp);
userOp.signature = signature;

// 4. 提交到 EntryPoint
const tx = await entryPoint.handleOps([userOp], beneficiary);
const receipt = await tx.wait();

console.log("Transaction Hash:", receipt.transactionHash);
```

**验证结果：**

```javascript
// A 的 bPNTs 余额减少（转账 + gas 费）
const aBalanceAfter = await bPNTs.balanceOf(ACCOUNT_A);
const expectedDecrease = ethers.parseEther("0.5") + gasFeeInBPNTs;
assert(aBalanceAfter === aBalanceBefore - expectedDecrease);

// B 的 bPNTs 余额增加
const bBalanceAfter = await bPNTs.balanceOf(ACCOUNT_B);
assert(bBalanceAfter === bBalanceBefore + ethers.parseEther("0.5"));

// PaymasterV4 treasury 收到 gas fee
const treasuryBalance = await bPNTs.balanceOf(PAYMASTER_V4_TREASURY);

// A 的 ETH 余额不变（gasless！）
const aEthAfter = await provider.getBalance(ACCOUNT_A);
assert(aEthAfter === aEthBefore);
```

---

### 测试 2：AOA+ 模式（SuperPaymasterV2 + aPNTs）

**测试场景：** Simple Account A 向 B 转账 0.5 aPNTs

```javascript
// 基本流程与 AOA 模式相同，只需修改 paymasterAndData

userOp.paymasterAndData = ethers.concat([
    SUPER_PAYMASTER_V2_ADDRESS,   // SuperPaymasterV2
    APNTS_ADDRESS,                // 用户指定 aPNTs
    ethers.zeroPadValue("0x", 6),
    ethers.zeroPadValue("0x", 6),
]);

// 其他步骤相同...
```

**额外验证（AOA+ 特有）：**

```javascript
// Operator 内部 aPNTs 余额减少
const operatorInfoBefore = await superPaymasterV2.operators(DEPLOYER_ADDRESS);
const operatorInfoAfter = await superPaymasterV2.operators(DEPLOYER_ADDRESS);

assert(
    operatorInfoAfter.aPNTsBalance < operatorInfoBefore.aPNTsBalance,
    "Operator aPNTs not deducted"
);

// SuperPaymaster treasury 收到 aPNTs
const treasuryAPNTsAfter = await superPaymasterV2.treasuryAPNTs();
assert(treasuryAPNTsAfter > treasuryAPNTsBefore);

// Operator totalSpent 增加
assert(operatorInfoAfter.totalSpent > operatorInfoBefore.totalSpent);
```

---

## 📊 测试检查清单

### ✅ 前置检查（必须全部通过）

- [ ] ABC 账户已部署为 Simple Account 合约
- [ ] GTokenStaking 绑定正确的 GToken 合约
- [ ] SuperPaymasterV2 和 Registry 已配置为 GTokenStaking 的 locker
- [ ] SuperPaymasterV2 最小质押要求 = 30 GT
- [ ] aPNTs 价格 = 0.02 USD
- [ ] MySBT 已注册到 PaymasterV4.1
- [ ] MySBT 已注册到 SuperPaymasterV2（operator 配置）
- [ ] aPNTs 预 approve SuperPaymasterV2
- [ ] bPNTs 预 approve PaymasterV4.1 和 SuperPaymasterV2
- [ ] bPNTs 汇率已设置（PaymasterV4.1）
- [ ] aPNTs 汇率已设置（SuperPaymasterV2 operator）

### ✅ 准备阶段（必须完成）

- [ ] Simple Account A/B/C 已创建并验证
- [ ] AAStar 社区已注册到 Registry
- [ ] BuilderDAO 社区已注册到 Registry
- [ ] aPNTs 已部署并验证
- [ ] bPNTs 已部署并验证
- [ ] OWNER2 拥有 1000 GToken
- [ ] Account A/B/C 各拥有 1000 GToken
- [ ] OWNER2 拥有 SBT
- [ ] Account A/B/C 各拥有 1 个 SBT
- [ ] OWNER2 拥有 1000 aPNTs
- [ ] Account A/B/C 各拥有 1000 aPNTs
- [ ] Account A/B/C 各拥有 1000 bPNTs

### ✅ AOA 测试（PaymasterV4.1）

- [ ] 构建 UserOp 成功
- [ ] OWNER2 签名成功
- [ ] EntryPoint 执行成功
- [ ] Account A bPNTs 余额减少（转账 + gas 费）
- [ ] Account B bPNTs 余额增加（转账金额）
- [ ] PaymasterV4 treasury 收到 gas fee
- [ ] Account A ETH 余额不变（gasless）
- [ ] 事件 UserOperationEvent 正确发出

### ✅ AOA+ 测试（SuperPaymasterV2）

- [ ] 构建 UserOp 成功
- [ ] OWNER2 签名成功
- [ ] EntryPoint 执行成功
- [ ] Account A aPNTs 余额减少（转账 + gas 费）
- [ ] Account B aPNTs 余额增加（转账金额）
- [ ] Operator aPNTs 余额减少
- [ ] SuperPaymaster treasury aPNTs 增加
- [ ] Operator totalSpent 增加
- [ ] Account A ETH 余额不变（gasless）
- [ ] 事件 UserOperationEvent 正确发出

---

## 🔧 脚本组织建议

### 推荐脚本结构

```
scripts/
├── 0-check-deployed-contracts.js      # 前置检查脚本
├── 1-create-simple-accounts.js        # 阶段1：创建 ABC 账户
├── 2-setup-communities-and-xpnts.js   # 阶段2：注册社区和部署 xPNTs
├── 3-mint-assets-to-accounts.js       # 阶段3：mint 资产
├── 4-test-aoa-paymaster.js            # 测试 AOA 模式
├── 5-test-aoa-plus-paymaster.js       # 测试 AOA+ 模式
└── utils/
    ├── userOp.js                      # UserOp 构建工具
    ├── signatures.js                  # 签名工具
    └── validation.js                  # 验证工具
```

---

## 📝 关键要点总结

1. **xPNTs 自动 approve**：工厂部署时已内置，无需用户手动授权

2. **Gas 费计价链**：
   ```
   ETH gas → ETH/USD (Chainlink) → USD → aPNTs (0.02 USD) → xPNTs (operator 汇率)
   ```

3. **两种模式对比**：
   - **AOA**: 用户直接付 xPNTs 给 Paymaster treasury，社区完全自主
   - **AOA+**: 用户付 xPNTs，运营方付 aPNTs，共享基础设施和流动性

4. **Simple Account 特性**：
   - 由 OWNER2 控制（签名）
   - 通过 `execute()` 执行任意调用
   - 兼容 ERC-4337 标准

5. **无需 Bundler**：直接调用 EntryPoint.handleOps()，适合测试环境

6. **SBT 必须性**：所有 gasless 交易必须持有对应社区的 SBT

7. **汇率配置**：
   - PaymasterV4: 每个 xPNTs 单独配置汇率
   - SuperPaymasterV2: 每个 operator 配置其支持的 xPNTs 汇率

---

## 🚨 常见问题排查

### 问题 1: UserOp 验证失败（AA33）

**原因**：用户没有 SBT 或 SBT 未注册到 Paymaster

**解决**：
```bash
# 检查 SBT 余额
cast call 0x73E635Fc9eD362b7061495372B6eDFF511D9E18F \
  "balanceOf(address)(uint256)" \
  $ACCOUNT_A \
  --rpc-url $SEPOLIA_RPC_URL
```

### 问题 2: xPNTs 扣除失败

**原因**：xPNTs 未预 approve Paymaster

**解决**：
```bash
# 检查 autoApprovedSpenders
cast call $XPNTS_ADDRESS \
  "autoApprovedSpenders(uint256)(address)" \
  0 \
  --rpc-url $SEPOLIA_RPC_URL
```

### 问题 3: Operator aPNTs 余额不足

**原因**：SuperPaymasterV2 的 operator 未充值 aPNTs

**解决**：
```javascript
await superPaymasterV2.connect(deployerSigner).depositAPNTs(
  ethers.parseEther("2000")
);
```

---

**文档版本**：v2.0
**最后更新**：2025-11-02
**合约版本**：@aastar/shared-config v0.2.10

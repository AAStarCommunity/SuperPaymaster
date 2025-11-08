# SuperPaymaster 产品架构与部署总览

**更新日期**: 2025-10-30
**网络**: Ethereum Sepolia Testnet
**Chain ID**: 11155111

---

## 1. 产品介绍

### SuperPaymaster 是什么？

SuperPaymaster是一个**去中心化的Gas Payment解决方案**，为ERC-4337账户抽象生态提供灵活、安全的gas支付服务。

### 核心架构

SuperPaymaster采用**双模式架构**，支持两种部署模式：

#### **AOA模式（Asset Oriented Abstraction - 资产导向抽象）**
- 运营者需部署**PaymasterV4合约**
- 每个社区运营自己的独立paymaster
- 使用社区自己的资产（gas token）支付gas费用
- 完全自主控制gas支付逻辑和资产管理
- 适合：需要定制化gas策略和资产管理的大型社区

#### **AOA+模式（增强型共享模式）**
- 使用共享的**SuperPaymasterV2合约**
- 无需部署独立paymaster合约
- 多社区共享基础设施，降低运营成本
- 适合：快速启动的中小型社区

### 共享基础设施

两种模式共用以下核心组件：

1. **Registry合约**（注册中心）
   - 社区注册与身份验证
   - 智能路由算法
   - Reputation计算与评分
   - 节点类型管理（Lite/Standard/Super/Enterprise）

2. **GTokenStaking合约**（质押管理）
   - 处理所有stake操作
   - Lock机制（资金锁定）
   - Slash惩罚机制（阶梯式slashing）
   - Reward分配

3. **Token系统**
   - **MySBT合约**：白板SBT（社区身份凭证）
   - **xPNTsFactory合约**：为每个社区提供gas token mint服务

### 价值主张

- **For Users/dApps**: 无需持有ETH，使用社区积分支付gas
- **For Communities**: 灵活的gas策略，提升用户体验
- **For Ecosystem**: 降低Web3使用门槛，推动大规模采用

---

## 2. 核心合约部署地址

### 2.1 SuperPaymaster V2 系统（AOA+模式）

| 合约名称 | 地址 | 部署日期 | 说明 | Etherscan |
|---------|------|---------|------|-----------|
| **SuperPaymasterV2** | `0x50c4Daf685170aa29513BA6dd89B8417b5b0FE4a` | 2025-10-25 | 共享paymaster，支持多社区 | [查看](https://sepolia.etherscan.io/address/0x50c4Daf685170aa29513BA6dd89B8417b5b0FE4a) |
| **Registry v2.1** | `0x529912C52a934fA02441f9882F50acb9b73A3c5B` | 2025-10-27 | 社区注册中心，支持节点类型 | [查看](https://sepolia.etherscan.io/address/0x529912C52a934fA02441f9882F50acb9b73A3c5B) |
| **GToken** | `0x868F843723a98c6EECC4BF0aF3352C53d5004147` | 2025-10-24 | 治理代币（sGT） | [查看](https://sepolia.etherscan.io/address/0x868F843723a98c6EECC4BF0aF3352C53d5004147) |
| **GTokenStaking** | `0x92eD5b659Eec9D5135686C9369440D71e7958527` | 2025-10-24 | 质押与slash管理 | [查看](https://sepolia.etherscan.io/address/0x92eD5b659Eec9D5135686C9369440D71e7958527) |

**功能概述**:
- SuperPaymasterV2: 处理UserOp验证，gas计算，token扣除
- Registry v2.1: 社区注册，节点类型（Lite/Standard/Super/Enterprise），reputation跟踪
- GToken: 社区治理与质押资产
- GTokenStaking: 30 sGT最低质押，阶梯式slashing（轻度10%，中度30%，重度60%）

### 2.2 PaymasterV4（AOA模式）

| 合约名称 | 地址 | 部署日期 | 说明 | Etherscan |
|---------|------|---------|------|-----------|
| **PaymasterV4** | `0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445` | 2025-10-15 | 独立paymaster，无需链下server | [查看](https://sepolia.etherscan.io/address/0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445) |

**功能概述**:
- 链上gas计算与token扣除
- 支持多种ERC-20 gas token
- 无需维护链下签名服务器
- 完全链上验证逻辑

### 2.3 Token系统

| 合约名称 | 地址 | 部署日期 | 说明 | Etherscan |
|---------|------|---------|------|-----------|
| **xPNTsFactory** | `0xC2AFEA0F736403E7e61D3F7C7c6b4E5E63B5cab6` | 2025-10-30 | 社区gas token工厂（统一架构） | [查看](https://sepolia.etherscan.io/address/0xC2AFEA0F736403E7e61D3F7C7c6b4E5E63B5cab6) |
| **MySBT v2.3** | `0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8` | 2025-10-28 | 白板SBT，社区身份凭证 | [查看](https://sepolia.etherscan.io/address/0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8) |

**功能概述**:
- xPNTsFactory:
  - 为每个社区部署独立的xPNTs gas token
  - 统一aPNTs定价管理（当前 $0.02）
  - 支持6参数部署：(name, symbol, communityName, communityENS, exchangeRate, paymasterAOA)
  - 支持AOA/AOA+双模式
- MySBT v2.3:
  - Soulbound Token（不可转移）
  - 社区成员身份验证
  - 支持metadata更新

### 2.4 DVT/BLS监控系统

| 合约名称 | 地址 | 部署日期 | 说明 | Etherscan |
|---------|------|---------|------|-----------|
| **DVTValidator** | `0x8E03495A45291084A73Cee65B986f34565321fb1` | 2025-10-25 | 分布式验证节点管理 | [查看](https://sepolia.etherscan.io/address/0x8E03495A45291084A73Cee65B986f34565321fb1) |
| **BLSAggregator** | `0xA7df6789218C5a270D6DF033979698CAB7D7b728` | 2025-10-25 | BLS签名聚合验证 | [查看](https://sepolia.etherscan.io/address/0xA7df6789218C5a270D6DF033979698CAB7D7b728) |

**功能概述**:
- DVTValidator: 管理7-13个验证节点，确保去中心化
- BLSAggregator: BLS阈值签名（7/13），slash提案验证

### 2.5 依赖合约（官方）

| 合约名称 | 地址 | 说明 |
|---------|------|------|
| **EntryPoint v0.7** | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | ERC-4337官方EntryPoint（跨链统一地址） |

---

## 3. 合约功能详解

### 3.1 SuperPaymasterV2（AOA+核心）

**核心功能**:
```solidity
// 验证UserOp，扣除aPNTs
function _validatePaymasterUserOp(
    PackedUserOperation calldata userOp,
    bytes32 userOpHash,
    uint256 maxCost
) internal override returns (bytes memory context, uint256 validationData)

// Post-Op处理（必须实现）
function _postOp(
    PostOpMode mode,
    bytes calldata context,
    uint256 actualGasCost,
    uint256 actualUserOpFeePerGas
) internal override
```

**Gas计算流程**:
```
1. gasCostWei = actualGasCost * actualUserOpFeePerGas
2. gasCostUSD = gasCostWei * ETH/USD (Chainlink)
3. aPNTsRequired = gasCostUSD / aPNTsPrice (from xPNTsFactory)
4. xPNTsRequired = aPNTsRequired * exchangeRate (from xPNTsToken)
5. 扣除用户xPNTs余额
```

**关键配置**:
- 支持的token: xPNTs (社区gas token)
- Chainlink价格预言机: ETH/USD feed
- 最低aPNTs余额: 100 aPNTs

### 3.2 Registry v2.1（注册中心）

**核心功能**:
```solidity
// 注册社区
function registerCommunity(
    address communityAddress,
    address paymasterAddress,
    string memory nodeType  // "Lite", "Standard", "Super", "Enterprise"
) external

// 查询社区信息
function getCommunityInfo(address community)
    external view returns (CommunityInfo memory)

// 更新reputation
function updateReputation(address community, int256 delta) external
```

**节点类型与质押要求**:
| 节点类型 | 最低质押(sGT) | Slash比例（轻/中/重） | 适用场景 |
|---------|--------------|---------------------|---------|
| Lite | 30 | 10%/30%/60% | 个人测试，小社区 |
| Standard | 100 | 10%/30%/60% | 中型社区 |
| Super | 500 | 10%/30%/60% | 大型社区 |
| Enterprise | 2000 | 10%/30%/60% | 企业级服务 |

### 3.3 xPNTsFactory（统一架构）

**核心功能**:
```solidity
// 为社区部署xPNTs token
function deployxPNTsToken(
    string memory name,
    string memory symbol,
    string memory communityName,
    string memory communityENS,
    uint256 exchangeRate,      // xPNTs与aPNTs兑换率（默认1:1）
    address paymasterAOA       // AOA模式paymaster地址（AOA+为0x0）
) external returns (address)

// 获取aPNTs价格（统一定价）
function getAPNTsPrice() external view returns (uint256)  // 返回 0.02e18

// 更新aPNTs价格（仅owner）
function updateAPNTsPrice(uint256 newPrice) external onlyOwner
```

**统一定价架构**:
- aPNTs价格由factory统一管理：$0.02 USD
- 所有xPNTs token通过factory查询价格
- 价格可由factory owner动态调整

### 3.4 PaymasterV4（AOA模式）

**核心功能**:
```solidity
// 验证并扣除gas token
function _validatePaymasterUserOp(
    UserOperation calldata userOp,
    bytes32 userOpHash,
    uint256 maxCost
) internal override returns (bytes memory context, uint256 validationData)

// 注册支持的gas token
function addGasToken(address token) external onlyOwner
```

**Gas计算**:
- 从UserOp.paymasterAndData解析token地址
- 计算所需token数量
- 直接从sender扣除token

### 3.5 GTokenStaking（质押与惩罚）

**核心功能**:
```solidity
// 质押sGT
function stake(uint256 amount) external

// 锁定质押（注册时）
function lockStake(address operator, uint256 amount) external

// Slash惩罚
function slash(address operator, uint256 amount) external
```

**阶梯式Slashing**:
- 轻度违规（迟到，偶尔离线）: 10% slash
- 中度违规（频繁离线，签名错误）: 30% slash
- 重度违规（恶意行为，欺诈）: 60% slash

---

## 4. 部署时间线

### Phase 1: V2基础架构（2025-10-24 ~ 2025-10-25）
- [x] GToken部署
- [x] GTokenStaking部署
- [x] SuperPaymasterV2部署
- [x] Registry v2.0部署
- [x] DVTValidator部署
- [x] BLSAggregator部署

### Phase 2: Registry v2.1升级（2025-10-27）
- [x] 新增nodeType字段
- [x] 可配置Slash比例
- [x] 重新部署Registry v2.1

### Phase 3: MySBT v2.3部署（2025-10-28）
- [x] 白板SBT合约
- [x] Metadata管理
- [x] The Graph subgraph部署

### Phase 4: 统一xPNTs架构（2025-10-30）
- [x] xPNTsFactory统一架构
- [x] aPNTs定价管理
- [x] 6参数部署接口
- [x] AOA/AOA+双模式支持

---

## 5. 使用指南

### 5.1 部署xPNTs Token（社区运营者）

**方式1: 使用前端界面**
1. 访问: http://localhost:3001/get-xpnts
2. 连接MetaMask（Sepolia网络）
3. 填写表单：
   - Token Name: "My Community Points"
   - Token Symbol: "MCP"
   - Community Name: "My Community"
   - Community ENS: "mycommunity.eth" (可选)
   - Paymaster Mode: 选择"AOA+"或"AOA"
   - Paymaster Address: (仅AOA模式需要)
   - Exchange Rate: 默认1（1:1兑换）
4. 点击"Deploy xPNTs Token"

**方式2: 使用Foundry脚本**
```bash
forge script script/DeployxPNTsToken.s.sol:DeployxPNTsToken \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### 5.2 注册到Registry

**注册社区（AOA+模式）**:
```bash
cast send $REGISTRY_ADDRESS \
  "registerCommunity(address,address,string)" \
  $COMMUNITY_ADDRESS \
  0x0000000000000000000000000000000000000000 \
  "Standard" \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL
```

**注册社区（AOA模式）**:
```bash
cast send $REGISTRY_ADDRESS \
  "registerCommunity(address,address,string)" \
  $COMMUNITY_ADDRESS \
  $PAYMASTER_V4_ADDRESS \
  "Standard" \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL
```

### 5.3 执行Gasless交易

**UserOp构造（AOA+模式）**:
```typescript
const paymasterAndData = ethers.concat([
  SUPER_PAYMASTER_V2_ADDRESS,           // SuperPaymaster地址
  ethers.zeroPadValue(ethers.toBeHex(200000n), 16),  // validationGasLimit
  ethers.zeroPadValue(ethers.toBeHex(100000n), 16),  // postOpGasLimit
  XPNTS_TOKEN_ADDRESS                   // xPNTs token地址
]);

const userOp = {
  sender: AA_ACCOUNT_ADDRESS,
  nonce: await entryPoint.getNonce(AA_ACCOUNT_ADDRESS, 0),
  callData: callData,
  accountGasLimits: ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(100000n), 16),  // verificationGasLimit
    ethers.zeroPadValue(ethers.toBeHex(500000n), 16),  // callGasLimit
  ]),
  preVerificationGas: 100000n,
  gasFees: ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(1000000000n), 16),  // maxPriorityFee
    ethers.zeroPadValue(ethers.toBeHex(2000000000n), 16),  // maxFeePerGas
  ]),
  paymasterAndData: paymasterAndData,
  signature: "0x"  // 占位符，稍后签名
};
```

---

## 6. 监控与维护

### 6.1 链上数据监控

**查询社区信息**:
```bash
cast call $REGISTRY_ADDRESS \
  "getCommunityInfo(address)" \
  $COMMUNITY_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL
```

**查询质押状态**:
```bash
cast call $GTOKEN_STAKING_ADDRESS \
  "getStakeInfo(address)" \
  $OPERATOR_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL
```

**查询aPNTs价格**:
```bash
cast call $XPNTS_FACTORY_ADDRESS \
  "getAPNTsPrice()" \
  --rpc-url $SEPOLIA_RPC_URL
# 返回: 0x00000000000000000000000000000000000000000000000000470de4df820000
# = 20000000000000000 wei = 0.02 USD
```

### 6.2 The Graph Subgraph

**MySBT查询示例**:
```graphql
query {
  mySBTs(first: 10) {
    id
    owner
    uri
    createdAt
  }

  communities(first: 10) {
    id
    operator
    reputation
    nodeType
    registeredAt
  }
}
```

**Subgraph Endpoint**:
- Studio: https://thegraph.com/studio/subgraph/mysbt-v2-3/

---

## 7. 配置文件说明

### SuperPaymaster/.env
```bash
# V2核心合约
SUPER_PAYMASTER_V2_ADDRESS="0x50c4Daf685170aa29513BA6dd89B8417b5b0FE4a"
REGISTRY_ADDRESS="0x529912C52a934fA02441f9882F50acb9b73A3c5B"
GTOKEN_ADDRESS="0x868F843723a98c6EECC4BF0aF3352C53d5004147"
GTOKEN_STAKING_ADDRESS="0x92eD5b659Eec9D5135686C9369440D71e7958527"

# Token系统
XPNTS_FACTORY_ADDRESS="0xC2AFEA0F736403E7e61D3F7C7c6b4E5E63B5cab6"
MYSBT_ADDRESS="0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8"

# PaymasterV4（AOA模式）
PAYMASTER_V4_ADDRESS="0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445"

# 监控系统
DVT_VALIDATOR_ADDRESS="0x8E03495A45291084A73Cee65B986f34565321fb1"
BLS_AGGREGATOR_ADDRESS="0xA7df6789218C5a270D6DF033979698CAB7D7b728"
```

### registry/.env
```bash
# 前端使用（VITE_前缀）
VITE_XPNTS_FACTORY_ADDRESS="0xC2AFEA0F736403E7e61D3F7C7c6b4E5E63B5cab6"
VITE_REGISTRY_ADDRESS="0x529912C52a934fA02441f9882F50acb9b73A3c5B"
VITE_SUPER_PAYMASTER_V2_ADDRESS="0x50c4Daf685170aa29513BA6dd89B8417b5b0FE4a"
VITE_MYSBT_ADDRESS="0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8"
```

---

## 8. 相关文档

### 核心文档
- [CLAUDE.md](./CLAUDE.md) - 开发者指南
- [DEPLOYMENT_READY.md](./DEPLOYMENT_READY.md) - 部署准备清单
- [SEPOLIA_DEPLOYMENT_REPORT.md](./SEPOLIA_DEPLOYMENT_REPORT.md) - Sepolia部署报告
- [Changes.md](./Changes.md) - 完整开发历史

### 技术文档
- [V2_CONTRACT_DEPENDENCIES_AND_MOCK_ANALYSIS.md](./docs/V2_CONTRACT_DEPENDENCIES_AND_MOCK_ANALYSIS.md)
- [V2-TEST-GUIDE.md](./docs/V2-TEST-GUIDE.md)
- [MYSBT-FEE-EXPLANATION.md](./docs/MYSBT-FEE-EXPLANATION.md)

### 部署指南
- [DEPLOYMENT_GUIDE_UNIFIED_XPNTS.md](./DEPLOYMENT_GUIDE_UNIFIED_XPNTS.md)
- [Registry v2.1部署](./docs/changes-2025-10-27.md)

---

## 9. 测试状态

### 本地测试
- ✅ 149/149 测试通过
- ✅ PaymasterV4_1: 10/10
- ✅ xPNTs相关: 3/3
- ✅ aPNTs相关: 1/1
- ✅ SuperPaymaster V2: 15/15
- ✅ MySBT v2.3: verifyCommunityMembership修复

### Sepolia测试网
- ✅ 所有合约部署成功
- ✅ xPNTsFactory功能验证通过
- ✅ getAPNTsPrice() = $0.02 ✅
- 🔄 端到端测试进行中

---

## 10. 社区与支持

**GitHub**: https://github.com/AAStarCommunity/SuperPaymaster
**Documentation**: https://docs.aastar.io
**Frontend**: http://localhost:3001 (开发环境)

**联系方式**:
- 技术问题: GitHub Issues
- 合作咨询: team@aastar.io

---

**最后更新**: 2025-10-30
**维护者**: AAStarCommunity Core Team
**许可证**: MIT

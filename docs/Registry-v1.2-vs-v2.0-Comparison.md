# Registry v1.2 vs v2.0 核心对比与合并方案

## 核心区别总结

| 维度 | Registry v1.2 | Registry v2.0 |
|------|--------------|---------------|
| **质押资产** | ETH（原生代币） | stGToken（Lido-style份额） |
| **数据模型** | Paymaster-centric | Community-centric |
| **元数据** | 最小（名称+费率） | 丰富（社交/Token/描述） |
| **模式支持** | 单一Paymaster | AOA/Super双模式 |
| **质押管理** | 内置（ETH转账） | 外部（GTokenStaking锁定） |
| **Slash机制** | 简单（百分比扣减） | 复杂（失败计数+自动触发） |
| **竞价系统** | ✅ 支持bidding | ❌ 不支持 |

---

## 详细功能对比

### 1️⃣ 数据结构

#### v1.2: PaymasterInfo（10字段）
```solidity
struct PaymasterInfo {
    address paymasterAddress;
    string name;               // ✅ 名称
    uint256 feeRate;          // ✅ 费率（basis points）
    uint256 stakedAmount;     // ✅ ETH质押量
    uint256 reputation;       // ✅ 声誉分数
    bool isActive;
    uint256 successCount;     // ✅ 成功次数
    uint256 totalAttempts;    // ✅ 总尝试次数
    uint256 registeredAt;
    uint256 lastActiveAt;
}
```

#### v2.0: CommunityProfile（17字段）
```solidity
struct CommunityProfile {
    string name;
    string ensName;           // ✅ ENS域名
    string description;       // ✅ 描述
    string website;           // ✅ 网站
    string logoURI;           // ✅ Logo
    string twitterHandle;     // ✅ Twitter
    string githubOrg;         // ✅ GitHub
    string telegramGroup;     // ✅ Telegram
    address xPNTsToken;       // ✅ 社区积分
    address[] supportedSBTs;  // ✅ SBT列表
    PaymasterMode mode;       // ✅ AOA/Super模式
    address paymasterAddress;
    address community;        // ✅ 管理员地址
    uint256 registeredAt;
    uint256 lastUpdatedAt;
    bool isActive;
    uint256 memberCount;      // ✅ 成员数
}
```

### 2️⃣ 质押机制

| 特性 | v1.2 | v2.0 |
|------|------|------|
| **质押资产** | ETH（msg.value） | stGToken（外部锁定） |
| **转账方式** | `payable` + ETH转账 | `GTokenStaking.lockStake()` |
| **可组合性** | ❌ 不可组合 | ✅ 可多重锁定 |
| **Gas成本** | 低（简单转账） | 中（调用外部合约） |

```solidity
// v1.2: 直接转账ETH
function registerPaymaster(string calldata _name, uint256 _feeRate)
    external payable
{
    require(msg.value >= minStakeAmount);
    paymasters[msg.sender].stakedAmount = msg.value;
}

// v2.0: 锁定stGToken份额
function registerCommunity(CommunityProfile memory profile, uint256 stGTokenAmount)
    external
{
    GTOKEN_STAKING.lockStake(msg.sender, stGTokenAmount, "registration");
}
```

### 3️⃣ Slash机制

| 特性 | v1.2 | v2.0 |
|------|------|------|
| **触发方式** | 手动（owner调用） | 自动（失败计数达阈值） |
| **Slash比例** | 可配置（治理调整） | 固定10% |
| **失败跟踪** | ❌ 不跟踪 | ✅ failureCount + threshold |
| **资产处理** | 转给Treasury | 通过GTokenStaking.slash() |

### 4️⃣ 特有功能

#### v1.2独有
- ✅ **竞价系统**（Bidding）：`placeBid()` + `getLowestBidPaymaster()`
- ✅ **声誉分数**：reputation字段（0-10000）
- ✅ **成功率统计**：successCount / totalAttempts
- ✅ **费率存储**：feeRate字段

#### v2.0独有
- ✅ **丰富元数据**：社交链接、Logo、描述
- ✅ **ENS集成**：ensName字段
- ✅ **Token绑定**：xPNTsToken（社区积分）
- ✅ **SBT支持**：supportedSBTs数组
- ✅ **模式区分**：AOA（30 GT）vs Super（50 GT）
- ✅ **自动Slash**：失败计数自动触发

---

## 合并方案：Registry v3.0

### 设计原则

1. **向后兼容**：支持v1.2和v2.0的所有数据查询
2. **灵活质押**：同时支持ETH和stGToken
3. **最佳特性**：保留两个版本的优点
4. **可扩展**：为未来的节点类型预留空间

### 架构设计

```solidity
contract RegistryV3 {
    // 1️⃣ 统一数据模型（兼容v1.2 + v2.0）
    struct NodeInfo {
        // v1.2字段
        string name;
        uint256 feeRate;
        uint256 reputation;
        uint256 successCount;
        uint256 totalAttempts;

        // v2.0字段
        string ensName;
        string description;
        string website;
        string logoURI;
        SocialLinks social;        // 打包社交链接
        address xPNTsToken;
        address[] supportedSBTs;
        NodeType nodeType;         // 扩展：支持多节点类型

        // 共有字段
        address nodeAddress;
        address owner;
        bool isActive;
        uint256 registeredAt;
        uint256 lastUpdatedAt;
    }

    struct SocialLinks {
        string twitter;
        string github;
        string telegram;
    }

    // 2️⃣ 灵活质押系统
    enum StakeType { ETH, STGTOKEN }

    struct StakeInfo {
        StakeType stakeType;
        uint256 amount;
        address stakeContract;  // v2.0: GTokenStaking address
    }

    mapping(address => StakeInfo) public stakes;

    // 3️⃣ 双模式注册
    function registerWithETH(NodeInfo memory info)
        external payable
    {
        // v1.2兼容路径
    }

    function registerWithStGToken(NodeInfo memory info, uint256 amount)
        external
    {
        // v2.0兼容路径
    }

    // 4️⃣ 竞价系统（保留v1.2特性）
    mapping(address => Bid) public bids;

    // 5️⃣ 自动Slash（采用v2.0机制）
    mapping(address => FailureTracker) public failures;
}
```

### 数据迁移策略

```solidity
// 从v1.2迁移
function migrateFromV1(address[] calldata v1Nodes) external onlyOwner {
    for (uint i = 0; i < v1Nodes.length; i++) {
        // 1. 读取v1.2数据
        PaymasterInfo memory v1Info = registryV1.getPaymasterFullInfo(v1Nodes[i]);

        // 2. 转换为v3格式
        NodeInfo memory v3Info = NodeInfo({
            name: v1Info.name,
            feeRate: v1Info.feeRate,
            reputation: v1Info.reputation,
            // ... 其他字段默认值
            nodeType: NodeType.PAYMASTER_V1
        });

        // 3. 记录质押类型为ETH
        stakes[v1Nodes[i]] = StakeInfo({
            stakeType: StakeType.ETH,
            amount: v1Info.stakedAmount,
            stakeContract: address(0)
        });

        nodes[v1Nodes[i]] = v3Info;
    }
}

// 从v2.0迁移
function migrateFromV2(address[] calldata v2Communities) external onlyOwner {
    for (uint i = 0; i < v2Communities.length; i++) {
        // 1. 读取v2.0数据
        CommunityProfile memory v2Profile = registryV2.getCommunityProfile(v2Communities[i]);

        // 2. 转换为v3格式
        NodeInfo memory v3Info = NodeInfo({
            name: v2Profile.name,
            ensName: v2Profile.ensName,
            description: v2Profile.description,
            // ... 复制所有字段
            nodeType: v2Profile.mode == 0 ? NodeType.PAYMASTER_AOA : NodeType.PAYMASTER_SUPER
        });

        // 3. 记录质押类型为stGToken
        stakes[v2Communities[i]] = StakeInfo({
            stakeType: StakeType.STGTOKEN,
            amount: communityStakes[v2Communities[i]].stGTokenLocked,
            stakeContract: address(GTOKEN_STAKING)
        });

        nodes[v2Communities[i]] = v3Info;
    }
}
```

### 兼容性API

```solidity
// v1.2兼容接口
function getPaymasterFullInfo(address paymaster)
    external view
    returns (PaymasterInfo memory)
{
    NodeInfo memory node = nodes[paymaster];
    return PaymasterInfo({
        paymasterAddress: node.nodeAddress,
        name: node.name,
        feeRate: node.feeRate,
        stakedAmount: stakes[paymaster].amount,
        reputation: node.reputation,
        isActive: node.isActive,
        successCount: node.successCount,
        totalAttempts: node.totalAttempts,
        registeredAt: node.registeredAt,
        lastActiveAt: node.lastUpdatedAt
    });
}

// v2.0兼容接口
function getCommunityProfile(address community)
    external view
    returns (CommunityProfile memory)
{
    NodeInfo memory node = nodes[community];
    return CommunityProfile({
        name: node.name,
        ensName: node.ensName,
        description: node.description,
        website: node.website,
        // ... 映射所有字段
    });
}
```

---

## 优劣分析

### 保持两个版本（当前方案）

**优点**：
- ✅ 清晰分离（Paymaster vs Community）
- ✅ 各自优化（不同用例）
- ✅ 风险隔离（一个版本bug不影响另一个）

**缺点**：
- ❌ 维护成本高（两套代码）
- ❌ 前端复杂（需支持两种API）
- ❌ 用户困惑（选哪个版本？）

### 合并为v3.0

**优点**：
- ✅ 统一入口
- ✅ 功能最全（两个版本的并集）
- ✅ 降低维护成本

**缺点**：
- ❌ 合约复杂度高
- ❌ Gas成本上升（更多存储）
- ❌ 迁移工作量大
- ❌ 测试成本高

---

## 推荐方案

### 短期（3个月内）：保持现状 + 改进前端

1. **不合并合约**：两个版本继续独立
2. **统一前端API**：创建适配层
   ```typescript
   // src/adapters/RegistryAdapter.ts
   class UnifiedRegistryAdapter {
     async getNode(address: string) {
       if (this.version === 'v1.2') {
         return this.adaptV1ToCommon(await v1.getPaymasterFullInfo(address));
       } else {
         return this.adaptV2ToCommon(await v2.getCommunityProfile(address));
       }
     }
   }
   ```
3. **文档说明**：清晰的版本选择指南

### 中期（6个月内）：推荐v2.0为默认

1. **新用户默认v2.0**
2. **v1.2进入维护模式**（只修bug，不加新功能）
3. **迁移工具**：提供v1.2→v2.0迁移脚本

### 长期（1年后）：评估是否需要v3.0

根据实际使用情况决定：
- 如果v2.0满足需求 → 废弃v1.2
- 如果需要validator/oracle等节点 → 开发v3.0（采用多节点类型方案）

---

## 立即行动项

1. ✅ 修复RegistryExplorer（已完成）
2. 📝 创建版本选择指南（新增文档）
3. 🔧 改进前端适配层
4. 📊 收集用户反馈

---

**建议**：**不立即合并**，先优化前端体验，观察6个月后再决定。

**原因**：
1. v1.2和v2.0设计哲学不同（Paymaster vs Community）
2. 合并会增加复杂度和Gas成本
3. 当前最大问题是前端显示不一致（已修复）
4. 未来如需支持多节点类型，直接开发RegistryV3（采用docs/Registry-Analysis.md方案）

---

**日期**: 2025-01-26
**结论**: 保持两个版本，优化前端兼容性

# SuperPaymaster v2.0 架构概览

## 系统架构图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          用户层 (User Layer)                             │
├─────────────────────────────────────────────────────────────────────────┤
│  EOA Wallet  │  Smart Wallet  │  Community Members  │  Operators        │
└────────┬─────────────┬─────────────────┬──────────────────┬─────────────┘
         │             │                 │                  │
         v             v                 v                  v
┌─────────────────────────────────────────────────────────────────────────┐
│                        Registry.sol (路由层)                             │
├─────────────────────────────────────────────────────────────────────────┤
│  - 社区信息存储 (CommunityProfile)                                       │
│  - 模式路由 (INDEPENDENT / SUPER)                                        │
│  - SBT验证 & 社区成员查询                                                │
│  - ENS域名索引                                                          │
└────────┬────────────────────┬───────────────────────────────────────────┘
         │                    │
         v                    v
┌──────────────────┐   ┌────────────────────────────────────────────────┐
│  Traditional     │   │      SuperPaymaster v2.0 (核心层)              │
│  Paymaster       │   ├────────────────────────────────────────────────┤
│  (独立部署)      │   │  - 多账户管理 (OperatorAccount[])              │
│                  │   │  - IPaymaster 接口实现                         │
│  - 独立EntryPoint │   │  - aPNTs 余额追踪                             │
│  - 自己的Stake    │   │  - 声誉系统 (Fibonacci)                       │
│  - 完全自主       │   │  - Slash执行                                  │
└──────────────────┘   └────────┬──────────┬──────────────┬──────────────┘
                                │          │              │
         ┌──────────────────────┘          │              └──────────────┐
         v                                 v                             v
┌─────────────────────┐     ┌──────────────────────┐    ┌───────────────────┐
│  GTokenStaking.sol  │     │   xPNTsFactory.sol   │    │    MySBT.sol      │
├─────────────────────┤     ├──────────────────────┤    ├───────────────────┤
│  - GToken → sGToken │     │  - 部署xPNTs合约     │    │  - 社区身份SBT    │
│  - Slash感知份额    │     │  - AI预测建议金额    │    │  - 不可转移       │
│  - 30 GT最低质押    │     │  - 预授权机制        │    │  - 声誉追踪       │
│  - 解质押7天锁定    │     │  - Permit签名支持    │    │  - 社区活跃度     │
└─────────────────────┘     └──────────────────────┘    └───────────────────┘
         │
         │ (Slash触发)
         v
┌─────────────────────────────────────────────────────────────────────────┐
│                   监控与惩罚层 (Monitoring Layer)                        │
├─────────────────────────────────────────────────────────────────────────┤
│  DVTValidator.sol (13个节点)    │    BLSAggregator.sol (7/13签名)      │
│  - 每小时检查aPNTs余额           │    - BLS签名聚合                     │
│  - 提交验证记录                  │    - 阈值验证 (7/13)                │
│  - 链下分布式验证                │    - 执行Slash                       │
└─────────────────────────────────────────────────────────────────────────┘
```

## 三种运营模式对比

| 特性 | Mode 1: Traditional | Mode 2: Super | Mode 3: Hybrid |
|------|-------------------|---------------|----------------|
| **合约部署** | 独立Paymaster合约 | 无需部署 | 独立Paymaster + SuperPaymaster |
| **启动时间** | 7步骤 (~15分钟) | 3秒注册 | 灵活切换 |
| **Stake要求** | 独立Stake到EntryPoint | 无需Stake (SuperPaymaster统一质押) | 可选独立或共享 |
| **aPNTs余额** | 自己管理 | SuperPaymaster管理 | 双账户并行 |
| **Gas成本** | 部署 + 每次操作 | 仅注册Gas | 优化混合 |
| **灵活性** | 完全自主控制 | 依赖SuperPaymaster | 最大灵活性 |
| **适用场景** | 大型社区/DAO | 小型社区/快速测试 | 成长型社区 |
| **升级路径** | 无法升级到Super | 可升级到Traditional | 双向切换 |

## 数据存储层设计

### Registry.sol - 社区元信息中心

```solidity
struct CommunityProfile {
    // 基本信息
    string name;                    // 社区名称
    string ensName;                 // ENS域名
    string description;             // 社区描述
    string website;                 // 官网
    string logoURI;                 // Logo URI

    // 社交链接
    string twitterHandle;           // Twitter账号
    string githubOrg;               // GitHub组织
    string telegramGroup;           // Telegram群组

    // Token & SBT
    address xPNTsToken;             // 社区积分Token地址
    address[] supportedSBTs;        // 支持的SBT列表

    // Paymaster配置
    PaymasterMode mode;             // INDEPENDENT / SUPER
    address paymasterAddress;       // Paymaster地址 (Traditional模式) 或 SuperPaymaster地址
    address community;              // 社区管理地址

    // 元数据
    uint256 registeredAt;           // 注册时间
    uint256 lastUpdatedAt;          // 最后更新时间
    bool isActive;                  // 是否激活
    uint256 memberCount;            // 成员数量
}

// 多索引查询
mapping(address => CommunityProfile) public communities;        // 主键查询
mapping(string => address) public communityByName;             // 名称查询
mapping(string => address) public communityByENS;              // ENS查询
mapping(address => address) public communityBySBT;             // 通过SBT反查社区
```

### SuperPaymaster v2.0 - 运营数据中心

```solidity
struct OperatorAccount {
    // 质押信息
    uint256 sGTokenLocked;          // 锁定的sGToken数量
    uint256 stakedAt;               // 质押时间

    // 运营余额
    uint256 aPNTsBalance;           // 当前aPNTs余额
    uint256 totalSpent;             // 累计消耗
    uint256 lastRefillTime;         // 最后充值时间

    // 社区配置
    address[] supportedSBTs;        // 支持的SBT列表
    address xPNTsToken;             // 社区积分Token

    // 声誉系统
    uint256 reputationScore;        // 声誉分数 (Fibonacci序列)
    uint256 consecutiveDays;        // 连续运营天数
    uint256 totalTxSponsored;       // 赞助交易总数

    // 监控状态
    uint256 lastCheckTime;          // 最后检查时间
    bool isPaused;                  // 是否暂停
    SlashRecord[] slashHistory;     // 惩罚历史
}
```

### MySBT.sol - 用户身份与活跃度

```solidity
struct UserProfile {
    uint256[] ownedSBTs;            // 拥有的SBT列表
    uint256 reputationScore;        // 用户声誉
    string ensName;                 // 用户ENS
    mapping(address => CommunityData) communities;  // 多社区数据
}

struct CommunityData {
    address community;              // 所属社区 (不是operator!)
    uint256 txCount;                // 该社区内交易数
    uint256 joinedAt;               // 加入时间
    uint256 lastActiveTime;         // 最后活跃时间
    uint256 contributionScore;      // 贡献分
}
```

## 安全机制

### 1. DVT + BLS 分布式监控

**架构**:
- 13个独立DVT验证节点
- 每小时检查一次aPNTs余额
- 需要7/13签名才能执行Slash

**流程**:
```
Hour 0: Operator aPNTs余额 = 100 aPNTs (正常)
Hour 1: 余额降至 50 aPNTs (< 100最低要求)
  → DVT节点检测到 → 广播警告
  → 达不到7/13共识 → 仅警告，声誉-10

Hour 2: 余额仍然 50 aPNTs
  → 7个节点达成共识 → BLS聚合签名
  → 执行Slash: 5% sGToken被扣除
  → 声誉-20

Hour 3: 余额仍然 50 aPNTs
  → 7个节点再次共识 → BLS签名
  → 执行Slash: 10% sGToken被扣除
  → 账户暂停 (isPaused = true)
  → 声誉-50
```

### 2. Fibonacci声誉等级

```
Level 1:  1 GT  (新手)
Level 2:  1 GT
Level 3:  2 GT
Level 4:  3 GT
Level 5:  5 GT
Level 6:  8 GT
Level 7:  13 GT
Level 8:  21 GT
Level 9:  34 GT
Level 10: 55 GT
Level 11: 89 GT
Level 12: 144 GT (大师)
```

**升级条件**:
- 连续30天无Slash
- 赞助至少1000笔交易
- aPNTs余额充足率 > 150%

### 3. xPNTs预授权机制

**问题**: 用户每次使用xPNTs兑换aPNTs需要approve()

**方案**: Override allowance() 函数

```solidity
mapping(address => bool) public autoApprovedSpenders;

function allowance(address owner, address spender) public view override returns (uint256) {
    if (autoApprovedSpenders[spender]) {
        return type(uint256).max;  // 无限授权
    }
    return super.allowance(owner, spender);
}
```

**受信任合约**:
- SuperPaymaster v2.0
- xPNTsFactory
- MySBT (用于mint费用)

## 开发路线图

### Phase 1: 核心合约 (2周)
- [ ] SuperPaymaster v2.0核心逻辑
- [ ] GTokenStaking质押机制
- [ ] Registry社区信息存储
- [ ] 基础测试覆盖

### Phase 2: 代币与身份 (6周)
- [ ] xPNTsFactory + AI预测
- [ ] MySBT非转让逻辑
- [ ] 预授权机制
- [ ] 声誉系统实现

### Phase 3: 监控与惩罚 (4周)
- [ ] DVTValidator节点逻辑
- [ ] BLS签名聚合
- [ ] 三级Slash时间线
- [ ] 链下监控服务

### Phase 4: 集成与测试 (2周)
- [ ] Frontend集成
- [ ] E2E测试
- [ ] 文档完善
- [ ] 安全审计准备

## 总结

SuperPaymaster v2.0 通过以下创新实现了运营效率与安全的平衡：

1. **Registry作为元信息中心**: 所有社区的基本信息、社交链接、ENS域名集中存储，避免数据冗余
2. **SuperPaymaster作为运营中心**: 专注于运营数据（余额、声誉、Slash历史），与Registry解耦
3. **三种模式并存**: Traditional、Super、Hybrid满足不同规模社区需求
4. **DVT + BLS安全保障**: 去中心化监控 + 阈值签名防止单点作恶
5. **xPNTs预授权**: 优化用户体验，减少Gas消耗
6. **Fibonacci声誉系统**: 指数级难度增长，激励长期稳定运营

---

**文档版本**: v2.0.0
**最后更新**: 2025-10-22
**作者**: SuperPaymaster Team
**状态**: 架构设计阶段

  SuperPaymaster 核心合约体系架构文档

  一、核心合约列表 (7个主要合约)

  1. GToken (治理代币)

  - 版本: v2.0.0
  - 地址: 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc
  - 类型: ERC20 with Cap + Ownable
  - 作用: 系统治理代币，支持质押、铸造

  2. GTokenStaking (质押合约)

  - 版本: v2.0.1
  - 地址: 0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0
  - 类型: Staking + Lock + Slash 机制
  - 作用: GToken 质押、锁定、惩罚系统
  - 新功能: stakeFor() - 为其他用户质押
  - API变更: 使用 balanceOf() 替代 stakedBalance()

  3. Registry (社区注册中心)

  - 版本: v2.1.4
  - 地址: 0xf384c592D5258c91805128291c5D4c069DD30CA6
  - 类型: Community Registry + Slash System
  - 作用: 社区注册、节点管理、惩罚机制

  4. MySBT (灵魂绑定代币)

  - 版本: v2.4.3
  - 地址: 0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C
  - 类型: ERC721 (Soulbound) + Reputation
  - 作用: 用户身份、社区会员、声誉系统
  - 新功能: mintWithAutoStake() - 单次交易完成质押+铸造
  - 优化: 代码精简至 509 行,合约大小 24,395 bytes (在 24KB 限制内)
  - 测试社区: Mycelium (0x411BD567E46C0781248dbB6a9211891C032885e5)

  5. SuperPaymasterV2 (AOA+ 模式 Paymaster)

  - 版本: v2.0.0
  - 地址: 0x95B20d8FdF173a1190ff71e41024991B2c5e58eF
  - 类型: ERC-4337 Paymaster + Multi-operator
  - 作用: AOA+ 模式共享 Paymaster，aPNTs 支付

  6. PaymasterFactory (Paymaster 工厂)

  - 版本: v1.0.0
  - 地址: 0x65Cf6C4ab3d40f3C919b6F3CADC09Efb72817920
  - 类型: EIP-1167 Minimal Proxy Factory
  - 作用: 部署 AOA 模式独立 Paymaster

  7. xPNTsFactory (xPNTs Token 工厂)

  - 版本: v2.0.0
  - 地址: 0x9dD72cB42427fC9F7Bf0c949DB7def51ef29D6Bd
  - 类型: Token Factory
  - 作用: 为社区部署自定义 xPNTs Token

  ---
  二、核心数据结构

  1. Registry 核心数据结构

  // 社区档案 (11 字段)
  struct CommunityProfile {
      string name;                    // 社区名称
      string ensName;                 // ENS 域名
      address xPNTsToken;             // 社区 xPNTs 代币地址
      address[] supportedSBTs;        // 支持的 SBT 列表
      NodeType nodeType;              // 节点类型 (AOA/SUPER/ANODE/KMS)
      address paymasterAddress;       // Paymaster 地址
      address community;              // 社区所有者地址
      uint256 registeredAt;           // 注册时间
      uint256 lastUpdatedAt;          // 最后更新时间
      bool isActive;                  // 是否激活
      bool allowPermissionlessMint;   // 是否允许无权限铸造
  }

  // 社区质押状态
  struct CommunityStake {
      uint256 stGTokenLocked;         // 锁定的 stGToken 数量
      uint256 failureCount;           // 失败次数
      uint256 lastFailureTime;        // 最后失败时间
      uint256 totalSlashed;           // 总惩罚金额
      bool isActive;                  // 是否激活
  }

  // 节点类型枚举
  enum NodeType {
      PAYMASTER_AOA,    // 独立 Paymaster (AOA 模式)
      PAYMASTER_SUPER,  // 共享 Paymaster (AOA+ 模式)
      ANODE,            // 社区计算节点
      KMS               // 密钥管理服务
  }

  // 节点类型配置
  struct NodeTypeConfig {
      uint256 minStake;        // 最低质押要求
      uint256 slashThreshold;  // 惩罚阈值
      uint256 slashBase;       // 基础惩罚
      uint256 slashIncrement;  // 惩罚增量 (Fibonacci)
      uint256 slashMax;        // 最大惩罚
  }

  2. GTokenStaking 核心数据结构

  // 质押信息
  struct StakeInfo {
      uint256 amount;                  // 质押数量
      uint256 stGTokenShares;          // stGToken 份额
      uint256 slashedAmount;           // 被惩罚金额
      uint256 stakedAt;                // 质押时间
      uint256 unstakeRequestedAt;      // 解除质押请求时间
  }

  // 锁定信息
  struct LockInfo {
      uint256 amount;          // 锁定数量
      uint256 lockedAt;        // 锁定时间
      string purpose;          // 锁定目的
      address beneficiary;     // 受益人
  }

  // Locker 配置 (用于 Registry 等合约锁定 stake)
  struct LockerConfig {
      bool authorized;             // 是否授权
      uint256 feeRateBps;          // 费率 (基点)
      uint256 minExitFee;          // 最低退出费
      uint256 maxFeePercent;       // 最大费用百分比
      uint256[] timeTiers;         // 时间层级
      uint256[] tierFees;          // 层级费用
      address feeRecipient;        // 费用接收地址
  }

  3. MySBT 核心数据结构

  // SBT 数据
  struct SBTData {
      address holder;             // 持有者
      address firstCommunity;     // 首个加入的社区
      uint256 mintedAt;           // 铸造时间
      uint256 totalCommunities;   // 加入的社区总数
  }

  // 社区会员资格
  struct CommunityMembership {
      address community;          // 社区地址
      uint256 joinedAt;           // 加入时间
      uint256 lastActiveTime;     // 最后活跃时间
      bool isActive;              // 是否激活
      string metadata;            // 元数据
  }

  // NFT 绑定 (用于头像)
  struct NFTBinding {
      address nftContract;        // NFT 合约地址
      uint256 nftTokenId;         // NFT Token ID
      uint256 bindTime;           // 绑定时间
      bool isActive;              // 是否激活
  }

  4. SuperPaymasterV2 核心数据结构

  // 运营商账户数据 (AOA+ 模式)
  struct OperatorAccount {
      uint256 stGTokenLocked;         // 锁定的 stGToken
      uint256 stakedAt;               // 质押时间
      uint256 aPNTsBalance;           // aPNTs 余额
      uint256 totalSpent;             // 总消费
      uint256 lastRefillTime;         // 最后充值时间
      uint256 minBalanceThreshold;    // 最低余额阈值
      address xPNTsToken;             // xPNTs Token 地址
      address treasury;               // 财务地址
      uint256 exchangeRate;           // 兑换率
      uint256 reputationScore;        // 声誉分数
      uint256 consecutiveDays;        // 连续活跃天数
      uint256 totalTxSponsored;       // 赞助交易总数
      uint256 reputationLevel;        // 声誉等级
      uint256 lastCheckTime;          // 最后检查时间
      bool isPaused;                  // 是否暂停
  }

  ---
  三、合约依赖关系图

  Constructor 依赖链

  graph TB
      GToken[GToken<br/>cap_: uint256]

      GTokenStaking[GTokenStaking<br/>_gtoken: address]
      GToken --> GTokenStaking

      Registry[Registry<br/>_gtokenStaking: address]
      GTokenStaking --> Registry

      MySBT[MySBT<br/>_gtoken: address<br/>_staking: address<br/>_registry: address<br/>_dao: address]
      GToken --> MySBT
      GTokenStaking --> MySBT
      Registry --> MySBT

      SuperPaymasterV2[SuperPaymasterV2<br/>_gtokenStaking: address<br/>_registry: address<br/>_ethUsdPriceFeed: address]
      GTokenStaking --> SuperPaymasterV2
      Registry --> SuperPaymasterV2

      xPNTsFactory[xPNTsFactory<br/>_superPaymaster: address<br/>_registry: address]
      SuperPaymasterV2 --> xPNTsFactory
      Registry --> xPNTsFactory

      PaymasterFactory[PaymasterFactory<br/>无依赖]

  核心依赖说明：

  1. GToken → 基础层，无依赖
  2. GTokenStaking → 依赖 GToken
  3. Registry → 依赖 GTokenStaking
  4. MySBT → 依赖 GToken, GTokenStaking, Registry, DAO
  5. SuperPaymasterV2 → 依赖 GTokenStaking, Registry, Chainlink PriceFeed
  6. xPNTsFactory → 依赖 SuperPaymasterV2, Registry
  7. PaymasterFactory → 无依赖（独立工厂）

  ---
  四、存储关系矩阵

  | 合约               | 存储 GToken   | 存储 Staking  | 存储 Registry | 存储 MySBT | 存储 SuperPM  | 存储 PriceFeed |
  |------------------|-------------|-------------|-------------|----------|-------------|--------------|
  | GToken           | -           | ❌           | ❌           | ❌        | ❌           | ❌            |
  | GTokenStaking    | ✅ immutable | -           | ❌           | ❌        | ❌           | ❌            |
  | Registry         | ❌           | ✅ immutable | -           | ❌        | ✅ mutable   | ❌            |
  | MySBT            | ✅ immutable | ✅ immutable | ✅ immutable | -        | ❌           | ❌            |
  | SuperPaymasterV2 | ❌           | ✅ immutable | ✅ immutable | ❌        | -           | ✅ immutable  |
  | xPNTsFactory     | ❌           | ❌           | ✅ immutable | ❌        | ✅ immutable | ❌            |
  | PaymasterFactory | ❌           | ❌           | ❌           | ❌        | ❌           | ❌            |

  ---
  五、数据流关系

  1. 社区注册流程

  用户 → Registry.registerCommunity()
    ├── 验证 GTokenStaking.balanceOf() >= minStake
    ├── GTokenStaking.lockStake() 锁定质押
    ├── 存储 CommunityProfile
    └── 发出 CommunityRegistered 事件

  2. AOA 模式 (独立 Paymaster) 部署

  社区运营商 → PaymasterFactory.deployPaymaster()
    ├── EIP-1167 Minimal Proxy 部署
    ├── 初始化 Paymaster (xPNTsToken, mySBT, treasury, fee)
    ├── 记录 operator → paymaster 映射
    └── 返回 paymaster 地址

  3. AOA+ 模式 (SuperPaymaster) 运营商加入

  运营商 → SuperPaymasterV2.depositAPNTs()
    ├── 验证 Registry.isRegisteredCommunity()
    ├── 验证 GTokenStaking.balanceOf() >= minStake
    ├── GTokenStaking.lockStake()
    ├── 转移 aPNTs 到合约
    ├── 创建 OperatorAccount
    └── 发出 OperatorJoined 事件

  4. SBT 铸造与社区加入

  用户 → MySBT.userMint(community)
    ├── 验证 Registry.isRegisteredCommunity(community)
    ├── 验证 Registry.isPermissionlessMintAllowed() 或 community 授权
    ├── GTokenStaking.lockStake() 锁定 minLockAmount
    ├── 铸造 SBT 或添加 CommunityMembership
    └── 发出 SBTMinted 或 MembershipAdded 事件

  5. xPNTs Token 部署

  社区 → xPNTsFactory.deployxPNTsToken()
    ├── 验证 Registry.isRegisteredCommunity(msg.sender)
    ├── 部署 xPNTsToken ERC20
    ├── 设置 exchangeRate, paymaster 地址
    ├── 记录 community → token 映射
    └── 返回 token 地址

  ---
  六、关键常量与配置

  Registry 配置

  MAX_NAME_LENGTH: 64
  MAX_SUPPORTED_SBTS: 10

  NodeType 配置示例：
  PAYMASTER_AOA:
    - minStake: 30 GToken
    - slashThreshold: 3 failures
    - slashBase: 1 GToken
    - slashIncrement: Fibonacci(failureCount)
    - slashMax: 100 GToken

  GTokenStaking 配置

  MIN_STAKE: 1 ether (1 GToken)
  UNSTAKE_DELAY: 7 days

  MySBT 声誉系统

  BASE_REPUTATION: 20
  NFT_BASE_SCORE_PER_MONTH: 5
  NFT_MAX_MONTHS: 12
  ACTIVITY_BONUS: 10
  ACTIVITY_WINDOW: 30 days
  MIN_ACTIVITY_INTERVAL: 1 days

  SuperPaymasterV2 配置

  ETH/USD Price Feed: Chainlink Sepolia
  MIN_ETH_USD_PRICE: $500
  MAX_ETH_USD_PRICE: $10,000
  REPUTATION_LEVELS: [0, 50, 100, 200, 500, 1000]

  ---
  七、合约交互总结

  核心交互链路

  1. GToken ↔ GTokenStaking: 质押/解除质押
  2. GTokenStaking ↔ Registry: 锁定质押用于社区注册
  3. Registry ↔ MySBT: 验证社区注册状态
  4. Registry ↔ SuperPaymasterV2: 验证运营商资格
  5. GTokenStaking ↔ MySBT: 锁定质押用于 SBT 铸造
  6. GTokenStaking ↔ SuperPaymasterV2: 锁定质押用于运营商加入

  授权关系

  - Registry 可以调用 GTokenStaking.lockStake/unlockStake
  - MySBT 可以调用 GTokenStaking.lockStake/unlockStake
  - SuperPaymasterV2 可以调用 GTokenStaking.lockStake/slashStake
  - Registry 可以调用 GTokenStaking.slash (用于惩罚社区)

  ---
  所有 3 个任务已完成：
  1. ✅ 确认智能路由功能尚未完全实现（价格路由存在，声誉路由计划中）
  2. ✅ Register Community 页面链接已存在于 LaunchPaymaster.tsx:689-691
  3. ✅ 完整整理出 SuperPaymaster 核心合约数据结构和依赖关系

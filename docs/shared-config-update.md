# shared-config 更新清单

**更新日期**: 2025-11-08
**网络**: Sepolia Testnet

## 新部署的合约地址

### 核心合约

```typescript
// @aastar/shared-config/src/contracts/sepolia.ts

export const sepoliaContracts = {
  // ... 现有配置

  // ========================================
  // v2 Contracts (Updated 2025-11-08)
  // ========================================

  // Registry v2.2.0 - 全新部署，支持 auto-stake registration
  registry: {
    address: "0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75",
    version: "2.2.0",
    deployedAt: 1762580772,
    features: [
      "MySBT-style auto-stake registration",
      "registerCommunityWithAutoStake function",
      "Node type configuration (AOA/Super/ANode/KMS)",
    ]
  },

  // SuperPaymasterV2 v2.0.1 - 全新部署，使用新 Registry
  superPaymasterV2: {
    address: "0xfaB5B2A129DF8308a70DA2fE77c61001e4Df58BC",
    version: "2.0.1",
    deployedAt: 1762581660,
    features: [
      "Oracle security fix (answeredInRound validation)",
      "Chainlink staleness check (1 hour)",
      "Price bounds validation ($100-$100k)",
    ],
    dependencies: {
      registry: "0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75",  // v2.2.0
      gTokenStaking: "0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0",  // v2.0.1
      entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",  // v0.7
      ethUsdPriceFeed: "0x694AA1769357215DE4FAC081bf1f309aDC325306",  // Chainlink Sepolia
    }
  },

  // GTokenStaking v2.0.1 - 已存在，新增 locker 配置
  gTokenStaking: {
    address: "0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0",
    version: "2.0.1",
    lockers: {
      // 新增授权 lockers (2025-11-08)
      mySBT: {
        address: "0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C",
        feeRate: 100,  // 1%
        minExitFee: "0.01",  // GT
        maxFeePercent: 500,  // 5%
      },
      superPaymasterV2: {
        address: "0xfaB5B2A129DF8308a70DA2fE77c61001e4Df58BC",
        feeRate: 100,  // 1% base
        minExitFee: "0.01",  // GT
        maxFeePercent: 500,  // 5%
        timeTiers: [
          { days: 7, fee: 500 },    // < 7 days: 5%
          { days: 30, fee: 400 },   // 7-30 days: 4%
          { days: 90, fee: 300 },   // 30-90 days: 3%
          { days: 180, fee: 200 },  // 90-180 days: 2%
          { days: Infinity, fee: 100 },  // > 180 days: 1%
        ]
      },
      registry: {
        address: "0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75",
        feeRate: 200,  // 2%
        minExitFee: "0.05",  // GT
        maxFeePercent: 1000,  // 10%
      }
    }
  },

  // 已存在的合约（保持不变）
  gToken: {
    address: "0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc",
  },

  entryPoint: {
    address: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
    version: "0.7",
  },

  chainlinkPriceFeeds: {
    ethUsd: "0x694AA1769357215DE4FAC081bf1f309aDC325306",
  }
};
```

## ABI 更新

### 新增 ABI 文件

1. **Registry_v2_2_0.json**
   - 路径: `@aastar/shared-config/src/abis/Registry_v2_2_0.json`
   - 来源: `SuperPaymaster/contracts/out/Registry_v2_2_0.sol/Registry.json`
   - 关键函数:
     - `registerCommunityWithAutoStake()` - 新增的一键注册+质押功能
     - `getCommunityProfile(address)` - 获取社区信息
     - `getCommunityCount()` - 获取社区总数
     - `isRegisteredCommunity(address)` - 检查社区注册状态

2. **SuperPaymasterV2.json**
   - 路径: `@aastar/shared-config/src/abis/SuperPaymasterV2.json`
   - 来源: `SuperPaymaster/contracts/out/SuperPaymasterV2.sol/SuperPaymasterV2.json`
   - 更新: v2.0.1 Oracle 安全功能

## 配置常量更新

```typescript
// @aastar/shared-config/src/constants/sepolia.ts

export const SEPOLIA_CONSTANTS = {
  // ... 现有配置

  // SuperPaymasterV2 配置
  superPaymasterV2: {
    minOperatorStake: "30",  // 30 GT
    minAPNTsBalance: "100",  // 100 aPNTs
    serviceFeeRate: 200,  // 2% (basis points)
    oracle: {
      minPrice: 100,  // $100
      maxPrice: 100000,  // $100,000
      stalenessThreshold: 3600,  // 1 hour
    }
  },

  // Registry v2.2.0 配置
  registry: {
    maxSupportedSBTs: 10,
    maxNameLength: 100,
    nodeTypes: {
      PAYMASTER_AOA: 0,
      PAYMASTER_SUPER: 1,
      ANODE: 2,
      KMS: 3,
    }
  },

  // Locker 费率配置
  lockerFees: {
    mySBT: {
      rate: 100,  // 1%
      minExit: "0.01",
      max: 500,  // 5%
    },
    superPaymasterV2: {
      baseRate: 100,  // 1%
      minExit: "0.01",
      max: 500,  // 5%
      tiers: [
        { maxDays: 7, rate: 500 },
        { maxDays: 30, rate: 400 },
        { maxDays: 90, rate: 300 },
        { maxDays: 180, rate: 200 },
        { maxDays: Infinity, rate: 100 },
      ]
    },
    registry: {
      rate: 200,  // 2%
      minExit: "0.05",
      max: 1000,  // 10%
    }
  }
};
```

## 版本更新

建议更新 @aastar/shared-config 版本号：

- 当前版本: `v0.2.18`
- 新版本: `v0.3.0` (major update - 新增 Registry v2.2.0 和 SuperPaymasterV2 v2.0.1)

变更说明:
- 新增 Registry v2.2.0 合约地址和 ABI
- 新增 SuperPaymasterV2 v2.0.1 合约地址和 ABI
- 更新 GTokenStaking lockers 配置
- 新增 Oracle 安全配置常量
- 新增 Locker 费率配置常量

## 废弃的合约地址

以下合约地址已废弃（错误的部署顺序）：
```
❌ SuperPaymasterV2 (第一次): 0x33A31d52db2ef2497e93226e0ed1B5d587D7D5e8
❌ SuperPaymasterV2 (第二次): 0x5675062cA5D98c791972eAC24eFa3BC3EBc096f3
```

原因: 使用了旧的 Registry 地址，无法使用 v2.2.0 新特性

## 部署验证信息

所有合约已在 Sepolia 上部署并通过测试：

| 合约 | 地址 | 版本 | 状态 |
|------|------|------|------|
| Registry | `0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75` | v2.2.0 | ✅ 已部署已测试 |
| SuperPaymasterV2 | `0xfaB5B2A129DF8308a70DA2fE77c61001e4Df58BC` | v2.0.1 | ✅ 已部署已测试 |
| GTokenStaking | `0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0` | v2.0.1 | ✅ Lockers 已配置 |

测试报告: `SuperPaymaster/test-reports/onchain-test-2025-11-08.md`

## 下一步

1. ✅ 更新 shared-config 合约地址和 ABI
2. ✅ 发布新版本 v0.3.0
3. ⏭️ 更新 registry 前端使用新 shared-config
4. ⏭️ 测试 registry 前端的 auto-stake 注册功能
5. ⏭️ 部署 registry 前端到 Vercel

# SuperPaymaster 四阶段开发计划

> **版本**: v1.1  
> **日期**: 2025-10-14  
> **作者**: Jason + Claude AI  
> **项目**: SuperPaymaster Ecosystem  
> **更新日志**: 
> - v1.1: 更新合约地址、移除 Settlement、添加 localStorage 缓存、完善配置参数

---

## 📋 目录

- [项目概述](#项目概述)
- [核心合约部署信息](#核心合约部署信息)
- [仓库结构](#仓库结构)
- [四阶段开发路线图](#四阶段开发路线图)
  - [第一阶段：基础功能完善](#第一阶段基础功能完善-sepolia-测试网)
  - [第二阶段：运营者自助服务](#第二阶段运营者自助服务-sepolia-测试网)
  - [第三阶段：公开浏览器](#第三阶段公开浏览器-sepolia-测试网)
  - [第四阶段：开发者生态](#第四阶段开发者生态-sepolia--mainnet)
- [技术架构](#技术架构)
- [开发优先级](#开发优先级)
- [时间线](#时间线)

---

## 项目概述

SuperPaymaster 是一个去中心化的 Gas 赞助公共物品平台,基于 ERC-4337 账户抽象标准,为社区和 DApp 提供无缝的 Gas 支付解决方案。

### 核心价值主张

1. **去中心化**: 无中心化服务器,纯合约驱动
2. **无需许可**: 任何社区都可以创建和注册 Paymaster
3. **自由市场**: 用户可以从市场中选择最优的 Gas 赞助方案
4. **可持续收益**: 社区可以通过服务费获得收入

### 生态系统组成

```
SuperPaymaster Ecosystem
│
├─ SuperPaymaster 合约
│   ├─ PaymasterV4 (Gas 支付合约)
│   ├─ Registry (注册表)
│   └─ GasToken/SBT 工厂合约
│
├─ Registry 应用 (https://superpaymaster.aastar.io/)
│   ├─ Landing Page
│   ├─ Developer Portal
│   ├─ Operators Portal
│   └─ Registry Explorer
│
├─ Faucet API (faucet.aastar.io)
│   ├─ SBT 领取
│   ├─ PNT 领取
│   ├─ 测试 USDT 领取
│   └─ 账户创建
│
└─ AAStar SDK (https://github.com/AAStarCommunity/aastar-sdk)
    ├─ Paymaster Client
    ├─ Account Factory
    └─ Transaction Builder
```

---

## 核心合约部署信息

### Ethereum Sepolia (Chain ID: 11155111)

**部署账户**: `0x411BD567E46C0781248dbB6a9211891C032885e5`

```typescript
// 已部署合约 (2025-10-14 最新)
const DEPLOYED_CONTRACTS = {
  // ERC-4337 标准合约
  EntryPoint_v0_7: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
  
  // 核心合约
  PaymasterV4: "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445",
  SuperPaymasterRegistry_v1_2: "0x838da93c815a6E45Aa50429529da9106C0621eF0",
  
  // Token 合约
  GasTokenV2_PNT: "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180",
  SBT: "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f",
  
  // 工厂合约
  GasTokenFactoryV2: "0x6720Dc8ce5021bC6F3F126054556b5d3C125101F",
  SimpleAccountFactory: "0x9bD66892144FCf0BAF5B6946AEAFf38B0d967881",
  
  // 测试合约
  MockUSDT: "0x14EaC6C3D49AEDff3D59773A7d7bfb50182bCfDc", // 6 decimals
};
```

### 合约状态

| 合约名称 | 状态 | 功能 | 优先级 |
|---------|------|------|--------|
| PaymasterV4 | ✅ 已部署 | Gas 支付 (80% 完成) | 🔴 高 |
| Registry v1.2 | ✅ 已部署 | Paymaster 注册表 | 🔴 高 |
| GasTokenV2 (PNT) | ✅ 已部署 | Gas Token | - |
| SBT | ✅ 已部署 | 社区身份凭证 | - |
| GasTokenFactoryV2 | ✅ 已部署 | Token 工厂 | - |
| ~~Settlement~~ | ❌ **已废弃** | ~~链上结算~~ | - |

**重要说明**: Settlement 结算模式已暂停,相关开发停止。PaymasterV4 采用直接支付模式。

---

## 仓库结构

SuperPaymaster 生态系统由以下仓库组成:

```
projects/
├── SuperPaymaster/          # 合约仓库
│   ├── contracts/          # Solidity 合约
│   ├── script/             # 部署脚本
│   └── docs/               # 📄 本计划文档位置
│
├── registry/               # Registry Web 应用
│   ├── src/
│   │   ├── pages/          # 页面组件
│   │   ├── components/     # UI 组件
│   │   └── hooks/          # React Hooks
│   └── docs/               # Registry 文档
│
├── faucet/                 # Faucet API
│   └── api/                # Cloudflare Workers
│
├── aastar-sdk/             # SDK 仓库 (独立)
│   ├── packages/
│   │   ├── core/           # 核心 SDK
│   │   ├── react/          # React Hooks
│   │   └── cli/            # CLI 工具
│   └── examples/           # 代码示例
│
├── aastar-shared-config/   # 共享配置
│   └── src/                # 品牌、合约地址等
│
└── demo/                   # Demo Playground
    └── src/                # 交互演示
```

**重要**: 
- Registry 网站: https://superpaymaster.aastar.io/
- SDK 仓库: https://github.com/AAStarCommunity/aastar-sdk
- **禁止删除或修改 registry 原有页面,只能新增页面、链接和路由**

---

## 四阶段开发路线图

### 第一阶段:基础功能完善 (Sepolia 测试网)

**目标**: 任意持有 SBT 和 PNTs(>100) 的合约账户都可以享受无 Gas 赞助

**当前完成度**: 80%

#### 1.1 核心功能

- ✅ PaymasterV4 合约已部署
- ✅ 基本资格检查 (SBT + PNTs)
- ✅ Gas 支付逻辑
- ✅ Treasury 收款机制
- ⚠️ **待完善**: Gas 使用分析报告

#### 1.2 技术架构

```typescript
// PaymasterV4 核心逻辑
interface PaymasterV4 {
  // 资格检查和支付
  function validatePaymasterUserOp(
    PackedUserOperation calldata userOp,
    bytes32 userOpHash,
    uint256 maxCost
  ) external returns (bytes memory context, uint256 validationData);
  
  // 链上记录事件 (已实现)
  event GasPaymentProcessed(
    address indexed user,
    address indexed gasToken,
    uint256 pntAmount,
    uint256 gasCostWei,
    uint256 actualGasCost
  );
  
  // 公开查询函数
  function estimatePNTCost(uint256 gasCostWei) external view returns (uint256);
  function getSupportedSBTs() external view returns (address[] memory);
  function getSupportedGasTokens() external view returns (address[] memory);
  
  // 待实现: 统计查询 (需要链下聚合)
  // 通过读取 GasPaymentProcessed 事件实现
}
```

#### 1.3 Registry 应用 - 第一阶段功能

**应用**: `registry` 项目 (https://superpaymaster.aastar.io/)

**重要约束**: 
- ❌ **禁止删除**原有页面
- ❌ **禁止修改**原有路由
- ✅ **允许新增**页面和链接

##### 新增页面结构

```
registry/src/pages/
├── analytics/              # 🆕 Gas 分析模块
│   ├── AnalyticsDashboard.tsx    # 管理员分析页面
│   └── UserGasRecords.tsx        # 用户个人记录
├── operator/              # 🆕 运营者模块 (第二阶段)
│   ├── DeployWizard.tsx
│   └── ManagePaymaster.tsx
└── [原有页面保持不变]
```

##### 核心功能实现

**1. Gas 使用分析报告**

```typescript
// hooks/useGasAnalytics.ts
interface GasAnalytics {
  totalOperations: number;
  totalGasSponsored: string; // ETH
  totalPntPaid: string;
  avgGasPerOp: string;
  topGasUsers: Array<{
    address: string;
    operations: number;
    gasUsed: string;
  }>;
  dailyStats: Array<{
    date: string;
    operations: number;
    gasUsed: string;
  }>;
}

export function useGasAnalytics() {
  const [analytics, setAnalytics] = useState<GasAnalytics | null>(null);
  const [loading, setLoading] = useState(true);
  
  useEffect(() => {
    async function fetchAnalytics() {
      // 1. 尝试从 localStorage 读取缓存
      const cached = loadFromCache('gas-analytics');
      if (cached && !isCacheExpired(cached.timestamp, 3600)) {
        setAnalytics(cached.data);
        setLoading(false);
        // 后台更新
        refreshInBackground();
        return;
      }
      
      // 2. 从链上事件读取
      const provider = new ethers.providers.JsonRpcProvider(SEPOLIA_RPC);
      const paymaster = new ethers.Contract(
        PAYMASTER_V4_ADDRESS,
        PAYMASTER_V4_ABI,
        provider
      );
      
      // 查询 GasPaymentProcessed 事件
      const filter = paymaster.filters.GasPaymentProcessed();
      const events = await paymaster.queryFilter(filter, -10000); // 最近 10000 个块
      
      // 3. 聚合数据
      const stats = aggregateEvents(events);
      setAnalytics(stats);
      
      // 4. 缓存到 localStorage
      saveToCache('gas-analytics', stats);
      
      setLoading(false);
    }
    
    fetchAnalytics();
  }, []);
  
  return { analytics, loading };
}

// localStorage 缓存工具
function loadFromCache(key: string) {
  const cached = localStorage.getItem(`spm_${key}`);
  return cached ? JSON.parse(cached) : null;
}

function saveToCache(key: string, data: any) {
  localStorage.setItem(`spm_${key}`, JSON.stringify({
    data,
    timestamp: Date.now()
  }));
}

function isCacheExpired(timestamp: number, ttlSeconds: number): boolean {
  return Date.now() - timestamp > ttlSeconds * 1000;
}

function aggregateEvents(events: Event[]): GasAnalytics {
  const userMap = new Map();
  const dailyMap = new Map();
  
  events.forEach(event => {
    const { user, pntAmount, gasCostWei, actualGasCost } = event.args;
    
    // 按用户聚合
    if (!userMap.has(user)) {
      userMap.set(user, { operations: 0, gasUsed: 0n });
    }
    const userData = userMap.get(user);
    userData.operations++;
    userData.gasUsed += BigInt(actualGasCost);
    
    // 按日期聚合
    const date = new Date(event.blockTimestamp * 1000).toISOString().split('T')[0];
    if (!dailyMap.has(date)) {
      dailyMap.set(date, { operations: 0, gasUsed: 0n });
    }
    const dailyData = dailyMap.get(date);
    dailyData.operations++;
    dailyData.gasUsed += BigInt(actualGasCost);
  });
  
  // 转换为输出格式
  const topUsers = Array.from(userMap.entries())
    .sort((a, b) => Number(b[1].gasUsed - a[1].gasUsed))
    .slice(0, 10)
    .map(([address, data]) => ({
      address,
      operations: data.operations,
      gasUsed: ethers.utils.formatEther(data.gasUsed)
    }));
  
  const dailyStats = Array.from(dailyMap.entries())
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([date, data]) => ({
      date,
      operations: data.operations,
      gasUsed: ethers.utils.formatEther(data.gasUsed)
    }));
  
  const totalGas = Array.from(userMap.values())
    .reduce((sum, u) => sum + u.gasUsed, 0n);
  
  return {
    totalOperations: events.length,
    totalGasSponsored: ethers.utils.formatEther(totalGas),
    totalPntPaid: events.reduce((sum, e) => sum + Number(e.args.pntAmount), 0).toString(),
    avgGasPerOp: ethers.utils.formatEther(totalGas / BigInt(events.length || 1)),
    topGasUsers: topUsers,
    dailyStats
  };
}
```

**2. 管理者 Gas 分析页面**

```typescript
// pages/analytics/AnalyticsDashboard.tsx
export function AnalyticsDashboard() {
  const { analytics, loading } = useGasAnalytics();
  const { address, isConnected } = useMetaMask();
  const isOwner = address === PAYMASTER_OWNER;
  
  if (!isConnected) {
    return <div>请连接钱包以查看分析数据</div>;
  }
  
  if (!isOwner) {
    return <div>仅 Paymaster Owner 可查看此页面</div>;
  }
  
  if (loading) {
    return <LoadingSpinner />;
  }
  
  return (
    <div className="analytics-dashboard">
      <h1>Gas 使用分析</h1>
      
      {/* 总览卡片 */}
      <div className="stats-grid">
        <StatsCard
          title="总赞助次数"
          value={analytics.totalOperations}
          icon={<IconActivity />}
        />
        <StatsCard
          title="总 Gas 赞助"
          value={`${analytics.totalGasSponsored} ETH`}
          icon={<IconGas />}
        />
        <StatsCard
          title="总 PNT 收取"
          value={`${analytics.totalPntPaid} PNT`}
          icon={<IconCoins />}
        />
        <StatsCard
          title="平均 Gas/次"
          value={`${analytics.avgGasPerOp} ETH`}
          icon={<IconTrendingUp />}
        />
      </div>
      
      {/* 每日趋势图 */}
      <div className="chart-container">
        <h2>每日 Gas 使用趋势</h2>
        <GasUsageChart data={analytics.dailyStats} />
      </div>
      
      {/* Top 用户 */}
      <div className="top-users">
        <h2>Top Gas 用户</h2>
        <table>
          <thead>
            <tr>
              <th>地址</th>
              <th>操作次数</th>
              <th>Gas 使用</th>
            </tr>
          </thead>
          <tbody>
            {analytics.topGasUsers.map(user => (
              <tr key={user.address}>
                <td>{formatAddress(user.address)}</td>
                <td>{user.operations}</td>
                <td>{user.gasUsed} ETH</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      
      {/* 导出功能 */}
      <div className="export-actions">
        <button onClick={() => exportToCSV(analytics)}>
          导出 CSV
        </button>
        <button onClick={() => exportToPDF(analytics)}>
          导出 PDF 报告
        </button>
      </div>
    </div>
  );
}
```

**3. 用户个人 Gas 记录**

```typescript
// pages/analytics/UserGasRecords.tsx
export function UserGasRecords() {
  const { address, isConnected } = useMetaMask();
  const [userStats, setUserStats] = useState<UserStats | null>(null);
  const [transactions, setTransactions] = useState<Transaction[]>([]);
  
  useEffect(() => {
    if (!isConnected) return;
    
    async function fetchUserData() {
      // 1. 尝试从 localStorage 读取
      const cached = loadFromCache(`user-gas-${address}`);
      if (cached && !isCacheExpired(cached.timestamp, 600)) {
        setUserStats(cached.data.stats);
        setTransactions(cached.data.transactions);
        return;
      }
      
      // 2. 从链上读取
      const provider = new ethers.providers.JsonRpcProvider(SEPOLIA_RPC);
      const paymaster = new ethers.Contract(
        PAYMASTER_V4_ADDRESS,
        PAYMASTER_V4_ABI,
        provider
      );
      
      // 查询用户相关事件
      const filter = paymaster.filters.GasPaymentProcessed(address);
      const events = await paymaster.queryFilter(filter);
      
      const stats = {
        totalOperations: events.length,
        gasSaved: events.reduce((sum, e) => sum + Number(e.args.actualGasCost), 0),
        pntPaid: events.reduce((sum, e) => sum + Number(e.args.pntAmount), 0),
      };
      
      const txs = events.map(e => ({
        hash: e.transactionHash,
        timestamp: e.blockTimestamp,
        gasUsed: ethers.utils.formatEther(e.args.actualGasCost),
        pntPaid: ethers.utils.formatUnits(e.args.pntAmount, 18),
        gasToken: e.args.gasToken,
      }));
      
      setUserStats(stats);
      setTransactions(txs);
      
      // 3. 缓存
      saveToCache(`user-gas-${address}`, { stats, transactions: txs });
    }
    
    fetchUserData();
  }, [address, isConnected]);
  
  return (
    <div className="user-gas-records">
      <h1>我的 Gas 记录</h1>
      
      {!isConnected ? (
        <div>请连接钱包查看您的 Gas 使用记录</div>
      ) : (
        <>
          <div className="user-stats">
            <StatsCard
              title="累计赞助次数"
              value={userStats?.totalOperations || 0}
            />
            <StatsCard
              title="节省的 Gas"
              value={`${ethers.utils.formatEther(userStats?.gasSaved || 0)} ETH`}
              subtitle="💰 价值约 $XXX USD"
            />
            <StatsCard
              title="已支付 PNT"
              value={`${ethers.utils.formatUnits(userStats?.pntPaid || 0, 18)} PNT`}
            />
          </div>
          
          <div className="transaction-history">
            <h2>交易记录</h2>
            <TransactionList transactions={transactions} />
          </div>
        </>
      )}
    </div>
  );
}
```

#### 1.4 数据存储策略

**阶段 1A: localStorage 缓存 (第一次查询后缓存)**

```typescript
// utils/cache.ts
const CACHE_PREFIX = 'spm_';
const DEFAULT_TTL = 3600; // 1 hour

export function loadFromCache(key: string) {
  try {
    const cached = localStorage.getItem(`${CACHE_PREFIX}${key}`);
    return cached ? JSON.parse(cached) : null;
  } catch (error) {
    console.error('Failed to load from cache:', error);
    return null;
  }
}

export function saveToCache(key: string, data: any, ttl: number = DEFAULT_TTL) {
  try {
    localStorage.setItem(`${CACHE_PREFIX}${key}`, JSON.stringify({
      data,
      timestamp: Date.now(),
      ttl
    }));
  } catch (error) {
    console.error('Failed to save to cache:', error);
  }
}

export function isCacheExpired(timestamp: number, ttl: number): boolean {
  return Date.now() - timestamp > ttl * 1000;
}

export function clearCache(pattern?: string) {
  if (!pattern) {
    // 清除所有 SPM 缓存
    Object.keys(localStorage)
      .filter(key => key.startsWith(CACHE_PREFIX))
      .forEach(key => localStorage.removeItem(key));
  } else {
    // 清除匹配模式的缓存
    Object.keys(localStorage)
      .filter(key => key.startsWith(CACHE_PREFIX) && key.includes(pattern))
      .forEach(key => localStorage.removeItem(key));
  }
}
```

**阶段 1B: Cloudflare KV (未来优化)**

```typescript
// workers/sync-gas-data.ts (后续优化)
export default {
  async scheduled(event, env, ctx) {
    // 每小时同步一次
    const latestBlock = await getLatestSyncedBlock(env.KV);
    const currentBlock = await provider.getBlockNumber();
    
    const events = await queryEvents(latestBlock, currentBlock);
    await storeToKV(env.KV, events);
  }
};
```

#### 1.5 第一阶段交付物

✅ **必须完成**:
- [ ] Gas 分析报告页面 (`/analytics/dashboard`)
- [ ] 用户 Gas 记录页面 (`/analytics/user`)
- [ ] localStorage 缓存实现
- [ ] 链上数据查询优化
- [ ] 管理员权限控制
- [ ] 数据导出功能 (CSV/PDF)

🎯 **成功标准**:
- 管理员可以查看实时 Gas 使用统计
- 用户可以查看个人 Gas 节省记录
- 首次加载时间 < 5s, 缓存后 < 1s
- 支持查询最近 30 天数据

---

### 第二阶段:运营者自助服务 (Sepolia 测试网)

**目标**: 通过 Web 界面完成 Paymaster 的创建、配置、Stake 和注册

**应用**: `registry` 项目

#### 2.1 用户流程

```
社区运营者访问 https://superpaymaster.aastar.io/operator
│
├─ Step 0: 选择模式
│   ├─ 🆕 新建 Paymaster → 进入 Step 1
│   └─ 📋 注册已有 Paymaster → 跳转 Step 4
│
├─ Step 1: 部署 PaymasterV4 合约
│   ├─ 连接 MetaMask (自动成为 Owner)
│   ├─ 填写配置表单
│   │   ├─ Community Name
│   │   ├─ Treasury Address (建议多签)
│   │   ├─ Gas to USD Rate (18 decimals, e.g., 4500e18 = $4500/ETH)
│   │   ├─ PNT Price USD (18 decimals, e.g., 0.02e18 = $0.02)
│   │   ├─ Service Fee Rate (basis points, 200 = 2%, max 1000 = 10%)
│   │   ├─ Max Gas Cost Cap (wei)
│   │   ├─ Min Token Balance (wei)
│   │   └─ Network (Sepolia)
│   ├─ 点击 "Deploy Paymaster"
│   ├─ 确认 MetaMask 交易 (~0.02 ETH gas)
│   └─ ✅ 获得 Paymaster 地址
│
├─ Step 2: 配置 Paymaster
│   ├─ 2.1 设置 SBT
│   │   ├─ 选项 A: 使用现有 SBT 合约
│   │   └─ 选项 B: 部署新 SBT (使用工厂合约)
│   ├─ 2.2 设置 Gas Token (PNT)
│   │   ├─ 选项 A: 使用现有 PNT 合约
│   │   └─ 选项 B: 部署新 PNT (使用 GasTokenFactoryV2)
│   ├─ 2.3 关联到 Paymaster
│   │   ├─ Call: paymaster.addSBT(sbtAddress)
│   │   └─ Call: paymaster.addGasToken(pntAddress)
│   └─ ✅ 配置完成
│
├─ Step 3: Stake 到 EntryPoint
│   ├─ 3.1 选择 EntryPoint 版本 (v0.7)
│   ├─ 3.2 存入 ETH
│   │   ├─ 输入金额 (建议 ≥ 0.1 ETH)
│   │   ├─ Call: entryPoint.depositTo{value}(paymaster)
│   │   └─ ✅ 查看余额
│   ├─ 3.3 Stake ETH (可选,增强信用)
│   │   ├─ 输入金额 (建议 ≥ 0.05 ETH)
│   │   ├─ Call: entryPoint.addStake{value}(unstakeDelay)
│   │   └─ ✅ 查看 Stake 状态
│   └─ 💡 提示: 至少需要 Deposit,Stake 可选
│
├─ Step 4: Stake GToken 并注册
│   ├─ 4.1 获取 GToken
│   │   ├─ 测试网: Faucet 领取 (20 GToken)
│   │   └─ 主网: Uniswap 购买
│   ├─ 4.2 Approve GToken
│   │   ├─ Call: gToken.approve(registry, amount)
│   │   └─ 最小: 10 GToken
│   ├─ 4.3 Stake & Register
│   │   ├─ Call: registry.registerPaymaster(
│   │   │   paymaster,
│   │   │   gTokenAmount,
│   │   │   metadata
│   │   │ )
│   │   └─ ✅ 注册成功
│   └─ 🎉 Paymaster 现在已上线!
│
└─ Step 5: 管理 Paymaster
    ├─ 查看余额 (EntryPoint Deposit)
    ├─ 查看 Stake (EntryPoint Stake + GToken Stake)
    ├─ 查看 Treasury 收入
    ├─ 调整参数 (PaymasterV4 所有可配置参数)
    │   ├─ Treasury (setTreasury)
    │   ├─ Gas to USD Rate (setGasToUSDRate)
    │   ├─ PNT Price USD (setPntPriceUSD)
    │   ├─ Service Fee Rate (setServiceFeeRate, max 10%)
    │   ├─ Max Gas Cost Cap (setMaxGasCostCap)
    │   ├─ Min Token Balance (setMinTokenBalance)
    │   ├─ Add/Remove SBT (addSBT/removeSBT)
    │   └─ Add/Remove GasToken (addGasToken/removeGasToken)
    └─ 暂停/恢复服务 (pause/unpause)
```

#### 2.2 PaymasterV4 可配置参数 (基于合约代码)

```typescript
// PaymasterV4 所有可配置参数
interface PaymasterV4Config {
  // 构造函数参数
  entryPoint: string;         // 不可变
  owner: string;              // 可转让 (transferOwnership)
  treasury: string;           // setTreasury(address)
  gasToUSDRate: BigNumber;    // setGasToUSDRate(uint256) - 18 decimals
  pntPriceUSD: BigNumber;     // setPntPriceUSD(uint256) - 18 decimals
  serviceFeeRate: number;     // setServiceFeeRate(uint256) - basis points (max 1000)
  maxGasCostCap: BigNumber;   // setMaxGasCostCap(uint256) - wei
  minTokenBalance: BigNumber; // setMinTokenBalance(uint256) - wei
  
  // 动态管理
  supportedSBTs: string[];         // addSBT(address) / removeSBT(address)
  supportedGasTokens: string[];    // addGasToken(address) / removeGasToken(address)
  paused: boolean;                 // pause() / unpause()
}

// 常量
const MAX_SERVICE_FEE = 1000;      // 10%
const MAX_SBTS = 5;                // 最多支持 5 个 SBT
const MAX_GAS_TOKENS = 10;         // 最多支持 10 个 Gas Token
```

#### 2.3 核心页面实现

##### **页面 1: Operator Portal 入口**

```typescript
// pages/operator/OperatorPortal.tsx (新增路由: /operator)
export function OperatorPortal() {
  const navigate = useNavigate();
  
  return (
    <div className="operators-portal">
      <h1>社区运营者</h1>
      
      <div className="mode-selection">
        <Card
          title="🆕 创建新 Paymaster"
          description="从零开始部署您的社区 Paymaster"
          onClick={() => navigate('/operator/deploy')}
        />
        
        <Card
          title="📋 注册已有 Paymaster"
          description="将已部署的 Paymaster 注册到 SuperPaymaster"
          onClick={() => navigate('/operator/register')}
        />
      </div>
      
      <div className="info-section">
        <h2>为什么需要社区 Paymaster?</h2>
        {/* 内容参考原设计文档 */}
      </div>
      
      <div className="cta-section">
        <Button primary onClick={() => navigate('/operators/launch-guide')}>
          📚 查看完整教程
        </Button>
        <Button onClick={() => window.open('https://aastar.io/demo?role=operator')}>
          🎮 进入演示沙盒
        </Button>
      </div>
    </div>
  );
}
```

##### **页面 2: Paymaster 部署向导**

```typescript
// pages/operator/DeployPaymaster.tsx (新增路由: /operator/deploy)
export function DeployPaymaster() {
  const [step, setStep] = useState(0);
  const { address, isConnected } = useMetaMask();
  const [config, setConfig] = useState<PaymasterConfig>({
    communityName: '',
    treasury: '',
    gasToUSDRate: ethers.utils.parseEther('4500'), // $4500/ETH
    pntPriceUSD: ethers.utils.parseEther('0.02'),  // $0.02/PNT
    serviceFeeRate: 200, // 2%
    maxGasCostCap: ethers.utils.parseEther('0.01'), // 0.01 ETH
    minTokenBalance: ethers.utils.parseEther('100'), // 100 PNT
    network: 'sepolia',
  });
  const [deployedAddress, setDeployedAddress] = useState<string | null>(null);
  
  const steps = [
    'Deploy Contract',
    'Configure Tokens',
    'Stake to EntryPoint',
    'Register to Registry',
    'Manage',
  ];
  
  return (
    <div className="deploy-wizard">
      {/* 步骤指示器 */}
      <Stepper steps={steps} currentStep={step} />
      
      {/* Step 1: 部署合约 */}
      {step === 0 && (
        <StepDeployContract
          config={config}
          onConfigChange={setConfig}
          onDeploy={(address) => {
            setDeployedAddress(address);
            setStep(1);
          }}
        />
      )}
      
      {/* Step 2-5: 其他步骤 */}
      {/* ... 完整代码见原文档 ... */}
    </div>
  );
}
```

##### **组件: Step 5 - 管理 Paymaster (完整参数配置)**

```typescript
// components/operator/StepManage.tsx
export function StepManage({ paymasterAddress }) {
  const { signer, address } = useMetaMask();
  const [paymasterInfo, setPaymasterInfo] = useState<PaymasterInfo | null>(null);
  const [showEditDialog, setShowEditDialog] = useState<string | null>(null);
  
  useEffect(() => {
    fetchPaymasterInfo();
  }, []);
  
  const fetchPaymasterInfo = async () => {
    const paymaster = new ethers.Contract(paymasterAddress, PAYMASTER_V4_ABI, signer);
    
    const info = {
      owner: await paymaster.owner(),
      treasury: await paymaster.treasury(),
      gasToUSDRate: await paymaster.gasToUSDRate(),
      pntPriceUSD: await paymaster.pntPriceUSD(),
      serviceFeeRate: await paymaster.serviceFeeRate(),
      maxGasCostCap: await paymaster.maxGasCostCap(),
      minTokenBalance: await paymaster.minTokenBalance(),
      paused: await paymaster.paused(),
      supportedSBTs: await paymaster.getSupportedSBTs(),
      supportedGasTokens: await paymaster.getSupportedGasTokens(),
    };
    
    setPaymasterInfo(info);
  };
  
  // 更新参数的通用函数
  const updateParameter = async (functionName: string, value: any) => {
    const paymaster = new ethers.Contract(paymasterAddress, PAYMASTER_V4_ABI, signer);
    const tx = await paymaster[functionName](value);
    await tx.wait();
    
    toast.success(`${functionName} 更新成功`);
    fetchPaymasterInfo();
  };
  
  return (
    <div className="step-manage">
      <h2>Step 5: 管理 Paymaster</h2>
      
      {/* 配置参数表格 */}
      <Card>
        <h3>可配置参数</h3>
        <table className="config-table">
          <thead>
            <tr>
              <th>参数</th>
              <th>当前值</th>
              <th>说明</th>
              <th>操作</th>
            </tr>
          </thead>
          <tbody>
            {/* Treasury */}
            <tr>
              <td>Treasury</td>
              <td>{paymasterInfo?.treasury}</td>
              <td>服务费收款地址</td>
              <td>
                <Button size="small" onClick={() => setShowEditDialog('treasury')}>
                  修改
                </Button>
              </td>
            </tr>
            
            {/* Gas to USD Rate */}
            <tr>
              <td>Gas to USD Rate</td>
              <td>${ethers.utils.formatEther(paymasterInfo?.gasToUSDRate || 0)}/ETH</td>
              <td>ETH 价格 (18 decimals)</td>
              <td>
                <Button size="small" onClick={() => setShowEditDialog('gasToUSDRate')}>
                  修改
                </Button>
              </td>
            </tr>
            
            {/* PNT Price USD */}
            <tr>
              <td>PNT Price (USD)</td>
              <td>${ethers.utils.formatEther(paymasterInfo?.pntPriceUSD || 0)}</td>
              <td>PNT 价格 (18 decimals)</td>
              <td>
                <Button size="small" onClick={() => setShowEditDialog('pntPriceUSD')}>
                  修改
                </Button>
              </td>
            </tr>
            
            {/* Service Fee Rate */}
            <tr>
              <td>Service Fee</td>
              <td>{(paymasterInfo?.serviceFeeRate || 0) / 100}%</td>
              <td>服务费率 (最大 10%)</td>
              <td>
                <Button size="small" onClick={() => setShowEditDialog('serviceFeeRate')}>
                  修改
                </Button>
              </td>
            </tr>
            
            {/* Max Gas Cost Cap */}
            <tr>
              <td>Max Gas Cost Cap</td>
              <td>{ethers.utils.formatEther(paymasterInfo?.maxGasCostCap || 0)} ETH</td>
              <td>单笔交易最大 Gas</td>
              <td>
                <Button size="small" onClick={() => setShowEditDialog('maxGasCostCap')}>
                  修改
                </Button>
              </td>
            </tr>
            
            {/* Min Token Balance */}
            <tr>
              <td>Min Token Balance</td>
              <td>{ethers.utils.formatEther(paymasterInfo?.minTokenBalance || 0)} PNT</td>
              <td>最小 PNT 余额要求</td>
              <td>
                <Button size="small" onClick={() => setShowEditDialog('minTokenBalance')}>
                  修改
                </Button>
              </td>
            </tr>
            
            {/* Paused */}
            <tr>
              <td>Status</td>
              <td>
                {paymasterInfo?.paused ? (
                  <Badge variant="error">已暂停</Badge>
                ) : (
                  <Badge variant="success">运行中</Badge>
                )}
              </td>
              <td>服务状态</td>
              <td>
                <Button
                  size="small"
                  variant={paymasterInfo?.paused ? 'primary' : 'secondary'}
                  onClick={() => {
                    const func = paymasterInfo?.paused ? 'unpause' : 'pause';
                    updateParameter(func, null);
                  }}
                >
                  {paymasterInfo?.paused ? '恢复' : '暂停'}
                </Button>
              </td>
            </tr>
          </tbody>
        </table>
      </Card>
      
      {/* Token 管理 */}
      <Card>
        <h3>Supported Tokens</h3>
        
        <div className="token-section">
          <h4>SBTs (最多 {MAX_SBTS} 个)</h4>
          <ul>
            {paymasterInfo?.supportedSBTs.map(sbt => (
              <li key={sbt}>
                {sbt}
                <Button
                  size="small"
                  variant="danger"
                  onClick={() => updateParameter('removeSBT', sbt)}
                >
                  移除
                </Button>
              </li>
            ))}
          </ul>
          {paymasterInfo?.supportedSBTs.length < MAX_SBTS && (
            <Button size="small" onClick={() => setShowEditDialog('addSBT')}>
              添加 SBT
            </Button>
          )}
        </div>
        
        <div className="token-section">
          <h4>Gas Tokens (最多 {MAX_GAS_TOKENS} 个)</h4>
          <ul>
            {paymasterInfo?.supportedGasTokens.map(token => (
              <li key={token}>
                {token}
                <Button
                  size="small"
                  variant="danger"
                  onClick={() => updateParameter('removeGasToken', token)}
                >
                  移除
                </Button>
              </li>
            ))}
          </ul>
          {paymasterInfo?.supportedGasTokens.length < MAX_GAS_TOKENS && (
            <Button size="small" onClick={() => setShowEditDialog('addGasToken')}>
              添加 Gas Token
            </Button>
          )}
        </div>
      </Card>
      
      {/* 编辑对话框 */}
      {showEditDialog && (
        <EditParameterDialog
          parameter={showEditDialog}
          currentValue={paymasterInfo[showEditDialog]}
          onSave={(value) => {
            updateParameter(`set${capitalize(showEditDialog)}`, value);
            setShowEditDialog(null);
          }}
          onCancel={() => setShowEditDialog(null)}
        />
      )}
    </div>
  );
}
```

#### 2.4 第二阶段交付物

✅ **必须完成**:
- [ ] Operator Portal 入口页面 (`/operator`)
- [ ] 5 步部署向导完整流程 (`/operator/deploy`)
- [ ] PaymasterV4 合约部署接口
- [ ] SBT/PNT 工厂合约集成
- [ ] EntryPoint Stake 管理界面
- [ ] Registry 注册流程
- [ ] Paymaster 管理页面 (所有参数配置)

🎯 **成功标准**:
- 运营者可以在 30 分钟内完成 Paymaster 创建和注册
- 所有 PaymasterV4 参数都可以通过 UI 配置
- 所有步骤有清晰的说明和错误提示
- 测试网流程完全可用

---

### 第三阶段:公开浏览器 (Sepolia 测试网)

**目标**: 公开展示所有注册的 Paymaster,提供管理员登录功能

**应用**: `registry` 项目

#### 3.1 功能需求

```
Public Explorer (https://superpaymaster.aastar.io/explorer)
│
├─ 公开数据 (无需登录)
│   ├─ 所有注册的 Paymaster 列表
│   ├─ 每个 Paymaster 的基本信息
│   │   ├─ 社区名称
│   │   ├─ 合约地址
│   │   ├─ 支持的 SBT/Gas Token
│   │   ├─ 服务费率
│   │   ├─ 累计赞助次数
│   │   ├─ 累计 Gas 节省
│   │   └─ 信用评分
│   ├─ 筛选和排序
│   │   ├─ 按信用排序
│   │   ├─ 按服务费排序
│   │   ├─ 按赞助次数排序
│   │   └─ 搜索 (名称/地址)
│   └─ Paymaster 详情页
│       ├─ 完整配置信息
│       ├─ 最近交易记录
│       ├─ Gas 使用图表
│       └─ 社区信息
│
└─ 管理员功能 (需 MetaMask 登录)
    ├─ 验证身份 (检查是否为 Paymaster Owner)
    ├─ 进入管理页面 → 跳转到 /operator/manage/:address
    └─ 修改 Paymaster 配置
```

#### 3.2 核心页面实现

##### **页面: Registry Explorer**

```typescript
// pages/explorer/RegistryExplorer.tsx (新增路由: /explorer)
export function RegistryExplorer() {
  const [paymasters, setPaymasters] = useState<PaymasterInfo[]>([]);
  const [loading, setLoading] = useState(true);
  const [filters, setFilters] = useState({
    sortBy: 'reputation', // reputation | fee | operations
    search: '',
  });
  
  useEffect(() => {
    fetchPaymasters();
  }, [filters]);
  
  const fetchPaymasters = async () => {
    setLoading(true);
    
    // 1. 尝试从 localStorage 读取
    const cached = loadFromCache('registry-paymasters');
    if (cached && !isCacheExpired(cached.timestamp, 600)) {
      setPaymasters(cached.data);
      setLoading(false);
      // 后台更新
      refreshInBackground();
      return;
    }
    
    // 2. 从合约读取
    const provider = new ethers.providers.JsonRpcProvider(SEPOLIA_RPC);
    const registry = new ethers.Contract(
      REGISTRY_V1_2_ADDRESS,
      REGISTRY_ABI,
      provider
    );
    
    const addresses = await registry.getAllPaymasters();
    
    const infos = await Promise.all(
      addresses.map(async (addr) => {
        const info = await registry.getPaymasterInfo(addr);
        const paymaster = new ethers.Contract(addr, PAYMASTER_V4_ABI, provider);
        
        const [treasury, serviceFeeRate, paused] = await Promise.all([
          paymaster.treasury(),
          paymaster.serviceFeeRate(),
          paymaster.paused(),
        ]);
        
        return {
          address: addr,
          name: info.metadata.name,
          treasury,
          serviceFeeRate,
          paused,
          gTokenStake: info.gTokenStake,
          reputation: info.reputation,
          totalOperations: info.totalOperations,
        };
      })
    );
    
    // 3. 排序和过滤
    const sorted = sortPaymasters(infos, filters.sortBy);
    const filtered = filters.search
      ? sorted.filter(pm =>
          pm.name.toLowerCase().includes(filters.search.toLowerCase()) ||
          pm.address.toLowerCase().includes(filters.search.toLowerCase())
        )
      : sorted;
    
    setPaymasters(filtered);
    
    // 4. 缓存
    saveToCache('registry-paymasters', filtered, 600); // 10 分钟
    
    setLoading(false);
  };
  
  return (
    <div className="registry-explorer">
      <h1>Paymaster Registry</h1>
      <p className="subtitle">
        探索所有注册的社区 Paymaster
      </p>
      
      {/* 筛选器 */}
      <div className="filters">
        <SearchBar
          placeholder="搜索 Paymaster 名称或地址..."
          value={filters.search}
          onChange={(value) => setFilters({ ...filters, search: value })}
        />
        
        <Select
          label="排序"
          value={filters.sortBy}
          onChange={(value) => setFilters({ ...filters, sortBy: value })}
          options={[
            { value: 'reputation', label: '按信用排序' },
            { value: 'fee', label: '按服务费排序' },
            { value: 'operations', label: '按赞助次数排序' },
          ]}
        />
      </div>
      
      {/* Paymaster 列表 */}
      {loading ? (
        <LoadingSpinner />
      ) : (
        <div className="paymaster-grid">
          {paymasters.map(pm => (
            <PaymasterCard
              key={pm.address}
              paymaster={pm}
              onClick={() => navigate(`/explorer/${pm.address}`)}
            />
          ))}
        </div>
      )}
    </div>
  );
}
```

##### **组件: Paymaster Card**

```typescript
// components/explorer/PaymasterCard.tsx
interface PaymasterCardProps {
  paymaster: PaymasterInfo;
  onClick: () => void;
}

export function PaymasterCard({ paymaster, onClick }: PaymasterCardProps) {
  return (
    <div className="paymaster-card" onClick={onClick}>
      {/* Logo */}
      <div className="card-header">
        <img
          src={paymaster.logo || DEFAULT_LOGO}
          alt={paymaster.name}
          className="logo"
        />
        <div className="status">
          {paymaster.paused ? (
            <Badge variant="error">暂停</Badge>
          ) : (
            <Badge variant="success">运行中</Badge>
          )}
        </div>
      </div>
      
      {/* 基本信息 */}
      <div className="card-body">
        <h3>{paymaster.name}</h3>
        <p className="address">{formatAddress(paymaster.address)}</p>
        
        <div className="stats">
          <div className="stat">
            <span className="label">服务费</span>
            <span className="value">{paymaster.serviceFeeRate / 100}%</span>
          </div>
          <div className="stat">
            <span className="label">赞助次数</span>
            <span className="value">{paymaster.totalOperations}</span>
          </div>
          <div className="stat">
            <span className="label">信用评分</span>
            <span className="value">
              {paymaster.reputation}
              <IconStar className="star" />
            </span>
          </div>
        </div>
      </div>
      
      {/* 操作 */}
      <div className="card-footer">
        <Button size="small" variant="secondary">
          查看详情 →
        </Button>
      </div>
    </div>
  );
}
```

##### **页面: Paymaster 详情页**

```typescript
// pages/explorer/PaymasterDetail.tsx (新增路由: /explorer/:address)
export function PaymasterDetail() {
  const { address: pmAddress } = useParams();
  const { address: userAddress, isConnected } = useMetaMask();
  const [paymasterInfo, setPaymasterInfo] = useState<PaymasterInfo | null>(null);
  const [transactions, setTransactions] = useState<Transaction[]>([]);
  const [isOwner, setIsOwner] = useState(false);
  
  useEffect(() => {
    fetchPaymasterDetail();
    fetchTransactions();
    checkOwnership();
  }, [pmAddress, userAddress]);
  
  const checkOwnership = async () => {
    if (!isConnected) {
      setIsOwner(false);
      return;
    }
    
    const provider = new ethers.providers.Web3Provider(window.ethereum);
    const paymaster = new ethers.Contract(pmAddress, PAYMASTER_V4_ABI, provider);
    const owner = await paymaster.owner();
    
    setIsOwner(owner.toLowerCase() === userAddress.toLowerCase());
  };
  
  return (
    <div className="paymaster-detail">
      {/* Header */}
      <div className="detail-header">
        <div className="header-left">
          <img src={paymasterInfo?.logo} alt={paymasterInfo?.name} />
          <div>
            <h1>{paymasterInfo?.name}</h1>
            <p className="address">{pmAddress}</p>
          </div>
        </div>
        
        <div className="header-right">
          {isOwner && (
            <Button
              primary
              onClick={() => navigate(`/operator/manage/${pmAddress}`)}
            >
              🔧 管理 Paymaster
            </Button>
          )}
          <Button
            onClick={() => window.open(`https://sepolia.etherscan.io/address/${pmAddress}`)}
          >
            📋 Etherscan
          </Button>
        </div>
      </div>
      
      {/* 配置信息 (显示所有 PaymasterV4 参数) */}
      <Card>
        <h2>配置信息</h2>
        <table className="config-table">
          <tbody>
            <tr>
              <td>Owner</td>
              <td>{paymasterInfo?.owner}</td>
            </tr>
            <tr>
              <td>Treasury</td>
              <td>{paymasterInfo?.treasury}</td>
            </tr>
            <tr>
              <td>Gas to USD Rate</td>
              <td>${ethers.utils.formatEther(paymasterInfo?.gasToUSDRate || 0)}/ETH</td>
            </tr>
            <tr>
              <td>PNT Price (USD)</td>
              <td>${ethers.utils.formatEther(paymasterInfo?.pntPriceUSD || 0)}</td>
            </tr>
            <tr>
              <td>Service Fee</td>
              <td>{(paymasterInfo?.serviceFeeRate || 0) / 100}%</td>
            </tr>
            <tr>
              <td>Max Gas Cost Cap</td>
              <td>{ethers.utils.formatEther(paymasterInfo?.maxGasCostCap || 0)} ETH</td>
            </tr>
            <tr>
              <td>Min Token Balance</td>
              <td>{ethers.utils.formatEther(paymasterInfo?.minTokenBalance || 0)} PNT</td>
            </tr>
          </tbody>
        </table>
      </Card>
      
      {/* 其他内容... */}
    </div>
  );
}
```

#### 3.3 管理员登录流程

```typescript
// components/AdminLogin.tsx
export function AdminLoginButton({ paymasterAddress }: { paymasterAddress: string }) {
  const { address, isConnected, connect } = useMetaMask();
  const [isOwner, setIsOwner] = useState(false);
  const [checking, setChecking] = useState(false);
  
  useEffect(() => {
    if (isConnected) {
      checkOwnership();
    }
  }, [isConnected, address]);
  
  const checkOwnership = async () => {
    setChecking(true);
    
    const provider = new ethers.providers.Web3Provider(window.ethereum);
    const paymaster = new ethers.Contract(paymasterAddress, PAYMASTER_V4_ABI, provider);
    const owner = await paymaster.owner();
    
    setIsOwner(owner.toLowerCase() === address.toLowerCase());
    setChecking(false);
  };
  
  const handleLoginClick = () => {
    if (!isConnected) {
      connect();
    } else if (isOwner) {
      navigate(`/operator/manage/${paymasterAddress}`);
    } else {
      toast.error('您不是此 Paymaster 的 Owner');
    }
  };
  
  return (
    <Button
      onClick={handleLoginClick}
      loading={checking}
      disabled={isConnected && !isOwner}
    >
      {!isConnected ? (
        '🔐 连接钱包登录'
      ) : isOwner ? (
        '🔧 管理此 Paymaster'
      ) : (
        '❌ 无权限'
      )}
    </Button>
  );
}
```

#### 3.4 第三阶段交付物

✅ **必须完成**:
- [ ] Registry Explorer 页面 (`/explorer`)
- [ ] Paymaster 列表展示
- [ ] Paymaster 详情页 (`/explorer/:address`)
- [ ] 筛选和排序功能
- [ ] 管理员登录验证
- [ ] localStorage 缓存 (10 分钟 TTL)

🎯 **成功标准**:
- 任何人都可以浏览所有 Paymaster
- 管理员可以通过 MetaMask 登录管理自己的 Paymaster
- 页面加载时间 < 3s (缓存后 < 1s)
- 显示所有 PaymasterV4 配置参数

---

### 第四阶段:开发者生态 (Sepolia + Mainnet)

**目标**: 完善开发者体验,提供 SDK 和文档,支持任何 DApp 快速集成

**应用**: `registry` + 独立 `aastar-sdk` repo

#### 4.1 Developer Portal 完善

```
https://superpaymaster.aastar.io/developer
│
├─ 集成指南 (已有基础,需完善)
│   ├─ Quick Start
│   ├─ SDK Installation
│   ├─ Configuration
│   └─ Examples
│
├─ API 文档 (新增)
│   ├─ PaymasterV4 合约 API
│   ├─ Registry 合约 API
│   ├─ SDK API Reference
│   └─ RPC Endpoints
│
├─ 代码示例 (新增)
│   ├─ Basic Transaction
│   ├─ Batch Transactions
│   ├─ Account Deployment
│   ├─ Custom Gas Token
│   └─ Multi-chain Support
│
├─ 工具 (新增)
│   ├─ Paymaster Selector Tool
│   ├─ Gas Estimator
│   └─ UserOp Builder
│
└─ 案例研究 (新增)
    ├─ DApp A: NFT Marketplace
    ├─ DApp B: Gaming Platform
    └─ DApp C: DAO Tools
```

#### 4.2 AAStar SDK 架构

**独立仓库**: `https://github.com/AAStarCommunity/aastar-sdk`

```
@aastar/sdk/
├─ packages/
│   ├─ core/                  # 核心逻辑
│   │   ├─ src/
│   │   │   ├─ account.ts     # 账户管理
│   │   │   ├─ paymaster.ts   # Paymaster 客户端
│   │   │   ├─ bundler.ts     # Bundler 交互
│   │   │   ├─ entrypoint.ts  # EntryPoint 版本适配 🆕
│   │   │   └─ utils.ts
│   │   └─ package.json
│   │
│   ├─ react/                 # React Hooks
│   │   ├─ src/
│   │   │   ├─ useAccount.ts
│   │   │   ├─ usePaymaster.ts
│   │   │   └─ useSendTransaction.ts
│   │   └─ package.json
│   │
│   └─ cli/                   # CLI 工具
│       ├─ src/
│       │   ├─ commands/
│       │   │   ├─ init.ts
│       │   │   ├─ deploy.ts
│       │   │   └─ test.ts
│       │   └─ index.ts
│       └─ package.json
│
├─ examples/
│   ├─ basic-transaction/
│   ├─ nft-marketplace/
│   └─ gaming-platform/
│
└─ docs/
    ├─ getting-started.md
    ├─ api-reference.md
    └─ migration-guide.md
```

#### 4.3 SDK 核心功能

##### **@aastar/sdk/core - EntryPoint 版本支持**

```typescript
// packages/core/src/entrypoint.ts

/**
 * EntryPoint 版本枚举
 * 
 * TODO: 扩展支持更多版本
 * - v0.8: 未来 ERC-4337 升级
 * - 自定义 EntryPoint: 允许用户提供自己的 EntryPoint 地址
 */
export enum EntryPointVersion {
  V0_6 = 'v0.6',
  V0_7 = 'v0.7',
  // TODO: V0_8 = 'v0.8', // 未来版本
}

/**
 * EntryPoint 配置
 */
export interface EntryPointConfig {
  version: EntryPointVersion;
  address: string;
  chainId: number;
}

/**
 * 默认 EntryPoint 地址
 */
export const DEFAULT_ENTRY_POINTS: Record<EntryPointVersion, string> = {
  [EntryPointVersion.V0_6]: '0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789',
  [EntryPointVersion.V0_7]: '0x0000000071727De22E5E9d8BAf0edAc6f37da032',
};

/**
 * UserOperation 类型 (根据 EntryPoint 版本)
 */
export type UserOperation = UserOperationV6 | UserOperationV7;

/**
 * EntryPoint v0.6 UserOperation
 */
export interface UserOperationV6 {
  sender: string;
  nonce: string;
  initCode: string;
  callData: string;
  callGasLimit: string;
  verificationGasLimit: string;
  preVerificationGas: string;
  maxFeePerGas: string;
  maxPriorityFeePerGas: string;
  paymasterAndData: string;  // Paymaster address + data
  signature: string;
}

/**
 * EntryPoint v0.7 UserOperation (PackedUserOperation)
 */
export interface UserOperationV7 {
  sender: string;
  nonce: string;
  factory?: string;          // 分离的工厂地址
  factoryData?: string;      // 分离的工厂数据
  callData: string;
  callGasLimit: string;
  verificationGasLimit: string;
  preVerificationGas: string;
  maxFeePerGas: string;
  maxPriorityFeePerGas: string;
  paymaster?: string;        // 分离的 Paymaster 地址
  paymasterVerificationGasLimit?: string;
  paymasterPostOpGasLimit?: string;
  paymasterData?: string;    // 分离的 Paymaster 数据
  signature: string;
}

/**
 * UserOperation Hash 计算
 * 
 * TODO: 实现不同版本的 hash 计算逻辑
 * - v0.6: keccak256(abi.encode(userOp, entryPoint, chainId))
 * - v0.7: keccak256(abi.encode(packedUserOp, entryPoint, chainId))
 */
export class UserOperationHasher {
  static computeHash(
    userOp: UserOperation,
    entryPointConfig: EntryPointConfig
  ): string {
    switch (entryPointConfig.version) {
      case EntryPointVersion.V0_6:
        return this.computeHashV6(userOp as UserOperationV6, entryPointConfig);
      case EntryPointVersion.V0_7:
        return this.computeHashV7(userOp as UserOperationV7, entryPointConfig);
      default:
        throw new Error(`Unsupported EntryPoint version: ${entryPointConfig.version}`);
    }
  }
  
  private static computeHashV6(
    userOp: UserOperationV6,
    config: EntryPointConfig
  ): string {
    // TODO: 实现 v0.6 hash 计算
    // 参考: https://eips.ethereum.org/EIPS/eip-4337
    throw new Error('V0.6 hash calculation not implemented');
  }
  
  private static computeHashV7(
    userOp: UserOperationV7,
    config: EntryPointConfig
  ): string {
    // TODO: 实现 v0.7 hash 计算
    // 参考: https://github.com/eth-infinitism/account-abstraction/blob/develop/contracts/core/UserOperationLib.sol
    throw new Error('V0.7 hash calculation not implemented');
  }
}

/**
 * EntryPoint Adapter
 * 提供统一接口,适配不同版本的 EntryPoint
 */
export class EntryPointAdapter {
  private config: EntryPointConfig;
  private contract: ethers.Contract;
  
  constructor(
    provider: ethers.providers.Provider,
    config: EntryPointConfig
  ) {
    this.config = config;
    this.contract = new ethers.Contract(
      config.address,
      this.getABI(config.version),
      provider
    );
  }
  
  private getABI(version: EntryPointVersion): any[] {
    // TODO: 返回对应版本的 ABI
    throw new Error('EntryPoint ABI not loaded');
  }
  
  /**
   * 发送 UserOperation
   * 
   * TODO: 实现不同版本的 UserOp 发送逻辑
   */
  async sendUserOperation(
    userOp: UserOperation,
    bundlerUrl: string
  ): Promise<string> {
    switch (this.config.version) {
      case EntryPointVersion.V0_6:
        return this.sendUserOpV6(userOp as UserOperationV6, bundlerUrl);
      case EntryPointVersion.V0_7:
        return this.sendUserOpV7(userOp as UserOperationV7, bundlerUrl);
      default:
        throw new Error(`Unsupported version: ${this.config.version}`);
    }
  }
  
  private async sendUserOpV6(
    userOp: UserOperationV6,
    bundlerUrl: string
  ): Promise<string> {
    // TODO: 实现 v0.6 发送逻辑
    throw new Error('V0.6 sendUserOp not implemented');
  }
  
  private async sendUserOpV7(
    userOp: UserOperationV7,
    bundlerUrl: string
  ): Promise<string> {
    // TODO: 实现 v0.7 发送逻辑
    throw new Error('V0.7 sendUserOp not implemented');
  }
}
```

##### **@aastar/sdk/core - SuperPaymasterClient**

```typescript
// packages/core/src/paymaster.ts

export class SuperPaymasterClient {
  private provider: ethers.providers.Provider;
  private network: Network;
  private registryAddress: string;
  private entryPointConfig: EntryPointConfig;
  
  constructor(config: SuperPaymasterConfig) {
    this.provider = new ethers.providers.JsonRpcProvider(config.rpcUrl);
    this.network = config.network;
    this.registryAddress = config.registryAddress || DEFAULT_REGISTRY[config.network];
    
    // 配置 EntryPoint 版本
    this.entryPointConfig = {
      version: config.entryPointVersion || EntryPointVersion.V0_7,
      address: config.entryPointAddress || DEFAULT_ENTRY_POINTS[config.entryPointVersion || EntryPointVersion.V0_7],
      chainId: CHAIN_IDS[config.network],
    };
  }
  
  /**
   * 自动选择最优 Paymaster
   */
  async selectPaymaster(userAddress: string): Promise<PaymasterInfo> {
    // 实现逻辑 (与原文档相同)
  }
  
  /**
   * 构建 UserOperation (支持不同 EntryPoint 版本)
   */
  async buildUserOp(params: BuildUserOpParams): Promise<UserOperation> {
    const paymaster = params.paymasterAddress
      ? { address: params.paymasterAddress }
      : await this.selectPaymaster(params.sender);
    
    const gasEstimate = await this.estimateGas(params);
    
    // 根据 EntryPoint 版本构建不同结构的 UserOp
    switch (this.entryPointConfig.version) {
      case EntryPointVersion.V0_6:
        return this.buildUserOpV6(params, paymaster, gasEstimate);
      case EntryPointVersion.V0_7:
        return this.buildUserOpV7(params, paymaster, gasEstimate);
      default:
        throw new Error(`Unsupported version: ${this.entryPointConfig.version}`);
    }
  }
  
  private buildUserOpV6(
    params: BuildUserOpParams,
    paymaster: PaymasterInfo,
    gasEstimate: GasEstimate
  ): UserOperationV6 {
    return {
      sender: params.sender,
      nonce: '0', // TODO: 获取实际 nonce
      initCode: params.initCode || '0x',
      callData: params.callData,
      callGasLimit: gasEstimate.callGasLimit,
      verificationGasLimit: gasEstimate.verificationGasLimit,
      preVerificationGas: gasEstimate.preVerificationGas,
      maxFeePerGas: '0', // TODO: 获取 gas price
      maxPriorityFeePerGas: '0',
      paymasterAndData: paymaster.address, // v0.6: Paymaster address only
      signature: '0x',
    };
  }
  
  private buildUserOpV7(
    params: BuildUserOpParams,
    paymaster: PaymasterInfo,
    gasEstimate: GasEstimate
  ): UserOperationV7 {
    return {
      sender: params.sender,
      nonce: '0', // TODO: 获取实际 nonce
      factory: params.factory,
      factoryData: params.factoryData,
      callData: params.callData,
      callGasLimit: gasEstimate.callGasLimit,
      verificationGasLimit: gasEstimate.verificationGasLimit,
      preVerificationGas: gasEstimate.preVerificationGas,
      maxFeePerGas: '0', // TODO: 获取 gas price
      maxPriorityFeePerGas: '0',
      paymaster: paymaster.address, // v0.7: 分离字段
      paymasterVerificationGasLimit: '100000',
      paymasterPostOpGasLimit: '50000',
      paymasterData: '0x',
      signature: '0x',
    };
  }
  
  /**
   * 发送 UserOperation
   */
  async sendUserOp(
    userOp: UserOperation,
    signer: Signer
  ): Promise<{ hash: string; receipt: TransactionReceipt }> {
    // 1. 计算 UserOp hash (根据版本)
    const userOpHash = UserOperationHasher.computeHash(userOp, this.entryPointConfig);
    
    // 2. 签名
    const signature = await signer.signMessage(ethers.utils.arrayify(userOpHash));
    userOp.signature = signature;
    
    // 3. 通过 EntryPoint Adapter 发送
    const adapter = new EntryPointAdapter(this.provider, this.entryPointConfig);
    const hash = await adapter.sendUserOperation(userOp, this.getBundlerUrl());
    
    // 4. 等待上链
    const receipt = await this.waitForUserOp(hash);
    
    return { hash, receipt };
  }
}
```

#### 4.4 第四阶段交付物

✅ **必须完成**:
- [ ] 完善 Developer Portal 页面
- [ ] 独立 SDK 仓库 (https://github.com/AAStarCommunity/aastar-sdk)
  - [ ] @aastar/sdk/core (包含 EntryPoint 版本支持)
  - [ ] @aastar/sdk/react
  - [ ] @aastar/sdk/cli
- [ ] API 文档站点 (docs.aastar.io)
- [ ] 开发者工具
  - [ ] Paymaster Selector
  - [ ] Gas Estimator
  - [ ] UserOp Builder
- [ ] 至少 3 个完整的代码示例
- [ ] 至少 2 个案例研究

🎯 **成功标准**:
- 开发者可以在 30 分钟内完成第一笔无 Gas 交易
- SDK 支持 EntryPoint v0.6 和 v0.7
- SDK 文档完整,有清晰的 Quick Start
- 至少 5 个外部 DApp 成功集成 (内测)

---

## 技术架构

### 系统架构图

```
┌─────────────────────────────────────────────────────────────┐
│                         Frontend Layer                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌────────────────┐  ┌────────────────┐  ┌──────────────┐  │
│  │   Registry     │  │ Demo Playground│  │  Developer   │  │
│  │   Website      │  │                │  │    Docs      │  │
│  │ (superpay*.io) │  │ (aastar.io/demo)│ │(docs.aa*.io) │  │
│  └────────┬───────┘  └───────┬────────┘  └──────┬───────┘  │
│           │                  │                   │          │
│           └──────────┬───────┴───────────────────┘          │
│                      │                                       │
└──────────────────────┼───────────────────────────────────────┘
                       │
┌──────────────────────┼───────────────────────────────────────┐
│                  SDK Layer                                    │
├──────────────────────┼───────────────────────────────────────┤
│                      │                                       │
│            ┌─────────▼──────────┐                            │
│            │  @aastar/sdk/core  │                            │
│            │  - SuperPaymaster  │                            │
│            │    Client          │                            │
│            │  - Account Manager │                            │
│            │  - EntryPoint      │                            │
│            │    Adapter (v0.6/  │                            │
│            │    v0.7 support)   │                            │
│            │  - Bundler Client  │                            │
│            └─────────┬──────────┘                            │
│                      │                                       │
└──────────────────────┼───────────────────────────────────────┘
                       │
┌──────────────────────┼───────────────────────────────────────┐
│                Blockchain Layer                               │
├──────────────────────┼───────────────────────────────────────┤
│                      │                                       │
│  ┌────────┬──────────▼──────┬──────────┬──────────┐         │
│  │        │                 │          │          │         │
│  │  ┌─────▼────────┐  ┌────▼─────┐ ┌──▼──────┐ ┌▼────────┐│
│  │  │PaymasterV4   │  │EntryPoint│ │Registry │ │SBT/PNT  ││
│  │  │              │  │(v0.7)    │ │v1.2     │ │Contracts││
│  │  │- validate    │  │          │ │         │ │         ││
│  │  │- postOp      │  │          │ │         │ │         ││
│  │  │- 8个可配置   │  │          │ │         │ │         ││
│  │  │  参数        │  │          │ │         │ │         ││
│  │  └──────────────┘  └──────────┘ └─────────┘ └─────────┘│
│  │                                                          │
│  │         Ethereum Sepolia / Mainnet / OP                  │
│  └──────────────────────────────────────────────────────────┘
│                                                              │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│                   Data & Infrastructure                       │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ localStorage │  │ Cloudflare   │  │   Bundler    │      │
│  │ (第一次缓存) │  │ KV (未来)    │  │   Service    │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## 开发优先级

### P0 - 必须完成 (阻塞上线)

1. **第一阶段核心**
   - [ ] Gas 分析报告页面
   - [ ] 用户 Gas 记录查询
   - [ ] localStorage 缓存实现

2. **第二阶段核心**
   - [ ] Paymaster 部署向导 (5 步)
   - [ ] EntryPoint Stake 管理
   - [ ] Registry 注册流程
   - [ ] 所有 PaymasterV4 参数配置

3. **第三阶段核心**
   - [ ] Registry Explorer
   - [ ] Paymaster 详情页
   - [ ] 管理员登录验证

### P1 - 重要功能 (影响体验)

1. **第二阶段增强**
   - [ ] SBT/PNT 工厂合约
   - [ ] 批量部署支持
   - [ ] 详细错误提示

2. **第三阶段增强**
   - [ ] Cloudflare KV 缓存 (优化)
   - [ ] 筛选和排序
   - [ ] 搜索功能

3. **第四阶段部分**
   - [ ] @aastar/sdk/core
   - [ ] EntryPoint v0.6/v0.7 支持
   - [ ] 基础代码示例

### P2 - 优化功能 (可延后)

1. **第四阶段完整**
   - [ ] @aastar/sdk/react
   - [ ] @aastar/sdk/cli
   - [ ] 开发者工具 (Selector/Estimator)
   - [ ] 案例研究

2. **性能优化**
   - [ ] The Graph 集成
   - [ ] 前端缓存策略优化
   - [ ] 图片 CDN

3. **高级功能**
   - [ ] EntryPoint v0.8 支持 (未来)
   - [ ] 多链支持 (OP Mainnet)
   - [ ] 自定义 EntryPoint

---

## 时间线

### 快速路径 (6-8 周)

```
Week 1-2: 第一阶段 (Gas 分析)
├─ Week 1: 链上数据查询 + localStorage 缓存
└─ Week 2: 图表集成 + 导出功能

Week 3-4: 第二阶段 (运营者自助)
├─ Week 3: 部署向导 UI + 合约交互
└─ Week 4: EntryPoint + Registry 集成

Week 5-6: 第三阶段 (公开浏览器)
├─ Week 5: Explorer UI + 数据同步
└─ Week 6: 详情页 + 管理员功能

Week 7-8: 第四阶段 (SDK 基础)
├─ Week 7: @aastar/sdk/core + EntryPoint 支持
└─ Week 8: 文档 + 示例 + 测试
```

### 完整路径 (10-12 周)

```
Week 1-2: 第一阶段完整
Week 3-5: 第二阶段完整
Week 6-7: 第三阶段完整
Week 8-10: 第四阶段完整
Week 11-12: 主网准备 + 优化
```

---

## 下一步行动

### 立即可以开始 ✅

1. **确认当前 SuperPaymaster 合约功能**
   ```bash
   cd SuperPaymaster/contracts
   forge test --match-contract PaymasterV4Test
   ```

2. **启动 Registry 项目**
   ```bash
   cd registry
   pnpm install
   pnpm dev
   # 访问 http://localhost:5173
   ```

3. **规划第一阶段 Gas 分析页面**
   - 设计数据结构
   - 确认需要的事件和字段
   - 实现 localStorage 缓存工具

### 需要你确认 ⏳

1. **合约地址确认** ✅ (已更新)
   - PaymasterV4: 0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445
   - Registry v1.2: 0x838da93c815a6E45Aa50429529da9106C0621eF0
   - GasTokenV2 (PNT): 0xD14E87d8D8B69016Fcc08728c33799bD3F66F180

2. **部署脚本确认**
   - `deploy-paymaster-v4.s.sol` 是否可用?
   - `configure-paymaster-v4.s.sol` 是否完整?

3. **Faucet API 扩展**
   - 是否可以添加新端点 (mint-usdt, create-account)?

### 可延后处理 💡

1. **Cloudflare KV** (第三阶段优化)
2. **The Graph 集成** (第三阶段优化)
3. **EntryPoint v0.8** (第四阶段后)

---

## 总结

本计划提供了 SuperPaymaster 生态系统的完整四阶段开发路线图:

1. **第一阶段**: 完善基础 Gas 分析功能,为管理员和用户提供透明的链上记录 (localStorage 缓存)
2. **第二阶段**: 构建运营者自助平台,让任何社区都能快速部署和管理 Paymaster (支持所有 8 个参数配置)
3. **第三阶段**: 公开 Registry Explorer,展示所有 Paymaster,提供管理员登录
4. **第四阶段**: 完善开发者生态,提供 SDK (支持 EntryPoint v0.6/v0.7) 和工具

**关键原则**:
- ✅ **简单优先**: 从 localStorage 缓存开始,逐步优化到 Cloudflare KV
- ✅ **去中心化**: 链上数据为主,缓存为辅
- ✅ **模块化**: Registry 和 SDK 独立开发和部署
- ✅ **禁止破坏**: 只新增页面和路由,不删除或修改原有内容
- ✅ **渐进增强**: P0 → P1 → P2,快速迭代
- ✅ **可扩展性**: SDK 支持多 EntryPoint 版本,预留 TODO

**预期成果**:
- 6-8 周内完成 MVP (P0 功能)
- 10-12 周内完成完整生态 (P0 + P1 + 部分 P2)
- 支撑至少 10 个社区 Paymaster 上线
- 支撑至少 5 个外部 DApp 集成


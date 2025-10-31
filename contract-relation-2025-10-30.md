# 合约部署依赖关系文档

生成日期：2025-10-30
测试状态：✅ 所有测试通过（149/149）

---

## 📊 合约部署依赖关系表

### 1. **基础层（Layer 0）- 无依赖**

| 合约 | 版本 | 构造参数 | 说明 |
|------|------|----------|------|
| **GToken** | ERC20 | `name, symbol, initialSupply` | 治理代币（GT），系统最底层基础 |
| **EntryPoint** | v0.7 | 无 | ERC-4337 官方合约（跨链统一地址） |
| **ETH/USD PriceFeed** | Chainlink | 无 | Chainlink 官方喂价合约 |

### 2. **质押层（Layer 1）- 依赖 GToken**

| 合约 | 版本 | 构造参数 | 依赖 | 部署顺序 |
|------|------|----------|------|----------|
| **GTokenStaking** | v2 | `gtoken` | ← GToken | 2️⃣ |

**说明**：
- 管理 stGT 质押、锁定、解锁、罚没
- 无许可多次 stake（v2 关键特性）
- 提供 Locker 机制供其他合约调用

### 3. **注册层（Layer 2）- 依赖 GTokenStaking**

| 合约 | 版本 | 构造参数 | 依赖 | 部署顺序 |
|------|------|----------|------|----------|
| **Registry** | v2.1.3 | `gtokenStaking` | ← GTokenStaking | 3️⃣ |

**说明**：
- 社区注册（30 stGT 锁定）
- 社区所有权转移（EOA → Gnosis Safe）
- Paymaster 部署注册

### 4. **应用层（Layer 3）- 多依赖**

#### 核心应用

| 合约 | 版本 | 构造参数 | 依赖 | 部署顺序 |
|------|------|----------|------|----------|
| **MySBT** | v2.3.3 | `gtoken, staking, registry, daoMultisig` | ← GToken<br>← GTokenStaking<br>← Registry | 4️⃣ |
| **SuperPaymasterV2** | v2 | `gtokenStaking, registry, ethUsdPriceFeed` | ← GTokenStaking<br>← Registry<br>← PriceFeed | 5️⃣ |

**说明**：
- **MySBT**：社区 SBT，支持 burnSBT() 退出
- **SuperPaymasterV2**：AOA+ 模式共享 paymaster

#### 工厂合约

| 合约 | 版本 | 构造参数 | 依赖 | 部署顺序 | 已部署地址（Sepolia） |
|------|------|----------|------|----------|---------------------|
| **xPNTsFactory** | v1 | `superPaymaster, registry` | ← SuperPaymasterV2<br>← Registry | 6️⃣ | `0xC2AFEA0F736403E7e61D3F7C7c6b4E5E63B5cab6` |
| **MySBTFactory** | v1 | `gtoken, staking` | ← GToken<br>← GTokenStaking | 可选 | `0x7ffd4b7db8a60015fad77530892505bd69c6b8ec` |
| **PaymasterFactory** | v1 | 无 | 无 | 未部署 | N/A |

**重要说明**：
- **MySBT v2.3.3** 是直接部署的合约（不通过 Factory），用于协议核心
- **MySBTFactory** 部署的是 `MySBTWithNFTBinding` 合约（支持 NFT 绑定），用于社区自定义
- **PaymasterV4_1** 是直接部署的合约代码（不通过 Factory），未来可迁移到 Factory 模式实现无许可部署

### 5. **扩展层（Layer 4）- 可选组件**

| 合约 | 版本 | 构造参数 | 依赖 | 部署顺序 |
|------|------|----------|------|----------|
| **DefaultReputationCalculator** | v1 | `mysbt` | ← MySBT | 7️⃣ |
| **xPNTsToken** | 动态 | `name, symbol, communityOwner, communityName, communityENS, exchangeRate` | ← xPNTsFactory | 运行时创建 |

**xPNTsToken 说明**：
- ✅ **构造参数**：
  - `name`：代币名称（如 "MyDAO Points"）
  - `symbol`：代币符号（如 "xMDAO"）
  - `communityOwner`：社区所有者地址
  - `communityName`：社区显示名称
  - `communityENS`：社区 ENS 域名
  - `exchangeRate`：与 aPNTs 的汇率（18 decimals，0 = 默认 1:1）

- ❌ **不包含的参数**：
  - ~~validFrom~~（不存在）
  - ~~validTo~~（不存在）
  - ~~superPaymaster~~（不作为构造参数）

- ⚙️ **SuperPaymaster 授权**：
  - xPNTsFactory 在部署后自动调用 `newToken.addAutoApprovedSpender(SUPERPAYMASTER)`
  - 实现无需 approve 的自动授权机制
  - 用户可直接调用 `SuperPaymaster.depositAPNTs()` 无需预先授权

---

## 🔄 标准部署顺序（Sepolia 实例）

| 步骤 | 合约 | 地址 | 状态 |
|------|------|------|------|
| **0️⃣** | EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | ✅ 官方部署 |
| **0️⃣** | ETH/USD PriceFeed | `0x694AA1769357215DE4FAC081bf1f309aDC325306` | ✅ Chainlink 官方 |
| **1️⃣** | GToken | `0x868F843723a98c6EECC4BF0aF3352C53d5004147` | ✅ 已部署 |
| **2️⃣** | GTokenStaking v2 | `0xB39c0c3c7Fac671Ce26acD7Be5d81192DDc8bB27` | ✅ 已部署 |
| **3️⃣** | Registry v2.1.3 | `0xd8f50dcF723Fb6d0Ec555691c3a19E446a3bb765` | ✅ 已部署 |
| **4️⃣** | MySBT v2.3.3 | `0x3cE0AB2a85Dc4b2B1976AA924CF8047F7afA9324` | ✅ 已部署 |
| **5️⃣** | SuperPaymasterV2 | `0x50c4Daf685170aa29513BA6dd89B8417b5b0FE4a` | ✅ 已部署 |
| **6️⃣** | xPNTsFactory | `0xC2AFEA0F736403E7e61D3F7C7c6b4E5E63B5cab6` | ✅ 已部署 |
| **可选** | MySBTFactory | `0x7ffd4b7db8a60015fad77530892505bd69c6b8ec` | ✅ 已部署 |

---

## 🔗 关键依赖关系图

```
                    ┌──────────────┐
                    │  EntryPoint  │ (官方)
                    │    v0.7      │
                    └──────────────┘
                           ↓
    ┌─────────────────────────────────────────┐
    │                                         │
┌───▼────┐                          ┌─────────▼─────────┐
│ GToken │                          │ ETH/USD PriceFeed │
└───┬────┘                          └─────────┬─────────┘
    │                                         │
    │                                         │
┌───▼───────────┐                             │
│ GTokenStaking │◄────────────┐               │
│      v2       │             │               │
└───┬───────────┘             │               │
    │                         │               │
    │                         │               │
┌───▼────────┐                │               │
│  Registry  │                │               │
│  v2.1.3    │                │               │
└───┬────────┘                │               │
    │                         │               │
    ├─────────────────┬───────┼───────────────┘
    │                 │       │
┌───▼───────┐   ┌─────▼───────▼────┐
│   MySBT   │   │ SuperPaymasterV2 │
│  v2.3.3   │   │       v2         │
└───┬───────┘   └─────┬────────────┘
    │                 │
    │           ┌─────▼─────────┐
    │           │ xPNTsFactory  │
    │           └───┬───────────┘
    │               │
    │               ▼
    │       ┌───────────────┐
    │       │  xPNTsToken   │
    │       │   (runtime)   │
    │       └───────────────┘
    │
┌───▼───────────────────┐
│ ReputationCalculator  │
└───────────────────────┘
```

---

## ⚙️ 配置步骤（部署后必须执行）

| 步骤 | 操作 | 合约 | 方法 | 说明 |
|------|------|------|------|------|
| 1️⃣ | 配置 MySBT Locker | GTokenStaking | `configureLocker(mysbt, true, 0.1 ether, [], [], 0x0)` | 授权 MySBT 锁定用户质押 + 设置 0.1 exitFee |
| 2️⃣ | 设置 Treasury | GTokenStaking | `setTreasury(treasury)` | 配置 exitFee 接收地址 |
| 3️⃣ | 设置 Registry | MySBT | `setRegistry(registry)` | 连接 Registry 验证社区 |
| 4️⃣ | 注册社区（可选） | Registry | `registerCommunity(...)` | 社区注册（30 stGT） |

---

## 📋 测试结果总结

```bash
✅ 所有测试通过：149 个测试全部成功

测试套件统计：
- MySBT_v2.3.t.sol       →  53 tests passed
- PaymasterV3.t.sol      →  34 tests passed
- MySBT_v2.1.t.sol       →  33 tests passed
- SuperPaymasterV2.t.sol →  16 tests passed
- PaymasterV4_1.t.sol    →  10 tests passed
- MySBTWithNFTBinding    →   3 tests passed
```

关键测试覆盖：
- ✅ MySBT burnSBT 退出机制（exitFee 分配验证）
- ✅ GTokenStaking 多次 stake（无许可设计）
- ✅ Registry 社区注册和验证
- ✅ SuperPaymasterV2 集成流程
- ✅ NFT 绑定和声誉计算

---

## 🏗️ 无许可部署能力分析

### 当前状态：

| 组件 | 部署方式 | 无许可性 | 说明 |
|------|---------|---------|------|
| **xPNTs** | xPNTsFactory | ✅ 完全无许可 | 任何社区都可以通过 Factory 部署自己的 xPNTs 代币 |
| **MySBT (NFT binding)** | MySBTFactory | ✅ 完全无许可 | 社区可部署支持 NFT 绑定的自定义 SBT |
| **Paymaster V4** | 直接部署代码 | ❌ 需手动部署 | 当前需从代码文件直接部署 |
| **MySBT v2.3.3** | 直接部署代码 | ❌ 协议核心 | 协议官方部署，非社区自定义 |

### 改进建议：

1. **PaymasterFactory 激活**：
   - 设置 PaymasterV4_1 为默认实现
   - 允许社区无许可部署自己的 Paymaster
   - 使用 EIP-1167 Minimal Proxy 降低 gas 成本

2. **统一工厂模式**：
   - 所有社区自定义合约（xPNTs, MySBT, Paymaster）均通过 Factory 部署
   - Factory 提供标准化配置和验证
   - 协议核心合约（如 MySBT v2.3.3）仍保持直接部署

---

## 📝 版本历史

### v2.3.3 (2025-10-30)
- MySBT 新增 burnSBT() 完整退出机制
- MySBT 新增 leaveCommunity() 部分退出
- GTokenStaking v2 移除 AlreadyStaked 限制
- Registry v2.1.3 新增 transferCommunityOwnership()

### v2.1.3 (2025-10-30)
- Registry 支持社区所有权转移（EOA → Gnosis Safe）

### v2.0 (2025-10-25)
- SuperPaymasterV2 部署（AOA+ 模式）
- xPNTsFactory 部署（无许可 xPNTs 发行）

---

**文档生成时间**: 2025-10-30
**测试覆盖率**: 149/149 (100%)
**部署网络**: Sepolia Testnet

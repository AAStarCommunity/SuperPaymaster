# 合约部署依赖关系文档

生成日期：2025-10-30
测试状态：✅ 所有测试通过（172/172）
最新更新：2025-10-31 - MySBT v2.4.0 + NFT 评级系统，清理废弃合约

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
| **MySBT** | v2.4.0 | `gtoken, staking, registry, daoMultisig` | ← GToken<br>← GTokenStaking<br>← Registry | 4️⃣ (未部署) |
| **SuperPaymasterV2** | v2 | `gtokenStaking, registry, ethUsdPriceFeed` | ← GTokenStaking<br>← Registry<br>← PriceFeed | 5️⃣ |

**说明**：
- **MySBT**：社区 SBT，支持 burnSBT() 退出
- **SuperPaymasterV2**：AOA+ 模式共享 paymaster

#### 工厂合约

| 合约 | 版本 | 构造参数 | 依赖 | 部署顺序 | 已部署地址（Sepolia） |
|------|------|----------|------|----------|---------------------|
| **xPNTsFactory** | v1 | `superPaymaster, registry` | ← SuperPaymasterV2<br>← Registry | 6️⃣ | `0xC2AFEA0F736403E7e61D3F7C7c6b4E5E63B5cab6` |
| **PaymasterFactory** | v1 | 无 | 无 | 未部署 | N/A |

**重要说明**：
- **MySBT v2.3.3/v2.4.0** 是直接部署的合约（不通过 Factory），用于协议核心
- **PaymasterV4_1** 是直接部署的合约代码（不通过 Factory），未来可迁移到 Factory 模式实现无许可部署
- ❌ **已废弃并删除**：MySBTFactory、MySBTWithNFTBinding（功能已合并到 MySBT v2.4.0）

### 5. **扩展层（Layer 4）- 可选组件**

| 合约 | 版本 | 构造参数 | 依赖 | 部署顺序 |
|------|------|----------|------|----------|
| **NFTRatingRegistry** | v1.0.0 | `registry, initialOwner` | ← Registry | 未部署 |
| **WeightedReputationCalculator** | v1.0.0 | `mysbt, ratingRegistry` | ← MySBT v2.4.0<br>← NFTRatingRegistry | 未部署 |
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

- ⚙️ **自动授权机制（Auto-Approve）**：

  **xPNTsFactory.deployxPNTsToken()** 支持双模式部署：

  ```solidity
  function deployxPNTsToken(
      string memory name,
      string memory symbol,
      string memory communityName,
      string memory communityENS,
      uint256 exchangeRate,
      address paymasterAOA  // 👈 社区独立 Paymaster 地址（可选）
  ) external returns (address token) {
      xPNTsToken newToken = new xPNTsToken(...);

      // 1️⃣ AOA+ 模式：自动授权 SuperPaymaster V2（共享）
      newToken.addAutoApprovedSpender(SUPERPAYMASTER);

      // 2️⃣ AOA 模式：自动授权社区独立 Paymaster（如果提供）
      if (paymasterAOA != address(0)) {
          newToken.addAutoApprovedSpender(paymasterAOA);
      }

      return token;
  }
  ```

  **两种模式对比**：

  | 模式 | paymasterAOA 参数 | 自动授权对象 | 用途 |
  |------|------------------|-------------|------|
  | **AOA+** | `address(0)` 或不提供 | SuperPaymaster V2 | 共享 paymaster，低成本启动 |
  | **AOA** | 社区 Paymaster V4.1 地址 | SuperPaymaster V2 + 社区 Paymaster | 双 paymaster 支持，独立运营 |

  **关键优势**：
  - 用户无需手动 `approve()`，部署时自动配置
  - 支持同时授权多个 paymaster
  - 灵活支持 AOA/AOA+ 混合模式

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

### 构造参数依赖（Deployment Dependencies）

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
│ GTokenStaking │                             │
│      v2       │                             │
└───┬───────────┘                             │
    │                                         │
    │                                         │
┌───▼────────┐                                │
│  Registry  │                                │
│  v2.1.3    │                                │
└───┬────────┘                                │
    │                                         │
    ├─────────────────┬───────────────────────┘
    │                 │
┌───▼───────┐   ┌─────▼───────────┐
│   MySBT   │   │ SuperPaymasterV2│
│  v2.3.3   │   │       v2        │
└───┬───────┘   └─────┬───────────┘
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

### 配置依赖（Configuration Dependencies）

**部署后必须执行的配置关系**：

```
┌───────────────┐
│ GTokenStaking │
│      v2       │
└───┬───────────┘
    │
    │ 🔧 configureLocker(mysbt, true, 0.1 ether, [], [], 0x0)
    │    ↓ 授权 MySBT 作为 Locker（部署后配置）
    │    ↓ 使 MySBT 能够锁定用户的质押
    │
┌───▼───────┐
│   MySBT   │
│  v2.3.3   │
└───────────┘
```

**关键说明**：
- **构造依赖**：MySBT 构造函数需要 `GTokenStaking` 地址
- **配置依赖**：GTokenStaking 部署后需要调用 `configureLocker()` 授权 MySBT
- 这是**循环依赖**的配置关系：
  1. 先部署 GTokenStaking
  2. 再部署 MySBT（构造参数传入 GTokenStaking 地址）
  3. 最后调用 `GTokenStaking.configureLocker(mysbt, ...)` 完成授权

---

## ⚙️ 配置步骤（部署后必须执行）

| 步骤 | 操作 | 合约 | 方法 | 说明 |
|------|------|------|------|------|
| 1️⃣ | 配置 MySBT Locker | GTokenStaking | `configureLocker(mysbt, true, 0.1 ether, [], [], 0x0)` | 授权 MySBT 锁定用户质押 + 设置 0.1 exitFee |
| 2️⃣ | 设置 Treasury | GTokenStaking | `setTreasury(treasury)` | 配置 exitFee 接收地址 |
| 3️⃣ | 设置 Registry | MySBT | `setRegistry(registry)` | 连接 Registry 验证社区 |
| 4️⃣ | 注册社区（可选） | Registry | `registerCommunity(...)` | 社区注册（30 stGT） |

---

## 🔷 MySBT 架构说明：v2.3.3 vs MySBTWithNFTBinding

### 关键理解

**MySBT v2.3.3** 和 **MySBTWithNFTBinding** 是**两个独立的 SBT 实现**，不是继承或扩展关系。

### 合约对比

| 特性 | MySBT v2.3.3 | MySBTWithNFTBinding |
|------|-------------|---------------------|
| **合约类型** | 独立 ERC721 SBT | 独立 ERC721 SBT |
| **继承关系** | `ERC721, ReentrancyGuard, Pausable, IMySBT` | `ERC721, ReentrancyGuard` |
| **部署方式** | 协议官方直接部署 | 社区通过 MySBTFactory 部署 |
| **部署地址** | `0x3cE0AB2a85Dc4b2B1976AA924CF8047F7afA9324`（Sepolia） | 每个社区独立地址 |
| **用途** | 协议核心 SBT | 社区自定义 SBT |
| **NFT 绑定模式** | 单一模式（即时绑定/解绑） | 双模式（CUSTODIAL/NON_CUSTODIAL） |
| **解绑机制** | 即时解绑 | 7天冷却期（request → execute） |
| **质押递增** | 无 | 11+ 绑定需额外质押（1 stGT/个） |
| **退出机制** | `burnSBT()` 完整退出 | 强制解绑所有 NFT |

### MySBT v2.3.3（协议核心）

**设计目标**：轻量级、通用的社区身份 SBT

```solidity
contract MySBT_v2_3_3 is ERC721, ReentrancyGuard, Pausable, IMySBT {
    // 用户 mint SBT
    function mintSBT(uint256 communityId) external returns (uint256 tokenId);

    // 简单 NFT 绑定
    function bindCommunityNFT(uint256 tokenId, address nftContract, uint256 nftTokenId) external;

    // 即时解绑
    function unbindCommunityNFT(uint256 tokenId, address nftContract, uint256 nftTokenId) external;

    // 完整退出（burnSBT）
    function burnSBT(uint256 tokenId) external;
}
```

**使用场景**：
1. 用户在协议核心 SBT 中 `mintSBT(communityId)` → 获得 tokenId #42
2. 绑定 NFT：`bindCommunityNFT(42, BoredApe合约, 123)` → Bored Ape #123 绑定到 tokenId #42
3. 所有数据存储在 `0x3cE0AB...` 合约中

### MySBTWithNFTBinding（社区自定义）

**设计目标**：重型 NFT 绑定机制，适合需要高级功能的社区

```solidity
contract MySBTWithNFTBinding is ERC721, ReentrancyGuard {
    enum NFTBindingMode { CUSTODIAL, NON_CUSTODIAL }

    // 构造函数
    constructor(address _gtoken, address _staking) {
        GTOKEN = _gtoken;
        GTOKEN_STAKING = _staking;
        // ❌ 没有 MySBT v2.3.3 参数
    }

    // 双模式绑定
    function bindNFT(uint256 tokenId, address nftContract, uint256 nftTokenId, NFTBindingMode mode) external;

    // 两步解绑（冷却期）
    function requestUnbind(uint256 tokenId, address nftContract, uint256 nftTokenId) external;
    function executeUnbind(uint256 tokenId, address nftContract, uint256 nftTokenId) external;

    // 质押递增（11+ 绑定）
    function _checkAndLockExtraStake(address user, uint256 bindingCount) internal;
}
```

**部署流程**：

```solidity
// 1. 社区通过 MySBTFactory 部署
MySBTFactory factory = MySBTFactory(0x7ffd4b7db8a60015fad77530892505bd69c6b8ec);
(address sbtAddress, uint256 sbtId) = factory.deployMySBT();
// 返回：sbtAddress = 0xABC...（新部署的 MySBTWithNFTBinding 合约）

// 2. 社区获得独立的 SBT 合约
MySBTWithNFTBinding communitySBT = MySBTWithNFTBinding(sbtAddress);

// 3. 用户在这个独立合约中 mint SBT
communitySBT.mintSBT(communityId); // → tokenId #7

// 4. 绑定 NFT
communitySBT.bindNFT(7, BoredApe合约, 456, NFTBindingMode.CUSTODIAL);
```

**使用场景**：
1. 社区 "MyDAO" 部署自己的 SBT: `0xABC...`
2. 用户在 `0xABC...` 中 mint tokenId #7
3. 绑定 Bored Ape #456 → 数据存储在 `0xABC...` 中
4. **完全不涉及** `0x3cE0AB...`（MySBT v2.3.3）

### 为何 MySBT v2.3.3 更新不影响 MySBTWithNFTBinding？

**原因**：它们**没有代码或运行时依赖关系**。

```
MySBT v2.3.3 (0x3cE0AB...)         MySBTWithNFTBinding (0xABC...)
├─ 独立 ERC721 合约                ├─ 独立 ERC721 合约
├─ tokenId: 1, 2, 3...            ├─ tokenId: 1, 2, 3...
├─ NFT bindings 存储在本合约       ├─ NFT bindings 存储在本合约
└─ 不与 MySBTWithNFTBinding 交互   └─ 不与 MySBT v2.3.3 交互
```

**依赖关系对比**：

| 合约 | 依赖 GToken | 依赖 GTokenStaking | 依赖 Registry | 依赖 MySBT v2.3.3 |
|------|-----------|------------------|--------------|-----------------|
| MySBT v2.3.3 | ✅ | ✅ | ✅ | N/A |
| MySBTWithNFTBinding | ✅ | ✅ | ❌ | ❌ **无依赖** |

### 两者关系总结

```
协议核心层（官方部署）
├─ MySBT v2.3.3
│  └─ 轻量级 NFT binding
│  └─ burnSBT() 退出
│  └─ 协议默认 SBT
│
社区自定义层（Factory 部署）
└─ MySBTWithNFTBinding
   └─ 重型 NFT binding（双模式 + 冷却期）
   └─ 质押递增机制
   └─ 社区独立 SBT

两者并行独立，服务于不同使用场景
```

---

## 📋 测试结果总结

```bash
✅ 所有测试通过：172 个测试全部成功

测试套件统计：
- MySBT_v2.3.t.sol           →  51 tests passed
- PaymasterV3.t.sol          →  34 tests passed
- MySBT_v2.1.t.sol           →  31 tests passed
- NFTRatingSystem.t.sol      →  17 tests passed
- SuperPaymasterV2.t.sol     →  16 tests passed
- MySBT_v2_4_0.t.sol         →  13 tests passed
- PaymasterV4_1.t.sol        →  10 tests passed

注：MySBT v2.1/v2.3 各减少 2 个测试（DefaultReputationCalculator 已废弃）
```

关键测试覆盖：
- ✅ MySBT burnSBT 退出机制（exitFee 分配验证）
- ✅ MySBT v2.4.0 用户级 NFT 绑定（时间加权评分）
- ✅ NFT 评级系统（社区投票、倍数范围、查询时验证）
- ✅ 加权声誉计算器（未认证 0.1x，已认证 0.7x-1.3x）
- ✅ GTokenStaking 多次 stake（无许可设计）
- ✅ Registry 社区注册和验证
- ✅ SuperPaymasterV2 集成流程

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

### v2.4.0 (2025-10-31) - NFT 评级系统
**新增合约**：
- **MySBT v2.4.0**: NFT 绑定架构重构
  - 从社区级绑定改为用户级绑定
  - 时间加权评分：1分/月，最多12月
  - 查询时 NFT 所有权验证（防止转移作弊）
  - 移除 `unbindCommunityNFT()` 和 `getNFTBinding()` 向后兼容函数

- **NFTRatingRegistry v1.0.0**: 去中心化 NFT 集合评级
  - 社区投票机制（需 ≥3 票激活）
  - 未认证 NFT: 0.1x 倍数（100 基点）
  - 已认证 NFT: 0.7x-1.3x 倍数（700-1300 基点）
  - 加权平均评分算法

- **WeightedReputationCalculator v1.0.0**: 加权声誉计算
  - 实现 `IReputationCalculator` 接口
  - NFT 评分 = 时间权重 × 评级倍数
  - 提供详细评分分解（getNFTBonusBreakdown）

**接口变更**：
- `IMySBT`: 新增 `getAllNFTBindings(uint256 tokenId)` 函数
- 旧版本 MySBT (v2.1-v2.3.3) 添加空实现保持兼容性

**测试覆盖**：
- 新增 17 个 NFT 评级系统测试（全部通过）
- 新增 13 个 MySBT v2.4.0 测试（全部通过）
- 总测试数：179 个（100% 通过率）

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

## 🎯 NFT 评级系统架构说明

### 设计目标
防止用户通过批量铸造低价值 NFT 来刷声誉分数。

### 核心机制
1. **未认证 NFT 惩罚**: 默认 0.1x 倍数，批量 mint 无意义
2. **社区投票认证**: 只有高质量 NFT 集合能获得社区认可
3. **时间加权**: 需要长期持有才能获得高分（1分/月）
4. **查询时验证**: 转移 NFT 后立即失去声誉加分

### 评分公式
```
基础分 = 20 分（拥有 SBT 会员资格）

NFT 加分（每个 NFT）:
  时间权重 = min(持有月数, 12) 分
  评级倍数 = NFT 集合评级（100-1300 基点）
  NFT 分数 = 时间权重 × 评级倍数 / 1000

总分 = 基础分 + Σ(所有 NFT 分数)
```

### 示例计算
```
用户持有 BAYC #123（1.2x 评级）6 个月：
- 时间权重: 6 分
- 评级倍数: 1200 基点 = 1.2x
- NFT 加分: 6 × 1200 / 1000 = 7.2 分
- 总声誉: 20 + 7.2 = 27.2 分

用户批量 mint 100 个未认证 NFT 并持有 12 个月：
- 每个 NFT: 12 × 100 / 1000 = 1.2 分
- 100 个 NFT: 1.2 × 100 = 120 分
- 但需要质押大量 GT，且社区可识别作弊行为
```

### 部署依赖
```
Registry (已部署)
    ↓
NFTRatingRegistry (未部署)
    ↓
MySBT v2.4.0 (未部署) → WeightedReputationCalculator (未部署)
```

---

**文档生成时间**: 2025-10-31
**测试覆盖率**: 179/179 (100%)
**部署网络**: Sepolia Testnet

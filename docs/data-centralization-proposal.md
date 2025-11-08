# Registry 数据中心化改进方案

## 一、当前数据存储分析

### 1.1 数据冗余问题

| 数据字段 | Registry | xPNTsToken | xPNTsFactory | MySBT | 问题 |
|---------|---------|------------|--------------|-------|------|
| Community Name | ✅ `name` | ✅ `communityName` | ❌ | ❌ | **数据冗余** |
| Community ENS | ✅ `ensName` | ✅ `communityENS` | ❌ | ❌ | **数据冗余** |
| xPNTs Token | ✅ `xPNTsToken` | N/A | ✅ `communityToToken` | ❌ | **映射重复** |
| Paymaster Address | ✅ `paymasterAddress` | ❌ | ❌ | ❌ | ✅ 正确 |
| Node Type | ✅ `nodeType` | ❌ | ❌ | ❌ | ✅ 正确 |
| Supported SBTs | ✅ `supportedSBTs[]` | ❌ | ❌ | ❌ | ✅ 正确 |

### 1.2 数据不一致风险

**场景 1**: 用户在 GetXPNTs 页面部署 token 时输入的 `Community Name` 与在 RegisterCommunity 页面输入的不一致。

```typescript
// GetXPNTs.tsx (第 120-121 行)
deployxPNTsToken(
    tokenName,
    tokenSymbol,
    communityName || tokenName,  // ⚠️ 用户可自由输入
    communityENS || "",          // ⚠️ 用户可自由输入
    exchangeRateWei,
    paymasterAddr
)
```

**场景 2**: xPNTsToken 合约存储的 `communityName` 无法被更新，而 Registry 的 `name` 可以被更新。

---

## 二、数据模型重构方案

### 2.1 核心原则

1. **单一数据源（Single Source of Truth）**: Registry 作为唯一的社区元数据存储
2. **合约职责分离**:
   - Registry → 存储社区元数据
   - xPNTsToken → 存储 token 经济模型数据（exchangeRate）
   - MySBT → 存储用户会员关系
3. **自动化数据同步**: 部署合约后自动更新 Registry

### 2.2 推荐数据架构

```
┌─────────────────────────────────────────────────────────────┐
│                        Registry (数据中心)                    │
├─────────────────────────────────────────────────────────────┤
│ CommunityProfile {                                           │
│   name: "My Community"           // ✅ 唯一存储位置          │
│   ensName: "mycommunity.eth"    // ✅ 唯一存储位置          │
│   xPNTsToken: 0x123...          // ✅ 指向 xPNTs 地址       │
│   supportedSBTs: [0xABC...]     // ✅ 唯一存储位置          │
│   paymasterAddress: 0x456...    // ✅ 唯一存储位置          │
│   nodeType: SUPER               // ✅ 唯一存储位置          │
│   ...                                                         │
│ }                                                             │
└─────────────────────────────────────────────────────────────┘
           │                          │
           ├──────────────────────────┼─────────────────┐
           ▼                          ▼                 ▼
  ┌────────────────┐        ┌──────────────┐   ┌─────────────┐
  │  xPNTsToken    │        │    MySBT     │   │ Paymaster   │
  ├────────────────┤        ├──────────────┤   ├─────────────┤
  │ ❌ communityName│       │ ❌ community  │   │ owner: addr │
  │ ❌ communityENS │       │ Registry ptr │   └─────────────┘
  │ ✅ exchangeRate │       │ membership[] │
  │ ✅ FACTORY      │       └──────────────┘
  └────────────────┘
```

---

## 三、具体改进方案

### 3.1 合约层改进

#### 方案 A: 移除 xPNTsToken 冗余字段（推荐）

**目标**: xPNTsToken 不再存储 `communityName` 和 `communityENS`

**变更**:
```solidity
// ❌ 移除
string public communityName;
string public communityENS;

// ✅ 保留
address public immutable FACTORY;
address public communityOwner;
uint256 public exchangeRate;
```

**优点**:
- 数据唯一性，避免不一致
- 减少合约存储成本
- 简化合约逻辑

**缺点**:
- **破坏性变更**，需要重新部署 xPNTsToken 和 xPNTsFactory
- 前端需要从 Registry 读取 community 信息

#### 方案 B: 保持现状但强制同步（妥协）

**目标**: xPNTsToken 保留字段，但部署时从 Registry 读取

**实现**:
```solidity
// xPNTsFactory.sol
function deployxPNTsToken(
    string memory name,
    string memory symbol,
    uint256 _exchangeRate,
    address paymasterAOA
) external returns (address token) {
    // 从 Registry 读取社区信息
    (string memory communityName, string memory ensName,,,,,,,,,) =
        IRegistry(REGISTRY).communities(msg.sender);

    // 使用 Registry 的数据部署
    token = new xPNTsToken(
        name,
        symbol,
        msg.sender,
        communityName,  // 从 Registry 读取
        ensName,        // 从 Registry 读取
        _exchangeRate
    );

    // ...
}
```

**优点**:
- 非破坏性变更
- 保持合约接口兼容性

**缺点**:
- 依然存在数据冗余
- 需要社区先注册才能部署 xPNTs

---

### 3.2 前端页面改进

#### 改进 1: GetXPNTs.tsx 移除冗余字段

**当前**（第 25-26 行）:
```typescript
const [communityName, setCommunityName] = useState<string>("");
const [communityENS, setCommunityENS] = useState<string>("");
```

**改进后**:
```typescript
// ❌ 移除 communityName 和 communityENS 字段
// ✅ 从 Registry 读取社区信息（如果已注册）
```

**UI 变更**:
```tsx
// 移除这两个输入框:
// - Community Name (optional)
// - Community ENS (optional)

// 添加提示:
⚠️ 部署 xPNTs 前请先注册社区
如果尚未注册，请前往 <Link to="/register-community">注册社区</Link>
```

#### 改进 2: GetXPNTs.tsx 自动注册到 Registry

**新增功能**: 部署成功后自动调用 `Registry.updateCommunityToken()`

```typescript
// GetXPNTs.tsx 部署成功后
const handleDeployToken = async () => {
  // ... 部署 xPNTs token

  await tx.wait();
  const tokenAddress = await factory.getTokenAddress(account);

  // ✅ 自动更新 Registry
  const registryContract = new ethers.Contract(
    REGISTRY_ADDRESS,
    RegistryV2_1_4ABI,
    signer
  );

  const updateTx = await registryContract.updateCommunityToken(tokenAddress);
  await updateTx.wait();

  console.log("✅ xPNTs token registered to Registry");
};
```

#### 改进 3: RegisterCommunity.tsx 检测 xPNTs 状态

**新增功能**: 页面加载时检测用户是否已部署 xPNTs

```typescript
// RegisterCommunity.tsx
const [xPNTsToken, setXPNTsToken] = useState<string>("");
const [hasXPNTs, setHasXPNTs] = useState<boolean>(false);

// 检测 xPNTs 状态
const checkXPNTsStatus = async (address: string) => {
  const factory = new ethers.Contract(
    XPNTS_FACTORY_ADDRESS,
    xPNTsFactoryABI,
    provider
  );

  const hasToken = await factory.hasToken(address);
  setHasXPNTs(hasToken);

  if (hasToken) {
    const tokenAddress = await factory.getTokenAddress(address);
    setXPNTsToken(tokenAddress);
  }
};

// UI 渲染
{!hasXPNTs ? (
  <div className="info-box">
    <p>🔗 尚未部署 xPNTs Token</p>
    <Link to="/get-xpnts" className="deploy-link">
      点击部署 xPNTs Token →
    </Link>
    <small>也可以稍后部署</small>
  </div>
) : (
  <div className="form-group">
    <label>xPNTs Token ✅</label>
    <input
      type="text"
      value={xPNTsToken}
      disabled
      className="readonly-input"
    />
    <small>已自动检测到您的 xPNTs Token</small>
  </div>
)}
```

---

## 四、数据流改进

### 4.1 推荐流程（方案 A - 先注册社区）

```
步骤 1: 注册社区（Register Community）
  ├── 用户输入: name, ensName, nodeType, stakeAmount
  ├── 提交: Registry.registerCommunity(profile, stakeAmount)
  └── 结果: CommunityProfile 存储到链上

步骤 2: 部署 xPNTs（Get xPNTs） [可选]
  ├── 前置检查: Registry.isRegisteredCommunity(msg.sender) ✅
  ├── 用户输入: tokenName, tokenSymbol, exchangeRate
  ├── 自动读取: communityName, ensName from Registry
  ├── 提交: xPNTsFactory.deployxPNTsToken(...)
  ├── 自动更新: Registry.updateCommunityToken(tokenAddress)
  └── 结果: xPNTs 地址写入 Registry

步骤 3: 部署 Paymaster（Launch Paymaster）[可选]
  ├── 前置检查: Registry.isRegisteredCommunity(msg.sender) ✅
  ├── AOA 模式: PaymasterFactory.deployPaymaster(...)
  ├── 自动更新: Registry.updatePaymaster(paymasterAddress)
  └── 结果: Paymaster 地址写入 Registry
```

### 4.2 旧流程问题（当前）

```
❌ 问题流程:
步骤 1: 部署 xPNTs (Get xPNTs)
  ├── 用户输入: tokenName, communityName, communityENS
  └── 结果: communityName 存储在 xPNTsToken ⚠️

步骤 2: 注册社区 (Register Community)
  ├── 用户输入: name, ensName  // ⚠️ 可能与 xPNTs 不一致
  └── 结果: name 存储在 Registry ⚠️

⚠️ 数据不一致: xPNTsToken.communityName ≠ Registry.name
```

---

## 五、Registry 新增函数建议

### 5.1 updateCommunityToken()

```solidity
/// @notice 更新社区的 xPNTs Token 地址
/// @param tokenAddress xPNTs Token 地址
function updateCommunityToken(address tokenAddress) external {
    if (!isRegisteredCommunity(msg.sender)) {
        revert CommunityNotRegistered(msg.sender);
    }

    communities[msg.sender].xPNTsToken = tokenAddress;
    communities[msg.sender].lastUpdatedAt = block.timestamp;

    emit CommunityTokenUpdated(msg.sender, tokenAddress);
}
```

### 5.2 updatePaymaster()

```solidity
/// @notice 更新社区的 Paymaster 地址
/// @param paymasterAddress Paymaster 地址
function updatePaymaster(address paymasterAddress) external {
    if (!isRegisteredCommunity(msg.sender)) {
        revert CommunityNotRegistered(msg.sender);
    }

    communities[msg.sender].paymasterAddress = paymasterAddress;
    communities[msg.sender].lastUpdatedAt = block.timestamp;

    emit PaymasterUpdated(msg.sender, paymasterAddress);
}
```

### 5.3 addSupportedSBT()

```solidity
/// @notice 添加支持的 SBT 地址
/// @param sbtAddress SBT 合约地址
function addSupportedSBT(address sbtAddress) external {
    if (!isRegisteredCommunity(msg.sender)) {
        revert CommunityNotRegistered(msg.sender);
    }

    if (communities[msg.sender].supportedSBTs.length >= MAX_SUPPORTED_SBTS) {
        revert MaxSBTsReached();
    }

    communities[msg.sender].supportedSBTs.push(sbtAddress);
    communities[msg.sender].lastUpdatedAt = block.timestamp;

    emit SBTAdded(msg.sender, sbtAddress);
}
```

---

## 六、数据查询优化

### 6.1 统一数据读取接口

```typescript
// ✅ 推荐: 使用 Registry 作为唯一数据源
const getCommunityInfo = async (communityAddress: string) => {
  const registry = new ethers.Contract(
    REGISTRY_ADDRESS,
    RegistryV2_1_4ABI,
    provider
  );

  const profile = await registry.getCommunityProfile(communityAddress);

  return {
    name: profile.name,
    ensName: profile.ensName,
    xPNTsToken: profile.xPNTsToken,
    paymaster: profile.paymasterAddress,
    nodeType: profile.nodeType,
    supportedSBTs: profile.supportedSBTs,
    isActive: profile.isActive,
    allowPermissionlessMint: profile.allowPermissionlessMint,
  };
};
```

```typescript
// ❌ 不推荐: 从多个合约读取
const xPNTsToken = await factory.getTokenAddress(community);
const token = new ethers.Contract(xPNTsToken, xPNTsABI, provider);
const communityName = await token.communityName();  // ⚠️ 可能不一致
```

---

## 七、实施计划

### Phase 1: 前端改进（非破坏性，立即实施）

- [x] **PR #1**: RegisterCommunity.tsx 检测 xPNTs 状态
  - 检测用户是否已部署 xPNTs
  - 如果有，自动填充地址（只读）
  - 如果没有，显示链接到 GetXPNTs

- [x] **PR #2**: GetXPNTs.tsx 移除冗余字段
  - 移除 Community Name 输入框
  - 移除 Community ENS 输入框
  - 添加提示：需要先注册社区

- [x] **PR #3**: GetXPNTs.tsx 自动更新 Registry
  - 部署成功后调用 `Registry.updateCommunityToken()`
  - 显示更新成功提示

### Phase 2: 合约改进（需要重新部署）

- [ ] **PR #4**: Registry 新增函数
  - `updateCommunityToken(address)`
  - `updatePaymaster(address)`
  - `addSupportedSBT(address)`

- [ ] **PR #5**: xPNTsFactory 读取 Registry
  - `deployxPNTsToken()` 从 Registry 读取 communityName/ENS
  - 或完全移除 communityName/ENS 参数（方案 A）

### Phase 3: 文档更新

- [ ] **PR #6**: 更新 data-relation.md
  - 标注数据中心化架构
  - 更新数据流图

---

## 八、决策建议

### 推荐方案: **Phase 1 (前端改进) + Phase 2 方案 B (合约妥协)**

**理由**:
1. **短期**: Phase 1 可立即实施，提升 UX，无需重新部署合约
2. **中期**: Phase 2 方案 B 保持兼容性，从 Registry 读取数据
3. **长期**: 如果需要进一步优化，可考虑方案 A（完全移除冗余字段）

**优先级**:
- **P0 (High)**: PR #1, #2, #3 - 立即改进前端
- **P1 (Medium)**: PR #4 - 新增 Registry 函数
- **P2 (Low)**: PR #5, #6 - 合约重构与文档

---

## 九、FAQ

### Q1: 为什么不在 xPNTsToken 中移除 communityName？

**A**: 有两种选择：
- **方案 A (理想)**: 完全移除，数据唯一性最佳，但需要重新部署
- **方案 B (妥协)**: 保留但强制从 Registry 读取，保持兼容性

建议先实施 Phase 1（前端改进），再根据实际需求决定是否重新部署合约。

### Q2: 如果用户先部署 xPNTs，再注册社区怎么办？

**A**: 当前可以，但会导致数据不一致。改进后：
- **推荐流程**: 先注册社区 → 再部署 xPNTs
- **旧用户**: 可通过 `Registry.updateCommunityToken()` 补救

### Q3: Registry 的 `supportedSBTs` 字段如何使用？

**A**: 该字段用于记录社区支持的 SBT 合约列表（例如多个版本的 MySBT）。当前自动 getter 无法返回该字段，前端应使用 `getCommunityProfile()` 读取。

---

**文档版本**: v1.0.0
**更新日期**: 2025-11-06
**作者**: Claude Code
**审阅**: Pending

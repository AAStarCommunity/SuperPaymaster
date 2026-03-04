# UUPS Upgrade Documentation

> Version: 4.0.0 | Date: 2026-03-04 | Branch: `feature/uups-migration`

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture Changes](#2-architecture-changes)
3. [Storage Layout (Verified)](#3-storage-layout-verified)
4. [Modified Files](#4-modified-files)
5. [Deployment Procedures](#5-deployment-procedures)
6. [Upgrade Procedures](#6-upgrade-procedures)
7. [Ownership Transfer (EOA → Multisig)](#7-ownership-transfer-eoa--multisig)
8. [Deep Security Analysis](#8-deep-security-analysis)
9. [Gas Impact Analysis](#9-gas-impact-analysis)
10. [ABI Compatibility](#10-abi-compatibility)
11. [Test Coverage Analysis](#11-test-coverage-analysis)
12. [Operational Checklist](#12-operational-checklist)
13. [Version History](#13-version-history)

---

## 1. Overview

### What Changed

SuperPaymaster 和 Registry 两个核心合约从**直接部署模式**升级为 **UUPS (ERC-1822) 可升级代理模式**。

| Before | After |
|--------|-------|
| `new Registry(owner, staking, mysbt)` | `ERC1967Proxy(regImpl, initData)` |
| `new SuperPaymaster(ep, owner, ...)` | `ERC1967Proxy(spImpl, initData)` |
| 升级 = 重新部署 + 更改所有配置 | 升级 = `upgradeToAndCall(newImpl, "")` |
| 地址随部署变化 | **代理地址永久不变** |

### What Did NOT Change

- 所有业务逻辑（validatePaymasterUserOp, postOp, configureOperator, registerRole 等）
- 所有外部接口签名（ABI 完全兼容）
- 工具合约（GToken, MySBT, GTokenStaking, BLS, xPNTs 等）
- OpenZeppelin 版本（保持 v5.0.2）
- Solidity 版本（保持 0.8.33）

### Version Numbers

| Contract | Before | After |
|----------|--------|-------|
| Registry | 3.0.2 | **4.0.0** |
| SuperPaymaster | 3.2.2 | **4.0.0** |

Major version bump (3→4) 因为这是一次架构层面的变更（constructor → initializer），符合 semver 规范。

---

## 2. Architecture Changes

### Core vs Tool Contracts

**Core Contracts (UUPS Proxy)**:
| Contract | Why UUPS | Proxy Address |
|----------|----------|---------------|
| **SuperPaymaster** | 资金枢纽，EntryPoint 注册地址，SDK 连接点 | 永久不变 |
| **Registry** | 全局身份名册、角色配置、声誉中枢 | 永久不变 |

**Tool Contracts (Pointer Replacement)** — 不需要 UUPS：
| Contract | Upgrade Method |
|----------|---------------|
| GToken | 部署新合约 |
| GTokenStaking | `registry.setStaking(newAddr)` |
| MySBT | `registry.setMySBT(newAddr)` |
| BLSValidator | `registry.setBLSValidator(newAddr)` |
| BLSAggregator | `registry.setBLSAggregator(newAddr)` |
| xPNTsFactory | `superPaymaster.setXPNTsFactory(newAddr)` |
| ReputationSystem | `registry.setReputationSource(newAddr, true)` |
| PaymasterV4 | `PaymasterFactory.addImplementation("v5", newAddr)` |

### Inheritance Chain

```
SuperPaymaster
├── BasePaymasterUpgradeable (NEW)
│   ├── IPaymaster
│   ├── Ownable                 (slot 0: _owner)
│   ├── Initializable           (ERC-7201 namespaced, no linear slots)
│   └── UUPSUpgradeable         (no state variables, immutable __self in bytecode)
├── ReentrancyGuard             (slot 1: _status)
└── ISuperPaymaster

Registry
├── Ownable                     (slot 0: _owner)
├── ReentrancyGuard             (slot 1: _status)
├── Initializable               (ERC-7201 namespaced, no linear slots)
├── UUPSUpgradeable             (no state variables)
└── IRegistry
```

### Immutable Variables Strategy

三个 immutable 变量保留在 implementation bytecode 中（不在 proxy storage）：

| Variable | Contract | Rationale |
|----------|----------|-----------|
| `entryPoint` | BasePaymasterUpgradeable | Hot path 省 2100 gas/call, EntryPoint v0.7 地址永不变 |
| `REGISTRY` | SuperPaymaster | Registry proxy 地址永不变 |
| `ETH_USD_PRICE_FEED` | SuperPaymaster | Chainlink feed 地址每条链固定 |

**升级时**：新 implementation 的 constructor 必须传入相同的三个地址。

---

## 3. Storage Layout (Verified)

### SuperPaymaster Storage (via `forge inspect`)

```
Slot   Variable                Type                                              Bytes
─────  ──────────────────────  ────────────────────────────────────────────────  ─────
0      _owner                  address                                           20
1      _status                 uint256 (ReentrancyGuard)                         32
2      APNTS_TOKEN             address                                           20
3      xpntsFactory            address                                           20
4      treasury                address                                           20
5      operators               mapping(address => OperatorConfig)                32
6      userOpState             mapping(address => mapping(address => State))     32
7      sbtHolders              mapping(address => bool)                          32
8      slashHistory            mapping(address => SlashRecord[])                 32
9      aPNTsPriceUSD           uint256                                           32
10-12  cachedPrice             PriceCache struct (96 bytes, 3 slots)             96
13     protocolFeeBPS          uint256                                           32
14     BLS_AGGREGATOR          address                                           20
15     totalTrackedBalance     uint256                                           32
16     protocolRevenue         uint256                                           32
17     priceStalenessThreshold uint256                                           32
18-67  __gap                   uint256[50]                                       1600
```

**Total used slots**: 18 (0-17)
**Reserved gap**: 50 slots (18-67)
**ERC-1967 implementation slot**: `0x360894...` (far from linear storage, no collision)
**Initializable storage**: ERC-7201 namespace at `0xf0c57e16...` (no collision)

### Registry Storage (via `forge inspect`)

```
Slot   Variable                Type                                     Bytes
─────  ──────────────────────  ───────────────────────────────────────  ─────
0      _owner                  address                                  20
1      _status                 uint256 (ReentrancyGuard)                32
2      GTOKEN_STAKING          contract IGTokenStaking                  20
3      MYSBT                   contract IMySBT                          20
4      SUPER_PAYMASTER         address                                  20
5      blsAggregator           address                                  20
6      blsValidator            contract IBLSValidator                   20
7      roleConfigs             mapping(bytes32 => RoleConfig)           32
8      hasRole                 mapping(bytes32 => mapping => bool)      32
9      roleStakes              mapping(bytes32 => mapping => uint256)   32
10     roleMembers             mapping(bytes32 => address[])            32
11     roleMemberIndex         mapping(bytes32 => mapping => uint256)   32
12     roleSBTTokenIds         mapping(bytes32 => mapping => uint256)   32
13     roleMetadata            mapping(bytes32 => mapping => bytes)     32
14     communityByName         mapping(string => address)               32
15     communityByENS          mapping(string => address)               32
16     accountToUser           mapping(address => address)              32
17     executedProposals       mapping(uint256 => bool)                 32
18     userRoles               mapping(address => bytes32[])            32
19     userRoleCount           mapping(address => uint256)              32
20     globalReputation        mapping(address => uint256)              32
21     lastReputationEpoch     mapping(address => uint256)              32
22     creditTierConfig        mapping(uint256 => uint256)              32
23     isReputationSource      mapping(address => bool)                 32
24     levelThresholds         uint256[]                                32
25     proposedRoleNames       mapping(bytes32 => string)               32
26     roleOwners              mapping(bytes32 => address)              32
27     roleLockDurations       mapping(bytes32 => uint256)              32
28-77  __gap                   uint256[50]                              1600
```

**Total used slots**: 28 (0-27)
**Reserved gap**: 50 slots (28-77)

### Future Upgrade Storage Rules

Adding new state variables in V2:
```solidity
// V1 (current)
uint256 public priceStalenessThreshold; // slot 17
uint256[50] private __gap;              // slots 18-67

// V2 (correct way to add variables)
uint256 public priceStalenessThreshold; // slot 17
address public newFeature;              // slot 18 (consumes __gap[0])
uint256[49] private __gap;              // slots 19-67 (reduced by 1)
```

**NEVER**:
- Insert variables before existing ones
- Change variable types for existing slots
- Remove variables from the middle of storage
- Reorder variables

---

## 4. Modified Files

### New Files

| File | Purpose |
|------|---------|
| `contracts/src/paymasters/superpaymaster/v3/BasePaymasterUpgradeable.sol` | UUPS base class for paymaster |
| `contracts/test/helpers/UUPSDeployHelper.sol` | Shared test library for proxy deployment |
| `contracts/test/v3/UUPSUpgrade.t.sol` | 13 dedicated UUPS upgrade tests |

### Modified Contracts

| File | Changes |
|------|---------|
| `SuperPaymaster.sol` | Inheritance → `BasePaymasterUpgradeable`, constructor → 3 immutables only, added `initialize()`, `__gap[50]`, `version()` made `virtual` |
| `Registry.sol` | Added `Initializable, UUPSUpgradeable`, constructor → `_disableInitializers()`, added `initialize()`, `_authorizeUpgrade()`, `__gap[50]`, `version()` made `virtual` |

### Modified Deployment Scripts

| File | Changes |
|------|---------|
| `contracts/script/v3/DeployAnvil.s.sol` | Registry + SuperPaymaster deployed as impl → proxy |
| `contracts/script/v3/DeployLive.s.sol` | Same proxy deployment pattern |

### Modified Test Files (20+)

All V3 test files updated `setUp()` to use `UUPSDeployHelper.deployRegistryProxy()` and `UUPSDeployHelper.deploySuperPaymasterProxy()`.

### Unchanged

- `BasePaymaster.sol` (original, kept for reference)
- All interfaces (`ISuperPaymaster.sol`, `IRegistry.sol`)
- All tool contracts
- All V4 tests

---

## 5. Deployment Procedures

### Fresh Deployment (New Chain)

```solidity
// Step 1: Deploy Registry impl + proxy
Registry regImpl = new Registry();
bytes memory regInit = abi.encodeCall(Registry.initialize, (deployer, staking, mysbt));
ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), regInit);
Registry registry = Registry(address(regProxy));

// Step 2: Deploy SuperPaymaster impl + proxy
SuperPaymaster spImpl = new SuperPaymaster(
    IEntryPoint(ENTRY_POINT),
    IRegistry(address(registry)),   // Registry PROXY address (permanent)
    ETH_USD_PRICE_FEED
);
bytes memory spInit = abi.encodeCall(SuperPaymaster.initialize, (
    deployer,
    apntsToken,
    treasury,
    4200  // staleness threshold
));
ERC1967Proxy spProxy = new ERC1967Proxy(address(spImpl), spInit);
SuperPaymaster sp = SuperPaymaster(payable(address(spProxy)));

// Step 3: Wire (same as before)
registry.setSuperPaymaster(address(sp));
// ... other wiring ...
```

**Key**: `initialize()` is called atomically in the proxy constructor — cannot be front-run.

### MySBT Address Pre-computation

MySBT needs the Registry proxy address in its constructor. We use `vm.computeCreateAddress`:

```solidity
uint256 nonce = vm.getNonce(deployer);
// Next deploys: MySBT (nonce), ERC1967Proxy (nonce+1)
address precomputedProxy = vm.computeCreateAddress(deployer, nonce + 1);
mysbt = new MySBT(gtoken, staking, precomputedProxy, deployer);
ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), regInit);
// address(regProxy) == precomputedProxy ✓
```

### Initialize Parameters

**Registry.initialize()**:
| Param | Description | Validation |
|-------|-------------|------------|
| `_owner` | Contract owner (receives onlyOwner permissions) | Must be non-zero |
| `_gtokenStaking` | GTokenStaking contract address | Can be zero (some functions will fail) |
| `_mysbt` | MySBT contract address | Can be zero (some functions will fail) |

Sets internally:
- 7 role configurations (COMMUNITY, ENDUSER, PAYMASTER_AOA, PAYMASTER_SUPER, DVT, ANODE, KMS)
- 6 credit tier configurations
- 5 level thresholds (Fibonacci: 13, 34, 89, 233, 610)
- Owner as reputation source

**SuperPaymaster.initialize()**:
| Param | Description | Default |
|-------|-------------|---------|
| `_owner` | Contract owner | Must be non-zero |
| `_apntsToken` | aPNTs token address | Can be zero (set later via `setAPNTsToken`) |
| `_protocolTreasury` | Fee receiver | Falls back to `_owner` if zero |
| `_priceStalenessThreshold` | Oracle staleness (seconds) | Falls back to 3600 if zero |

Sets internally:
- `aPNTsPriceUSD = 0.02 ether` ($0.02)
- `protocolFeeBPS = 1000` (10%)

---

## 6. Upgrade Procedures

### Pre-Upgrade Checklist

1. **Verify new implementation compiles** with same Solidity version (0.8.33)
2. **Constructor params match**: entryPoint, REGISTRY proxy, ETH_USD_PRICE_FEED
3. **Storage layout compatible**: run `forge inspect NewContract storage-layout` and compare with baseline
4. **No new variables inserted before existing ones**
5. **`__gap` size reduced by number of new variables added**
6. **All tests pass** with new implementation

### Upgrade Execution

#### Method 1: EOA Owner (Current)

```bash
# 1. Deploy new implementation
forge create SuperPaymasterV2 \
  --constructor-args $ENTRY_POINT $REGISTRY_PROXY $ETH_USD_FEED \
  --private-key $OWNER_KEY --rpc-url $RPC_URL

# 2. Upgrade proxy
cast send $PROXY_ADDRESS \
  "upgradeToAndCall(address,bytes)" \
  $NEW_IMPL_ADDRESS 0x \
  --private-key $OWNER_KEY --rpc-url $RPC_URL

# 3. Verify
cast call $PROXY_ADDRESS "version()(string)" --rpc-url $RPC_URL
cast call $PROXY_ADDRESS "owner()(address)" --rpc-url $RPC_URL
```

#### Method 2: Upgrade with Migration Data

If the new version needs a one-time setup function:

```solidity
// New implementation
contract SuperPaymasterV2 is SuperPaymaster {
    function initializeV2(address newParam) external reinitializer(2) {
        newVariable = newParam;
    }
}
```

```bash
# Encode migration call
MIGRATION_DATA=$(cast calldata "initializeV2(address)" $NEW_PARAM)

# Upgrade + migrate atomically
cast send $PROXY "upgradeToAndCall(address,bytes)" $NEW_IMPL $MIGRATION_DATA
```

#### Method 3: Gnosis Safe Multisig

```
1. Safe UI → "New Transaction" → "Contract Interaction"
2. Target: Proxy address
3. Function: upgradeToAndCall(address newImplementation, bytes memory data)
4. Params: newImplementation = new impl address, data = 0x
5. Submit → Wait for co-signers → Execute
```

### Post-Upgrade Verification

```bash
# Version updated
cast call $PROXY "version()(string)"

# Owner unchanged
cast call $PROXY "owner()(address)"

# Key state preserved (SuperPaymaster)
cast call $PROXY "APNTS_TOKEN()(address)"
cast call $PROXY "treasury()(address)"
cast call $PROXY "aPNTsPriceUSD()(uint256)"
cast call $PROXY "protocolFeeBPS()(uint256)"

# Immutables correct (SuperPaymaster)
cast call $PROXY "entryPoint()(address)"
cast call $PROXY "REGISTRY()(address)"
cast call $PROXY "ETH_USD_PRICE_FEED()(address)"

# Key state preserved (Registry)
cast call $PROXY "SUPER_PAYMASTER()(address)"
cast call $PROXY "GTOKEN_STAKING()(address)"
cast call $PROXY "MYSBT()(address)"
```

---

## 7. Ownership Transfer (EOA → Multisig)

### Current: Single-Step Transfer

```solidity
// OZ v5 Ownable.transferOwnership()
SuperPaymaster(proxy).transferOwnership(SAFE_ADDRESS);
Registry(proxy).transferOwnership(SAFE_ADDRESS);
```

**Risk**: If `SAFE_ADDRESS` is wrong, ownership is permanently lost.

### Recommended: Two-Step Transfer (Ownable2Step)

当前使用 OZ v5 `Ownable`（单步）。如果未来迁移到 `Ownable2Step`：

```solidity
// Step 1: Propose new owner
contract.transferOwnership(SAFE_ADDRESS);

// Step 2: New owner accepts (from Safe)
contract.acceptOwnership();
```

**建议**：在转移到多签前，在测试网先验证 Safe 能正确调用 `upgradeToAndCall()` 和所有 `onlyOwner` 函数。

### Multisig Compatibility

OZ v5.0.2 `_authorizeUpgrade` → `onlyOwner` → `owner()`. 无论 owner 是 EOA、Safe、AA 账户还是 Timelock，只要 `msg.sender == owner()` 即可。Gnosis Safe 通过内部交易执行时，Safe 合约地址就是 `msg.sender`。

---

## 8. Deep Security Analysis

### 8.1 Storage Collision Analysis

**结论: 无碰撞风险 ✅**

| Storage Domain | Location | Collision Risk |
|---------------|----------|----------------|
| Ownable `_owner` | Slot 0 (linear) | None |
| ReentrancyGuard `_status` | Slot 1 (linear) | None |
| Contract variables | Slots 2-27 (linear) | None |
| `__gap[50]` | Slots after variables | None |
| Initializable state | ERC-7201 at `0xf0c57e16...` | None (far from linear) |
| UUPSUpgradeable | No state vars | N/A |
| ERC-1967 impl slot | `0x360894...` | None (far from linear) |

OZ v5.0.2 的 `Initializable` 使用 ERC-7201 命名空间存储（slot `0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00`），与线性存储 slot 0-77 完全不冲突。

### 8.2 Initialization Security

#### 8.2.1 Re-initialization Prevention

- **Proxy**: `initializer` modifier 确保 `initialize()` 只能调用一次（`_initialized` 从 0 → 1）
- **Implementation**: constructor 调用 `_disableInitializers()` 设置 `_initialized = type(uint64).max`
- **测试验证**: `test_Registry_CannotReinitialize`, `test_SuperPaymaster_CannotReinitialize`, `test_Registry_ImplCannotBeInitialized`, `test_SuperPaymaster_ImplCannotBeInitialized`

#### 8.2.2 Atomic Initialization

```solidity
new ERC1967Proxy(address(impl), initData)
```

`initData` 在 proxy constructor 中通过 `Address.functionDelegateCall` 调用。整个初始化是原子的——不存在"已部署未初始化"的窗口期。**无前置运行风险**。

#### 8.2.3 Proxy Storage Default Values (CRITICAL FIX)

**已修复的关键 Bug**: Proxy storage 不继承 implementation 声明中的 Solidity 默认值。

```solidity
// 这些默认值只存在于 implementation storage，不在 proxy storage
uint256 public aPNTsPriceUSD = 0.02 ether;  // proxy 中为 0 ❌
uint256 public protocolFeeBPS = 1000;        // proxy 中为 0 ❌
```

**修复方案**：在 `initialize()` 中显式设置：
```solidity
function initialize(...) external initializer {
    aPNTsPriceUSD = 0.02 ether;  // 显式设置 ✅
    protocolFeeBPS = 1000;       // 显式设置 ✅
}
```

如果不修复，`_calculateAPNTsAmount()` 会因 `aPNTsPriceUSD = 0` 除以零而 revert，`postOp` 中费用计算也会失败。

### 8.3 ReentrancyGuard in Proxy Context

**行为分析**:
- Implementation constructor: `_status = NOT_ENTERED (1)` → 写入 implementation storage
- Proxy storage slot 1: 初始值为 `0`（非 1）
- `nonReentrant` modifier 检查: `if (_status == ENTERED(2)) revert`

**First call trace** (proxy):
1. `_status` = 0, not equal to `ENTERED(2)` → pass ✅
2. `_status = ENTERED(2)` → set
3. Execute function body
4. `_status = NOT_ENTERED(1)` → set

**结论**: 首次调用时 `_status` 从 0→2→1（而非 1→2→1），但行为完全正确。0 ≠ 2，所以首次调用不会被误拒。之后 `_status = 1`，行为与非代理模式完全一致。**无安全风险**。

**可选加固**: 在 `initialize()` 中添加 `_status = 1` 以确保一致性，但非必需。

### 8.4 UUPS-Specific Attack Vectors

#### 8.4.1 Implementation Self-Destruct → N/A
Solidity 0.8.33 on Cancun EVM 已移除 `selfdestruct` 语义（EIP-6780），implementation 合约无法被销毁。

#### 8.4.2 Unauthorized Upgrade Prevention
OZ v5.0.2 `UUPSUpgradeable` 通过两层保护：
1. `_authorizeUpgrade(address) → onlyOwner` — 仅 owner 可调用
2. `onlyProxy()` modifier — 阻止在 implementation 上直接调用 `upgradeToAndCall`
   ```solidity
   modifier onlyProxy() {
       if (address(this) == __self) { revert UUPSUnauthorizedCallContext(); }
   }
   ```

#### 8.4.3 Upgrade to Non-UUPS Implementation
如果升级到一个没有 `proxiableUUID()` 的合约：
- OZ v5 的 `upgradeToAndCall` 会调用 `proxiableUUID()` 验证
- 如果不存在或返回错误值 → 自动 revert
- **建议添加测试**: 验证升级到无效 implementation 会 revert

#### 8.4.4 Front-Running During Upgrade
Owner 的升级交易可能被矿工/MEV front-run，但：
- 升级前的 UserOps 使用旧 implementation → 安全
- 升级交易本身是原子的 → 无中间状态
- 升级后的 UserOps 使用新 implementation → 预期行为
- **风险级别**: LOW

#### 8.4.5 In-Flight UserOps During Upgrade
如果升级发生在 validate ↔ postOp 之间：
- `validatePaymasterUserOp` 用旧 implementation 编码 context
- `postOp` 用新 implementation 解码 context
- **风险**: 如果 context 编码格式变化 → `postOp` 解码失败

**缓解措施**:
1. 不要在版本间改变 context 编码格式
2. 如果必须改变：先暂停所有 operator → 等待 pending UserOps 完成 → 升级 → 恢复

### 8.5 Access Control Review

#### SuperPaymaster

| Function | Access Control | Proxy-Safe |
|----------|---------------|------------|
| `initialize` | `initializer` (one-time) | ✅ |
| `upgradeToAndCall` | `onlyOwner` + `onlyProxy` | ✅ |
| `configureOperator` | Registry role check | ✅ |
| `deposit/withdraw/depositFor` | Registry role + `nonReentrant` | ✅ |
| `validatePaymasterUserOp` | `onlyEntryPoint` + `nonReentrant` | ✅ |
| `postOp` | `onlyEntryPoint` + `nonReentrant` | ✅ |
| `updatePriceDVT` | BLS_AGGREGATOR or owner | ✅ |
| `updateBlockedStatus` | `msg.sender == REGISTRY` | ✅ |
| `updateSBTStatus` | `msg.sender == REGISTRY` | ✅ |
| `slashOperator` | `onlyOwner` | ✅ |
| `executeSlashWithBLS` | `msg.sender == BLS_AGGREGATOR` | ✅ |
| All setters | `onlyOwner` | ✅ |
| `onTransferReceived` | `msg.sender == APNTS_TOKEN` | ✅ |

**注**: `REGISTRY` 是 immutable，指向 Registry proxy 地址（永久不变）。所以 `msg.sender == address(REGISTRY)` 在 proxy 模式下依然正确。

#### Registry

| Function | Access Control | Proxy-Safe |
|----------|---------------|------------|
| `initialize` | `initializer` | ✅ |
| `upgradeToAndCall` | `onlyOwner` + `onlyProxy` | ✅ |
| `registerRole` | `nonReentrant`, role checks | ✅ |
| `exitRole` | `nonReentrant`, role holder only | ✅ |
| `safeMintForRole` | `nonReentrant`, COMMUNITY only | ✅ |
| `batchUpdateGlobalReputation` | ReputationSource + BLS proof | ✅ |
| `updateOperatorBlacklist` | ReputationSource | ✅ |
| All setters | `onlyOwner` | ✅ |
| `configureRole` | roleOwner or owner | ✅ |

### 8.6 Oracle Security in Proxy Context

`ETH_USD_PRICE_FEED` 是 immutable → 存储在 implementation bytecode，不受 proxy storage 影响。

Price validation:
- `MIN_ETH_USD_PRICE = 100 * 1e8` ($100)
- `MAX_ETH_USD_PRICE = 100_000 * 1e8` ($100K)
- Staleness: `block.timestamp - updatedAt < priceStalenessThreshold`
- DVT deviation: ±20% vs Chainlink

**Proxy 影响**: 无。所有价格逻辑在 proxy storage 和 immutable bytecode 中正确运行。

### 8.7 Financial Safety

#### Balance Tracking
- `operators[].aPNTsBalance` (uint128) — 正确跟踪
- `totalTrackedBalance` — 与 aPNTsBalance 总和保持同步
- `protocolRevenue` — validate 时全额计入，postOp 时退回差额

#### Overflow/Underflow
- 所有 uint128 cast 前有 `if (amount > type(uint128).max)` 检查
- 所有减法前有余额检查
- Solidity 0.8.33 默认 overflow/underflow 检查

### 8.8 Identified Risks & Recommendations

| # | Risk | Severity | Status | Recommendation |
|---|------|----------|--------|----------------|
| 1 | Owner 转移到错误地址 → 永久失去控制 | **HIGH** | 现有风险 | 升级到 `Ownable2Step` |
| 2 | 新 implementation constructor 传入错误 immutable | **MEDIUM** | 操作风险 | 使用脚本自动验证 |
| 3 | In-flight UserOps 在升级期间 context 不兼容 | **MEDIUM** | 可缓解 | 升级前暂停 operators |
| 4 | initialize() 允许 `_owner = address(0)` | **LOW** | 仅部署时 | 可选: 添加 require |
| 5 | ReentrancyGuard 首次调用 _status=0 而非 1 | **INFO** | 安全 | 行为正确，可选加固 |
| 6 | Proxy delegatecall overhead (~2600 gas) | **INFO** | 预期 | immutable 优化补偿 |

---

## 9. Gas Impact Analysis

### Per-Transaction Overhead

| Component | Gas Cost |
|-----------|----------|
| ERC1967Proxy fallback (delegatecall) | ~2,600 gas |
| SuperPaymaster validates + postOp (2 delegatecalls) | ~5,200 gas |
| Typical gasless UserOp total | ~300,000-500,000 gas |
| **Overhead percentage** | **1.0-1.7%** |

### Immutable Optimization Savings

| Optimization | Gas Saved |
|-------------|-----------|
| `entryPoint` as immutable vs storage (hot path) | ~2,100 gas × 2 calls |
| `REGISTRY` as immutable | ~2,100 gas |
| `ETH_USD_PRICE_FEED` as immutable | ~0 gas (not in hot path) |
| **Total savings** | **~6,300 gas** |

### Net Impact

```
Overhead:  +5,200 gas (2× delegatecall)
Savings:   -6,300 gas (3× immutable vs SLOAD)
───────────────────────────────
Net:       -1,100 gas (slight improvement)
```

**结论**: UUPS 代理模式在 gas 方面基本中性，immutable 优化略有抵消代理开销。

---

## 10. ABI Compatibility

### Preserved Functions (64 original)

所有 64 个原有函数的 selector 完全不变。SDK、前端、EntryPoint 无需任何更改。

### New Functions (4)

| Function | Selector | Used By |
|----------|----------|---------|
| `initialize(address,address,address,uint256)` | 部署时一次 | 部署脚本 |
| `upgradeToAndCall(address,bytes)` | 升级时 | Owner/Multisig |
| `proxiableUUID()` | ERC-1822 | 内部验证 |
| `UPGRADE_INTERFACE_VERSION()` | ERC-1967 | 版本查询 |

**SDK/前端影响**: 零。这 4 个新函数不在正常业务流程中使用。

### EntryPoint Compatibility

EntryPoint v0.7 注册的是 **proxy 地址**（永久不变）。`validatePaymasterUserOp` 和 `postOp` 的 function selector 不变。EntryPoint 完全不知道背后是代理还是直接部署。

---

## 11. Test Coverage Analysis

### Current Test Suite

| Category | Tests | Status |
|----------|-------|--------|
| UUPS Upgrade (dedicated) | 13 | ✅ All pass |
| Registry tests | 33 | ✅ All pass |
| SuperPaymaster tests | 55 | ✅ All pass |
| Tokens/xPNTs tests | 35 | ✅ All pass |
| PaymasterV4 tests | 25 | ✅ All pass |
| Module tests (BLS/DVT/Rep) | 19 | ✅ All pass |
| Other | 131 | ✅ All pass |
| **Total** | **311** | **0 failed** |

### UUPS-Specific Tests (13)

| Test | Covers |
|------|--------|
| `test_Registry_InitialState` | Proxy state after initialization |
| `test_Registry_UpgradeSuccess` | Owner can upgrade, state preserved |
| `test_Registry_UpgradeRejectedByNonOwner` | Non-owner cannot upgrade |
| `test_Registry_CannotReinitialize` | Re-initialization blocked |
| `test_Registry_ImplCannotBeInitialized` | Implementation init blocked |
| `test_Registry_StatePreservedAfterUpgrade` | Custom state survives upgrade |
| `test_SuperPaymaster_InitialState` | All proxy state correct |
| `test_SuperPaymaster_UpgradeSuccess` | Upgrade + state preservation |
| `test_SuperPaymaster_UpgradeRejectedByNonOwner` | Access control |
| `test_SuperPaymaster_CannotReinitialize` | Re-init blocked |
| `test_SuperPaymaster_ImplCannotBeInitialized` | Implementation init blocked |
| `test_MultisigUpgrade_TransferAndUpgrade` | Ownership transfer + upgrade |
| `test_ProxyAddressStableAfterUpgrade` | Address permanence |

### Coverage Gaps & Recommended Additional Tests

| # | Missing Test | Priority | Why |
|---|-------------|----------|-----|
| 1 | Upgrade to non-UUPS implementation → should revert | **HIGH** | Prevents accidental bricking |
| 2 | Double upgrade (A→B→C) state preservation | **MEDIUM** | Validates multi-version lifecycle |
| 3 | Business logic after upgrade (deposit, withdraw, configureOperator) | **MEDIUM** | Validates hot-path functions work |
| 4 | `upgradeToAndCall` with migration data (reinitializer) | **MEDIUM** | V2 migration path validation |
| 5 | Initialize with `_owner = address(0)` behavior | **LOW** | Edge case documentation |
| 6 | ReentrancyGuard works correctly after upgrade | **LOW** | Validates guard state |
| 7 | `forge inspect` storage layout snapshot test | **LOW** | Automated regression |

### Assessment

当前 13 个 UUPS 测试覆盖了核心场景（初始化、升级权限、状态保留、重初始化防护、多签模拟）。对于 V1 发布来说是**足够的**。

建议在下次迭代中添加 #1（非 UUPS implementation 升级）和 #2（多版本升级链），因为这些是生产环境中最可能遇到的场景。

---

## 12. Operational Checklist

### First Deployment

- [ ] Deploy Registry implementation
- [ ] Deploy Registry proxy with `initialize(owner, staking, mysbt)`
- [ ] Deploy SuperPaymaster implementation with 3 immutables
- [ ] Deploy SuperPaymaster proxy with `initialize(owner, apnts, treasury, staleness)`
- [ ] Wire: `registry.setSuperPaymaster(address(spProxy))`
- [ ] Wire: Other setter calls (xPNTsFactory, BLS, etc.)
- [ ] Fund: `sp.deposit{value: 0.1 ether}()`
- [ ] Fund: `sp.addStake{value: 0.1 ether}(1 days)`
- [ ] Verify: `cast call $PROXY "version()(string)"`
- [ ] Save: Record both proxy AND implementation addresses

### Upgrade

- [ ] Verify: New implementation compiles
- [ ] Verify: Constructor immutables match existing values
- [ ] Verify: Storage layout compatible (`forge inspect`)
- [ ] Verify: All tests pass
- [ ] Optional: Pause operators if changing context format
- [ ] Execute: `upgradeToAndCall(newImpl, data)`
- [ ] Verify: version() returns new version
- [ ] Verify: owner() unchanged
- [ ] Verify: All state preserved (balances, configs, roles)
- [ ] Verify: Business operations functional

### Ownership Transfer

- [ ] Pre-verify: Safe address is correct and accessible
- [ ] Pre-verify: Safe can call `upgradeToAndCall()` on testnet
- [ ] Execute: `transferOwnership(SAFE_ADDRESS)`
- [ ] Verify: `owner()` returns Safe address
- [ ] Post-verify: Execute a test `onlyOwner` function from Safe
- [ ] Record: Safe address, signers, threshold

---

## 13. Version History

| Version | Date | Changes |
|---------|------|---------|
| 3.0.2 | 2025-11 | Registry last pre-UUPS version |
| 3.2.2 | 2025-11 | SuperPaymaster last pre-UUPS version |
| **4.0.0** | **2026-03** | **UUPS migration: proxy deployment, initialize(), __gap, BasePaymasterUpgradeable** |

### Migration from v3 to v4

This was a **fresh deployment migration** (not a proxy upgrade), since the contracts were previously deployed without proxy infrastructure. All existing tool contracts on OP mainnet can be pointed to new proxy addresses via their respective setter functions:

```bash
# Update tool contracts to point to new proxy addresses
registry.setSuperPaymaster(NEW_SP_PROXY)
xpntsFactory.setSuperPaymasterAddress(NEW_SP_PROXY)
aggregator = new BLSAggregator(address(registry_proxy), address(sp_proxy), address(0))
# etc.
```

---

## Appendix A: OpenZeppelin v5.0.2 Security Status

| Component | Status | Notes |
|-----------|--------|-------|
| UUPSUpgradeable | ✅ Secure | No known vulnerabilities |
| Initializable | ✅ Secure | ERC-7201 namespaced storage |
| ERC1967Proxy | ✅ Secure | Standard implementation |
| Ownable | ✅ Secure | Single-step transfer |
| ReentrancyGuard | ✅ Secure | Traditional linear storage |
| SafeERC20 | ✅ Secure | No issues |

v5.0.2 → v5.6.1 之间唯一安全公告：`Bytes.lastIndexOf` 漏洞 (GHSA-9rcw-c2f9-2j55)，仅影响 v5.2.0+，v5.0.2 中不存在该函数。

**不升级 OZ 的理由**:
- v5.5.0: `_validateUserOp` 签名变更（影响 AA）
- v5.6.0: ERC1967Proxy 强制初始化 + EntryPoint 默认 v0.9（我们用 v0.7）
- 无安全增益，仅功能优化

## Appendix B: File Quick Reference

```
contracts/src/
├── paymasters/superpaymaster/v3/
│   ├── BasePaymasterUpgradeable.sol   ← NEW
│   ├── BasePaymaster.sol              ← UNCHANGED (legacy)
│   └── SuperPaymaster.sol             ← MODIFIED
├── core/
│   └── Registry.sol                   ← MODIFIED
contracts/test/
├── helpers/
│   └── UUPSDeployHelper.sol           ← NEW
├── v3/
│   └── UUPSUpgrade.t.sol             ← NEW (13 tests)
contracts/script/v3/
├── DeployAnvil.s.sol                  ← MODIFIED
└── DeployLive.s.sol                   ← MODIFIED
```

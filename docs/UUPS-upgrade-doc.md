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
- [Appendix A: OpenZeppelin v5.0.2 Security Status](#appendix-a-openzeppelin-v502-security-status)
- [Appendix B: File Quick Reference](#appendix-b-file-quick-reference)
- [Appendix C: Architecture Knowledge Base](#appendix-c-architecture-knowledge-base) ← NEW
- [Appendix D: TODO List](#appendix-d-todo-list) ← NEW
- [Appendix E: Refactoring Notes Audit](#appendix-e-refactoring-notes-audit-2026-03-05) ← NEW

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
16     accountToUser           REMOVED in feat/remove-account-to-user   —
17     executedProposals       REMOVED in v5.1 (moved to BLSAggregator) —
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
- Attempt in-place `upgradeToAndCall` from pre-UUPS (non-proxy) deployments — storage layouts are incompatible (e.g., `pendingDebts` was inserted at SuperPaymaster slot 17, shifting subsequent slots). Migration path is always: deploy new proxy → migrate state via script.

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
| UUPS Upgrade (dedicated) | 19 | ✅ All pass |
| Registry tests | 33 | ✅ All pass |
| SuperPaymaster tests | 55 | ✅ All pass |
| Tokens/xPNTs tests | 35 | ✅ All pass |
| PaymasterV4 tests | 25 | ✅ All pass |
| Module tests (BLS/DVT/Rep) | 19 | ✅ All pass |
| Other | 131 | ✅ All pass |
| **Total** | **317** | **0 failed** |

### UUPS-Specific Tests (19)

| Test | Covers |
|------|--------|
| `test_Registry_InitialState` | Proxy state after initialization |
| `test_Registry_UpgradeSuccess` | Owner can upgrade, state preserved |
| `test_Registry_UpgradeRejectedByNonOwner` | Non-owner cannot upgrade |
| `test_Registry_CannotReinitialize` | Re-initialization blocked |
| `test_Registry_ImplCannotBeInitialized` | Implementation init blocked |
| `test_Registry_StatePreservedAfterUpgrade` | Custom state survives upgrade |
| `test_Registry_UpgradeToNonUUPS_Reverts` | Non-UUPS impl rejected (ERC-1967 safety) |
| `test_Registry_DoubleUpgrade_StatePreserved` | V1→V2→V3 state preserved |
| `test_Registry_BusinessLogicAfterUpgrade` | Admin functions work post-upgrade |
| `test_SuperPaymaster_InitialState` | All proxy state correct |
| `test_SuperPaymaster_UpgradeSuccess` | Upgrade + state preservation |
| `test_SuperPaymaster_UpgradeRejectedByNonOwner` | Access control |
| `test_SuperPaymaster_CannotReinitialize` | Re-init blocked |
| `test_SuperPaymaster_ImplCannotBeInitialized` | Implementation init blocked |
| `test_SuperPaymaster_UpgradeToNonUUPS_Reverts` | Non-UUPS impl rejected |
| `test_SuperPaymaster_DoubleUpgrade_StatePreserved` | V1→V2→V3 state preserved |
| `test_SuperPaymaster_BusinessLogicAfterUpgrade` | Admin + deposit work post-upgrade |
| `test_MultisigUpgrade_TransferAndUpgrade` | Ownership transfer + upgrade |
| `test_ProxyAddressStableAfterUpgrade` | Address permanence |

### Remaining Coverage Gaps

| # | Missing Test | Priority | Why |
|---|-------------|----------|-----|
| 1 | `upgradeToAndCall` with migration data (reinitializer) | **MEDIUM** | V2 migration path validation |
| 2 | Initialize with `_owner = address(0)` behavior | **LOW** | Edge case documentation |
| 3 | ReentrancyGuard works correctly after upgrade | **LOW** | Validates guard state |
| 4 | `forge inspect` storage layout snapshot test | **LOW** | Automated regression |

### Assessment

当前 19 个 UUPS 测试覆盖了全部核心场景：初始化、升级权限、状态保留、重初始化防护、多签模拟、非 UUPS 合约拒绝、多版本升级链、升级后业务逻辑验证。对于生产发布来说是**充分的**。

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
│   └── UUPSUpgrade.t.sol             ← NEW (19 tests)
contracts/script/v3/
├── DeployAnvil.s.sol                  ← MODIFIED
└── DeployLive.s.sol                   ← MODIFIED
```

---

## Appendix C: Architecture Knowledge Base

> 从重构笔记中整理的关键架构知识，供后续开发参考。

### C.1 Two-Tier Slash Architecture

系统实现了两层惩罚机制，分别针对不同资产：

| 层级 | 目标合约 | 扣除资产 | 触发场景 | 权限 |
|------|---------|---------|---------|------|
| **Tier 1** | `SuperPaymaster.executeSlashWithBLS()` | aPNTs 运营资金 | 服务质量问题（交易失败、离线） | `BLS_AGGREGATOR` |
| **Tier 2** | `GTokenStaking.slashByDVT()` | GToken 质押物 | 严重违规（恶意行为、持续离线） | `authorizedSlashers` |

- `SuperPaymaster.slashOperator()` (onlyOwner) 是管理员手动 slash 接口
- `SuperPaymaster._slash()` 有 30% hardcap 保护
- `GTokenStaking.setAuthorizedSlasher(blsAggregator, true)` 需在部署时 wiring
- Slash 三级别：WARNING (-10 rep), MINOR (-20 rep + -10% balance), MAJOR (-50 rep + pause)

**Slash vs 自动停服的关系**：
- `validatePaymasterUserOp:798` 的 `aPNTsBalance < required → 拒绝 UserOp` 是**被动保护**（没钱了 → 停服）
- Slash 是**主动惩罚**（作恶 → 罚款 + 降级）
- 两者互补，不能互相替代

### C.2 Reputation System Three-Tier Architecture

| 层级 | 接口 | 数据流 | 场景 |
|------|------|--------|------|
| **Tier 1 (Manual)** | `ReputationSystem.setCommunityReputation()` | Owner/白名单直接写入 | 管理员手动设置 |
| **Tier 2 (Rule-based)** | `ReputationSystem.computeScore()` → `syncToRegistry()` | 链上透明算法 | 测试/小规模 |
| **Tier 3 (DVT Batch)** | `Registry.batchUpdateGlobalReputation()` | BLS 聚合签名证明 | **生产路径** |

**Event-Driven 架构**：
- SuperPaymaster 不再每次 UserOp 调用 Registry.updateReputation（gas 太高）
- 改为 emit `UserReputationAccrued(user, aPNTsValue)` 事件
- Off-chain Validator 监听事件、聚合、定期 batch 提交

**Community Reputation Rules**：
- `ReputationSystem.setRule(ruleId, baseScore, bonus, maxBonus, desc)` — 社区自定义评分权重
- `setNFTBoost(collection, boost)` — onlyOwner，NFT 持有加速器
- 声誉标准化为 aPNTs 金额（非 xPNTs 数量）：`AccumulatedReputation += aPNTsAmount`

### C.3 Credit System (Revolving Credit Model)

```
信用额度 = Registry.getCreditLimit(user)     ← 基于 globalReputation 和 Fibonacci 阈值
当前债务 = xPNTsToken.getDebt(user)          ← 在 xPNTs 层记录
可用信用 = creditLimit - currentDebt          ← SuperPaymaster.getAvailableCredit()
```

**Fibonacci 阈值配置**（默认）：

| Level | Reputation >= | Credit Limit |
|-------|--------------|-------------|
| 1 | 0 | 0 aPNTs |
| 2 | 13 | 100 aPNTs |
| 3 | 34 | 300 aPNTs |
| 4 | 89 | 600 aPNTs |
| 5 | 233 | 1,000 aPNTs |
| 6 | 610 | 2,000 aPNTs |

**Global Debt Anti-Double-Spend**：用户在社区 A 透支 500 aPNTs → 社区 B、C 的可用信用立即归零。

**Auto-Repayment**：`xPNTsToken._update()` hook 仅在 `mint` 时触发自动还款（协议奖励/空投），普通 `transfer` 走标准 ERC20 逻辑。`repayDebt()` 提供手动还款。

### C.4 Oracle Hybrid Pricing Model

```
Validation Phase → 读取 cachedPrice（合规 ERC-4337，无外部存储访问）
PostOp Phase     → 读取 Chainlink.latestRoundData()（实时）
                   └→ Chainlink 失败 → 回退到 cachedPrice
```

**三层防御**：
1. Keeper 正常 → `updatePrice()` 定期刷新 cache
2. Keeper 宕机 → PostOp 中 Chainlink fallback（每 4h auto-refresh，~6k-10k gas）
3. 双重故障 → try/catch 使用旧 cache（Liveness > Accuracy）

**SuperPaymaster vs PaymasterV4 定价差异**：

| 特性 | SuperPaymaster | PaymasterV4 |
|------|---------------|-------------|
| 价格源 | DVT 共识 + Chainlink | Chainlink + Keeper |
| 管理员后门 | 无 `setCachedPrice` | 有 `setCachedPrice` |
| DVT fallback | `updatePriceDVT()` + ±20% 偏差检查 | 无 |
| 适用场景 | 公共基础设施 | 社区私有域 |

**价格计算公式**：
```
TokenAmount = (GasWei * EthPrice * TotalRate * 10^TokenDecimals) / (TokenPrice * BPS * 10^(10 + EthDecimals))
```
使用 `Math.mulDiv` 防溢出和最小精度损失。

### C.5 ABI Encoding Compatibility (SDK ↔ Contract)

**问题**：Solidity `abi.encode(struct)` 自动前缀 32 字节 offset (`0x0000...0020`)，而 Viem `encodeAbiParameters(tuple)` 不加。这导致 Registry 解码 `roleData` 时 `panic code 0x41` (内存分配错误)。

**解决方案**：
- SDK 端: `RoleDataFactory.community()` 包装 struct，手动前缀 `0x0000...0020`
- 合约端: `Registry.sol` 有双解码逻辑（检测 0x20 offset 存在与否）

**维护规则**：若 `roleData` 结构变化，必须同步更新：
1. `Registry.sol` helper decode 函数
2. SDK `roleData.ts`
3. 回归测试中的 `encodeAbiParameters` 定义

### C.6 V3 (SuperPaymaster) vs V4 (PaymasterV4) Architecture

| 特性 | SuperPaymaster (V3/AOA+) | Paymaster (V4/AOA) |
|------|-------------------------|-------------------|
| Token 类型 | 专属 xPNTsToken | 任意 ERC20 (USDC/USDT) |
| 核心函数 | `burnFromWithOpHash()` — xPNTs 特有 | 标准 ERC20 transfer |
| SBT 验证 | 被动/黑名单（DVT push `blockedUsers`） | 主动/白名单（`balanceOf` 检查） |
| 定价 | DVT 共识 + Chainlink | Admin-set + Chainlink |
| 适用场景 | 公共基础设施、多运营商 | 社区私有域、单运营商 |
| Gas 支付模型 | 信用+即时（revolving credit） | 预充值（deposit-only） |
| 部署方式 | UUPS Proxy | EIP-1167 Clone (PaymasterFactory) |

### C.7 Role Management Reference

**7 个预定义角色**：

| 角色 | Role ID | 最低质押 | Entry Burn | 说明 |
|------|---------|---------|-----------|------|
| COMMUNITY | `keccak256("COMMUNITY")` | 30 GT | 3 GT | 社区注册 |
| ENDUSER | `keccak256("ENDUSER")` | 0.3 GT | 0.05 GT | 终端用户 |
| PAYMASTER_AOA | `keccak256("PAYMASTER_AOA")` | 30 GT | 3 GT | AOA 模式 Paymaster |
| PAYMASTER_SUPER | `keccak256("PAYMASTER_SUPER")` | 50 GT | 5 GT | AOA+ 超级运营商 |
| DVT | `keccak256("DVT")` | 30 GT | 0 | 验证者 |
| ANODE | `keccak256("ANODE")` | 20 GT | 2 GT | 应用节点 |
| KMS | `keccak256("KMS")` | 100 GT | 10 GT | 密钥管理 |

**业务规则**：注册 Paymaster 角色必须先有 Community 角色（双重质押）。`exitRole` 释放 namespace（`communityByNameV3` mapping 清除）。

**SBT 生命周期绑定**：一账户一 SBT 多角色。注册首个角色 → mint SBT。退出最后一个角色 → burn SBT + 撤销 SuperPaymaster 权限。

### C.8 Deployment Network Configuration

| Network | Env File | Chain ID |
|---------|----------|----------|
| Anvil | `.env.anvil` | 31337 |
| Sepolia | `.env.sepolia` | 11155111 |
| OP Sepolia | `.env.op-sepolia` | 11155420 |
| OP Mainnet | `.env.op-mainnet` | 10 |
| ETH Mainnet | `.env.mainnet` | 1 |

**Deployment Hash Skip 机制**：`deploy-core` 脚本计算所有 `contracts/src/*.sol` 的 SHA256，与 `deployments/config.<env>.json` 中存储的 `srcHash` 比较，代码无变化时跳过部署（除非 `--force`）。

---

## Appendix D: TODO List

### D.1 Contract-Level TODO (合约层)

> 合约代码改动或部署配置相关

| # | Item | Priority | Status | Notes |
|---|------|----------|--------|-------|
| 1 | **Deploy wiring: `setAuthorizedSlasher(blsAggregator, true)`** | HIGH | ✅ Done | Added to both DeployLive.s.sol and DeployAnvil.s.sol `_executeWiring()` |
| 2 | **Role lock duration 配置** | HIGH | ✅ Done | Already set in `initialize()` via `_initRole()`: 30 days for AOA/SUPER/DVT/ANODE/KMS/COMMUNITY, 7 days for ENDUSER. All deploy paths (DeployAnvil, DeployLive, MigrateToUUPS) call `initialize()`. |
| 3 | **补充测试: Registry 角色注册** | MEDIUM | ✅ Done | Added in `SupplementaryLifecycle.t.sol`: 7 tests covering register→exit lifecycle, multi-role, safeMintForRole, dynamic role config, lock duration enforcement |
| 4 | **补充测试: Staking exit flow** | MEDIUM | ✅ Done | Added in `SupplementaryLifecycle.t.sol`: 3 tests covering exit fee verification (preview→actual), slash-then-exit, view functions |
| 5 | **补充测试: MySBT burn 联动** | MEDIUM | ✅ Done | Added in `SupplementaryLifecycle.t.sol`: 4 tests covering mint-on-registration, burn-on-all-exit, deactivation, metadata fields |
| 6 | **Ownable2Step 迁移评估** | LOW | ✅ Evaluated | OZ v5.0.2 has `Ownable2Step.sol` but **NOT** `Ownable2StepUpgradeable`. Key blocker: `_pendingOwner` inserts at Slot 1, causing storage collision with ReentrancyGuard._status on existing proxies. **Decision: Defer to mainnet deployment as a clean redeploy operation.** Interim mitigation: verify Safe address with a dry-run `onlyOwner` call before `transferOwnership`. |
| 7 | **`upgradeToAndCall` + reinitializer 测试** | LOW | ✅ Done | Added in `SupplementaryLifecycle.t.sol`: 3 tests — Registry reinitializer(2), cannot-run-twice, SuperPaymaster reinitializer(2) |
| 8 | **`updateBlockedStatus` 端到端验证** | LOW | ✅ Done | Added in `SupplementaryLifecycle.t.sol`: 5 tests — Registry→SP blocked status sync, unblock, onlyRegistry guards, SBT status sync/clear |

### D.2 Deployment Script TODO (部署脚本)

| # | Item | Priority | Notes |
|---|------|----------|-------|
| 1 | `DeployLive.s.sol` 添加 `setAuthorizedSlasher` wiring | HIGH | ✅ Done — Added to both DeployLive and DeployAnvil |
| 2 | 删除笔记中 "Short-term: Immutable + Migration" 策略描述 | LOW | ✅ Done — Old strategy descriptions were already removed during UUPS migration. Only historical reference in Appendix E #9 remains as audit record. |

### D.3 SDK-Level TODO (移至 SDK 仓库)

> 以下 TODO 属于 SDK 层面，合并 UUPS 分支后转移到 SDK 仓库的 TODO 中

| # | Item | Category | Notes |
|---|------|----------|-------|
| 1 | **L1 Core Actions ABI 覆盖** | SDK-Core | 当前 186/446 函数 (41.7%)，目标 357 (80%)。UUPS 迁移不影响 ABI（4 个新函数仅部署用） |
| 2 | **L2 Business Clients** | SDK-Business | `CommunityClient`, `OperatorClient`, `EndUserClient` 面向 DApp 开发者。关键规则：L2 必须 100% 构建在 L1 之上，不直接 `viem.writeContract` |
| 3 | **L3 Scenario Patterns** | SDK-Patterns | `DAO Launchpad`, `Operator Lifecycle`, `User Onboarding` 端到端模板 |
| 4 | **ABI Encoding Wrapper 维护** | SDK-Core | `RoleDataFactory.community()` 中的 struct 前缀逻辑（见 C.5），`roleData` 结构变化时必须同步 |
| 5 | **Dynamic Gas Estimation** | SDK-Core | 1.5x 动态调参：`eth_estimateUserOperationGas` × 1.5 (validation) / × 1.1 (execution)。完全 SDK 层面 |
| 6 | **Node Tools 分离** | SDK-Infra | `@aastar/sdk/node` sub-path export (`KeyManager`, `FundingManager`)，主入口保持 browser-compatible |
| 7 | **React Hooks / UI Components** | SDK-Frontend | `useSuperPaymaster`, `useEndUserCredit`, `<EvaluationPanel />` — Milestone 3 目标 |
| 8 | **UserClient Registration Pattern** | SDK-Business | AA 账户 via UserOperation vs EOA owner 直接调用 `registry.registerRole` 的区分。合约层已支持 `user` 参数 |
| 9 | **Error Mapping** | SDK-Core | EVM Revert → TypeScript `ErrorCode.OPERATOR_PAUSED` 等可读错误码 |
| 10 | **L3 Complete Demo** | SDK-Patterns | `examples/l3-complete-demo.ts` — 完整生命周期演示脚本 |

---

## Appendix E: Refactoring Notes Audit (2026-03-05)

> 对历史重构笔记（30 个话题）的审计结果

| # | Topic | Status | Disposition |
|---|-------|--------|-------------|
| 1 | Decentralized Slash (V2.3.3→V3) | ✅ 已完成 | 合约层全部实现，仅缺部署 wiring → D.1 #1 |
| 2 | Reputation System | ✅ 已完成 | 三层架构全部实现 |
| 3 | Credit/Debt System | ✅ 已完成 | Revolving credit + Fibonacci + auto-repayment |
| 4 | DVT/BLS Consensus | ✅ 已完成 | BLS12-381 + threshold + replay protection |
| 5 | SDK L1-L3 Architecture | ⏩ SDK 范畴 | 转入 SDK TODO → D.3 |
| 6 | PaymasterV4 Stablecoin | ✅ 已完成 | Deposit-only + multi-token + 13 unit tests |
| 7 | xPNTsFactory Binding | ✅ 已完成 | Factory binding + burnFromWithOpHash + replay |
| 8 | Oracle/Pricing | ✅ 已完成 | Hybrid pricing + DVT fallback + ±20% check |
| 9 | Deployment Workflows | ✅ 已清理 | "Immutable + Migration" 策略已废弃，UUPS 替代。旧策略描述已在迁移过程中清除。 |
| 10 | Role Management | ✅ 已完成 | 7 roles + lock + burn + lifecycle |
| 11 | SBT Lifecycle | ✅ 已完成 | 一 SBT 多角色 + onlyRegistry burn |
| 12 | Blacklist/Rate Limiting | ✅ 已完成 | blockedUsers + minTxInterval + DVT blacklist |
| 13 | Gas Optimization (Bit-Pack) | ✅ 已完成 | OperatorConfig struct 打包优化 |
| 14 | ABI Encoding Compat | 📚 知识库 | 永久性注意点 → C.5 |
| 15 | Version Standardization | ✅ 已完成 | 统一 `version()` + virtual |
| 16 | PaymasterFactory Logic | ✅ 已完成 | addImplementation + deploy + deterministic |
| 17 | Sepolia Config Sync | 📋 运维 | sync 脚本仍有效 |
| 18 | Dynamic Gas Estimation | ⏩ SDK 范畴 | 转入 SDK TODO → D.3 #5 |
| 19 | 7702 Account Support | ✅ 已完成 | Bridge 文件存在 |
| 20 | SDK Project Structure | ⏩ SDK 范畴 | 转入 SDK TODO → D.3 |
| 21 | Missing Test Scenarios | ⚠️ 仍需补充 | → D.1 #3, #4, #5 |
| 22 | UserClient Registration | ⏩ SDK 范畴 | 转入 SDK TODO → D.3 #8 |
| 23 | SP Storage Mappings | 🗑️ 已过时 | 设计讨论记录，已实现 |
| 24 | xPNTs Auto-Repayment | ✅ 已完成 | Mint-only auto-repay + manual repayDebt |
| 25 | V3 vs V4 Differences | 📚 知识库 | → C.6 |
| 26 | L2 Client Rules | ⏩ SDK 范畴 | 转入 SDK TODO → D.3 #2 |
| 27 | PMV4 Security Features | ✅ 已完成 | factory binding + disableInitializers |
| 28 | xPNTs Consumption Limit | ✅ 已完成 | 5000 ether 单笔限额 |
| 29 | L3 Complete Demo | ⏩ SDK 范畴 | 转入 SDK TODO → D.3 #10 |
| 30 | Reputation Test Results | 📚 知识库 | Sepolia 验证基线保留 |

**统计**: 20 已完成 / 6 SDK 范畴 / 4 保留参考

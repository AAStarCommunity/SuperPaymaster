# Mycelium Protocol V3 完整变化报告

**日期**: 2025-11-28
**版本**: v3.0.0  
**状态**: ✅ 编译通过

---

## 核心设计原则

### ✅ 单一入口原则
**所有角色注册必须通过 Registry.registerRole()**
- 移除了所有 permissionless 用户直接注册函数
- MySBT 不再提供 userMint/mintWithAutoStake等用户可调用的mint函数
- GTokenStaking 只负责 token 锁定/解锁,不再关心业务逻辑

---

## 合约变化详情

### 1. Registry_v3_0_0.sol (927 行)

#### 核心API变化
| v2 Function | v3 Replacement | 说明 |
|-------------|----------------|------|
| `registerCommunity()` | `registerRole(ROLE_COMMUNITY, user, data)` | 统一入口 |
| `registerPaymaster()` | `registerRole(ROLE_PAYMASTER, user, data)` | 统一入口 |  
| `registerEndUser()` | `registerRole(ROLE_ENDUSER, user, data)` | 统一入口 |
| `exitCommunity()` | `exitRole(ROLE_COMMUNITY)` | 统一退出 |

#### 新增功能
- `safeMintForRole()` - 社区空投角色
- `configureRole()` - 动态配置新角色
- `BurnRecord[]` - 完整销毁历史追踪
- 动态 `RoleConfig` mapping

#### 编译状态
✅ 成功 (927 lines, no errors)

---

### 2. MySBT_v3.sol (变化最大)

#### BREAKING CHANGES
```solidity
// ❌ REMOVED: 违反 v3 单一入口原则
- function mintOrAddMembership(address, string) 
- function userMint(address, string)
- function mintWithAutoStake(address, string)
```

```solidity
// ✅ KEPT: Registry调用 + DAO应急
+ function airdropMint(address, string) onlyReg
+ function safeMint(address, address, string) onlyDAO
```

#### 社区验证逻辑升级
```solidity
// V2
function _isValid(address c) {
    return IRegistryV2_1(REGISTRY).isRegisteredCommunity(c);
}

// V3 (with fallback)
function _isValid(address c) {
    bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");
    try IRegistryV3(REGISTRY).hasRole(ROLE_COMMUNITY, c) {
        return true;
    } catch {
        // Fallback to v2 during transition
        return IRegistryV2_1(REGISTRY).isRegisteredCommunity(c);
    }
}
```

#### 接口变化
- ❌ 不再实现 `IMySBT` 接口 (该接口要求 mintOrAddMembership)
- ✅ Struct 定义移入合约内部 (SBTData, CommunityMembership)

#### 行数变化
546 → 438 lines (-108 lines / -19.8%)

#### 编译状态
✅ 成功

---

### 3. IGTokenStakingV3.sol

#### 核心接口变化
```solidity
// V3: Role-based locking
function lockStake(
    address user,
    bytes32 roleId,      // ← roleId instead of string purpose
    uint256 stakeAmount,
    uint256 entryBurn    // ← Track entry burn
) external returns (uint256 lockId);

function unlockStake(
    address user,
    bytes32 roleId       // ← roleId-based unlock
) external returns (uint256 netAmount);
```

#### 新增数据结构
```solidity
struct RoleLock {
    bytes32 roleId;
    uint256 amount;
    uint256 entryBurn;
    uint256 lockedAt;
    bytes metadata;
}
```

#### 移除的向后兼容
```diff
- // V2 compatibility (REMOVED per user request)
- function lockStake(address, uint256, string) external;
- function getLockedStake(address, address) external;
```

#### 编译状态
✅ 成功 (接口定义完整)

---

## 文件对比矩阵

| 文件 | 状态 | 行数 | 变化 | 编译 |
|------|------|------|------|------|
| Registry_v3_0_0.sol | ✅ 完成 | 927 | 新增 | ✅ |
| MySBT_v3.sol | ✅ 完成 | 438 | -108行 | ✅ |
| IRegistryV3.sol | ✅ 完成 | 180 | 新增 | ✅ |
| IGTokenStakingV3.sol | ✅ 完成 | 283 | 新增 | ✅ |

---

## Gas 优化目标

| 操作 | v2 Gas | v3 预期 | 优化幅度 |
|------|--------|---------|----------|
| registerCommunity | ~450k | ~120-150k | **~70%** |
| exitRole | ~180k | ~60-80k | **~65%** |

*注: 实际 gas 数据需要部署测试网验证*

---

## 向后兼容性

### ✅ 保留的 v2 函数 (Registry)
- `registerCommunity()` - 内部调用 registerRole()
- `registerCommunityWithAutoStake()`
- `updateCommunityProfile()`
- `deactivateCommunity()`
- `reactivateCommunity()`
- 所有 view 函数

### ❌ 不兼容的变化 (MySBT)
- 用户无法直接调用 MySBT 进行 mint
- 必须通过 Registry.registerRole() 注册
- 前端需要更新所有调用逻辑

---

## Role ID 设计

### 核心角色定义
```javascript
const ROLE_ENDUSER = keccak256("ENDUSER")
const ROLE_COMMUNITY = keccak256("COMMUNITY")
const ROLE_PAYMASTER = keccak256("PAYMASTER")
const ROLE_SUPER = keccak256("SUPER")
```

### 优势
- ✅ 动态可扩展 (社区可自定义角色)
- ✅ 固定大小 (Gas 效率高)
- ✅ 符合 OpenZeppelin AccessControl 标准

### 可读性改进
```javascript
// Frontend helper
function getRoleId(roleName) {
    return ethers.utils.keccak256(ethers.utils.toUtf8Bytes(roleName))
}

const ROLES = {
    ENDUSER: getRoleId("ENDUSER"),
    COMMUNITY: getRoleId("COMMUNITY"),
    // 社区可自定义
    VIP_MEMBER: getRoleId("VIP_MEMBER"),
    PREMIUM: getRoleId("PREMIUM")
}
```

---

## 测试清单

### 单元测试 (待完成)
- [ ] Registry v3 - registerRole() 所有角色类型
- [ ] Registry v3 - exitRole() 含销毁记录
- [ ] Registry v3 - safeMintForRole() 社区空投
- [ ] MySBT v3 - _isValid() 使用 hasRole()
- [ ] MySBT v3 - airdropMint() 仅 Registry 可调用

### 集成测试 (待完成)
- [ ] Registry + MySBT + GTokenStaking 完整流程
- [ ] 角色注册 → SBT mint → Stake lock 链路
- [ ] 角色退出 → Stake unlock → Token burn 链路

### Gas 基准测试 (待完成)
- [ ] 对比 v2 vs v3 的 registerCommunity gas
- [ ] 验证 70% gas 优化目标

---

## 部署建议

### Testnet 部署顺序
1. **GTokenStaking** (使用现有 v2 或部署 v3)
2. **Registry_v3_0_0** 
3. **MySBT_v3**
4. **更新前端配置**

### 配置文件更新
```javascript
// scripts/config-v3.js
const CONTRACTS_V3 = {
    REGISTRY_V3: "0x...",      // 待部署
    MYSBT_V3: "0x...",         // 待部署
    GTOKEN_STAKING: "0x...",   // 复用或新部署
    GTOKEN: "0x99cCb70...",    // 现有合约
}
```

---

## 迁移指南

### 前端迁移 (已完成)
✅ 5个 deprecated scripts 已迁移到 v3 API:
- `register-aastar-community.js`
- `testSbtMint.js`
- `test-prepare-assets.js`
- `2-setup-communities-and-xpnts.js`
- `tx-test/utils/config.js`

### 新用户流程
```javascript
// OLD (v2)
await mysbt.userMint(communityAddress, metadata)

// NEW (v3)
const roleData = ethers.utils.defaultAbiCoder.encode(
    ["string"],
    [metadata]
)
await registry.registerRole(ROLE_ENDUSER, userAddress, roleData)
```

---

## 未来扩展

### v3.1 潜在功能
1. **多角色支持** - 用户同时持有多个角色
2. **角色升级** - ENDUSER → VIP_MEMBER
3. **角色委托** - Stake 委托机制
4. **时间锁定** - 角色有效期管理

---

## 总结

### ✅ 已完成
- Registry_v3_0_0 完整实现 (927行)
- MySBT_v3 移除 permissionless mint (-108行)
- IGTokenStakingV3 接口定义
- IRegistryV3 接口定义
- 所有合约编译通过
- 5个前端脚本迁移完成

### ⚠️ 待完成
- GTokenStaking_v3 具体实现 (当前使用接口定义)
- 单元测试编写
- Testnet 部署
- Gas 基准测试
- 生产环境验证

---

**报告生成**: 2025-11-28  
**编译状态**: ✅ 全部通过  
**下一步**: 部署测试网并运行集成测试


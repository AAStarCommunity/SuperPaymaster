# Mycelium Protocol V3 Function Map & Gas Analysis

**生成日期**: 2025-11-28
**版本**: v3.0.0

---

## 三大核心合约交互图

```
┌─────────────────────────────────────────────────────────────────┐
│                          USER/FRONTEND                           │
└────────────┬────────────────────────────────────────────────────┘
             │
             v
┌────────────────────────────────────────────────────────────────┐
│                    Registry_v3_0_0.sol                         │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │ 角色注册/管理                                             │ │
│  │ - registerRole()         [主入口]                       │ │
│  │ - exitRole()                                            │ │
│  │ - safeMintForRole()      [社区空投]                     │ │
│  │ - updateXxxRole()        [角色特定更新]                 │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │ 角色配置                                                  │ │
│  │ - configureRole()        [owner配置role]                │ │
│  │ - proposeNewRole()       [owner提议新role]              │ │
│  │ - activateRole()         [owner激活role]                │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                                  │
│  调用↓                     调用↓                               │
└─────┬──────────────────────────┬─────────────────────────────┘
      │                          │
      v                          v
┌─────────────────────┐   ┌──────────────────────┐
│  MySBT_v3.sol       │   │ GTokenStaking (V3)   │
│                     │   │                      │
│  SBT Minting:       │   │  Stake Locking:      │
│  - mintForRole()    │   │  - lockStake()       │
│  - airdropMint()    │   │  - unlockStake()     │
│                     │   │  - slash()           │
│  SBT管理:           │   │                      │
│  - burnSBT()        │   │  Staking:            │
│  - leaveCommunity() │   │  - stake()           │
│                     │   │  - stakeFor()        │
│  View:              │   │  - requestUnstake()  │
│  - getUserSBT()     │   │  - completeUnstake() │
│  - getSBTData()     │   │                      │
│  - verify...()      │   │  View:               │
│                     │   │  - balanceOf()       │
│                     │   │  - availableBalance()│
│                     │   │  - getLockedStake()  │
└─────────────────────┘   └──────────────────────┘
```

---

## 1. Registry_v3_0_0 函数地图

### 1.1 核心角色管理 (V3 主功能)

| 函数名 | 类型 | Gas估算 | 关键操作 | 优化建议 |
|--------|------|---------|----------|----------|
| `registerRole()` | external | ~150-200k | - 验证role config<br>- 验证role data<br>- 存储metadata<br>- lockStake()<br>- mintForRole()<br>- 更新索引 | ⚠️ 高gas,可优化 |
| `exitRole()` | external | ~80-120k | - 验证权限<br>- unlockStake()<br>- burn tokens<br>- 记录burn history | ✅ 已优化 |
| `safeMintForRole()` | external | ~180-250k | - 验证社区权限<br>- autoStake<br>- lockStake()<br>- airdropMint() | ⚠️ 高gas,可优化 |

### 1.2 角色更新函数

| 函数名 | 类型 | Gas估算 | 操作 | 优化建议 |
|--------|------|---------|------|----------|
| `updateCommunityRole()` | external | ~40-60k | 更新name/ENS索引 | ✅ 已优化 |
| `updateEndUserRole()` | external | ~30-50k | 更新account映射 | ✅ 已优化 |
| `updatePaymasterRole()` | external | ~25-35k | 存储metadata | ✅ 已优化 |

### 1.3 角色配置 (Owner Only)

| 函数名 | 类型 | Gas估算 | 操作 |
|--------|------|---------|------|
| `configureRole()` | onlyOwner | ~45k | 配置roleConfig |
| `proposeNewRole()` | onlyOwner | ~55k | 提议新role |
| `activateRole()` | onlyOwner | ~30k | 激活role |

### 1.4 View Functions (免gas)

| 函数名 | 返回值 | 用途 |
|--------|--------|------|
| `checkRole()` | bool | 检查用户是否有role |
| `getRoleStake()` | uint256 | 获取stake amount |
| `getRoleMembers()` | address[] | 获取role成员列表 |
| `getRoleSBTTokenId()` | uint256 | 获取SBT tokenId |
| `getRoleMetadata()` | bytes | 获取role metadata |
| `getUserBurnHistory()` | uint256[] | 获取burn历史 |
| `getBurnRecord()` | BurnRecord | 获取burn记录详情 |

### 1.5 Legacy V2 兼容函数

| 函数名 | 类型 | 状态 | Gas估算 |
|--------|------|------|---------|
| `registerCommunity()` | external | 🟡 Deprecated | ~450k (高!) |
| `updateCommunityProfile()` | external | 🟡 Deprecated | ~80-100k |
| `deactivateCommunity()` | external | ✅ 保留 | ~25k |
| `reactivateCommunity()` | external | ✅ 保留 | ~25k |

### 1.6 Internal Helper Functions

| 函数名 | 用途 | Gas影响 |
|--------|------|---------|
| `_validateAndExtractStake()` | Role-specific验证 | 中 (~10-15k) |
| `_postRegisterRole()` | 更新索引mappings | 中 (~5-10k) |
| `_autoStakeForUser()` | 自动stake | 高 (~50-80k) |
| `_tryDecodeGenericRole()` | 解码通用role | 低 (~2k) |

---

## 2. MySBT_v3 函数地图

### 2.1 核心Minting函数 (Registry Only)

| 函数名 | 调用方 | Gas估算 | 关键操作 | 优化建议 |
|--------|--------|---------|----------|----------|
| `mintForRole()` | Registry | ~80-150k | - 检查是否已有SBT<br>- mint新SBT或更新<br>- 添加membership<br>- 更新活跃度 | ⚠️ 高gas,可优化 |
| `airdropMint()` | Registry | ~100-180k | - 同mintForRole<br>- DAO付费逻辑<br>- 社区验证 | ⚠️ 高gas,可优化 |

### 2.2 SBT管理函数

| 函数名 | 类型 | Gas估算 | 操作 |
|--------|------|---------|------|
| `burnSBT()` | external | ~60-90k | burn SBT + 退还locked tokens |
| `leaveCommunity()` | external | ~40-60k | 移除社区membership |

### 2.3 View Functions (免gas)

| 函数名 | 返回值 | 用途 |
|--------|--------|------|
| `getUserSBT()` | uint256 | 获取用户SBT tokenId |
| `getSBTData()` | SBTData | 获取SBT数据 |
| `getMemberships()` | CommunityMembership[] | 获取社区memberships |
| `verifyCommunityMembership()` | bool | 验证membership |

### 2.4 管理函数 (DAO Only)

| 函数名 | 类型 | 操作 |
|--------|------|------|
| `setSuperPaymaster()` | onlyDAO | 设置paymaster地址 |
| `setRegistry()` | onlyDAO | 设置registry地址 |
| `pause()/unpause()` | onlyDAO | 暂停/恢复合约 |

---

## 3. GTokenStaking (V3) 函数地图

### 3.1 Role-based Locking (Registry调用)

| 函数名 | 调用方 | Gas估算 | 操作 | 优化建议 |
|--------|--------|---------|------|----------|
| `lockStake()` | Registry | ~40-70k | 锁定stake for role | ✅ 已优化 |
| `unlockStake()` | Registry | ~35-60k | 解锁stake + 计算exit fee | ✅ 已优化 |
| `slash()` | Oracle/Registry | ~30-50k | slash用户stake | ✅ 已优化 |

### 3.2 Staking Functions (用户直接调用)

| 函数名 | 类型 | Gas估算 | 操作 |
|--------|------|---------|------|
| `stake()` | external | ~50-80k | stake GToken获取shares |
| `stakeFor()` | external | ~55-85k | 为他人stake |
| `requestUnstake()` | external | ~30-45k | 请求unstake (启动cooldown) |
| `completeUnstake()` | external | ~45-70k | 完成unstake (cooldown后) |

### 3.3 View Functions (免gas)

| 函数名 | 返回值 | 用途 |
|--------|--------|------|
| `balanceOf()` | uint256 | 总staked余额 |
| `availableBalance()` | uint256 | 可用余额(未锁定) |
| `getLockedStake()` | uint256 | 特定role的锁定量 |
| `getUserRoleLocks()` | RoleLock[] | 所有role locks |
| `previewExitFee()` | (uint256,uint256) | 预览exit fee |

---

## 4. 完整用户流程 Gas 分析

### 4.1 用户注册为 Community (V3)

```
用户调用: registry.registerRole(ROLE_COMMUNITY, user, roleData)
  |
  ├─> [Registry] _validateAndExtractStake()      ~15k
  |     └─> 解码CommunityRoleData
  |     └─> 验证name/ENS唯一性
  |
  ├─> [Registry] GTOKEN_STAKING.lockStake()      ~60k  ⚠️
  |     └─> [Staking] 更新RoleLock mapping
  |     └─> [Staking] emit StakeLocked
  |
  ├─> [Registry] MYSBT.mintForRole()             ~120k ⚠️
  |     └─> [MySBT] mint SBT token (ERC721)
  |     └─> [MySBT] 添加membership
  |     └─> [MySBT] _registerSBTHolder()
  |
  ├─> [Registry] 存储roleMetadata                ~25k
  |
  ├─> [Registry] _postRegisterRole()             ~10k
  |     └─> 更新communityByName
  |     └─> 更新communityByENSV3
  |
  └─> [Registry] emit events                     ~5k

总计: ~235k gas (v2: ~450k) ✅ 省47%
```

### 4.2 用户注册为 EndUser (V3)

```
用户调用: registry.registerRole(ROLE_ENDUSER, user, roleData)
  |
  ├─> [Registry] _validateAndExtractStake()      ~12k
  ├─> [Registry] GTOKEN_STAKING.lockStake()      ~60k
  ├─> [Registry] MYSBT.mintForRole()             ~100k
  ├─> [Registry] 存储roleMetadata                ~25k
  ├─> [Registry] _postRegisterRole()             ~8k
  └─> [Registry] emit events                     ~5k

总计: ~210k gas
```

### 4.3 退出 Role

```
用户调用: registry.exitRole(roleId)
  |
  ├─> [Registry] GTOKEN_STAKING.unlockStake()    ~55k
  |     └─> 计算exit fee
  |     └─> 更新RoleLock
  |
  ├─> [Registry] burn tokens                     ~30k
  |     └─> GTOKEN.safeTransferFrom()
  |     └─> GTOKEN.burn()
  |
  ├─> [Registry] 记录BurnRecord                  ~20k
  |     └─> burnHistory.push()
  |     └─> userBurnHistory.push()
  |
  └─> [Registry] emit events                     ~5k

总计: ~110k gas (v2: ~180k) ✅ 省39%
```

---

## 5. Gas 优化建议

### 5.1 🔴 高优先级优化

#### 优化1: 移除重复的 role name 验证

**当前问题**:
```solidity
// _validateAndExtractStake() 中
if (bytes(data.name).length == 0) revert InvalidParameter("Community name required");

// 然后在 mintForRole() 中可能还有验证
```

**建议**: 统一在一处验证,减少重复的 `bytes()` 转换和 `length` 调用。

**预计节省**: ~2-3k gas/tx

---

#### 优化2: 使用 packed encoding 存储 roleMetadata

**当前问题**:
```solidity
mapping(bytes32 => mapping(address => bytes)) public roleMetadata;  // 直接存储ABI-encoded bytes
```

**建议**: 对于简单的数据类型,使用 packed storage:
```solidity
// 对于只有几个字段的role,可以用packed storage
struct PackedCommunityData {
    uint128 stakeAmount;
    uint64 registeredAt;
    uint32 nameHash;  // 只存hash,name存在events
    uint32 ensHash;
}
```

**预计节省**: ~10-15k gas/tx (在registerRole中)

---

#### 优化3: Batch operations

**当前问题**: 用户需要多次交易来注册多个roles

**建议**: 添加 `batchRegisterRoles()`:
```solidity
function batchRegisterRoles(
    bytes32[] calldata roleIds,
    address[] calldata users,
    bytes[] calldata roleDatas
) external nonReentrant {
    // 批量注册,节省base transaction cost
}
```

**预计节省**: ~21k gas × (n-1) transactions

---

### 5.2 🟡 中优先级优化

#### 优化4: 使用 immutable 代替 constant 计算

**当前问题**:
```solidity
bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");  // 每次函数调用都计算
```

**建议**: 在合约中定义为 immutable 或 constant:
```solidity
bytes32 public immutable ROLE_COMMUNITY = keccak256("COMMUNITY");
bytes32 public immutable ROLE_ENDUSER = keccak256("ENDUSER");
bytes32 public immutable ROLE_PAYMASTER_AOA = keccak256("PAYMASTER_AOA");
bytes32 public immutable ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
bytes32 public immutable ROLE_KMS = keccak256("KMS");
```

**预计节省**: ~200-300 gas/function call

---

#### 优化5: 减少 SLOAD 操作

**当前问题**: 多次读取同一个storage变量
```solidity
if (!roleConfigs[roleId].isActive) revert ...
// ... 后面又读取
RoleConfig memory config = roleConfigs[roleId];  // 重复SLOAD
```

**建议**: 一次性load到memory:
```solidity
RoleConfig memory config = roleConfigs[roleId];
if (!config.isActive) revert ...
if (stakeAmount < config.minStake) revert ...
```

**预计节省**: ~2.1k gas/重复SLOAD

---

#### 优化6: Event参数优化

**当前问题**: Events包含大量indexed参数
```solidity
event RoleGranted(bytes32 indexed roleId, address indexed user, uint256 stakeAmount);
```

**建议**: 最多3个indexed参数,其余不indexed以节省gas:
```solidity
event RoleGranted(
    bytes32 indexed roleId,
    address indexed user,
    uint256 stakeAmount,  // 不indexed,节省375 gas
    uint256 sbtTokenId    // 不indexed
);
```

**预计节省**: ~375 gas/indexed parameter

---

### 5.3 🟢 低优先级优化

#### 优化7: 使用自定义errors (已部分实现)

**当前**: 部分使用 `require()` with string

**建议**: 全部改为 custom errors:
```solidity
error RoleNotConfigured(bytes32 roleId);
error InsufficientStake(uint256 provided, uint256 required);
```

**预计节省**: ~50-100 gas/revert

---

#### 优化8: 使用 unchecked 算术

**位置**: 确定不会overflow的地方
```solidity
unchecked {
    roleMembers[roleId].push(user);  // array push
    burnHistory.push(record);
}
```

**预计节省**: ~20-40 gas/operation

---

## 6. Gas 估算总结

### 6.1 主要操作对比 (V2 vs V3)

| 操作 | V2 Gas | V3 Gas (当前) | V3 Gas (优化后) | 改进 |
|------|--------|---------------|-----------------|------|
| registerCommunity | ~450k | ~235k | **~180k** | 60% ↓ |
| registerEndUser | ~300k | ~210k | **~160k** | 47% ↓ |
| exitRole | ~180k | ~110k | **~85k** | 53% ↓ |
| updateRole | ~80k | ~50k | **~40k** | 50% ↓ |

### 6.2 优化潜力分析

**立即可优化** (1-2天实现):
- ✅ 添加 role constants (优化4): -300 gas/tx
- ✅ 减少重复验证 (优化1): -2-3k gas/tx
- ✅ 优化SLOAD (优化5): -4-6k gas/tx
- ✅ Event优化 (优化6): -375 gas/event

**总计立即优化**: **~7-10k gas/transaction** (约3-5%改进)

**中期优化** (1周实现):
- 🔄 Packed storage (优化2): -10-15k gas/tx
- 🔄 Batch operations (优化3): -21k × (n-1)

**总计中期优化**: **~30-40k gas/transaction** (约15-20%改进)

---

## 7. 推荐优化优先级

### Phase 1 (本周) - 快速wins
1. ✅ 添加 role constants 作为 storage variables (优化4)
2. ✅ 优化SLOAD,一次性load到memory (优化5)
3. ✅ 移除重复验证 (优化1)

**预期改进**: 3-5% gas 节省

### Phase 2 (下周) - 结构性优化
1. 🔄 Packed storage for role metadata (优化2)
2. 🔄 Batch registration function (优化3)

**预期改进**: 额外15-20% gas 节省

### Phase 3 (可选) - 边际优化
1. Event 参数优化 (优化6)
2. Unchecked 算术 (优化8)

**预期改进**: 额外2-3% gas 节省

---

## 8. 函数调用关系图

### 8.1 registerRole 调用链

```
用户 → registry.registerRole()
         ├─> _validateAndExtractStake()      [internal view]
         │     ├─> CommunityRoleData解码
         │     ├─> 检查name唯一性 (SLOAD communityByName)
         │     └─> 返回stakeAmount
         │
         ├─> GTOKEN_STAKING.lockStake()      [external call]
         │     ├─> 更新RoleLock mapping (SSTORE)
         │     └─> emit StakeLocked
         │
         ├─> MYSBT.mintForRole()             [external call]
         │     ├─> _mint() [ERC721]
         │     ├─> _registerSBTHolder() (SSTORE)
         │     └─> 添加membership (SSTORE)
         │
         ├─> roleMetadata[roleId][user] = roleData  [SSTORE]
         │
         ├─> _postRegisterRole()             [internal]
         │     └─> communityByName[name] = user (SSTORE)
         │
         └─> emit RoleGranted + RoleMetadataUpdated
```

### 8.2 exitRole 调用链

```
用户 → registry.exitRole(roleId)
         ├─> 验证hasRole (SLOAD)
         ├─> 读取roleStakes (SLOAD)
         │
         ├─> GTOKEN_STAKING.unlockStake()    [external call]
         │     ├─> 计算exit fee
         │     ├─> 删除RoleLock (SSTORE)
         │     └─> emit StakeUnlocked
         │
         ├─> GTOKEN.safeTransferFrom()       [external call]
         ├─> GTOKEN.burn()                   [external call]
         │
         ├─> burnHistory.push()              [SSTORE]
         ├─> userBurnHistory.push()          [SSTORE]
         │
         └─> emit RoleRevoked + RoleBurned
```

---

## 9. Storage Layout 分析

### 9.1 高频访问的 Storage

| Storage Variable | 访问频率 | Gas消耗 | 优化建议 |
|------------------|----------|---------|----------|
| `hasRole[roleId][user]` | 🔴 极高 | 2.1k/SLOAD | ✅ 已优化(packed bool) |
| `roleStakes[roleId][user]` | 🟡 高 | 2.1k/SLOAD | 可考虑packed |
| `roleMetadata[roleId][user]` | 🟡 高 | 2.1k+/SLOAD | ⚠️ 大bytes,考虑hash |
| `roleSBTTokenIds[roleId][user]` | 🟢 中 | 2.1k/SLOAD | ✅ 已优化 |

### 9.2 Storage Slot 优化机会

```solidity
// 当前 (每个变量独立slot)
mapping(bytes32 => mapping(address => bool)) public hasRole;       // slot 1
mapping(bytes32 => mapping(address => uint256)) public roleStakes; // slot 2

// 优化方案: Packed struct
struct RoleData {
    bool hasRole;        // 1 byte
    uint248 stakeAmount; // 31 bytes (足够大,最大: 2^248)
}
mapping(bytes32 => mapping(address => RoleData)) public roleData;  // 合并到1个slot!
```

**节省**: 1 SLOAD (2.1k gas) per access

---

## 10. 关键发现和建议

### 10.1 当前架构优势 ✅

1. **单一入口原则**: 所有role注册通过`registerRole()`,统一逻辑
2. **Role-based design**: 灵活扩展,不同stake要求
3. **Clean separation**: Registry(逻辑) + MySBT(身份) + Staking(金融)
4. **V3已经很优化**: 相比V2节省~50% gas

### 10.2 主要gas消耗来源 ⚠️

1. **ERC721 Minting** (~80-120k): 不可避免,标准ERC721成本
2. **External calls** (~20k each): Registry → MySBT, Registry → Staking
3. **Storage writes** (SSTORE ~20k each): metadata, indices
4. **ABI encoding/decoding** (~5-10k): roleData 序列化

### 10.3 优化ROI评估

| 优化项 | 实现难度 | Gas节省 | ROI | 推荐 |
|--------|----------|---------|-----|------|
| Role constants | 🟢 简单 | ~300/tx | 高 | ⭐⭐⭐ |
| 减少SLOAD | 🟢 简单 | ~4-6k/tx | 高 | ⭐⭐⭐ |
| Packed storage | 🟡 中等 | ~10-15k/tx | 中 | ⭐⭐ |
| Batch ops | 🟡 中等 | ~21k×(n-1) | 高(多次) | ⭐⭐⭐ |
| Event优化 | 🟢 简单 | ~375/event | 低 | ⭐ |

### 10.4 最终建议

**立即实施** (本周):
1. 添加 role constants 到 storage
2. 优化 SLOAD (一次性load到memory)
3. 移除重复的name验证

**计划实施** (下周):
1. 实现 batch registration
2. 考虑 packed storage for RoleData

**暂缓考虑**:
- Event 参数优化 (收益小)
- 过度优化的 unchecked (可能影响安全性)

---

**报告生成**: 2025-11-28
**下一步**: 实施 Phase 1 优化,预期节省 3-5% gas

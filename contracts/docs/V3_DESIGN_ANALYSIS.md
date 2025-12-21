# V3 设计问题分析与修正建议

**日期**: 2025-11-28
**状态**: 待修正

---

## 问题 1: Owner vs Admin 权限混淆

### 当前问题

函数地图中混淆了两种不同的"owner"概念：

1. **Role Owner** (角色拥有者):
   - `configureRole()` - 应该由角色拥有者配置自己的角色参数
   - 例如：Paymaster owner 配置自己的 stake 参数

2. **Registry Admin** (协议管理员):
   - `proposeNewRole()` - 提议新角色类型
   - `activateRole()` - 激活新角色
   - 应该由 DAO/Multisig 控制

### 当前实现检查

```solidity
// Registry_v3_0_0.sol
function configureRole(bytes32 roleId, RoleConfig calldata config)
    external onlyOwner  // ❌ 错误：应该是 role owner

function proposeNewRole(string calldata roleName, RoleConfig calldata config)
    external onlyOwner  // ✅ 正确：Registry admin

function activateRole(bytes32 roleId)
    external onlyOwner  // ✅ 正确：Registry admin
```

### 修正建议

```solidity
// 添加角色所有权映射
mapping(bytes32 => address) public roleOwners;  // roleId => owner address

// 修改权限控制
function configureRole(bytes32 roleId, RoleConfig calldata config)
    external {
    // 允许 role owner 或 registry admin
    if (msg.sender != roleOwners[roleId] && msg.sender != owner()) {
        revert Unauthorized();
    }
    // ...
}

function proposeNewRole(...) external onlyOwner { }  // Registry admin only
function activateRole(...) external onlyOwner { }    // Registry admin only
```

### 影响范围

- configureRole() 需要修改权限逻辑
- 需要在 registerRole() 时设置 roleOwners[roleId][user] = user
- 文档需要明确区分两种 owner

---

## 问题 2: Burn 逻辑和账目记录

### 当前问题

需要确认：
1. Burn 是否真的 transfer 到 `0x000...dEaD`？
2. Registry 是否完整记录了所有 burn 账目？
3. Burn 的 token 去向是否清晰？

### 当前实现检查

让我检查 exitRole() 的实现...

```solidity
// Registry_v3_0_0.sol - exitRole()
function exitRole(bytes32 roleId) external nonReentrant {
    // ... validation ...

    // Unlock stake from GTokenStaking
    uint256 grossAmount = GTOKEN_STAKING.unlockStake(msg.sender, roleId);

    // Burn tokens according to config
    uint256 burnAmount = (grossAmount * config.exitBurnPercent) / 10000;
    if (burnAmount > 0) {
        GTOKEN.safeTransferFrom(msg.sender, BURN_ADDRESS, burnAmount);  // ✅ 转到 0xdead
    }

    // Record burn history
    BurnRecord memory record = BurnRecord({
        roleId: roleId,
        user: msg.sender,
        amount: burnAmount,
        timestamp: block.timestamp,
        reason: "Role exit"
    });
    burnHistory.push(record);                          // ✅ Registry 记录
    userBurnHistory[msg.sender].push(burnHistory.length - 1);  // ✅ 用户索引

    // ... emit events ...
}
```

### 分析结果

✅ **Burn 逻辑正确**:
- Token 确实 transfer 到 `0x000000000000000000000000000000000000dEaD`
- Registry 完整记录了 burn history
- 用户可查询自己的 burn 记录

✅ **账目记录完整**:
- `burnHistory[]` - 全局 burn 记录
- `userBurnHistory[user][]` - 用户 burn 索引
- Events 记录 (RoleBurned)

**建议**: 保持当前实现，无需修改

---

## 问题 3: V2 兼容函数是否应该移除？

### 当前保留的 V2 函数

```solidity
// 🟡 Deprecated but kept
function registerCommunity()             // ~450k gas (高!)
function registerCommunityWithAutoStake()
function updateCommunityProfile()        // ~80-100k gas

// ✅ 仍在使用
function deactivateCommunity()           // ~25k gas
function reactivateCommunity()           // ~25k gas
```

### 分析

**支持移除的理由**:
1. V3 已有统一入口 `registerRole(ROLE_COMMUNITY, ...)`
2. V2 函数 gas 消耗高 (~450k vs ~235k)
3. 简化代码维护
4. 强制用户迁移到 v3 API

**支持保留的理由**:
1. 平滑迁移 - 给用户时间适应
2. 向后兼容 - 现有集成不会立即破坏
3. `deactivate/reactivate` 仍有实际用途

### 建议方案

**Phase 1 (当前)**: 保留但标记为 Deprecated
```solidity
/// @notice DEPRECATED: Use registerRole(ROLE_COMMUNITY, ...) instead
/// @dev Will be removed in v4.0.0
function registerCommunity() external { ... }
```

**Phase 2 (v3.1.0 - 3个月后)**: 移除高 gas 的注册函数
```solidity
// REMOVED:
// - registerCommunity()
// - registerCommunityWithAutoStake()
// - updateCommunityProfile()

// KEPT:
// - deactivateCommunity()  (仍有用)
// - reactivateCommunity()  (仍有用)
```

**Phase 3 (v4.0.0 - 6个月后)**: 完全移除 v2 API

---

## 问题 4: Staking 函数是否应该暴露？

### 当前 GTokenStaking 接口

```solidity
interface IGTokenStakingV3 {
    // Role-based locking (Registry调用)
    function lockStake(user, roleId, amount, entryBurn) external;  // ✅ Registry only
    function unlockStake(user, roleId) external;                   // ✅ Registry only

    // Regular staking (用户直接调用)  ← 问题：是否需要？
    function stake(amount) external;
    function stakeFor(beneficiary, amount) external;
    function requestUnstake(shares) external;
    function completeUnstake() external;
}
```

### 分析

**场景 1: 用户需要提前 stake**
```javascript
// 用户流程 1: 先 stake 再 register
await gtoken.approve(staking.address, 1000e18);
await staking.stake(1000e18);           // 用户直接调用
await registry.registerRole(ROLE_COMMUNITY, user, data); // lockStake() 使用已有 stake
```

**场景 2: 用户在 registerRole 时自动 stake**
```javascript
// 用户流程 2: registerRole 内部自动 stake
await gtoken.approve(staking.address, 1000e18);
await registry.registerRole(ROLE_COMMUNITY, user, data); // 内部调用 staking.stake()
```

### 当前实现检查

```solidity
// Registry_v3_0_0.sol - registerRole()
function registerRole(bytes32 roleId, address user, bytes calldata roleData) {
    // ... validation ...

    // Check user has sufficient AVAILABLE balance
    uint256 available = GTOKEN_STAKING.availableBalance(user);  // ← 用户必须提前 stake!
    if (available < stakeAmount) {
        revert InsufficientRoleStake(available, stakeAmount);
    }

    // Lock from existing stake
    GTOKEN_STAKING.lockStake(user, roleId, stakeAmount, config.entryBurn);
}
```

### 结论

**✅ 需要保留 stake() 函数** - 原因：

1. **两阶段设计**: 用户先 stake → 再 lock for role
   - Stake: 用户自愿存入 GToken 获取 stGToken shares
   - Lock: Registry 锁定已有的 stake 用于特定 role

2. **灵活性**: 用户可以：
   - 提前 stake 以获取 stGToken 收益
   - 在多个 roles 之间复用同一笔 stake
   - Unstake 未被 lock 的部分

3. **安全性**: Registry 不直接处理 GToken transfer

### 修正建议

**选项 A (推荐)**: 保持当前设计，但优化文档
```solidity
/// @notice Stake GToken to participate in protocol
/// @dev Users must stake before registering for roles
/// @dev Registry.registerRole() will lock from your available stake
function stake(uint256 amount) external returns (uint256 shares);
```

**选项 B**: 添加便捷函数 (可选)
```solidity
// Registry_v3_0_0.sol
/// @notice Stake and register in one transaction
function stakeAndRegisterRole(
    bytes32 roleId,
    uint256 stakeAmount,
    bytes calldata roleData
) external {
    // 1. User approves GToken to Staking
    // 2. Staking.stakeFor(user, stakeAmount)
    // 3. lockStake() for role
    // 4. Register role
}
```

**推荐**: 选项 A - 保持简单，通过文档说明清楚两阶段流程

---

## 问题 5: Staking 函数内部化？

### 分析是否应该 internal

**不应该 internal 的理由**:

1. **用户需要自主 stake**
   ```javascript
   // 用户场景：我想提前 stake 赚取收益，但还没决定加入哪个 role
   await staking.stake(10000e18);  // ← 必须是 external
   // ... 一周后 ...
   await registry.registerRole(ROLE_PAYMASTER, ...);
   ```

2. **Unstake 需要直接调用**
   ```javascript
   // 用户退出 role 后，想取回 tokens
   await registry.exitRole(ROLE_COMMUNITY);  // unlock stake
   await staking.requestUnstake(shares);     // ← 必须是 external
   await staking.completeUnstake();          // ← 必须是 external
   ```

3. **独立的 Staking 合约职责**
   - GTokenStaking 是独立的 staking 协议
   - 可被其他合约复用（不仅仅是 Registry）
   - 用户应该能直接与 Staking 交互

**结论**: ✅ 保持 `external`，不改为 `internal`

---

## 修正优先级

### 🔴 立即修正 (Phase 2)

1. **修正权限设计**
   - 区分 `roleOwner` 和 `registryAdmin`
   - `configureRole()` 允许 role owner 调用
   - `proposeNewRole/activateRole()` 仅 admin

2. **更新文档**
   - FUNCTION_MAP_V3.md 中明确 owner 含义
   - 添加权限矩阵表

### 🟡 中期优化 (v3.1.0)

1. **标记 Deprecated 函数**
   - 添加 `@deprecated` 标记
   - 添加 removal timeline

2. **优化 Staking 文档**
   - 明确两阶段流程 (stake → lock)
   - 添加用户流程图

### 🟢 长期规划 (v4.0.0)

1. **移除 V2 兼容函数**
   - 完全移除 legacy API
   - 仅保留 v3 unified API

---

## 总结

| 问题 | 状态 | 行动 |
|------|------|------|
| Owner vs Admin 混淆 | ❌ 需修正 | 添加 roleOwners mapping + 修改 configureRole() |
| Burn 逻辑 | ✅ 正确 | 无需修改 |
| V2 兼容函数 | 🟡 待讨论 | 保留但标记 deprecated |
| Staking 函数暴露 | ✅ 正确 | 保持 external，优化文档 |

**下一步**: 实施 Phase 2 优化 + 修正权限设计

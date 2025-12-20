# Registry 角色机制完整总结

## 📋 角色配置结构

### RoleConfig 数据结构
```solidity
struct RoleConfig {
    uint256 minStake;        // 最小质押量
    uint256 entryBurn;       // 注册时销毁量
    uint256 slashThreshold;  // 惩罚触发阈值(错误次数)
    uint256 slashBase;       // 基础惩罚金额
    uint256 slashIncrement;  // 惩罚递增量
    uint256 slashMax;        // 最大惩罚上限
    uint256 exitFeePercent;  // 退出费用百分比(BPS, 1000 = 10%)
    uint256 minExitFee;      // 最低退出费用
    bool isActive;           // 角色是否激活
    string description;      // 角色描述
}
```

## 🎯 预置角色配置

### 1. ROLE_PAYMASTER_AOA
- **minStake**: 30 ether
- **entryBurn**: 3 ether
- **slashThreshold**: 10 (10次错误后触发惩罚)
- **slashBase**: 2
- **slashIncrement**: 1
- **slashMax**: 10
- **exitFeePercent**: 1000 (10%)
- **minExitFee**: 1 ether

### 2. ROLE_PAYMASTER_SUPER
- **minStake**: 50 ether
- **entryBurn**: 5 ether
- **slashThreshold**: 10
- **slashBase**: 2
- **slashIncrement**: 1
- **slashMax**: 10
- **exitFeePercent**: 1000 (10%)
- **minExitFee**: 2 ether

### 3. ROLE_ANODE
- **minStake**: 20 ether
- **entryBurn**: 2 ether
- **slashThreshold**: 15
- **slashBase**: 1
- **slashIncrement**: 1
- **slashMax**: 5
- **exitFeePercent**: 1000 (10%)
- **minExitFee**: 1 ether

### 4. ROLE_KMS
- **minStake**: 100 ether
- **entryBurn**: 10 ether
- **slashThreshold**: 5
- **slashBase**: 5
- **slashIncrement**: 2
- **slashMax**: 20
- **exitFeePercent**: 1000 (10%)
- **minExitFee**: 5 ether

### 5. ROLE_COMMUNITY
- **minStake**: 10 ether
- **entryBurn**: 1 ether
- **slashThreshold**: 10
- **slashBase**: 2
- **slashIncrement**: 1
- **slashMax**: 10
- **exitFeePercent**: 1000 (10%)
- **minExitFee**: 0.5 ether

### 6. ROLE_ENDUSER ⭐
- **minStake**: 0.3 ether
- **entryBurn**: 0.05 ether
- **slashThreshold**: 0 (无惩罚机制)
- **slashBase**: 0
- **slashIncrement**: 0
- **slashMax**: 0
- **exitFeePercent**: 1000 (10%)
- **minExitFee**: 0.05 ether

## 🔧 角色管理接口

### 1. 配置现有角色 (Role Owner)
```solidity
function configureRole(bytes32 roleId, RoleConfig calldata config) external;
```
- **权限**: 角色所有者 (`roleOwners[roleId]`)
- **用途**: 修改已存在角色的配置
- **自动同步**: 退出费用会自动同步到 `GTokenStaking`

### 2. 创建新角色 (Protocol Owner) ⭐ 新增
```solidity
function createNewRole(
    bytes32 roleId, 
    RoleConfig calldata config, 
    address roleOwner
) external onlyOwner;
```
- **权限**: 协议所有者 (`owner()`)
- **用途**: 动态添加新角色
- **参数**:
  - `roleId`: 唯一角色标识符 (例如: `keccak256("NEW_ROLE")`)
  - `config`: 完整的角色配置
  - `roleOwner`: 该角色的所有者地址(可以后续重新配置该角色)

### 使用示例
```solidity
// 创建一个新的 "VALIDATOR" 角色
bytes32 ROLE_VALIDATOR = keccak256("VALIDATOR");

IRegistryV3.RoleConfig memory validatorConfig = IRegistryV3.RoleConfig({
    minStake: 50 ether,
    entryBurn: 5 ether,
    slashThreshold: 5,
    slashBase: 10,
    slashIncrement: 5,
    slashMax: 100,
    exitFeePercent: 1000,  // 10%
    minExitFee: 2 ether,
    isActive: true,
    description: "Network Validator"
});

registry.createNewRole(ROLE_VALIDATOR, validatorConfig, daoMultisig);
```

## 🔄 退出机制

### 退出流程
1. 用户调用 `registry.exitRole(roleId)`
2. Registry 检查锁定时间 (`roleLockDurations[roleId]`)
3. 调用 `GTokenStaking.unlockAndTransfer()`
4. GTokenStaking 计算退出费用:
   - `fee = (amount * exitFeePercent) / 10000`
   - `if (fee < minExitFee) fee = minExitFee`
5. 扣除费用后退还净额给用户

### 费用分配
- **退出费用**: 转入 `treasury` (国库)
- **Slash 扣款**: 转入 `treasury`
- **净退还**: 转给用户

## 📊 关键特性

### 1. 统一配置
- 所有角色参数集中在 `RoleConfig` 结构体
- 通过 `configureRole()` 一次性配置
- 退出费用自动同步到 `GTokenStaking`

### 2. 动态扩展
- 协议管理员可通过 `createNewRole()` 添加新角色
- 新角色立即可用,无需重新部署合约

### 3. 权限分离
- **Protocol Owner**: 创建新角色
- **Role Owner**: 配置自己的角色参数
- **用户**: 注册/退出角色

### 4. 锁定机制
- 永久锁定直到主动退出 (`roleLockDurations` 未设置)
- 退出时检查时间锁(如果配置)

## 🎨 设计优势

1. **简洁性**: 退出费用作为静态配置,避免额外的动态setter
2. **一致性**: 所有角色参数统一管理
3. **可扩展性**: 支持动态添加新角色
4. **Gas优化**: 减少跨合约调用
5. **权限清晰**: 三级权限模型(Protocol/Role/User)

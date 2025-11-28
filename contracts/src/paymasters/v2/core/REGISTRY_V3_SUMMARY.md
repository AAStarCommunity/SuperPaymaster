# Registry v3.0.0 - 统一角色管理系统

## 概述

Registry v3.0.0 是对 v2.2.1 的最小化改进版本，引入了统一的角色管理系统，同时保持与 v2 版本的完全向后兼容性。

## 核心改进

### 1. 统一角色管理 API

新增三个核心函数，提供统一的角色管理入口点：

#### `registerRole(bytes32 roleId, address user, bytes roleData)`
- 统一的角色注册入口
- 支持任意自定义角色（通过 bytes32 roleId）
- 使用 CEI 模式确保安全性
- 自动验证质押要求

#### `exitRole(bytes32 roleId)`
- 统一的角色退出机制
- 自动解锁并销毁质押代币
- 记录完整的销毁历史

#### `safeMintForRole(bytes32 roleId, address user, bytes data)`
- 社区空投角色给用户
- 自动质押（auto-stake）模式支持
- 仅限已注册社区调用

### 2. 动态角色配置系统

```solidity
struct RoleConfig {
    uint256 minStake;           // 最小质押要求
    uint256 slashThreshold;     // 惩罚阈值
    uint256 slashBase;          // 基础惩罚百分比
    uint256 slashIncrement;     // 惩罚递增百分比
    uint256 slashMax;           // 最大惩罚百分比
    bool isActive;              // 角色是否激活
    string description;         // 角色描述
}
```

- `mapping(bytes32 => RoleConfig) public roleConfigs` - 支持动态添加新角色
- `configureRole(bytes32 roleId, RoleConfig config)` - Owner 可配置任意角色
- 不再局限于硬编码的 NodeType enum

### 3. 完整的销毁历史追踪

```solidity
struct BurnRecord {
    bytes32 roleId;             // 角色标识符
    address user;               // 销毁者地址
    uint256 amount;             // 销毁数量
    uint256 timestamp;          // 销毁时间
    string reason;              // 销毁原因
}
```

新增存储：
- `BurnRecord[] public burnHistory` - 全局销毁记录
- `mapping(address => uint256[]) public userBurnHistory` - 用户销毁历史索引

新增查询函数：
- `getUserBurnHistory(address user)` - 获取用户历史记录
- `getBurnRecord(uint256 index)` - 获取特定记录
- `getBurnHistoryCount()` - 总记录数

## 向后兼容性

### 保留所有 v2 函数

所有 v2.2.1 的函数均保留，包括：
- `registerCommunity()`
- `registerCommunityWithAutoStake()`
- `updateCommunityProfile()`
- `deactivateCommunity()`
- `reactivateCommunity()`
- `transferCommunityOwnership()`
- `setPermissionlessMint()`
- 所有 view 函数

### NodeType 映射到 RoleConfig

构造函数中自动初始化默认角色：
```solidity
roleConfigs[keccak256("PAYMASTER_AOA")] = nodeTypeConfigs[NodeType.PAYMASTER_AOA];
roleConfigs[keccak256("PAYMASTER_SUPER")] = nodeTypeConfigs[NodeType.PAYMASTER_SUPER];
roleConfigs[keccak256("ANODE")] = nodeTypeConfigs[NodeType.ANODE];
roleConfigs[keccak256("KMS")] = nodeTypeConfigs[NodeType.KMS];
```

## 安全特性

### 1. CEI 模式 (Checks-Effects-Interactions)

所有关键函数遵循 CEI 模式：
```solidity
// 1. Checks
if (!config.isActive) revert RoleNotConfigured(roleId);
if (hasRole[roleId][user]) revert RoleAlreadyGranted(roleId, user);

// 2. Effects
hasRole[roleId][user] = true;
roleStakes[roleId][user] = stakeAmount;

// 3. Interactions
GTOKEN_STAKING.lockStake(user, stakeAmount, ...);
```

### 2. 重入保护

所有外部函数使用 `nonReentrant` modifier：
- `registerRole()`
- `exitRole()`
- `safeMintForRole()`
- 所有 v2 兼容函数

### 3. 权限控制

- `onlyOwner` - 角色配置、Oracle 设置等
- 社区权限检查 - `safeMintForRole()` 仅限已注册社区
- Oracle 授权 - `reportFailure()` 仅限 Oracle 或 Owner

### 4. 输入验证

完整的参数验证：
- 零地址检查
- 质押数量验证
- 字符串长度限制
- 数组大小限制

## 使用示例

### 创建新角色

```solidity
// 1. Owner 配置新角色
bytes32 validatorRole = keccak256("VALIDATOR");
RoleConfig memory config = RoleConfig({
    minStake: 100 ether,
    slashThreshold: 3,
    slashBase: 5,
    slashIncrement: 2,
    slashMax: 15,
    isActive: true,
    description: "Network Validator"
});
registry.configureRole(validatorRole, config);

// 2. 用户注册角色
bytes memory data = abi.encode(100 ether); // 质押数量
registry.registerRole(validatorRole, userAddress, data);

// 3. 检查角色
bool hasRole = registry.checkRole(validatorRole, userAddress);
uint256 stake = registry.getRoleStake(validatorRole, userAddress);
```

### 社区空投角色

```solidity
// 社区向用户空投角色
bytes32 memberRole = keccak256("MEMBER");
bytes memory data = abi.encode(50 ether);
registry.safeMintForRole(memberRole, userAddress, data);
```

### 退出角色

```solidity
// 用户退出角色并销毁质押
registry.exitRole(validatorRole);

// 查看销毁历史
uint256[] memory history = registry.getUserBurnHistory(userAddress);
```

## 事件系统

### v3.0.0 新增事件

```solidity
event RoleConfigured(bytes32 indexed roleId, uint256 minStake, uint256 slashThreshold, string description);
event RoleGranted(bytes32 indexed roleId, address indexed user, uint256 stakeAmount);
event RoleRevoked(bytes32 indexed roleId, address indexed user, uint256 burnedAmount);
event RoleMintedByCommunity(bytes32 indexed roleId, address indexed user, address indexed community, uint256 amount);
event RoleBurned(bytes32 indexed roleId, address indexed user, uint256 amount, string reason);
```

### v2 兼容事件

所有 v2.2.1 事件均保留，确保现有监听器继续工作。

## 存储布局

### v3.0.0 新增存储

```solidity
// 角色管理
mapping(bytes32 => RoleConfig) public roleConfigs;
mapping(bytes32 => mapping(address => bool)) public hasRole;
mapping(bytes32 => mapping(address => uint256)) public roleStakes;
mapping(bytes32 => address[]) public roleMembers;

// 销毁历史
BurnRecord[] public burnHistory;
mapping(address => uint256[]) public userBurnHistory;
```

### v2 存储（保留不变）

所有 v2.2.1 的存储变量位置不变，确保升级兼容性。

## Gas 优化

1. **批量查询** - `getRoleMembers()` 返回所有成员数组
2. **索引优化** - `userBurnHistory` 使用数组索引避免遍历
3. **CEI 模式** - 减少重入检查的 gas 消耗
4. **紧凑存储** - struct 字段顺序优化

## 测试建议

### 单元测试覆盖

1. 角色配置测试
   - 创建新角色
   - 修改角色配置
   - 非 owner 调用失败

2. 角色注册测试
   - 成功注册
   - 重复注册失败
   - 质押不足失败
   - 角色未配置失败

3. 角色退出测试
   - 成功退出并销毁
   - 未注册角色退出失败
   - 销毁历史记录正确

4. 社区空投测试
   - 社区成功空投
   - 非社区调用失败
   - 自动质押逻辑

5. 向后兼容性测试
   - v2 函数继续工作
   - 事件正确触发
   - 存储迁移无问题

### 集成测试

1. 与 GTokenStaking 集成
2. 与现有社区系统集成
3. 升级路径测试（v2 → v3）

## 升级路径

### 从 v2.2.1 升级到 v3.0.0

1. 部署新 Registry_v3_0_0 合约
2. 迁移现有社区数据（如需要）
3. 配置新角色（如需要）
4. 更新前端调用新 API
5. v2 功能继续工作，无需改动

### 渐进式迁移

- 新用户使用 v3.0.0 API (`registerRole`)
- 现有用户继续使用 v2 API (`registerCommunity`)
- 两套 API 共存，互不影响

## 版本信息

- **版本号**: 3.0.0
- **版本代码**: 30000
- **Solidity**: ^0.8.23
- **OpenZeppelin**: v5.0.2
- **基于**: Registry v2.2.1

## 未来扩展

v3.0.0 的动态角色系统为未来扩展奠定基础：

1. **多角色支持** - 用户可同时持有多个角色
2. **角色升级** - 角色间转换机制
3. **角色委托** - 质押委托给其他用户
4. **时间锁定** - 角色有效期管理
5. **动态惩罚** - 基于链上数据的惩罚调整

## 总结

Registry v3.0.0 通过引入统一的角色管理系统，在保持向后兼容的同时，显著提升了系统的灵活性和可扩展性。动态角色配置、完整的历史追踪、增强的安全性，使其成为企业级区块链应用的理想选择。

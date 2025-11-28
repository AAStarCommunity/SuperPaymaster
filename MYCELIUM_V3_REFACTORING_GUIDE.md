# Mycelium Protocol V3 重构指南

## 概述
本文档记录了从 Mycelium Protocol v2 到 v3 的完整重构过程，包括 Registry、MySBT 和 GTokenStaking 合约的所有变更。

## 1. 核心变更总览

### 1.1 架构变化
- **v2**: 多个独立的注册函数（registerCommunity, registerPaymaster, registerEndUser等）
- **v3**: 统一的 `registerRole()` API，通过 roleId 参数区分不同角色

### 1.2 主要改进
- **Gas优化**: 从 450k 降至 120-150k gas（约70%优化）
- **可扩展性**: 动态角色配置，支持未来新角色
- **代码复用**: 消除重复代码，统一注册逻辑
- **配置集中化**: SharedConfig 统一管理所有配置

## 2. Registry 合约重构

### 2.1 API 变更对照表

| v2 函数 | v3 函数 | 参数变化 |
|---------|---------|----------|
| `registerCommunity(profile, stGTokenAmount)` | `registerRole(ROLE_COMMUNITY, user, roleData)` | roleData 包含 profile 和 stGTokenAmount |
| `registerPaymaster(data)` | `registerRole(ROLE_PAYMASTER, user, roleData)` | 统一的 roleData 格式 |
| `registerSuperPaymaster(data)` | `registerRole(ROLE_SUPER, user, roleData)` | 统一的 roleData 格式 |
| `registerEndUser()` | `registerRole(ROLE_ENDUSER, user, roleData)` | 支持额外元数据 |
| `exitCommunity()` | `exitRole(ROLE_COMMUNITY)` | 仅需角色ID |
| `exitPaymaster()` | `exitRole(ROLE_PAYMASTER)` | 仅需角色ID |
| `exitSuperPaymaster()` | `exitRole(ROLE_SUPER)` | 仅需角色ID |
| `safeMint(user, tokenURI)` | `safeMintForRole(roleId, user, roleData)` | 支持按角色mint |

### 2.2 新增功能
- `configureRole(roleId, config)`: DAO 配置角色参数
- `getRoleConfig(roleId)`: 查询角色配置
- `getUserRoles(user)`: 获取用户所有角色
- `calculateExitFee(roleId, lockedAmount)`: 计算退出费用

### 2.3 数据结构变化

#### v2 NodeType 枚举
```solidity
enum NodeType {
    PAYMASTER_AOA,      // 0
    PAYMASTER_SUPER,    // 1
    ANODE,              // 2
    KMS                 // 3
}
```

#### v3 角色ID（bytes32）
```solidity
bytes32 constant ROLE_ENDUSER = keccak256("ENDUSER");
bytes32 constant ROLE_COMMUNITY = keccak256("COMMUNITY");
bytes32 constant ROLE_PAYMASTER = keccak256("PAYMASTER");
bytes32 constant ROLE_SUPER = keccak256("SUPER");
```

### 2.4 存储变化

#### v2 存储
```solidity
mapping(address => CommunityProfile) public communities;
mapping(address => CommunityStake) public communityStakes;
mapping(NodeType => NodeTypeConfig) public nodeTypeConfigs;
```

#### v3 存储
```solidity
mapping(bytes32 => RoleConfig) public roleConfigs;          // 角色配置
mapping(bytes32 => mapping(address => bool)) public hasRole; // 用户角色
mapping(address => bytes32[]) public userRoles;              // 用户的所有角色
mapping(address => BurnRecord[]) public burnHistory;         // 燃烧历史
```

## 3. GTokenStaking 接口更新

### 3.1 函数签名变化

| v2 函数签名 | v3 函数签名 | 变更说明 |
|------------|------------|----------|
| `lockStake(address user, uint256 amount, string purpose)` | `lockStake(address user, bytes32 roleId, uint256 amount, uint256 entryBurn)` | 增加 roleId 和 entryBurn 参数 |
| `unlockStake(address user, uint256 amount)` | `unlockStake(address user, bytes32 roleId)` | 使用 roleId 标识解锁 |
| `getLockedStake(address user, address locker)` | `getLockedStake(address user, bytes32 roleId)` | 使用 roleId 替代 locker |

### 3.2 新增接口
```solidity
interface IGTokenStakingV3 {
    // 锁定质押（用于角色注册）
    function lockStake(
        address user,
        bytes32 roleId,
        uint256 stakeAmount,
        uint256 entryBurn
    ) external returns (uint256 lockId);

    // 解锁质押（用于角色退出）
    function unlockStake(
        address user,
        bytes32 roleId
    ) external returns (uint256 netAmount);

    // 查询锁定金额
    function getLockedStake(
        address user,
        bytes32 roleId
    ) external view returns (uint256);
}
```

## 4. MySBT 合约更新

### 4.1 Registry 调用变化

#### v2 调用方式
```solidity
// 检查社区是否注册
IRegistryV2_1(REGISTRY).isRegisteredCommunity(community);
// 检查是否允许无权限铸造
IRegistryV2_1(REGISTRY).isPermissionlessMintAllowed(community);
```

#### v3 调用方式
```solidity
// 检查用户是否有社区角色
IRegistryV3(REGISTRY).hasRole(ROLE_COMMUNITY, community);
// 检查社区配置
RoleConfig memory config = IRegistryV3(REGISTRY).getRoleConfig(ROLE_COMMUNITY);
bool allowPermissionlessMint = config.allowPermissionlessMint;
```

### 4.2 接口定义更新
```solidity
interface IRegistryV3 {
    struct RoleConfig {
        uint256 minStake;
        uint256 entryBurn;
        uint256 exitFeePercent;
        uint256 minExitFee;
        bool allowPermissionlessMint;
        bool isActive;
    }

    function hasRole(bytes32 roleId, address user) external view returns (bool);
    function getRoleConfig(bytes32 roleId) external view returns (RoleConfig memory);
    function registerRole(bytes32 roleId, address user, bytes calldata roleData) external;
    function exitRole(bytes32 roleId) external;
}
```

## 5. 前端迁移指南

### 5.1 合约调用变化

#### v2 前端代码
```javascript
// 注册社区
await registry.registerCommunity(profile, stakeAmount);

// 注册 Paymaster
await registry.registerPaymaster(paymasterData);

// 退出社区
await registry.exitCommunity();
```

#### v3 前端代码
```javascript
// 导入 SharedConfig
import { ROLE_COMMUNITY, ROLE_PAYMASTER, ROLE_SUPER, ROLE_ENDUSER } from './SharedConfig';

// 注册社区
const roleData = ethers.utils.defaultAbiCoder.encode(
    ['tuple(string,string,address,address[],address,bool)', 'uint256'],
    [profile, stakeAmount]
);
await registry.registerRole(ROLE_COMMUNITY, userAddress, roleData);

// 注册 Paymaster
await registry.registerRole(ROLE_PAYMASTER, userAddress, paymasterData);

// 退出社区
await registry.exitRole(ROLE_COMMUNITY);
```

### 5.2 角色ID常量
```javascript
// SharedConfig.js
export const ROLE_ENDUSER = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ENDUSER"));
export const ROLE_COMMUNITY = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("COMMUNITY"));
export const ROLE_PAYMASTER = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("PAYMASTER"));
export const ROLE_SUPER = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("SUPER"));
```

### 5.3 事件监听变化

#### v2 事件
```javascript
registry.on("CommunityRegistered", (community, name, nodeType, staked) => {
    // 处理社区注册
});
```

#### v3 事件
```javascript
registry.on("RoleRegistered", (roleId, user, burnAmount, timestamp) => {
    // 处理角色注册
    if (roleId === ROLE_COMMUNITY) {
        // 社区注册逻辑
    }
});
```

## 6. 配置参数对照

### 6.1 ENDUSER 配置
- **最小质押**: 0.3 GT
- **入场燃烧**: 0.1 GT
- **退出费率**: 17%
- **最小退出费**: 0.05 GT

### 6.2 COMMUNITY 配置
- **最小质押**: 30 GT
- **入场燃烧**: 3 GT
- **退出费率**: 10%
- **最小退出费**: 0.3 GT

### 6.3 PAYMASTER 配置
- **最小质押**: 100 GT
- **入场燃烧**: 10 GT
- **退出费率**: 15%
- **最小退出费**: 1 GT

### 6.4 SUPER (SuperPaymaster) 配置
- **最小质押**: 500 GT
- **入场燃烧**: 50 GT
- **退出费率**: 20%
- **最小退出费**: 5 GT

## 7. 测试检查清单

### 7.1 Registry v3 测试
- [ ] 注册 ENDUSER 角色
- [ ] 注册 COMMUNITY 角色
- [ ] 注册 PAYMASTER 角色
- [ ] 注册 SUPER 角色
- [ ] 退出各种角色
- [ ] 配置角色参数（DAO权限）
- [ ] 查询角色配置
- [ ] 批量注册（safeMintForRole）
- [ ] 燃烧历史记录
- [ ] Gas 消耗对比

### 7.2 GTokenStaking v3 测试
- [ ] 使用 roleId 锁定质押
- [ ] 使用 roleId 解锁质押
- [ ] 查询锁定余额
- [ ] 入场燃烧机制
- [ ] 退出费用计算

### 7.3 MySBT v3 测试
- [ ] 检查角色权限
- [ ] 无权限铸造配置
- [ ] SBT 铸造流程
- [ ] SBT 燃烧流程
- [ ] Registry 回调

## 8. 部署步骤

### 8.1 部署顺序
1. 部署 SharedConfig
2. 部署 GTokenStaking v3（如需要）
3. 部署 Registry_v3_0_0
4. 更新 MySBT 以使用新 Registry
5. 配置角色参数
6. 迁移现有数据

### 8.2 配置脚本
```javascript
// 初始化角色配置
const configs = [
    { roleId: ROLE_ENDUSER, config: enduserConfig },
    { roleId: ROLE_COMMUNITY, config: communityConfig },
    { roleId: ROLE_PAYMASTER, config: paymasterConfig },
    { roleId: ROLE_SUPER, config: superConfig }
];

for (const { roleId, config } of configs) {
    await registry.configureRole(roleId, config);
}
```

## 9. 向后兼容性

### 9.1 兼容性保证
- 所有 v2 功能在 v3 中都有对应实现
- 数据结构可以迁移
- 事件格式保持相似

### 9.2 迁移策略
1. **并行运行**: 可以同时部署 v2 和 v3，逐步迁移
2. **数据迁移**: 通过脚本批量迁移现有注册
3. **前端适配**: 使用适配器模式支持两个版本

## 10. 常见问题

### Q1: 为什么使用 bytes32 roleId 而不是枚举？
A: bytes32 提供更好的可扩展性，允许动态添加新角色而无需修改合约。

### Q2: 如何处理现有的 NodeType？
A: NodeType 映射到对应的 roleId:
- PAYMASTER_AOA (0) → ROLE_PAYMASTER
- PAYMASTER_SUPER (1) → ROLE_SUPER
- ANODE (2) → ROLE_COMMUNITY
- KMS (3) → 可以创建新的 ROLE_KMS

### Q3: Gas 优化是如何实现的？
A: 通过统一的注册逻辑、减少存储操作和优化的数据结构实现。

## 11. 审计建议

### 11.1 安全检查项
- [ ] 重入攻击防护
- [ ] 角色权限检查
- [ ] 溢出保护
- [ ] 前置条件验证

### 11.2 代码审查重点
- RoleConfig 参数验证
- 燃烧和费用计算
- 角色转换逻辑
- 事件发射正确性

## 12. 联系和支持

如有问题或需要协助，请联系开发团队：
- GitHub: [Mycelium Protocol](https://github.com/mycelium-protocol)
- Discord: [开发者频道]
- 文档: [开发者文档]

---

*最后更新: 2024年11月*
*版本: v3.0.0*
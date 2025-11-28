# Registry v2.2.1 vs v3.0.0 功能对比

## 核心差异概览

| 特性 | v2.2.1 | v3.0.0 | 说明 |
|------|--------|--------|------|
| **角色系统** | 硬编码 NodeType enum | 动态 bytes32 roleId | v3 支持任意自定义角色 |
| **注册入口** | registerCommunity() | registerRole() | v3 提供统一接口 |
| **退出机制** | 无统一退出 | exitRole() | v3 标准化退出流程 |
| **社区空投** | 无专用接口 | safeMintForRole() | v3 支持社区批量操作 |
| **销毁追踪** | 无历史记录 | BurnRecord[] | v3 完整历史追踪 |
| **向后兼容** | N/A | 100% 兼容 | v3 保留所有 v2 函数 |

## API 对比

### 角色管理

#### v2.2.1
```solidity
// 硬编码的节点类型
enum NodeType {
    PAYMASTER_AOA,      // 0
    PAYMASTER_SUPER,    // 1
    ANODE,              // 2
    KMS                 // 3
}

// 社区注册（每个地址一个社区）
function registerCommunity(
    CommunityProfile memory profile,
    uint256 stGTokenAmount
) external;
```

#### v3.0.0
```solidity
// 动态角色系统
bytes32 roleId = keccak256("VALIDATOR");
bytes32 roleId = keccak256("MODERATOR");
bytes32 roleId = keccak256("CUSTOM_ROLE");

// 统一角色注册
function registerRole(
    bytes32 roleId,
    address user,
    bytes calldata roleData
) external;

// 统一退出
function exitRole(bytes32 roleId) external;

// 社区空投
function safeMintForRole(
    bytes32 roleId,
    address user,
    bytes calldata data
) external;
```

### 配置管理

#### v2.2.1
```solidity
// 只能修改预定义的 NodeType
function configureNodeType(
    NodeType nodeType,
    NodeTypeConfig calldata config
) external onlyOwner;
```

#### v3.0.0
```solidity
// 可以创建和配置任意角色
function configureRole(
    bytes32 roleId,
    RoleConfig calldata config
) external onlyOwner;

// 示例：添加新角色
bytes32 newRole = keccak256("GOVERNANCE_VOTER");
registry.configureRole(newRole, RoleConfig({
    minStake: 10 ether,
    slashThreshold: 5,
    slashBase: 2,
    slashIncrement: 1,
    slashMax: 10,
    isActive: true,
    description: "Governance Voter"
}));
```

### 查询接口

#### v2.2.1
```solidity
// 社区相关查询
function getCommunityProfile(address) external view returns (CommunityProfile);
function isRegisteredCommunity(address) external view returns (bool);
function getCommunityCount() external view returns (uint256);
```

#### v3.0.0
```solidity
// v2 查询（完全保留）
function getCommunityProfile(address) external view returns (CommunityProfile);
function isRegisteredCommunity(address) external view returns (bool);

// v3 新增角色查询
function checkRole(bytes32 roleId, address user) external view returns (bool);
function getRoleStake(bytes32 roleId, address user) external view returns (uint256);
function getRoleMembers(bytes32 roleId) external view returns (address[]);
function getRoleMemberCount(bytes32 roleId) external view returns (uint256);

// v3 新增历史查询
function getUserBurnHistory(address user) external view returns (uint256[]);
function getBurnRecord(uint256 index) external view returns (BurnRecord);
function getBurnHistoryCount() external view returns (uint256);
```

## 数据结构对比

### v2.2.1

```solidity
struct NodeTypeConfig {
    uint256 minStake;
    uint256 slashThreshold;
    uint256 slashBase;
    uint256 slashIncrement;
    uint256 slashMax;
}

// 固定的映射
mapping(NodeType => NodeTypeConfig) public nodeTypeConfigs;
```

### v3.0.0

```solidity
struct RoleConfig {
    uint256 minStake;
    uint256 slashThreshold;
    uint256 slashBase;
    uint256 slashIncrement;
    uint256 slashMax;
    bool isActive;           // 新增：角色激活状态
    string description;      // 新增：角色描述
}

struct BurnRecord {         // 新增：销毁历史
    bytes32 roleId;
    address user;
    uint256 amount;
    uint256 timestamp;
    string reason;
}

// 动态映射，支持任意角色
mapping(bytes32 => RoleConfig) public roleConfigs;
mapping(bytes32 => mapping(address => bool)) public hasRole;
mapping(bytes32 => mapping(address => uint256)) public roleStakes;
mapping(bytes32 => address[]) public roleMembers;

// 历史追踪
BurnRecord[] public burnHistory;
mapping(address => uint256[]) public userBurnHistory;
```

## 使用场景对比

### 场景 1: 注册 Paymaster

#### v2.2.1 方式
```solidity
CommunityProfile memory profile = CommunityProfile({
    name: "My Paymaster",
    ensName: "",
    xPNTsToken: address(0),
    supportedSBTs: new address[](0),
    nodeType: NodeType.PAYMASTER_SUPER,  // 固定类型
    paymasterAddress: paymasterAddr,
    community: address(0),
    registeredAt: 0,
    lastUpdatedAt: 0,
    isActive: false,
    allowPermissionlessMint: true
});

registry.registerCommunity(profile, 50 ether);
```

#### v3.0.0 方式（向后兼容）
```solidity
// 方式 1: 使用 v2 API（完全兼容）
registry.registerCommunity(profile, 50 ether);

// 方式 2: 使用 v3 统一 API
bytes32 paymasterRole = keccak256("PAYMASTER_SUPER");
bytes memory data = abi.encode(50 ether);
registry.registerRole(paymasterRole, msg.sender, data);
```

### 场景 2: 创建自定义角色

#### v2.2.1
```solidity
// ❌ 不支持，只能使用预定义的 4 种 NodeType
```

#### v3.0.0
```solidity
// ✅ 支持任意自定义角色

// 1. Owner 配置新角色
bytes32 customRole = keccak256("CONTENT_MODERATOR");
RoleConfig memory config = RoleConfig({
    minStake: 5 ether,
    slashThreshold: 10,
    slashBase: 1,
    slashIncrement: 1,
    slashMax: 5,
    isActive: true,
    description: "Content Moderator"
});
registry.configureRole(customRole, config);

// 2. 用户注册角色
bytes memory data = abi.encode(5 ether);
registry.registerRole(customRole, userAddr, data);

// 3. 查询角色
bool isModerator = registry.checkRole(customRole, userAddr);
```

### 场景 3: 社区空投角色

#### v2.2.1
```solidity
// ❌ 无专用接口，需要用户自己注册
```

#### v3.0.0
```solidity
// ✅ 社区可以批量空投角色给用户

// 社区调用
bytes32 memberRole = keccak256("COMMUNITY_MEMBER");
bytes memory data = abi.encode(10 ether);

// 空投给单个用户
registry.safeMintForRole(memberRole, user1, data);

// 批量空投（在应用层循环）
address[] memory users = [user1, user2, user3];
for (uint i = 0; i < users.length; i++) {
    registry.safeMintForRole(memberRole, users[i], data);
}
```

### 场景 4: 退出角色

#### v2.2.1
```solidity
// ❌ 无统一退出机制
// 只能通过 deactivateCommunity() 暂停，无法销毁
registry.deactivateCommunity();
```

#### v3.0.0
```solidity
// ✅ 统一退出和销毁

// 退出角色，自动解锁和销毁质押
bytes32 roleId = keccak256("VALIDATOR");
registry.exitRole(roleId);

// 查看销毁历史
uint256[] memory history = registry.getUserBurnHistory(msg.sender);
for (uint i = 0; i < history.length; i++) {
    BurnRecord memory record = registry.getBurnRecord(history[i]);
    console.log("Burned", record.amount, "at", record.timestamp);
}
```

## 事件对比

### v2.2.1 事件
```solidity
event CommunityRegistered(address indexed community, string name, NodeType indexed nodeType, uint256 staked);
event CommunityUpdated(address indexed community, string name);
event CommunityDeactivated(address indexed community);
event CommunityReactivated(address indexed community);
// ... 其他社区事件
```

### v3.0.0 新增事件
```solidity
// v2 事件（完全保留）
event CommunityRegistered(...);  // 保留
event CommunityUpdated(...);     // 保留

// v3 新增事件
event RoleConfigured(bytes32 indexed roleId, uint256 minStake, uint256 slashThreshold, string description);
event RoleGranted(bytes32 indexed roleId, address indexed user, uint256 stakeAmount);
event RoleRevoked(bytes32 indexed roleId, address indexed user, uint256 burnedAmount);
event RoleMintedByCommunity(bytes32 indexed roleId, address indexed user, address indexed community, uint256 amount);
event RoleBurned(bytes32 indexed roleId, address indexed user, uint256 amount, string reason);
```

## 安全性对比

| 安全特性 | v2.2.1 | v3.0.0 |
|----------|--------|--------|
| CEI 模式 | ✅ 部分函数 | ✅ 所有关键函数 |
| 重入保护 | ✅ 外部函数 | ✅ 所有外部函数 |
| 权限控制 | ✅ Owner/Oracle | ✅ Owner/Oracle/Community |
| 输入验证 | ✅ 基础验证 | ✅ 完整验证 |
| 历史审计 | ❌ 无 | ✅ 完整 BurnRecord |

## Gas 消耗对比（估算）

| 操作 | v2.2.1 | v3.0.0 | 差异 |
|------|--------|--------|------|
| 注册社区 | ~250k gas | ~250k gas | 相同 |
| 注册角色 | N/A | ~200k gas | 新功能 |
| 退出角色 | N/A | ~180k gas | 新功能 |
| 社区空投 | N/A | ~220k gas | 新功能 |
| 查询角色 | N/A | ~30k gas | 新功能 |

## 迁移指南

### 零改动迁移（推荐）

```solidity
// 现有 v2 代码无需任何修改
Registry_v2_2_1 registryV2 = Registry_v2_2_1(registryAddr);
registryV2.registerCommunity(profile, 50 ether);

// 升级到 v3 后，相同代码继续工作
Registry_v3_0_0 registryV3 = Registry_v3_0_0(registryAddr);
registryV3.registerCommunity(profile, 50 ether);  // ✅ 完全兼容
```

### 渐进式迁移

```solidity
// 阶段 1: 部署 v3，继续使用 v2 API
registry.registerCommunity(profile, amount);

// 阶段 2: 新功能使用 v3 API
bytes32 newRole = keccak256("NEW_ROLE");
registry.configureRole(newRole, config);
registry.registerRole(newRole, user, data);

// 阶段 3: 逐步迁移到 v3 统一 API
bytes32 paymasterRole = keccak256("PAYMASTER_SUPER");
registry.registerRole(paymasterRole, user, data);
```

## 选择指南

### 使用 v2.2.1 如果：
- 只需要 4 种预定义节点类型
- 不需要角色退出机制
- 不需要历史审计追踪
- 追求最小化改动

### 使用 v3.0.0 如果：
- 需要自定义角色类型
- 需要统一的角色管理 API
- 需要社区空投功能
- 需要完整的历史追踪
- 计划未来扩展（多角色、角色升级等）
- 需要更强的安全保证（完整 CEI 模式）

## 总结

### v3.0.0 的优势

1. **灵活性** ⭐⭐⭐⭐⭐
   - 动态角色系统，不受预定义类型限制
   - 支持任意数量的自定义角色

2. **可扩展性** ⭐⭐⭐⭐⭐
   - 为未来功能奠定基础（多角色、角色升级）
   - 统一 API 简化集成

3. **安全性** ⭐⭐⭐⭐⭐
   - 完整 CEI 模式
   - 全面重入保护
   - 完整历史审计

4. **兼容性** ⭐⭐⭐⭐⭐
   - 100% 向后兼容 v2
   - 零改动迁移成本

5. **功能完整性** ⭐⭐⭐⭐⭐
   - 统一入口：registerRole
   - 统一退出：exitRole
   - 社区空投：safeMintForRole
   - 历史追踪：完整的 BurnRecord

### v3.0.0 的限制

1. 代码复杂度略高（927 行 vs v2 的 582 行）
2. 新功能的学习成本
3. 部分高级功能尚未实现（多角色持有、角色转移）

### 推荐

**强烈推荐使用 v3.0.0**，原因：
- ✅ 完全向后兼容，无风险
- ✅ 更强的安全性
- ✅ 更好的可扩展性
- ✅ 更完整的功能
- ✅ 为未来发展奠定基础

---

更新时间: 2025-11-28
对比版本: v2.2.1 vs v3.0.0

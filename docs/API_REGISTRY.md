# Registry API Reference

**[English](#english)** | **[中文](#chinese)**

<a name="english"></a>

---

## Contract Information

- **Version**: v2.2.1
- **Sepolia Address**: `0xf384c592D5258c91805128291c5D4c069DD30CA6`

## Data Structures

### NodeType (enum)

```solidity
enum NodeType {
    PAYMASTER_AOA,      // 0: Independent paymaster (30 GT)
    PAYMASTER_SUPER,    // 1: SuperPaymaster operator (50 GT)
    ANODE,              // 2: Compute node (20 GT)
    KMS                 // 3: Key management (100 GT)
}
```

### CommunityProfile (struct)

```solidity
struct CommunityProfile {
    string name;                    // Community name (max 100 chars)
    string ensName;                 // ENS domain (optional)
    address xPNTsToken;             // Community gas token
    address[] supportedSBTs;        // Supported SBT contracts (max 10)
    NodeType nodeType;              // Node type
    address paymasterAddress;       // Paymaster address
    address community;              // Owner address
    uint256 registeredAt;           // Registration timestamp
    uint256 lastUpdatedAt;          // Last update timestamp
    bool isActive;                  // Active status
    bool allowPermissionlessMint;   // Allow public SBT minting
}
```

### CommunityStake (struct)

```solidity
struct CommunityStake {
    uint256 stGTokenLocked;   // Locked stake amount
    uint256 failureCount;     // Failure count (for slashing)
    uint256 lastFailureTime;  // Last failure timestamp
    uint256 totalSlashed;     // Total slashed amount
    bool isActive;            // Stake active status
}
```

---

## Write Functions

### registerCommunity

Register a new community with pre-staked balance.

```solidity
function registerCommunity(
    CommunityProfile memory profile,
    uint256 stGTokenAmount
) external
```

**Parameters:**
- `profile`: Community profile data
- `stGTokenAmount`: Amount to lock (0 if already locked)

**Events:** `CommunityRegistered`

---

### registerCommunityWithAutoStake

Register with automatic staking (recommended).

```solidity
function registerCommunityWithAutoStake(
    CommunityProfile memory profile,
    uint256 stakeAmount
) external
```

**Requirements:**
- `GToken.approve(Registry, stakeAmount)` called first

**Events:** `CommunityRegistered`, `CommunityRegisteredWithAutoStake`

---

### updateCommunityProfile

Update community profile (owner only).

```solidity
function updateCommunityProfile(
    CommunityProfile memory profile
) external
```

**Events:** `CommunityUpdated`

---

### deactivateCommunity

Deactivate community (owner only).

```solidity
function deactivateCommunity() external
```

**Events:** `CommunityDeactivated`

---

### reactivateCommunity

Reactivate community (owner only).

```solidity
function reactivateCommunity() external
```

**Events:** `CommunityReactivated`

---

### transferCommunityOwnership

Transfer ownership to new address.

```solidity
function transferCommunityOwnership(address newOwner) external
```

**Events:** `CommunityOwnershipTransferred`

---

### setPermissionlessMint

Toggle permissionless SBT minting.

```solidity
function setPermissionlessMint(bool enabled) external
```

**Events:** `PermissionlessMintToggled`

---

## Read Functions

### getCommunityProfile

```solidity
function getCommunityProfile(address communityAddress)
    external view
    returns (CommunityProfile memory)
```

---

### getCommunityByName

```solidity
function getCommunityByName(string memory name)
    external view
    returns (address)
```

---

### getCommunityByENS

```solidity
function getCommunityByENS(string memory ensName)
    external view
    returns (address)
```

---

### getCommunityBySBT

```solidity
function getCommunityBySBT(address sbtAddress)
    external view
    returns (address)
```

---

### getCommunityCount

```solidity
function getCommunityCount() external view returns (uint256)
```

---

### getCommunities

Get paginated community list.

```solidity
function getCommunities(uint256 offset, uint256 limit)
    external view
    returns (address[] memory)
```

---

### getCommunityStatus

```solidity
function getCommunityStatus(address communityAddress)
    external view
    returns (bool registered, bool isActive)
```

---

### isRegisteredCommunity

```solidity
function isRegisteredCommunity(address communityAddress)
    external view
    returns (bool)
```

---

### isPermissionlessMintAllowed

```solidity
function isPermissionlessMintAllowed(address communityAddress)
    external view
    returns (bool)
```

---

## Admin Functions (Owner Only)

### setOracle

```solidity
function setOracle(address _oracle) external onlyOwner
```

---

### setSuperPaymasterV2

```solidity
function setSuperPaymasterV2(address _superPaymasterV2) external onlyOwner
```

---

### configureNodeType

```solidity
function configureNodeType(
    NodeType nodeType,
    NodeTypeConfig calldata config
) external onlyOwner
```

---

### reportFailure (Oracle)

```solidity
function reportFailure(address community) external
```

**Access:** Oracle or Owner only

---

### resetFailureCount

```solidity
function resetFailureCount(address community) external onlyOwner
```

---

## Events

```solidity
event CommunityRegistered(address indexed community, string name, NodeType indexed nodeType, uint256 staked);
event CommunityUpdated(address indexed community, string name);
event CommunityDeactivated(address indexed community);
event CommunityReactivated(address indexed community);
event CommunityOwnershipTransferred(address indexed oldOwner, address indexed newOwner, uint256 timestamp);
event FailureReported(address indexed community, uint256 failureCount);
event CommunitySlashed(address indexed community, uint256 amount, uint256 newStake);
event PermissionlessMintToggled(address indexed community, bool enabled);
event CommunityRegisteredWithAutoStake(address indexed community, string name, uint256 staked, uint256 autoStaked);
```

## Errors

```solidity
error CommunityAlreadyRegistered(address community);
error CommunityNotRegistered(address community);
error NameAlreadyTaken(string name);
error ENSAlreadyTaken(string ensName);
error InvalidAddress(address addr);
error InvalidParameter(string message);
error CommunityNotActive(address community);
error InsufficientStake(uint256 provided, uint256 required);
error UnauthorizedOracle(address caller);
error NameEmpty();
error NotFound();
error InsufficientGTokenBalance(uint256 available, uint256 required);
error AutoStakeFailed(string reason);
```

## Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `MAX_SUPPORTED_SBTS` | 10 | Max SBTs per community |
| `MAX_NAME_LENGTH` | 100 | Max name length |
| `VERSION` | "2.2.1" | Contract version |
| `VERSION_CODE` | 20201 | Numeric version |

---

<a name="chinese"></a>

# Registry API 参考

**[English](#english)** | **[中文](#chinese)**

---

## 合约信息

- **版本**: v2.2.1
- **Sepolia 地址**: `0xf384c592D5258c91805128291c5D4c069DD30CA6`

## 数据结构

### NodeType (枚举)

```solidity
enum NodeType {
    PAYMASTER_AOA,      // 0: 独立 paymaster (30 GT)
    PAYMASTER_SUPER,    // 1: SuperPaymaster 运营商 (50 GT)
    ANODE,              // 2: 计算节点 (20 GT)
    KMS                 // 3: 密钥管理 (100 GT)
}
```

### CommunityProfile (结构体)

```solidity
struct CommunityProfile {
    string name;                    // 社区名称（最多 100 字符）
    string ensName;                 // ENS 域名（可选）
    address xPNTsToken;             // 社区 Gas 代币
    address[] supportedSBTs;        // 支持的 SBT 合约（最多 10 个）
    NodeType nodeType;              // 节点类型
    address paymasterAddress;       // Paymaster 地址
    address community;              // 所有者地址
    uint256 registeredAt;           // 注册时间戳
    uint256 lastUpdatedAt;          // 最后更新时间戳
    bool isActive;                  // 激活状态
    bool allowPermissionlessMint;   // 允许公开 SBT 铸造
}
```

### CommunityStake (结构体)

```solidity
struct CommunityStake {
    uint256 stGTokenLocked;   // 锁定的质押金额
    uint256 failureCount;     // 失败次数（用于惩罚）
    uint256 lastFailureTime;  // 最后失败时间戳
    uint256 totalSlashed;     // 总惩罚金额
    bool isActive;            // 质押激活状态
}
```

---

## 写入函数

### registerCommunity

使用预质押余额注册新社区。

```solidity
function registerCommunity(
    CommunityProfile memory profile,
    uint256 stGTokenAmount
) external
```

**参数:**
- `profile`: 社区资料数据
- `stGTokenAmount`: 锁定金额（如已锁定则为 0）

**事件:** `CommunityRegistered`

---

### registerCommunityWithAutoStake

自动质押注册（推荐）。

```solidity
function registerCommunityWithAutoStake(
    CommunityProfile memory profile,
    uint256 stakeAmount
) external
```

**要求:**
- 需先调用 `GToken.approve(Registry, stakeAmount)`

**事件:** `CommunityRegistered`, `CommunityRegisteredWithAutoStake`

---

### updateCommunityProfile

更新社区资料（仅所有者）。

```solidity
function updateCommunityProfile(
    CommunityProfile memory profile
) external
```

**事件:** `CommunityUpdated`

---

### deactivateCommunity

停用社区（仅所有者）。

```solidity
function deactivateCommunity() external
```

**事件:** `CommunityDeactivated`

---

### reactivateCommunity

重新激活社区（仅所有者）。

```solidity
function reactivateCommunity() external
```

**事件:** `CommunityReactivated`

---

### transferCommunityOwnership

转移所有权到新地址。

```solidity
function transferCommunityOwnership(address newOwner) external
```

**事件:** `CommunityOwnershipTransferred`

---

### setPermissionlessMint

切换无需许可 SBT 铸造。

```solidity
function setPermissionlessMint(bool enabled) external
```

**事件:** `PermissionlessMintToggled`

---

## 读取函数

### getCommunityProfile

```solidity
function getCommunityProfile(address communityAddress)
    external view
    returns (CommunityProfile memory)
```

---

### getCommunityByName

```solidity
function getCommunityByName(string memory name)
    external view
    returns (address)
```

---

### getCommunityByENS

```solidity
function getCommunityByENS(string memory ensName)
    external view
    returns (address)
```

---

### getCommunityBySBT

```solidity
function getCommunityBySBT(address sbtAddress)
    external view
    returns (address)
```

---

### getCommunityCount

```solidity
function getCommunityCount() external view returns (uint256)
```

---

### getCommunities

获取分页社区列表。

```solidity
function getCommunities(uint256 offset, uint256 limit)
    external view
    returns (address[] memory)
```

---

### getCommunityStatus

```solidity
function getCommunityStatus(address communityAddress)
    external view
    returns (bool registered, bool isActive)
```

---

### isRegisteredCommunity

```solidity
function isRegisteredCommunity(address communityAddress)
    external view
    returns (bool)
```

---

### isPermissionlessMintAllowed

```solidity
function isPermissionlessMintAllowed(address communityAddress)
    external view
    returns (bool)
```

---

## 管理函数（仅所有者）

### setOracle

```solidity
function setOracle(address _oracle) external onlyOwner
```

---

### setSuperPaymasterV2

```solidity
function setSuperPaymasterV2(address _superPaymasterV2) external onlyOwner
```

---

### configureNodeType

```solidity
function configureNodeType(
    NodeType nodeType,
    NodeTypeConfig calldata config
) external onlyOwner
```

---

### reportFailure (预言机)

```solidity
function reportFailure(address community) external
```

**访问权限:** 仅预言机或所有者

---

### resetFailureCount

```solidity
function resetFailureCount(address community) external onlyOwner
```

---

## 事件

```solidity
event CommunityRegistered(address indexed community, string name, NodeType indexed nodeType, uint256 staked);
event CommunityUpdated(address indexed community, string name);
event CommunityDeactivated(address indexed community);
event CommunityReactivated(address indexed community);
event CommunityOwnershipTransferred(address indexed oldOwner, address indexed newOwner, uint256 timestamp);
event FailureReported(address indexed community, uint256 failureCount);
event CommunitySlashed(address indexed community, uint256 amount, uint256 newStake);
event PermissionlessMintToggled(address indexed community, bool enabled);
event CommunityRegisteredWithAutoStake(address indexed community, string name, uint256 staked, uint256 autoStaked);
```

## 错误

```solidity
error CommunityAlreadyRegistered(address community);  // 社区已注册
error CommunityNotRegistered(address community);      // 社区未注册
error NameAlreadyTaken(string name);                  // 名称已被占用
error ENSAlreadyTaken(string ensName);                // ENS 已被占用
error InvalidAddress(address addr);                    // 无效地址
error InvalidParameter(string message);                // 无效参数
error CommunityNotActive(address community);          // 社区未激活
error InsufficientStake(uint256 provided, uint256 required);  // 质押不足
error UnauthorizedOracle(address caller);              // 未授权的预言机
error NameEmpty();                                     // 名称为空
error NotFound();                                      // 未找到
error InsufficientGTokenBalance(uint256 available, uint256 required);  // GToken 余额不足
error AutoStakeFailed(string reason);                  // 自动质押失败
```

## 常量

| 常量 | 值 | 描述 |
|------|-----|------|
| `MAX_SUPPORTED_SBTS` | 10 | 每个社区最大 SBT 数量 |
| `MAX_NAME_LENGTH` | 100 | 最大名称长度 |
| `VERSION` | "2.2.1" | 合约版本 |
| `VERSION_CODE` | 20201 | 数字版本 |

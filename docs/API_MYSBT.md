# MySBT API Reference

**[English](#english)** | **[中文](#chinese)**

<a name="english"></a>

---

## Contract Information

- **Version**: v2.4.5
- **Sepolia Address**: `0xa4eda5d023ea94a60b1d4b5695f022e1972858e7`
- **Standard**: ERC-721 (Non-transferable)

## Data Structures

### SBTData (struct)

```solidity
struct SBTData {
    address holder;           // SBT owner address
    address firstCommunity;   // First community joined
    uint256 mintedAt;         // Mint timestamp
    uint256 totalCommunities; // Number of communities joined
}
```

### CommunityMembership (struct)

```solidity
struct CommunityMembership {
    address community;    // Community address
    uint256 joinedAt;     // Join timestamp
    uint256 lastActive;   // Last activity timestamp
    bool isActive;        // Active status
    string metadata;      // JSON metadata (max 1024 bytes)
}
```

---

## Minting Functions

### mintWithAutoStake

Recommended: Single transaction mint with automatic staking.

```solidity
function mintWithAutoStake(
    address comm,
    string memory meta
) external returns (uint256 tid, bool isNew)
```

**Parameters:**
- `comm`: Community address to join
- `meta`: JSON metadata (max 1024 bytes)

**Requirements:**
- `GToken.approve(MySBT, 0.4 ether)` called first
- Community must allow permissionless mint

**Returns:**
- `tid`: Token ID (new or existing)
- `isNew`: True if new SBT minted

**Events:** `SBTMinted` or `MembershipAdded`

---

### userMint

Mint using pre-staked balance.

```solidity
function userMint(
    address comm,
    string memory meta
) external returns (uint256 tid, bool isNew)
```

**Requirements:**
- Available staked balance >= 0.3 GT
- GToken approval for 0.1 GT mint fee
- Community must allow permissionless mint

---

### mintOrAddMembership

Called by registered communities.

```solidity
function mintOrAddMembership(
    address u,
    string memory meta
) external returns (uint256 tid, bool isNew)
```

**Access:** Registered communities only

---

### airdropMint

Operator-paid minting (v2.4.4+).

```solidity
function airdropMint(
    address u,
    string memory meta
) external returns (uint256 tid, bool isNew)
```

**Parameters:**
- `u`: User address to receive SBT
- `meta`: JSON metadata

**Access:** Registered communities only

**Operator pays:**
- 0.3 GT staked for user via `stakeFor()`
- 0.1 GT burned as mint fee

---

### safeMint

DAO-only emergency mint.

```solidity
function safeMint(
    address to,
    address comm,
    string memory meta
) external returns (uint256 tid)
```

**Access:** DAO multisig only

---

## Burn Function

### burnSBT

Burn SBT and unlock stake.

```solidity
function burnSBT() external returns (uint256 net)
```

**Returns:**
- `net`: Amount returned after exit fee

**Process:**
1. Deactivates all community memberships
2. Removes SBT holder from SuperPaymaster (v2.4.5)
3. Burns the SBT token
4. Unlocks stake (minus exit fee)

**Events:** `SBTBurned`, `MembershipDeactivated`

---

## Community Functions

### leaveCommunity

Leave a community without burning SBT.

```solidity
function leaveCommunity(address comm) external
```

**Events:** `MembershipDeactivated`

---

### recordActivity

Record user activity (called by communities).

```solidity
function recordActivity(address u) external
```

**Access:** Registered communities only

**Requirements:**
- Minimum 5 minutes between activity records

**Events:** `ActivityRecorded`

---

## Read Functions

### userToSBT

Get user's token ID.

```solidity
function userToSBT(address user)
    external view
    returns (uint256 tokenId)
```

Returns 0 if user has no SBT.

---

### sbtData

Get SBT data by token ID.

```solidity
function sbtData(uint256 tokenId)
    external view
    returns (SBTData memory)
```

---

### getUserSBT

Alias for userToSBT.

```solidity
function getUserSBT(address u)
    external view
    returns (uint256)
```

---

### getSBTData

Alias for sbtData.

```solidity
function getSBTData(uint256 tid)
    external view
    returns (SBTData memory)
```

---

### getMemberships

Get all community memberships.

```solidity
function getMemberships(uint256 tid)
    external view
    returns (CommunityMembership[] memory)
```

---

### getCommunityMembership

Get specific community membership.

```solidity
function getCommunityMembership(uint256 tid, address comm)
    external view
    returns (CommunityMembership memory)
```

---

### verifyCommunityMembership

Check if user is active member of community.

```solidity
function verifyCommunityMembership(address u, address comm)
    external view
    returns (bool)
```

---

## Admin Functions (DAO Only)

### setSuperPaymaster

Set SuperPaymaster for callbacks (v2.4.5).

```solidity
function setSuperPaymaster(address _paymaster) external
```

**Events:** `SuperPaymasterUpdated`

---

### setReputationCalculator

```solidity
function setReputationCalculator(address c) external
```

---

### setMinLockAmount

```solidity
function setMinLockAmount(uint256 a) external
```

Default: 0.3 ether

---

### setMintFee

```solidity
function setMintFee(uint256 f) external
```

Default: 0.1 ether

---

### setDAOMultisig

```solidity
function setDAOMultisig(address d) external
```

---

### setRegistry

```solidity
function setRegistry(address r) external
```

---

### pause / unpause

```solidity
function pause() external
function unpause() external
```

---

## Events

```solidity
event SBTMinted(address indexed holder, uint256 indexed tokenId, address indexed community, uint256 timestamp);
event SBTBurned(address indexed holder, uint256 indexed tokenId, uint256 lockedAmount, uint256 netReturned, uint256 timestamp);
event MembershipAdded(uint256 indexed tokenId, address indexed community, string metadata, uint256 timestamp);
event MembershipDeactivated(uint256 indexed tokenId, address indexed community, uint256 timestamp);
event ActivityRecorded(uint256 indexed tokenId, address indexed community, uint256 weekNumber, uint256 timestamp);
event SuperPaymasterUpdated(address indexed oldPaymaster, address indexed newPaymaster, uint256 timestamp);
event ReputationCalculatorUpdated(address indexed oldCalculator, address indexed newCalculator, uint256 timestamp);
event MinLockAmountUpdated(uint256 oldAmount, uint256 newAmount, uint256 timestamp);
event MintFeeUpdated(uint256 oldFee, uint256 newFee, uint256 timestamp);
event DAOMultisigUpdated(address indexed oldDAO, address indexed newDAO, uint256 timestamp);
event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry, uint256 timestamp);
event ContractPaused(address indexed by, uint256 timestamp);
event ContractUnpaused(address indexed by, uint256 timestamp);
```

## Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `VERSION` | "2.4.5" | Contract version |
| `VERSION_CODE` | 20405 | Numeric version |
| `minLockAmount` | 0.3 ether | Min stake to lock |
| `mintFee` | 0.1 ether | Burned on mint |
| `BURN_ADDRESS` | `0x...dEaD` | Fee burn address |
| `MIN_INT` | 5 minutes | Activity cooldown |

## SuperPaymaster Integration (v2.4.5)

MySBT automatically registers/unregisters SBT holders with SuperPaymaster:

```
Mint Flow:
  User mints SBT → MySBT._mint() → MySBT._registerSBTHolder()
                                 → SuperPaymaster.registerSBTHolder()

Burn Flow:
  User burns SBT → MySBT._removeSBTHolder() → SuperPaymaster.removeSBTHolder()
                → MySBT._burn()
```

This enables SuperPaymaster to verify SBT ownership internally (~800 gas saved per tx).

---

<a name="chinese"></a>

# MySBT API 参考

**[English](#english)** | **[中文](#chinese)**

---

## 合约信息

- **版本**: v2.4.5
- **Sepolia 地址**: `0xa4eda5d023ea94a60b1d4b5695f022e1972858e7`
- **标准**: ERC-721（不可转让）

## 数据结构

### SBTData (结构体)

```solidity
struct SBTData {
    address holder;           // SBT 所有者地址
    address firstCommunity;   // 首个加入的社区
    uint256 mintedAt;         // 铸造时间戳
    uint256 totalCommunities; // 加入的社区数量
}
```

### CommunityMembership (结构体)

```solidity
struct CommunityMembership {
    address community;    // 社区地址
    uint256 joinedAt;     // 加入时间戳
    uint256 lastActive;   // 最后活动时间戳
    bool isActive;        // 激活状态
    string metadata;      // JSON 元数据（最大 1024 字节）
}
```

---

## 铸造函数

### mintWithAutoStake

推荐：单笔交易自动质押铸造。

```solidity
function mintWithAutoStake(
    address comm,
    string memory meta
) external returns (uint256 tid, bool isNew)
```

**参数:**
- `comm`: 要加入的社区地址
- `meta`: JSON 元数据（最大 1024 字节）

**要求:**
- 需先调用 `GToken.approve(MySBT, 0.4 ether)`
- 社区必须允许无需许可铸造

**返回:**
- `tid`: 代币 ID（新建或已存在）
- `isNew`: 如果铸造了新 SBT 则为 true

**事件:** `SBTMinted` 或 `MembershipAdded`

---

### userMint

使用预质押余额铸造。

```solidity
function userMint(
    address comm,
    string memory meta
) external returns (uint256 tid, bool isNew)
```

**要求:**
- 可用质押余额 >= 0.3 GT
- GToken 授权 0.1 GT 铸造费
- 社区必须允许无需许可铸造

---

### mintOrAddMembership

由已注册社区调用。

```solidity
function mintOrAddMembership(
    address u,
    string memory meta
) external returns (uint256 tid, bool isNew)
```

**访问权限:** 仅已注册社区

---

### airdropMint

运营商付费铸造（v2.4.4+）。

```solidity
function airdropMint(
    address u,
    string memory meta
) external returns (uint256 tid, bool isNew)
```

**参数:**
- `u`: 接收 SBT 的用户地址
- `meta`: JSON 元数据

**访问权限:** 仅已注册社区

**运营商支付:**
- 通过 `stakeFor()` 为用户质押 0.3 GT
- 燃烧 0.1 GT 铸造费

---

### safeMint

DAO 专用紧急铸造。

```solidity
function safeMint(
    address to,
    address comm,
    string memory meta
) external returns (uint256 tid)
```

**访问权限:** 仅 DAO 多签

---

## 销毁函数

### burnSBT

销毁 SBT 并解锁质押。

```solidity
function burnSBT() external returns (uint256 net)
```

**返回:**
- `net`: 扣除退出费后返还的金额

**流程:**
1. 停用所有社区会员资格
2. 从 SuperPaymaster 移除 SBT 持有者（v2.4.5）
3. 销毁 SBT 代币
4. 解锁质押（扣除退出费）

**事件:** `SBTBurned`, `MembershipDeactivated`

---

## 社区函数

### leaveCommunity

离开社区但不销毁 SBT。

```solidity
function leaveCommunity(address comm) external
```

**事件:** `MembershipDeactivated`

---

### recordActivity

记录用户活动（由社区调用）。

```solidity
function recordActivity(address u) external
```

**访问权限:** 仅已注册社区

**要求:**
- 活动记录间隔至少 5 分钟

**事件:** `ActivityRecorded`

---

## 读取函数

### userToSBT

获取用户的代币 ID。

```solidity
function userToSBT(address user)
    external view
    returns (uint256 tokenId)
```

如果用户没有 SBT 则返回 0。

---

### sbtData

通过代币 ID 获取 SBT 数据。

```solidity
function sbtData(uint256 tokenId)
    external view
    returns (SBTData memory)
```

---

### getUserSBT

userToSBT 的别名。

```solidity
function getUserSBT(address u)
    external view
    returns (uint256)
```

---

### getSBTData

sbtData 的别名。

```solidity
function getSBTData(uint256 tid)
    external view
    returns (SBTData memory)
```

---

### getMemberships

获取所有社区会员资格。

```solidity
function getMemberships(uint256 tid)
    external view
    returns (CommunityMembership[] memory)
```

---

### getCommunityMembership

获取特定社区会员资格。

```solidity
function getCommunityMembership(uint256 tid, address comm)
    external view
    returns (CommunityMembership memory)
```

---

### verifyCommunityMembership

检查用户是否为社区的活跃成员。

```solidity
function verifyCommunityMembership(address u, address comm)
    external view
    returns (bool)
```

---

## 管理函数（仅 DAO）

### setSuperPaymaster

设置 SuperPaymaster 用于回调（v2.4.5）。

```solidity
function setSuperPaymaster(address _paymaster) external
```

**事件:** `SuperPaymasterUpdated`

---

### setReputationCalculator

```solidity
function setReputationCalculator(address c) external
```

---

### setMinLockAmount

```solidity
function setMinLockAmount(uint256 a) external
```

默认: 0.3 ether

---

### setMintFee

```solidity
function setMintFee(uint256 f) external
```

默认: 0.1 ether

---

### setDAOMultisig

```solidity
function setDAOMultisig(address d) external
```

---

### setRegistry

```solidity
function setRegistry(address r) external
```

---

### pause / unpause

```solidity
function pause() external
function unpause() external
```

---

## 事件

```solidity
event SBTMinted(address indexed holder, uint256 indexed tokenId, address indexed community, uint256 timestamp);  // SBT 铸造
event SBTBurned(address indexed holder, uint256 indexed tokenId, uint256 lockedAmount, uint256 netReturned, uint256 timestamp);  // SBT 销毁
event MembershipAdded(uint256 indexed tokenId, address indexed community, string metadata, uint256 timestamp);  // 会员添加
event MembershipDeactivated(uint256 indexed tokenId, address indexed community, uint256 timestamp);  // 会员停用
event ActivityRecorded(uint256 indexed tokenId, address indexed community, uint256 weekNumber, uint256 timestamp);  // 活动记录
event SuperPaymasterUpdated(address indexed oldPaymaster, address indexed newPaymaster, uint256 timestamp);  // SuperPaymaster 更新
event ReputationCalculatorUpdated(address indexed oldCalculator, address indexed newCalculator, uint256 timestamp);  // 声誉计算器更新
event MinLockAmountUpdated(uint256 oldAmount, uint256 newAmount, uint256 timestamp);  // 最小锁定金额更新
event MintFeeUpdated(uint256 oldFee, uint256 newFee, uint256 timestamp);  // 铸造费更新
event DAOMultisigUpdated(address indexed oldDAO, address indexed newDAO, uint256 timestamp);  // DAO 多签更新
event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry, uint256 timestamp);  // Registry 更新
event ContractPaused(address indexed by, uint256 timestamp);  // 合约暂停
event ContractUnpaused(address indexed by, uint256 timestamp);  // 合约取消暂停
```

## 常量

| 常量 | 值 | 描述 |
|------|-----|------|
| `VERSION` | "2.4.5" | 合约版本 |
| `VERSION_CODE` | 20405 | 数字版本 |
| `minLockAmount` | 0.3 ether | 最小锁定质押 |
| `mintFee` | 0.1 ether | 铸造时燃烧 |
| `BURN_ADDRESS` | `0x...dEaD` | 费用燃烧地址 |
| `MIN_INT` | 5 分钟 | 活动冷却时间 |

## SuperPaymaster 集成 (v2.4.5)

MySBT 自动向 SuperPaymaster 注册/注销 SBT 持有者：

```
铸造流程:
  用户铸造 SBT → MySBT._mint() → MySBT._registerSBTHolder()
                               → SuperPaymaster.registerSBTHolder()

销毁流程:
  用户销毁 SBT → MySBT._removeSBTHolder() → SuperPaymaster.removeSBTHolder()
              → MySBT._burn()
```

这使 SuperPaymaster 能够内部验证 SBT 所有权（每笔交易节省约 800 Gas）。

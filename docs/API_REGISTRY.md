# Registry API Reference

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

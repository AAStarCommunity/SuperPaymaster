# Mycelium Registry Refactor: Complete Changelog
## 菌丝体架构重构：完整变更日志

**Date**: 2025-11-27
**Status**: In Progress (Phase 1 - Registry Refactor)
**Purpose**: Track ALL changes for frontend migration

---

## 📋 Contracts Being Modified

### 1. Registry.sol
**Status**: 🔴 IN PROGRESS
**Lines Changed**: ~2000+ (major refactor)
**Breaking Changes**: YES

### 2. MySBT.sol
**Status**: ⏳ PENDING
**Lines Changed**: ~500+ (moderate refactor)
**Breaking Changes**: YES

### 3. GTokenStaking.sol
**Status**: ⏳ PENDING
**Lines Changed**: ~200+ (parameter updates)
**Breaking Changes**: YES (function signatures)

---

## 🎯 Phase 1: Registry Refactor

### Removed from Registry

#### ❌ Enum & Structs
```solidity
// REMOVED
enum NodeType {
    PAYMASTER_AOA = 0,
    PAYMASTER_SUPER = 1,
    ANODE = 2,
    KMS = 3
}

struct NodeTypeConfig {
    uint256 minStake;
    uint256 slashThreshold;
    uint256 slashBase;
    uint256 slashIncrement;
    uint256 slashMax;
}

struct CommunityProfile {
    string name;
    string ensName;
    address xPNTsToken;
    address[] supportedSBTs;
    NodeType nodeType;
    address paymasterAddress;
    address community;
    uint256 registeredAt;
    uint256 lastUpdatedAt;
    bool isActive;
    bool allowPermissionlessMint;
}

struct CommunityStake {
    uint256 stGTokenLocked;
    uint256 failureCount;
    uint256 lastFailureTime;
    uint256 totalSlashed;
    bool isActive;
}
```

#### ❌ Storage Variables
```solidity
// REMOVED
mapping(NodeType => NodeTypeConfig) public nodeTypeConfigs;
mapping(address => CommunityProfile) public communities;
mapping(address => CommunityStake) public communityStakes;
mapping(string => address) public communityByName;
mapping(string => address) public communityByENS;
mapping(address => address) public communityBySBT;
address[] public communityList;
mapping(address => bool) public isRegistered;
```

#### ❌ Functions
```solidity
// REMOVED - All of these are replaced by registerRole()
function registerCommunity(CommunityProfile memory profile, uint256 stGTokenAmount) external
function registerCommunityWithAutoStake(CommunityProfile memory profile, uint256 stakeAmount) external
function updateCommunityProfile(CommunityProfile memory profile) external
function deactivateCommunity() external
function reactivateCommunity() external
function transferCommunityOwnership(address newOwner) external nonReentrant
function setPermissionlessMint(bool enabled) external nonReentrant

// View functions removed
function getCommunityProfile(address communityAddress) external view returns (CommunityProfile memory)
function getCommunityByName(string memory name) external view returns (address)
function getCommunityByENS(string memory ensName) external view returns (address)
function getCommunityBySBT(address sbtAddress) external view returns (address)
function getCommunityCount() external view returns (uint256)
function getCommunities(uint256 offset, uint256 limit) external view returns (address[] memory)
function getCommunityStatus(address communityAddress) external view returns (bool, bool)
function isRegisteredCommunity(address communityAddress) external view returns (bool)
function isPermissionlessMintAllowed(address communityAddress) external view returns (bool)
```

#### ❌ Slash Functions
```solidity
// REMOVED - Slash moved to separate governance mechanism
function reportFailure(address community) external
function _slashCommunity(address community) internal
function resetFailureCount(address community) external onlyOwner
```

#### ❌ Events
```solidity
// REMOVED
event CommunityRegistered(address indexed community, string name, NodeType indexed nodeType, uint256 staked);
event CommunityUpdated(address indexed community, string name);
event CommunityDeactivated(address indexed community);
event CommunityReactivated(address indexed community);
event CommunityOwnershipTransferred(address indexed oldOwner, address indexed newOwner, uint256 timestamp);
event FailureReported(address indexed community, uint256 failureCount);
event CommunitySlashed(address indexed community, uint256 amount, uint256 newStake);
event FailureCountReset(address indexed community);
event CommunityRegisteredWithAutoStake(address indexed community, string name, uint256 staked, uint256 autoStaked);
event PaymasterRegisteredWithAutoStake(address indexed paymaster, address indexed owner, NodeType indexed nodeType, uint256 staked, uint256 autoStaked);
event PermissionlessMintToggled(address indexed community, bool enabled);
```

---

### Added to Registry

#### ✅ New Structs
```solidity
// RoleConfig - replaces NodeTypeConfig
struct RoleConfig {
    bytes32 roleId;           // "ENDUSER_V1", "COMMUNITY_V1", etc.
    string roleName;          // "End User", "Community", "Paymaster"
    uint256 minStake;         // Stake amount
    uint256 entryBurn;        // Burn amount
    uint256 exitFeePercent;   // Exit fee percentage (e.g., 17)
    uint256 minExitFee;       // Minimum exit fee
    bool requiresSBT;         // Should mint SBT?
    address sbtContract;      // MySBT contract
    uint256 createdAt;
    uint256 updatedAt;
    bool enabled;
}

// User role tracking
struct UserRoleData {
    bytes32 roleId;
    uint256 registeredAt;
    uint256 lastUpdatedAt;
    uint256 sbtTokenId;       // Associated SBT token
    bool active;
}

// Burn record for audit trail
struct BurnRecord {
    uint256 amount;
    bytes32 roleId;
    string reason;            // "entry", "exit"
    uint256 timestamp;
}

// Role registration history
struct RoleRegistration {
    bytes32 roleId;
    uint256 amount;
    uint256 burn;
    uint256 sbtTokenId;
    uint256 registeredAt;
    uint256 exitedAt;
}

// Role statistics
struct RoleStats {
    uint256 totalRegistrations;
    uint256 activeRegistrations;
    uint256 totalBurned;
    uint256 totalExitFees;
}
```

#### ✅ New Storage
```solidity
// Dynamic role configurations
mapping(bytes32 roleId => RoleConfig) public roleConfigs;

// User roles (can have multiple)
mapping(address user => bytes32[] roles) public userRoles;

// User role data
mapping(address user => mapping(bytes32 => UserRoleData)) public userRoleData;

// Burn audit trail
mapping(address user => BurnRecord[]) public burnHistory;
mapping(address user => uint256) public totalBurned;

// Role registration history
mapping(address user => RoleRegistration[]) public roleHistory;

// Role statistics
mapping(bytes32 roleId => RoleStats) public roleStats;

// Authorized minters (only MySBT)
mapping(address => bool) public authorizedMinters;

// GTokenStaking reference
address public gTokenStakingAddress;

// Constants for role IDs
bytes32 public constant ROLE_ENDUSER = keccak256("ENDUSER");
bytes32 public constant ROLE_COMMUNITY = keccak256("COMMUNITY");
bytes32 public constant ROLE_PAYMASTER = keccak256("PAYMASTER");
bytes32 public constant ROLE_SUPER = keccak256("SUPER_PAYMASTER");
```

#### ✅ New Events
```solidity
event RoleRegistered(
    address indexed user,
    bytes32 indexed roleId,
    uint256 sbtTokenId,
    uint256 stakeAmount,
    uint256 burnAmount,
    uint256 timestamp
);

event RoleExited(
    address indexed user,
    bytes32 indexed roleId,
    uint256 lockedAmount,
    uint256 exitFee,
    uint256 refund,
    uint256 timestamp
);

event BurnRecorded(
    address indexed user,
    bytes32 indexed roleId,
    uint256 amount,
    string reason,
    uint256 timestamp
);

event RoleAdded(
    bytes32 indexed roleId,
    string roleName,
    uint256 minStake,
    uint256 entryBurn,
    uint256 timestamp
);

event RoleConfigUpdated(
    bytes32 indexed roleId,
    uint256 newMinStake,
    uint256 newEntryBurn,
    uint256 timestamp
);

event RoleEnabled(bytes32 indexed roleId, bool enabled, uint256 timestamp);

event AuthorizationChanged(
    address indexed account,
    bool authorized,
    uint256 timestamp
);
```

#### ✅ New Errors
```solidity
error RoleNotFound(bytes32 roleId);
error RoleNotEnabled(bytes32 roleId);
error UserAlreadyHasRole(address user, bytes32 roleId);
error InvalidRoleConfig();
error InsufficientStake(uint256 provided, uint256 required);
error UnauthorizedMinter(address caller);
error NoActiveRole(address user);
error InvalidBurnAmount();
```

#### ✅ New Core Functions

**Main Entry Points**:
```solidity
// SINGLE ENTRY POINT FOR ALL ROLES
function registerRole(
    bytes32 roleId,
    address user,
    bytes calldata roleData
) external nonReentrant returns (uint256 sbtTokenId)

// User-friendly wrapper
function registerRoleSelf(
    bytes32 roleId,
    bytes calldata roleData
) external nonReentrant returns (uint256 sbtTokenId)

// Exit a role
function exitRole(
    bytes32 roleId
) external nonReentrant returns (uint256 refund)

// Exit as another user (for batch processing)
function exitRoleFor(
    address user,
    bytes32 roleId
) external nonReentrant returns (uint256 refund)
```

**DAO Functions**:
```solidity
function addRole(RoleConfig calldata config) external onlyDAO
function updateRoleConfig(bytes32 roleId, RoleConfig calldata config) external onlyDAO
function enableRole(bytes32 roleId, bool enabled) external onlyDAO
function setAuthorization(address account, bool authorized) external onlyOwner
```

**Helper Functions**:
```solidity
function calculateExitFee(uint256 lockedAmount, RoleConfig memory config) public pure returns (uint256)
function hasRole(address user, bytes32 roleId) external view returns (bool)
function getUserRoles(address user) external view returns (bytes32[] memory)
function getRoleConfig(bytes32 roleId) external view returns (RoleConfig memory)
function getTotalBurned(address user) external view returns (uint256)
function getBurnHistory(address user, uint256 offset, uint256 limit) external view returns (BurnRecord[] memory)
function getRoleHistory(address user, uint256 offset, uint256 limit) external view returns (RoleRegistration[] memory)
```

**Internal Functions**:
```solidity
function _recordBurn(address user, bytes32 roleId, uint256 amount, string memory reason) internal
function _recordRoleRegistration(address user, bytes32 roleId, uint256 sbtTokenId, uint256 amount) internal
function _recordRoleExit(address user, bytes32 roleId, uint256 exitFee) internal
function _clearUserRole(address user, bytes32 roleId) internal
function _getRoleDescription(bytes32 roleId) internal view returns (string memory)
function _initializeDefaultRoles() internal
```

---

## 🎯 Phase 2: MySBT Changes (Pending)

### Removed Functions
```solidity
// REMOVED - All community-based minting
function mintOrAddMembership(address u, string memory meta) external returns (uint256 tid, bool isNew)
function userMint(address comm, string memory meta) public returns (uint256 tid, bool isNew)
function mintWithAutoStake(address comm, string memory meta) external returns (uint256 tid, bool isNew)

// REMOVED - Community membership management
function addMembership(uint256 tid, address comm, string memory meta) external
function removeMembership(uint256 tid, address comm) external
function _m mapping (replaced with roleMetadata)
function membershipIndex mapping (no longer needed)
```

### Added Functions
```solidity
// Only Registry can call
function mintForRole(
    address user,
    bytes32 roleId,
    bytes calldata roleMetadata
) external onlyAuthorized returns (uint256 tokenId)

function burnForRole(
    address user,
    bytes32 roleId
) external onlyAuthorized

// Authorization
function setAuthorization(address account, bool authorized) external onlyDAO
```

### Storage Changes
```solidity
// REMOVED
mapping(uint256 => CommunityMembership[]) private _m;
mapping(uint256 => mapping(address => uint256)) public membershipIndex;

// ADDED
mapping(address => bool) public authorizedMinters;
mapping(uint256 => bytes32[] roles) public sbtRoles;
mapping(uint256 => mapping(bytes32 => bytes)) public roleMetadata;
mapping(uint256 => mapping(bytes32 => uint256)) public roleCreatedAt;
```

---

## 🎯 Phase 3: GTokenStaking Changes (Pending)

### Function Signature Changes
```solidity
// OLD
function lockStake(
    address user,
    uint256 amount,
    string memory purpose
) external

// NEW
function lockStake(
    address user,
    uint256 amount,
    string memory purpose,
    uint256 entryBurn
) external onlyAuthorized

// OLD
function unlockStake(
    address user,
    uint256 grossAmount
) external returns (uint256 netAmount)

// NEW
function unlockStake(
    address user,
    uint256 grossAmount,
    uint256 exitFee
) external onlyAuthorized returns (uint256 netAmount)
```

### New Authorization
```solidity
mapping(address => bool) public authorizedLockers;

function setAuthorization(address locker, bool authorized) external onlyOwner
```

---

## 📊 Frontend Migration Guide

### API Changes Summary

| Old Function | New Function | Parameters Changed | Return Changed |
|---|---|---|---|
| `registerCommunity()` | `registerRole()` | ✅ YES | ✅ Returns sbtTokenId |
| `registerCommunityWithAutoStake()` | `registerRole()` | ✅ YES | ✅ Returns sbtTokenId |
| `mintOrAddMembership()` | REMOVED | — | — |
| `userMint()` | REMOVED | — | — |
| `mintWithAutoStake()` | REMOVED | — | — |
| `lockStake()` | `lockStake()` | ✅ New param: entryBurn | ❌ Same |
| `unlockStake()` | `unlockStake()` | ✅ New param: exitFee | ❌ Same |

### ABI Changes

**Registry ABI Changes**:
```javascript
// OLD
{
  name: "registerCommunity",
  inputs: [
    { name: "profile", type: "tuple", components: [...] },
    { name: "stGTokenAmount", type: "uint256" }
  ],
  outputs: []
}

// NEW
{
  name: "registerRole",
  inputs: [
    { name: "roleId", type: "bytes32" },
    { name: "user", type: "address" },
    { name: "roleData", type: "bytes" }
  ],
  outputs: [
    { name: "sbtTokenId", type: "uint256" }
  ]
}
```

**MySBT ABI Changes**:
```javascript
// OLD
{
  name: "mintOrAddMembership",
  inputs: [
    { name: "u", type: "address" },
    { name: "meta", type: "string" }
  ],
  outputs: [
    { name: "tid", type: "uint256" },
    { name: "isNew", type: "bool" }
  ]
}

// NEW
{
  name: "mintForRole",
  inputs: [
    { name: "user", type: "address" },
    { name: "roleId", type: "bytes32" },
    { name: "roleMetadata", type: "bytes" }
  ],
  outputs: [
    { name: "tokenId", type: "uint256" }
  ]
}
```

**GTokenStaking ABI Changes**:
```javascript
// OLD lockStake
{
  name: "lockStake",
  inputs: [
    { name: "user", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "purpose", type: "string" }
  ]
}

// NEW lockStake
{
  name: "lockStake",
  inputs: [
    { name: "user", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "purpose", type: "string" },
    { name: "entryBurn", type: "uint256" }  // NEW
  ]
}

// OLD unlockStake
{
  name: "unlockStake",
  inputs: [
    { name: "user", type: "address" },
    { name: "grossAmount", type: "uint256" }
  ]
}

// NEW unlockStake
{
  name: "unlockStake",
  inputs: [
    { name: "user", type: "address" },
    { name: "grossAmount", type: "uint256" },
    { name: "exitFee", type: "uint256" }  // NEW
  ]
}
```

### Migration Scripts Changes

**OLD Pattern**:
```javascript
// Step 1: Register community
await registry.registerCommunity(
  {
    name: "MyDAO",
    ensName: "",
    xPNTsToken: xPNTsAddr,
    supportedSBTs: [mysbtAddr],
    nodeType: 2,  // ANODE
    paymasterAddress: paymaster,
    community: commAddr,
    registeredAt: 0,
    lastUpdatedAt: 0,
    isActive: true,
    allowPermissionlessMint: true
  },
  ethers.utils.parseEther("30")
);

// Step 2: Register SBT separately
await mysbt.mintOrAddMembership(userAddr, "metadata");
```

**NEW Pattern**:
```javascript
// Single call handles everything
const roleId = ethers.utils.id("COMMUNITY");
const roleData = ethers.utils.defaultAbiCoder.encode(
  ["string", "address", "bool"],
  ["MyDAO", paymasterAddr, true]
);

const tx = await registry.registerRole(roleId, userAddr, roleData);
const receipt = await tx.wait();
// SBT automatically minted, stake locked, burn executed
```

---

## 📋 Deployment Checklist

### Pre-Deployment
- [ ] Registry refactored and tested
- [ ] MySBT refactored and tested
- [ ] GTokenStaking updated and tested
- [ ] 70+ tests passing
- [ ] Gas optimization verified
- [ ] Security audit passed
- [ ] New ABIs generated

### Deployment
- [ ] Deploy GTokenStaking (no storage migration needed)
- [ ] Deploy MySBT (no storage migration needed)
- [ ] Deploy new Registry
- [ ] Set authorizations on MySBT
- [ ] Set authorizations on GTokenStaking
- [ ] Initialize default roles in Registry
- [ ] Verify on-chain

### Post-Deployment
- [ ] All scripts migrated and tested
- [ ] Frontend updated with new ABIs
- [ ] Frontend tested with testnet
- [ ] User documentation updated
- [ ] Monitoring setup
- [ ] Gradual rollout (if applicable)

---

## 🔍 Frontend Audit Checklist

Before deploying, audit ALL frontend code for:

- [ ] `registerCommunity()` calls → change to `registerRole()`
- [ ] `mintOrAddMembership()` calls → change to Registry flow
- [ ] `lockStake()` calls → add entryBurn parameter
- [ ] `unlockStake()` calls → add exitFee parameter
- [ ] NodeType enum usage → change to bytes32 roleId
- [ ] CommunityProfile struct → change to RoleConfig
- [ ] Community-specific queries → change to role-based
- [ ] ABI imports → regenerate and update
- [ ] Event handling → update to new events
- [ ] Error handling → update to new error types

---

## ✅ Status Tracking

### Registry Refactor
- [ ] Remove old structs/enums
- [ ] Remove old storage variables
- [ ] Remove old functions
- [ ] Add new structs
- [ ] Add new storage variables
- [ ] Add registerRole() function
- [ ] Add exitRole() function
- [ ] Add DAO functions
- [ ] Add view functions
- [ ] Add internal helpers
- [ ] Write tests (50+ cases)
- [ ] Gas optimization review

### MySBT Refactor
- [ ] Add authorization mechanism
- [ ] Add mintForRole() function
- [ ] Add burnForRole() function
- [ ] Remove old minting functions
- [ ] Update storage structure
- [ ] Write tests (20+ cases)

### GTokenStaking Update
- [ ] Update lockStake() signature
- [ ] Update unlockStake() signature
- [ ] Add authorization checks
- [ ] Write tests (10+ cases)

### Documentation
- [ ] This changelog (IN PROGRESS)
- [ ] Migration guide for frontend
- [ ] New contract interfaces
- [ ] Test results summary

---

**Last Updated**: 2025-11-27
**Next Phase**: MySBT and GTokenStaking refactor

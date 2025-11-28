# Code Changes Required: Mycelium Mechanism Implementation
## 代码改动清单

**Date**: 2025-11-27
**Focus**: Exact code modifications needed in existing contracts

---

## 🎯 Executive: 3 Contracts, 4 Critical Issues

| Contract | Issue | Fix Complexity | Lines of Code |
|----------|-------|----------------|---------------|
| GTokenStaking | Missing entry burn | Low | +100 |
| GTokenStaking | No burn tracking | Low | +50 |
| Registry | Enum-based roles | Medium | +300 |
| Registry | No entry burn execution | Medium | +100 |
| MySBT | Not connected to staking | Medium | +80 |
| MySBT | No burn-based reputation | Low | +30 |
| **Total** | **6 issues** | **Manageable** | **~660 lines** |

---

## 1️⃣ GTokenStaking.sol Modifications

### Change 1.1: Add burn-related storage (after line 100)
```solidity
// Current line 100:
// uint256 public constant VERSION_CODE = 20000;

// ADD AFTER line 100:
/// @notice Track total burned per user
mapping(address => uint256) public totalBurned;

/// @notice Burn history for audit trail
mapping(address => BurnRecord[]) public burnHistory;

/// @notice Burn record structure
struct BurnRecord {
    uint256 amount;
    uint256 timestamp;
    string reason;  // "entry", "exit", "usage"
}

/// @notice MySBT contract for burn recording (optional)
address public mySBTForBurnRecording;

/// @notice Standard burn address
address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
```

### Change 1.2: Add internal burn recording method (after line 210)
```solidity
// ADD NEW FUNCTION (after constructor):

/**
 * @notice Record burn event internally
 * @param user User who burned tokens
 * @param amount Amount burned
 * @param reason Burn reason ("entry", "exit", or "usage")
 * @dev Internal helper for tracking burns across all operations
 */
function recordBurn(
    address user,
    uint256 amount,
    string memory reason
) internal {
    totalBurned[user] += amount;
    burnHistory[user].push(BurnRecord({
        amount: amount,
        timestamp: block.timestamp,
        reason: reason
    }));
}
```

### Change 1.3: Modify lockStake() to handle entry burn (MAJOR CHANGE)
```solidity
// BEFORE (line 345-369):
function lockStake(
    address user,
    uint256 amount,
    string memory purpose
) external {
    LockerConfig memory config = lockerConfigs[msg.sender];
    if (!config.authorized) {
        revert UnauthorizedLocker(msg.sender);
    }

    uint256 available = availableBalance(user);
    if (available < amount) {
        revert InsufficientAvailableBalance(available, amount);
    }

    locks[user][msg.sender].amount += amount;
    locks[user][msg.sender].lockedAt = block.timestamp;
    locks[user][msg.sender].purpose = purpose;
    locks[user][msg.sender].beneficiary = msg.sender;

    totalLocked[user] += amount;

    emit StakeLocked(user, msg.sender, amount, purpose);
}

// AFTER (NEW SIGNATURE WITH ENTRY BURN):
/**
 * @notice Lock user's stGToken with optional entry burn
 * @param user User whose stake to lock
 * @param amount Gross amount to lock (before burn)
 * @param purpose Lock purpose description
 * @param entryBurn Amount to burn before locking (NEW)
 * @dev Called by authorized lockers (Registry, MySBT, etc.)
 *      Entry burn happens BEFORE locking:
 *      - Burn amount: transferred to BURN_ADDRESS
 *      - Lock amount: amount - entryBurn (locked in GTokenStaking)
 */
function lockStake(
    address user,
    uint256 amount,
    string memory purpose,
    uint256 entryBurn  // NEW PARAMETER
) external {
    LockerConfig memory config = lockerConfigs[msg.sender];
    if (!config.authorized) {
        revert UnauthorizedLocker(msg.sender);
    }

    // NEW: Validate entry burn
    if (entryBurn > amount) {
        revert InvalidParameter("Burn exceeds stake amount");
    }

    // Calculate lock amount after burn
    uint256 lockAmount = amount - entryBurn;

    uint256 available = availableBalance(user);
    if (available < amount) {  // Check available includes the burn amount
        revert InsufficientAvailableBalance(available, amount);
    }

    // NEW: Execute entry burn
    if (entryBurn > 0) {
        // Transfer from user to BURN_ADDRESS
        IERC20(GTOKEN).transfer(BURN_ADDRESS, entryBurn);

        // Record burn
        recordBurn(user, entryBurn, "entry");

        // NEW: Emit burn event
        emit EntryBurned(user, msg.sender, entryBurn);
    }

    // Lock remaining amount
    locks[user][msg.sender].amount += lockAmount;
    locks[user][msg.sender].lockedAt = block.timestamp;
    locks[user][msg.sender].purpose = purpose;
    locks[user][msg.sender].beneficiary = msg.sender;

    totalLocked[user] += lockAmount;

    emit StakeLocked(user, msg.sender, lockAmount, purpose);
}

// NEW EVENT (add with other events around line 143):
event EntryBurned(
    address indexed user,
    address indexed locker,
    uint256 amount
);
```

### Change 1.4: Modify unlockStake() to record exit fees (line 379-431)
```solidity
// In unlockStake(), after the transfer section:

// EXISTING CODE (up to line 425):
emit StakeUnlocked(user, msg.sender, grossAmount, exitFee, netAmount);

// CEI: Transfer exit fee to treasury (external call last)
if (exitFee > 0) {
    IERC20(GTOKEN).safeTransfer(feeRecipient, feeInGT);
}

// ADD AFTER LINE 430:
        // NEW: Record exit fee as burn
        if (exitFee > 0) {
            recordBurn(user, exitFee, "exit");
        }

    return netAmount;
}
```

### Change 1.5: Add view functions for burn queries (after line 826)
```solidity
// ADD AFTER getGlobalStats() function:

/**
 * @notice Get total burned by user
 * @param user User address
 * @return Total amount burned
 */
function getTotalBurned(address user) external view returns (uint256) {
    return totalBurned[user];
}

/**
 * @notice Get burn history for user
 * @param user User address
 * @param offset Start index
 * @param limit Number of records
 * @return Array of burn records
 */
function getBurnHistory(
    address user,
    uint256 offset,
    uint256 limit
) external view returns (BurnRecord[] memory) {
    BurnRecord[] memory history = burnHistory[user];
    uint256 length = history.length;

    if (offset >= length) {
        return new BurnRecord[](0);
    }

    uint256 end = offset + limit > length ? length : offset + limit;
    BurnRecord[] memory result = new BurnRecord[](end - offset);

    for (uint256 i = 0; i < end - offset; i++) {
        result[i] = history[offset + i];
    }

    return result;
}

/**
 * @notice Preview burn for a registration (helper)
 * @param user User address
 * @param locker Locker address
 * @param grossAmount Gross amount
 * @param entryBurn Entry burn amount
 * @return exitFee Expected exit fee
 */
function previewBurn(
    address user,
    address locker,
    uint256 grossAmount,
    uint256 entryBurn
) external view returns (uint256 exitFee) {
    uint256 lockAmount = grossAmount - entryBurn;
    exitFee = calculateExitFee(locker, user, lockAmount);
}
```

---

## 2️⃣ Registry.sol Modifications

### Change 2.1: Add RoleConfig struct and storage (after line 60)
```solidity
// AFTER line 60 (Constants section):

// ====================================
// NEW: Role Fee Configuration
// ====================================

/// @notice Configuration for each role (replaces enum)
struct RoleConfig {
    uint256 minStake;           // Minimum stake required
    uint256 entryBurn;          // Amount to burn on entry
    uint256 exitFeePercent;     // Exit fee as percentage (e.g., 10 = 10%)
    uint256 minExitFee;         // Minimum exit fee amount
    bool enabled;               // Is role enabled
}

// ====================================
// END: Role Fee Configuration
// ====================================
```

### Change 2.2: Replace NodeTypeConfig in storage (line 73-87)
```solidity
// BEFORE (line 73-87):
mapping(NodeType => NodeTypeConfig) public nodeTypeConfigs;
mapping(address => CommunityProfile) public communities;
mapping(address => CommunityStake) public communityStakes;
mapping(string => address) public communityByName;
mapping(string => address) public communityByENS;
mapping(address => address) public communityBySBT;
address[] public communityList;
mapping(address => bool) public isRegistered;

// AFTER (ADD THESE):
// Keep existing mappings, ADD:
mapping(address => RoleConfig) public roleConfigs;  // role address → config
mapping(address => address) public userRoles;  // user → role address
mapping(address => uint256) public userTotalBurned;  // user → total burned

// Also ADD these constants (after VERSION_CODE, line 67):
address public constant ROLE_ENDUSER = address(1);  // Placeholder
address public constant ROLE_COMMUNITY = address(2);
address public constant ROLE_PAYMASTER = address(3);
address public constant ROLE_SUPER = address(4);
```

### Change 2.3: Add initialization in constructor (line 144)
```solidity
// AFTER existing nodeTypeConfigs initialization (line 143), ADD:

        // NEW: Initialize role configs (Mycelium mechanism)
        _initializeRoleConfigs();
    }

    // NEW HELPER FUNCTION:
    function _initializeRoleConfigs() internal {
        // END_USER role (via MySBT)
        roleConfigs[address(0x1)] = RoleConfig({
            minStake: 0.3 ether,
            entryBurn: 0.1 ether,
            exitFeePercent: 17,  // 17% for users
            minExitFee: 0.05 ether,
            enabled: true
        });

        // COMMUNITY role
        roleConfigs[address(0x2)] = RoleConfig({
            minStake: 30 ether,
            entryBurn: 3 ether,
            exitFeePercent: 10,
            minExitFee: 0.3 ether,
            enabled: true
        });

        // PAYMASTER role
        roleConfigs[address(0x3)] = RoleConfig({
            minStake: 30 ether,
            entryBurn: 3 ether,
            exitFeePercent: 10,
            minExitFee: 0.3 ether,
            enabled: true
        });

        // SUPER_PAYMASTER role
        roleConfigs[address(0x4)] = RoleConfig({
            minStake: 50 ether,
            entryBurn: 5 ether,
            exitFeePercent: 10,
            minExitFee: 0.5 ether,
            enabled: true
        });
    }
```

### Change 2.4: Add new events (after line 106)
```solidity
// ADD AFTER event PaymasterRegisteredWithAutoStake (line 106):

event UserRoleRegistered(
    address indexed user,
    address indexed role,
    uint256 stakeAmount,
    uint256 entryBurn
);

event UserRoleExited(
    address indexed user,
    address indexed role,
    uint256 lockedAmount,
    uint256 exitFee,
    uint256 refund
);

event RoleAdded(
    address indexed roleAddress,
    uint256 minStake,
    uint256 entryBurn
);

event RoleUpdated(
    address indexed roleAddress,
    uint256 newMinStake,
    uint256 newEntryBurn
);
```

### Change 2.5: Add registerRole() method (new core function)
```solidity
// ADD AFTER registerCommunityWithAutoStake() (around line 586):

/**
 * @notice Register user/community for a role with entry burn
 * @param roleAddress The role contract address
 * @param user User address to register
 * @dev Handles:
 *   1. Verify GToken transfer from user
 *   2. Execute entry burn via GTokenStaking
 *   3. Lock remaining stake in GTokenStaking
 *   4. Record user role
 */
function registerRole(address roleAddress, address user)
    external
    nonReentrant
{
    RoleConfig memory config = roleConfigs[roleAddress];
    require(config.enabled, "Role not enabled");
    require(config.minStake > 0, "Invalid role config");

    // CEI Pattern:
    // 1. CHECKS
    if (userRoles[user] != address(0)) {
        revert InvalidParameter("User already has a role");
    }

    // 2. EFFECTS
    // Mark user as having this role
    userRoles[user] = roleAddress;

    // 3. INTERACTIONS
    // Transfer stake amount from user to Registry first
    IERC20(GTOKEN).safeTransferFrom(user, address(this), config.minStake);

    // Approve GTokenStaking
    IERC20(GTOKEN).approve(address(GTOKEN_STAKING), config.minStake);

    // Lock in GTokenStaking (which handles entry burn internally)
    GTOKEN_STAKING.lockStake(
        user,
        config.minStake,
        string(abi.encodePacked(_getRoleName(roleAddress))),
        config.entryBurn  // Entry burn parameter
    );

    emit UserRoleRegistered(user, roleAddress, config.minStake, config.entryBurn);
}

/**
 * @notice Exit a role and unlock stake
 * @param user User to exit
 * @dev Handles:
 *   1. Get locked amount
 *   2. Unlock from GTokenStaking (exits fee deducted)
 *   3. Clear user role
 */
function exitRole(address user)
    external
    nonReentrant
{
    // CHECKS
    address roleAddress = userRoles[user];
    require(roleAddress != address(0), "User has no role");

    RoleConfig memory config = roleConfigs[roleAddress];
    uint256 lockedAmount = GTOKEN_STAKING.lockedBalanceBy(user, address(this));
    require(lockedAmount > 0, "No locked stake");

    // EFFECTS
    delete userRoles[user];

    // INTERACTIONS
    uint256 refund = GTOKEN_STAKING.unlockStake(user, lockedAmount);

    // Calculate what fee was deducted (for event)
    uint256 exitFee = lockedAmount - refund;

    emit UserRoleExited(user, roleAddress, lockedAmount, exitFee, refund);
}

/**
 * @notice Helper: Get role name from address
 */
function _getRoleName(address roleAddress)
    internal
    pure
    returns (string memory)
{
    if (roleAddress == address(0x1)) return "ENDUSER";
    if (roleAddress == address(0x2)) return "COMMUNITY";
    if (roleAddress == address(0x3)) return "PAYMASTER";
    if (roleAddress == address(0x4)) return "SUPER_PAYMASTER";
    return "UNKNOWN";
}
```

### Change 2.6: Add DAO governance functions (after exitRole)
```solidity
/**
 * @notice DAO: Add new role with custom economics
 * @param roleAddress Address of the role
 * @param config Role configuration
 */
function addRole(address roleAddress, RoleConfig calldata config)
    external
    onlyOwner
{
    require(roleAddress != address(0), "Invalid role address");
    require(config.minStake > 0, "Invalid stake amount");
    require(config.entryBurn < config.minStake, "Burn exceeds stake");

    roleConfigs[roleAddress] = config;

    emit RoleAdded(roleAddress, config.minStake, config.entryBurn);
}

/**
 * @notice DAO: Update existing role configuration
 * @param roleAddress Role address
 * @param newConfig New configuration
 */
function updateRole(address roleAddress, RoleConfig calldata newConfig)
    external
    onlyOwner
{
    require(roleConfigs[roleAddress].minStake > 0, "Role not found");
    require(newConfig.minStake > 0, "Invalid stake amount");
    require(newConfig.entryBurn < newConfig.minStake, "Burn exceeds stake");

    roleConfigs[roleAddress] = newConfig;

    emit RoleUpdated(roleAddress, newConfig.minStake, newConfig.entryBurn);
}
```

---

## 3️⃣ MySBT.sol Modifications

### Change 3.1: Add burn tracking to SBTData struct
```solidity
// In SBTData struct (around line 200), ADD:
struct SBTData {
    // ... existing fields ...
    uint256 totalBurned;  // NEW: Total burned for reputation
    // ... rest of struct ...
}
```

### Change 3.2: Modify mint() to verify staking (simplified version)
```solidity
// In existing mint() function, ADD before minting:

function mint(address to, address community)
    external
    returns (uint256 tokenId)
{
    require(_isValid(msg.sender), "Unauthorized");

    // NEW: Verify user has stake in GTokenStaking via Registry
    if (msg.sender == REGISTRY || msg.sender == address(this)) {
        uint256 minStake = 0.3 ether;
        uint256 expectedLock = minStake - 0.1 ether;  // 0.2 after burn

        uint256 locked = IGTokenStaking(GTOKEN_STAKING).lockedBalanceBy(
            to,
            REGISTRY
        );
        require(locked == expectedLock, "Invalid stake amount");
    }

    // ... rest of mint() ...

    // ADD after minting SBT, before returning:
    sbtData[tokenId].totalBurned = 0.1 ether;  // Record entry burn

    return tokenId;
}
```

### Change 3.3: Update reputation calculation
```solidity
// In getReputation() function, ADD burn factor:

/**
 * @notice Calculate reputation score including burns
 * @param tokenId SBT token ID
 * @return reputation score
 */
function getReputation(uint256 tokenId)
    external
    view
    returns (uint256)
{
    SBTData memory data = sbtData[tokenId];

    // Base reputation
    uint256 rep = BASE_REP;

    // Activity bonus
    rep += _calculateActivityBonus(tokenId);

    // NEW: Burn contribution (showing commitment)
    uint256 burnScore = data.totalBurned / 1e17;  // 0.1 GT = 1 point
    rep += min(burnScore, 20);  // Cap at 20 points

    // Membership bonus
    rep += min(data.communityJoinCount, 10);

    return rep;
}
```

---

## 🧪 Changes Summary

| File | Changes | Lines | Priority |
|------|---------|-------|----------|
| GTokenStaking | Entry burn + tracking | ~250 | 🔴 CRITICAL |
| Registry | RoleConfig + register/exit | ~350 | 🔴 CRITICAL |
| MySBT | Integration + reputation | ~100 | 🟠 HIGH |
| **Total** | **3 contracts** | **~700** | **Manageable** |

---

## ✅ Testing Required

**Per GTokenStaking changes**:
- [ ] lockStake() with entryBurn parameter
- [ ] recordBurn() internal method
- [ ] unlockStake() records exit fee as burn
- [ ] getBurnHistory() returns correct data

**Per Registry changes**:
- [ ] registerRole() for all 4 role types
- [ ] exitRole() with refund verification
- [ ] addRole() / updateRole() DAO functions
- [ ] Burn amounts match expectations

**Integration**:
- [ ] Full flow: register → use → exit
- [ ] MySBT mint with verified stake
- [ ] Reputation includes burn factor
- [ ] Sybil cost is prohibitive (150 GT for 1000 attempts)

---

## 🎯 Implementation Order

1. **GTokenStaking** (1-2 days) - Core mechanism
2. **Registry** (1-2 days) - Role integration
3. **MySBT** (0.5-1 day) - UI layer
4. **Tests** (2-3 days) - Full coverage
5. **Review** (1 day) - Security audit
6. **Deploy** (0.5 day) - Testnet

---

**Total estimated implementation time**: 6-9 days

**Ready to start?** Follow the code changes above in order.

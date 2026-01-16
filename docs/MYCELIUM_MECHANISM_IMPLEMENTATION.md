# Mycelium Protocol Mechanism: Implementation Details
## 菌丝体协议机制：实现细节

**Date**: 2025-11-27
**Status**: Detailed code review + refinement plan
**Focus**: Integration with existing GTokenStaking, Registry, MySBT contracts

---

## 📋 Executive Summary

You have the core infrastructure already:
- ✅ **GTokenStaking**: Lock/unlock mechanism with configurable exit fees
- ✅ **Registry**: Community/Paymaster registration with staking
- ✅ **MySBT**: User activity tracking and reputation

**What's missing**: Complete Mycelium mechanism that ties them together with proper:
1. Entry burn fees (at registration)
2. Exit fee handling (to protocol account)
3. Burn record tracking (for reputation)
4. Role-based staking configuration (in Registry)
5. DAO governance for parameter updates

---

## 🔍 Current State Analysis

### GTokenStaking (READY)
✅ **Status**: Well-designed, production-ready

**What works**:
- `lockStake()`: Lock with configurable fees
- `unlockStake()`: Unlock with exit fee deduction
- `calculateExitFee()`: Flexible fee calculation (percentage + min/max)
- `configureLocker()`: Per-locker fee configuration
- User-level slash tracking (no global impact)

**What's missing**:
- ❌ Entry burn mechanism (should happen at `lockStake()`, not after)
- ❌ Burn record storage in contract
- ❌ Per-role configuration (currently per-locker only)

### Registry (NEEDS REFINEMENT)
⚠️ **Status**: Partially integrated, needs role-based mechanism

**Current structure**:
- `NodeType` enum: 4 types (PAYMASTER_AOA, PAYMASTER_SUPER, ANODE, KMS)
- `NodeTypeConfig`: Has minStake but no entry burn/exit fee fields
- `registerCommunity()`: Manual staking flow, no auto-burn

**Missing pieces**:
- ❌ Entry burn configuration per role
- ❌ Auto-burn execution during registration
- ❌ Dynamic role addition (still enum-based)
- ❌ Connection to burn tracking

### MySBT (NEEDS INTEGRATION)
⚠️ **Status**: Has staking, needs burn tracking

**Current status**:
- Has `minLockAmount` (0.3 ether) and `mintFee` (0.1 ether)
- Can mint SBT and track activities
- SuperPaymaster callback exists

**Missing**:
- ❌ Burn fee deduction on mint (currently 0.1 is just a fee, not a burn)
- ❌ Burn record tracking (for reputation calculation)
- ❌ Connection to GTokenStaking for lock/unlock
- ❌ Exit fee mechanism for SBT burning

---

## 🎯 Implementation Plan

### Phase 1: Enhance GTokenStaking (Critical)

#### 1.1 Add Entry Burn to lockStake()
```solidity
// BEFORE (current):
function lockStake(address user, uint256 amount, string memory purpose) external {
    // Just locks, no burn
}

// AFTER (proposed):
function lockStake(
    address user,
    uint256 amount,
    string memory purpose,
    uint256 entryBurn  // NEW: entry burn amount
) external {
    // 1. Validate entry burn
    require(entryBurn <= amount, "Burn exceeds stake amount");

    // 2. BURN the entry fee (NEW)
    if (entryBurn > 0) {
        IERC20(GTOKEN).transfer(BURN_ADDRESS, entryBurn);
        // Record burn in MySBT if available
        if (IMySBT(mySBTAddress).canRecordBurn()) {
            IMySBT(mySBTAddress).recordBurn(user, entryBurn);
        }
    }

    // 3. Lock the remaining amount
    uint256 lockAmount = amount - entryBurn;
    locks[user][msg.sender].amount += lockAmount;
    totalLocked[user] += lockAmount;

    emit StakeLocked(user, msg.sender, lockAmount, purpose);
    emit EntryBurned(user, entryBurn);  // NEW event
}
```

#### 1.2 Add Burn Record Storage
```solidity
// In GTokenStaking contract storage:
mapping(address => uint256) public totalBurned;  // Track total burns per user
mapping(address => BurnRecord[]) public burnHistory;  // Detailed history

struct BurnRecord {
    uint256 amount;
    uint256 timestamp;
    string reason;  // "entry", "exit", "usage"
}

// Add method to record burns:
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

#### 1.3 Modify unlockStake() to record burns
```solidity
// In unlockStake(), after exit fee transfer:
function unlockStake(address user, uint256 grossAmount)
    external
    returns (uint256 netAmount)
{
    // ... existing code ...

    uint256 exitFee = calculateExitFee(msg.sender, user, grossAmount);
    netAmount = grossAmount - exitFee;

    // ... existing transfers ...

    // NEW: Record exit fee as burn
    if (exitFee > 0) {
        recordBurn(user, exitFee, "exit");
    }

    return netAmount;
}
```

---

### Phase 2: Extend Registry (Critical)

#### 2.1 Add Role-Based Fee Configuration to Registry
```solidity
// In Registry contract:

// NEW: Role fee configuration (replace NodeTypeConfig enum usage)
struct RoleConfig {
    uint256 minStake;           // Minimum stake required
    uint256 entryBurn;          // Amount to burn on entry
    uint256 exitFeePercent;     // Exit fee as percentage (e.g., 10 = 10%)
    uint256 minExitFee;         // Minimum exit fee
    bool enabled;               // Is role enabled
}

// NEW: Store role configs dynamically (not enum)
mapping(address => RoleConfig) public roleConfigs;  // user => role => config
mapping(uint256 => RoleConfig) public roleConfigsById;  // roleId => config
uint256 public nextRoleId = 0;

// Initialize in constructor (backwards compatible):
function _initializeRoles() internal {
    // PAYMASTER_AOA
    roleConfigs[address(PaymasterAOA)] = RoleConfig({
        minStake: 30 ether,
        entryBurn: 3 ether,
        exitFeePercent: 10,  // 10%
        minExitFee: 0.1 ether,
        enabled: true
    });

    // COMMUNITY (ANODE)
    roleConfigs[address(Community)] = RoleConfig({
        minStake: 30 ether,
        entryBurn: 3 ether,
        exitFeePercent: 10,
        minExitFee: 0.1 ether,
        enabled: true
    });

    // END_USER (special role via MySBT)
    roleConfigs[address(MySBT)] = RoleConfig({
        minStake: 0.3 ether,
        entryBurn: 0.1 ether,
        exitFeePercent: 17,  // 17% for user role
        minExitFee: 0.01 ether,
        enabled: true
    });
}
```

#### 2.2 Add registerRole() method to Registry
```solidity
/**
 * @notice Register user/community for a role with automatic staking and burning
 * @param role The role to register for (address of the role's contract)
 * @param user User address (msg.sender if self-registering)
 */
function registerRole(address role, address user)
    external
    nonReentrant
{
    RoleConfig memory config = roleConfigs[role];
    require(config.enabled, "Role not enabled");
    require(config.minStake > 0, "Invalid role config");

    // 1. Transfer stake amount from user
    IERC20(GTOKEN).safeTransferFrom(user, address(this), config.minStake);

    // 2. Execute entry burn
    IERC20(GTOKEN).transfer(BURN_ADDRESS, config.entryBurn);
    recordBurn(user, config.entryBurn, "entry");

    // 3. Lock remaining stake in GTokenStaking
    uint256 lockAmount = config.minStake - config.entryBurn;
    IERC20(GTOKEN).approve(address(GTOKEN_STAKING), lockAmount);
    GTOKEN_STAKING.lockStake(user, lockAmount, _getRoleName(role));

    // 4. Record user role (for tracking)
    userRoles[user] = role;

    // 5. Update registration (for communities)
    if (isCommunityCourseAddress(role)) {
        communities[user].registeredAt = block.timestamp;
    }

    emit UserRoleRegistered(user, role, config.minStake, config.entryBurn);
}
```

#### 2.3 Add exitRole() method to Registry
```solidity
/**
 * @notice Exit a role and unlock stake with exit fee
 * @param user User address to exit
 */
function exitRole(address user)
    external
    nonReentrant
{
    address role = userRoles[user];
    require(role != address(0), "User has no role");

    RoleConfig memory config = roleConfigs[role];
    uint256 lockedAmount = GTOKEN_STAKING.lockedBalanceBy(user, address(this));

    // Calculate exit fee (percentage-based)
    uint256 exitFee = calculateExitFee(lockedAmount, config.exitFeePercent, config.minExitFee);

    // Unlock from GTokenStaking (exit fee deducted automatically)
    uint256 refund = GTOKEN_STAKING.unlockStake(user, lockedAmount);

    // Exit fee is already sent to treasury by GTokenStaking
    // Just record the burn
    recordBurn(user, exitFee, "exit");

    // Clear user role
    delete userRoles[user];

    emit UserRoleExited(user, role, lockedAmount, exitFee, refund);
}
```

#### 2.4 Add DAO governance for new roles
```solidity
/**
 * @notice DAO: Add a new role with custom economics
 * @param roleAddress Address of the role contract
 * @param config Role configuration
 */
function addRole(address roleAddress, RoleConfig calldata config)
    external
    onlyDAO
{
    require(roleAddress != address(0), "Invalid role address");
    require(config.minStake > 0, "Invalid stake amount");
    require(config.entryBurn < config.minStake, "Burn exceeds stake");

    roleConfigs[roleAddress] = config;
    nextRoleId++;

    emit RoleAdded(roleAddress, config.minStake, config.entryBurn);
}

/**
 * @notice DAO: Update existing role configuration
 */
function updateRole(address roleAddress, RoleConfig calldata newConfig)
    external
    onlyDAO
{
    require(roleConfigs[roleAddress].minStake > 0, "Role not found");
    roleConfigs[roleAddress] = newConfig;

    emit RoleUpdated(roleAddress, newConfig.minStake, newConfig.entryBurn);
}
```

#### 2.5 Add burn tracking to Registry
```solidity
// In Registry storage:
mapping(address => uint256) public totalUserBurns;  // User → total burned
mapping(address => BurnRecord[]) public userBurnHistory;

struct BurnRecord {
    uint256 amount;
    uint256 timestamp;
    string reason;
}

function recordBurn(address user, uint256 amount, string memory reason) internal {
    totalUserBurns[user] += amount;
    userBurnHistory[user].push(BurnRecord({
        amount: amount,
        timestamp: block.timestamp,
        reason: reason
    }));
}

// View function:
function getBurnTotal(address user) external view returns (uint256) {
    return totalUserBurns[user];
}
```

---

### Phase 3: Integrate MySBT (Important)

#### 3.1 Connect MySBT mint to Registry
```solidity
// In MySBT contract:

/**
 * @notice Mint MySBT for end user (via Registry)
 * @param to User address
 * @param community Community address (optional)
 */
function mint(address to, address community)
    external
    returns (uint256 tokenId)
{
    require(_isValid(msg.sender), "Unauthorized");  // Only Registry or authorized

    // 1. Record user role registration
    if (msg.sender == REGISTRY) {
        // This is an end-user registration
        uint256 minStake = 0.3 ether;
        uint256 entryBurn = 0.1 ether;

        // Verify user has staked
        uint256 locked = IGTokenStaking(GTOKEN_STAKING).lockedBalanceBy(to, REGISTRY);
        require(locked == minStake - entryBurn, "Invalid stake amount");
    }

    // 2. Mint SBT
    tokenId = nextTokenId++;
    _mint(to, tokenId);
    userToSBT[to] = tokenId;

    // 3. Initialize SBT data
    sbtData[tokenId] = SBTData({
        holder: to,
        mintedAt: block.timestamp,
        reputation: BASE_REP,
        communityJoinCount: 0
    });

    // 4. Register to SuperPaymaster
    _registerSBTHolder(to, tokenId);

    // 5. Record initial burn
    recordBurnActivity(to, entryBurn, "mint_entry");

    return tokenId;
}

/**
 * @notice Burn SBT and execute exit (charge exit fee)
 * @param to User address
 */
function burn(address to)
    external
    returns (uint256 refund)
{
    uint256 tokenId = userToSBT[to];
    require(tokenId > 0, "No SBT found");

    // 1. Calculate exit fee from locked stake
    uint256 lockedAmount = IGTokenStaking(GTOKEN_STAKING).lockedBalanceBy(to, REGISTRY);
    uint256 exitFee = calculateExitFee(lockedAmount, 17, 0.01 ether);  // 17% for user role

    // 2. Unlock from GTokenStaking
    refund = IGTokenStaking(GTOKEN_STAKING).unlockStake(to, lockedAmount);

    // 3. Record exit fee as burn
    recordBurnActivity(to, exitFee, "exit");

    // 4. Burn SBT
    _burn(tokenId);
    _removeSBTHolder(to, tokenId);  // Remove from SuperPaymaster
    delete userToSBT[to];

    return refund;
}

/**
 * @notice Record burn activity for reputation calculation
 */
function recordBurnActivity(address user, uint256 amount, string memory reason) internal {
    uint256 tokenId = userToSBT[user];
    if (tokenId == 0) return;

    // Accumulate burn amount for reputation
    sbtData[tokenId].totalBurned += amount;

    // Update reputation if using burn-based scoring
    updateReputationForBurn(tokenId, amount);
}
```

#### 3.2 Update MySBT reputation calculator
```solidity
/**
 * @notice Calculate reputation including burn score
 * @param tokenId SBT token ID
 */
function getReputation(uint256 tokenId) external view returns (uint256) {
    SBTData memory data = sbtData[tokenId];

    // Base reputation
    uint256 rep = BASE_REP;

    // Activity bonus
    rep += _calculateActivityBonus(tokenId);

    // NEW: Burn contribution (user burning for entry/exit shows commitment)
    uint256 burnScore = data.totalBurned / 1e17;  // 0.1 GT = 1 point
    rep += min(burnScore, 20);  // Cap burn bonus at 20 points

    // Membership bonus
    rep += min(data.communityJoinCount, 10);  // Cap at 10 communities

    return rep;
}
```

---

## 🔗 Data Flow Diagrams

### Flow 1: End User Registration (0.3 GT)
```
User Action:
1. User approves MySBT: approve(0.3 GT)
2. User calls: Registry.registerRole(MySBT_ADDRESS, userAddress)

Registry.registerRole():
3. Transfer: 0.3 GT from user → Registry
4. Burn: 0.1 GT → address(0)
   - recordBurn(user, 0.1, "entry")
5. Lock: 0.2 GT in GTokenStaking
   - GTOKEN_STAKING.lockStake(user, 0.2, "MySBT_membership")
6. Record: userRoles[user] = MySBT_ADDRESS

MySBT.mint():
7. Mint MySBT to user
8. Record burn activity: sbtData[tokenId].totalBurned += 0.1
9. Update reputation based on burn

Result:
├─ User has MySBT (SBT)
├─ 0.2 GT locked in GTokenStaking
├─ 0.1 GT burned (recorded for reputation)
└─ Full access to protocol services
```

### Flow 2: Community Registration (30 GT)
```
Community Action:
1. Community approves Registry: approve(30 GT)
2. Community calls: Registry.registerCommunity() [existing flow]
   OR: Registry.registerRole(COMMUNITY_ROLE, communityAddress)

Registry.registerRole():
3. Transfer: 30 GT from community → Registry
4. Burn: 3 GT → address(0)
   - recordBurn(community, 3, "entry")
5. Lock: 27 GT in GTokenStaking
   - GTOKEN_STAKING.lockStake(community, 27, "Community_operations")
6. Record: userRoles[community] = COMMUNITY_ADDRESS
7. Create community profile: communities[community] = {...}

Result:
├─ Community registered and active
├─ 27 GT locked for operations
├─ 3 GT burned (sunk cost)
├─ Full infrastructure support (free)
└─ Can recruit members
```

### Flow 3: User Exit (0.2 GT locked → 0.15 GT refund)
```
User Action:
1. User calls: Registry.exitRole()

Registry.exitRole():
2. Get locked amount: 0.2 GT
3. Calculate exit fee: 0.2 × 17% = 0.034 GT → 0.05 GT (minimum)
4. Call: GTOKEN_STAKING.unlockStake(user, 0.2)

GTokenStaking.unlockStake():
5. Calculate fee: 0.05 GT
6. Transfer fee to treasury: 0.05 GT
7. Transfer net to user: 0.2 - 0.05 = 0.15 GT
8. Update locks and totalLocked
9. Emit StakeUnlocked event

Registry.exitRole() continued:
10. recordBurn(user, 0.05, "exit")
11. Clear: delete userRoles[user]

MySBT.burn():
12. Remove SBT from user
13. Record exit in burn history

Result:
├─ User receives: 0.15 GT
├─ Entry burn: 0.1 GT (sunk)
├─ Exit fee: 0.05 GT (sunk)
├─ Total loss: 0.15 GT
├─ Recorded in burn history
└─ SBT burned (history remains)
```

---

## 💾 Storage Schema Changes

### GTokenStaking additions
```solidity
mapping(address => uint256) totalBurned;
mapping(address => BurnRecord[]) burnHistory;
address public mySBTAddress;  // For burn recording
address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
```

### Registry additions
```solidity
mapping(address => RoleConfig) roleConfigs;  // role → config
mapping(address => address) userRoles;  // user → role
mapping(address => uint256) totalUserBurns;
mapping(address => BurnRecord[]) userBurnHistory;
address public burnRecordingContract;  // Where to record burns
```

### MySBT additions
```solidity
mapping(uint256 => uint256) totalBurned;  // tokenId → burned amount
mapping(uint256 => BurnRecord[]) burnHistory;  // tokenId → burn records
```

---

## 🧪 Testing Checklist

### Unit Tests - GTokenStaking
- [ ] lockStake() with entry burn
- [ ] unlockStake() with exit fee
- [ ] recordBurn() tracking
- [ ] Exit fee calculation (percentage + min/max)
- [ ] Burn history retrieval

### Unit Tests - Registry
- [ ] registerRole() with all 4 role types
- [ ] exitRole() with refund verification
- [ ] DAO: addRole() - new role creation
- [ ] DAO: updateRole() - parameter updates
- [ ] Burn tracking accuracy

### Unit Tests - MySBT
- [ ] mint() with automatic burn
- [ ] burn() with exit fee
- [ ] Reputation calculation including burns
- [ ] SuperPaymaster callback execution

### Integration Tests
- [ ] End-to-end: User join → use → exit
- [ ] End-to-end: Community join → operate → exit
- [ ] Multi-user scenarios (10+ concurrent)
- [ ] DAO role parameter updates (live)
- [ ] Burn total verification

### Security Tests
- [ ] Reentrancy: lockStake() → transfer
- [ ] Reentrancy: unlockStake() → transfer
- [ ] Sybil cost: 1000 attacks = 150 GT loss
- [ ] Authorization: onlyDAO checks
- [ ] State consistency: lock + burn records

---

## 📝 Code Review Findings

### Current Issues to Fix

1. **GTokenStaking: Entry burn missing**
   - Status: lockStake() doesn't handle entry burn
   - Fix: Add entryBurn parameter and transfer to BURN_ADDRESS
   - Priority: 🔴 CRITICAL

2. **Registry: Enum-based roles (not extensible)**
   - Status: Uses enum NodeType, can't add roles via DAO
   - Fix: Convert to mapping-based RoleConfig
   - Priority: 🔴 CRITICAL

3. **Registry: Missing automatic stake burning**
   - Status: registerCommunity() doesn't burn entry fee
   - Fix: Add entry burn in registerRole() method
   - Priority: 🔴 CRITICAL

4. **MySBT: No connection to GTokenStaking**
   - Status: mint()/burn() don't interact with locks
   - Fix: Add lockStake/unlockStake calls
   - Priority: 🟠 HIGH

5. **Burn tracking scattered**
   - Status: No single source of truth for burn amounts
   - Fix: Centralize in GTokenStaking or Registry
   - Priority: 🟠 HIGH

6. **Exit fee destination**
   - Status: Treasury concept exists but not used everywhere
   - Fix: Ensure consistent fee routing in all contracts
   - Priority: 🟡 MEDIUM

### Current Strengths to Preserve

✅ GTokenStaking lock/unlock architecture - solid foundation
✅ Fee calculation with min/max protection - flexible
✅ User-level slash tracking - doesn't impact other users
✅ MySBT SBT structure - good for reputation tracking
✅ Registry community tracking - clear metadata

---

## 🚀 Implementation Priority

### Phase 1 (Week 1): Critical Path
1. GTokenStaking: Add entry burn to lockStake()
2. Registry: Convert to RoleConfig mapping
3. Registry: Add registerRole() and exitRole()
4. Add burn tracking in both contracts

### Phase 2 (Week 2): Integration
5. MySBT: Connect to GTokenStaking
6. MySBT: Implement exit with fee
7. MySBT: Update reputation for burns

### Phase 3 (Week 3): Governance & Testing
8. Registry: Add DAO methods (addRole, updateRole)
9. Complete test suite (70+ tests)
10. Internal security review

### Phase 4 (Week 4): Documentation & Deployment
11. Code documentation (NatSpec)
12. User/admin documentation
13. Testnet deployment and verification

---

## 📊 Economic Verification

### Sybil Attack Cost Analysis
```
Attack: 1000 fake users

Cost:
├─ Entry burn: 0.1 × 1000 = 100 GT
├─ Exit fee: 0.05 × 1000 = 50 GT
└─ Total: 150 GT

Benefit:
├─ Temporary protocol access: negligible
└─ No economic gain

ROI: -150 GT / 0 gain = -∞ ← INFEASIBLE
```

### Annual Burn Projection (10k users + 100 communities)
```
Entry burns:
├─ Users: 0.1 × 10,000 = 1,000 GT
├─ Communities: 3 × 100 = 300 GT
└─ Subtotal: 1,300 GT/year

Exit burns:
├─ Users (10% exit): 0.05 × 1,000 = 50 GT
├─ Communities: 0 GT (stay longer)
└─ Subtotal: 50 GT/year

Total: ~1,350 GT/year (0.0064% of 21M supply)
Sustainable: YES ✅
```

---

## 📌 Summary of Changes

| Component | Change | Impact | Priority |
|-----------|--------|--------|----------|
| GTokenStaking | Add entry burn | Core mechanism | 🔴 Critical |
| GTokenStaking | Add burn tracking | Reputation data | 🟠 High |
| Registry | RoleConfig mapping | DAO extensibility | 🔴 Critical |
| Registry | registerRole() | User/community flow | 🔴 Critical |
| Registry | exitRole() | Exit flow | 🔴 Critical |
| MySBT | GTokenStaking integration | Lock/unlock flow | 🟠 High |
| MySBT | Burn reputation factor | Reputation calc | 🟡 Medium |
| DAO | Role governance | Parameter changes | 🟠 High |

---

## ✅ Success Criteria

- ✅ Entry burns executed on registration
- ✅ Exit fees deducted on exit
- ✅ Burn records tracked and queryable
- ✅ All 4 roles fully implemented and tested
- ✅ DAO can add/update roles without redeployment
- ✅ Sybil attack cost verified as prohibitive
- ✅ 70+ comprehensive tests with >95% coverage
- ✅ Zero critical security issues

---

**Next Step**: Start with Phase 1 Week 1 implementation

# Optimal Architecture: Mycelium Registry-Centric Design
## 最优架构：以Registry为中心的菌丝体机制

**Date**: 2025-11-27
**Scope**: Complete redesign analysis (NOT backward compatible)
**Impact**: Full codebase refactor

---

## 📊 Current State Analysis

### Contract Call Graph (现有调用关系)

```
Frontend/Scripts
  ├─ registerCommunity() → Registry
  ├─ mintOrAddMembership() → MySBT
  ├─ userMint() → MySBT
  ├─ lockStake() → GTokenStaking
  └─ safeMint() → MySBT (DAO only)

Within Contracts (27处):
  ├─ Registry → GTokenStaking.lockStake() [1处]
  ├─ MySBT → GTokenStaking.lockStake() [3处]
  └─ Others → various [23处]

Frontend Scripts Found:
  ├─ scripts/deploy/
  ├─ scripts/gasless-test/register-operator-v2.3.3-new.js
  └─ deprecated/scripts/ [many old files]
```

### Issues with Current Design

| Issue | Impact | Severity |
|-------|--------|----------|
| **MySBT no authorization** | Anyone can call mint | 🔴 CRITICAL |
| **Split entry points** | registerCommunity vs mintOrAddMembership | 🔴 CRITICAL |
| **No role abstraction** | Hardcoded roles (enum) | 🟠 HIGH |
| **No burn tracking** | Can't calculate reputation | 🟠 HIGH |
| **Manual orchestration** | Client must do: approve → transfer → stake → lock → mint | 🟡 MEDIUM |
| **No fee configuration** | Fixed amounts, can't adjust | 🟡 MEDIUM |
| **No exit mechanism** | Users stuck in stake | 🟡 MEDIUM |

---

## 🎯 Optimal Architecture (最优方案)

### Design Principles

1. **单一入口**: Registry 是唯一的用户交互合约
2. **完全编排**: Registry 调用 MySBT 和 GTokenStaking
3. **原子性**: 所有操作在一个交易中完成（approve → transfer → stake → lock → burn → mint → record）
4. **灵活参数**: 所有费用参数动态可配，支持新角色
5. **完整记录**: 所有操作都有审计记录
6. **Gas优化**: 批量操作，最小化跨合约调用

### Architecture Diagram

```
Frontend/User
    ↓
Registry (Single Entry Point)
    ├─→ Transfer GToken (SafeERC20)
    ├─→ GTokenStaking.lockStake()
    │    ├─ Execute burn
    │    ├─ Record burn history
    │    └─ Lock stake
    ├─→ MySBT.mintForRole() (authorized)
    │    ├─ Mint SBT
    │    ├─ Record membership
    │    └─ Register to SuperPaymaster
    ├─→ Record role metadata
    └─→ Emit registration event

GTokenStaking (Stake Management)
    ├─ lockStake() + burn
    ├─ unlockStake() + exit fee
    ├─ Burn history
    └─ Slash management

MySBT (Role SBT Issuance)
    ├─ Only Registry can mint
    ├─ One SBT per user
    ├─ Multiple roles tracked
    └─ Reputation calculation

SuperPaymaster (SBT Registry)
    └─ Read-only integration
```

---

## 🔧 Core Contract Changes

### 1. Registry Contract (Hub)

#### New Storage
```solidity
// Role configurations
mapping(bytes32 roleId => RoleConfig) roleConfigs;
mapping(address user => bytes32[] roles) userRoles;
mapping(address user => UserRoleData) userRoleData;

// Audit trail
mapping(address user => RoleRegistration[]) roleHistory;
mapping(bytes32 roleId => RoleStats) roleStats;

// Authorizations
mapping(address => bool) authorizedMinters;  // Only MySBT
```

#### RoleConfig Structure
```solidity
struct RoleConfig {
    bytes32 roleId;          // "ENDUSER", "COMMUNITY", etc.
    string roleName;         // Display name

    // Economics
    uint256 minStake;        // Amount to stake
    uint256 entryBurn;       // Amount to burn
    uint256 exitFeePercent;  // Percentage (e.g., 17 = 17%)
    uint256 minExitFee;      // Minimum exit fee

    // Behavior
    bool requiresSBT;        // Must mint SBT?
    bool canHaveMultiple;    // User can have multiple?
    address sbtContract;     // Which SBT to mint? (MySBT)

    // Metadata
    uint256 createdAt;
    uint256 updatedAt;
    bool enabled;
}
```

#### Core Functions
```solidity
// SINGLE ENTRY POINT FOR ALL REGISTRATIONS
function registerRole(
    bytes32 roleId,
    address user,              // msg.sender for self-register
    bytes calldata roleData    // role-specific metadata
) external nonReentrant returns (uint256 sbtTokenId) {
    // 1. CHECKS
    RoleConfig config = roleConfigs[roleId];
    require(config.enabled, "Role disabled");
    require(!userAlreadyHasRole(user, roleId) || config.canHaveMultiple, "Already has role");

    // 2. TRANSFER & APPROVE
    uint256 totalAmount = config.minStake;
    IERC20(GTOKEN).safeTransferFrom(user, address(this), totalAmount);

    // 3. BURN
    if (config.entryBurn > 0) {
        IERC20(GTOKEN).transfer(BURN_ADDRESS, config.entryBurn);
        recordBurn(user, config.entryBurn, roleId, "entry");
    }

    // 4. STAKE & LOCK
    uint256 lockAmount = totalAmount - config.entryBurn;
    IERC20(GTOKEN).approve(GTOKEN_STAKING, lockAmount);
    GTOKEN_STAKING.lockStake(user, lockAmount, _getRoleDescription(roleId));

    // 5. MINT SBT (if applicable)
    uint256 sbtTokenId = 0;
    if (config.requiresSBT) {
        sbtTokenId = IMySBT(config.sbtContract).mintForRole(
            user,
            roleId,
            roleData
        );
    }

    // 6. RECORD
    _recordRoleRegistration(user, roleId, sbtTokenId, config.minStake);

    // 7. EMIT
    emit RoleRegistered(user, roleId, sbtTokenId, config.minStake, config.entryBurn);

    return sbtTokenId;
}

// SELF-REGISTER (wrapped for UX)
function registerRoleSelf(
    bytes32 roleId,
    bytes calldata roleData
) external returns (uint256 sbtTokenId) {
    return registerRole(roleId, msg.sender, roleData);
}

// EXIT ROLE
function exitRole(
    address user,
    bytes32 roleId
) external nonReentrant returns (uint256 refund) {
    // 1. Verify user has role
    require(hasRole(user, roleId), "No role");

    // 2. Get locked amount
    uint256 lockedAmount = GTOKEN_STAKING.getLockedStake(user, address(this));

    // 3. Calculate exit fee
    RoleConfig config = roleConfigs[roleId];
    uint256 exitFee = calculateExitFee(lockedAmount, config);

    // 4. Unlock from GTokenStaking
    refund = GTOKEN_STAKING.unlockStake(user, lockedAmount);

    // 5. Record burn
    recordBurn(user, exitFee, roleId, "exit");

    // 6. Burn SBT (if applicable)
    if (config.requiresSBT) {
        IMySBT(config.sbtContract).burnForRole(user, roleId);
    }

    // 7. Clear role
    _clearUserRole(user, roleId);

    emit RoleExited(user, roleId, lockedAmount, exitFee, refund);

    return refund;
}

// DAO: ADD NEW ROLE (dynamic)
function addRole(RoleConfig calldata config) external onlyDAO {
    require(!roleExists(config.roleId), "Role exists");
    require(config.minStake > 0, "Invalid stake");
    require(config.entryBurn < config.minStake, "Burn exceeds stake");

    roleConfigs[config.roleId] = config;
    emit RoleAdded(config.roleId, config.minStake, config.entryBurn);
}

// DAO: UPDATE ROLE PARAMETERS
function updateRoleConfig(
    bytes32 roleId,
    RoleConfig calldata newConfig
) external onlyDAO {
    require(roleExists(roleId), "Role not found");
    roleConfigs[roleId] = newConfig;
    emit RoleConfigUpdated(roleId);
}

// VIEW: Get user roles
function getUserRoles(address user) external view returns (bytes32[] memory) {
    return userRoles[user];
}

// VIEW: Get role config
function getRoleConfig(bytes32 roleId) external view returns (RoleConfig memory) {
    return roleConfigs[roleId];
}

// VIEW: Get user burn history
function getUserBurnHistory(
    address user,
    uint256 offset,
    uint256 limit
) external view returns (BurnRecord[] memory) {
    // Return paginated burn history
}

// VIEW: Get total burned by user
function getTotalBurned(address user) external view returns (uint256) {
    return userBurnStats[user].totalBurned;
}
```

### 2. MySBT Contract (SBT Issuance Only)

#### New Authorization
```solidity
// Only Registry can mint
mapping(address => bool) authorizedMinters;

modifier onlyAuthorized() {
    require(authorizedMinters[msg.sender], "Not authorized");
    _;
}
```

#### Simplified Interface
```solidity
// ONLY CALLED BY REGISTRY
function mintForRole(
    address user,
    bytes32 roleId,
    bytes calldata roleMetadata
) external onlyAuthorized returns (uint256 tokenId) {
    require(userToSBT[user] == 0, "Already has SBT");

    // Mint SBT
    tokenId = nextTokenId++;
    _mint(user, tokenId);
    userToSBT[user] = tokenId;

    // Record role
    sbtData[tokenId].roles.push(roleId);
    sbtData[tokenId].roleMetadata[roleId] = roleMetadata;
    sbtData[tokenId].roleCreatedAt[roleId] = block.timestamp;

    // Register to SuperPaymaster
    _registerSBTHolder(user, tokenId);

    emit SBTMintedForRole(user, tokenId, roleId);

    return tokenId;
}

// BURN ROLE FROM SBT (multiple roles per SBT)
function burnForRole(address user, bytes32 roleId) external onlyAuthorized {
    uint256 tokenId = userToSBT[user];
    require(tokenId > 0, "No SBT");

    // Remove role from SBT
    uint256 idx = _findRoleIndex(sbtData[tokenId].roles, roleId);
    require(idx < sbtData[tokenId].roles.length, "Role not found");

    sbtData[tokenId].roles[idx] = sbtData[tokenId].roles[sbtData[tokenId].roles.length - 1];
    sbtData[tokenId].roles.pop();

    // If no more roles, burn SBT
    if (sbtData[tokenId].roles.length == 0) {
        _burn(tokenId);
        delete userToSBT[user];
        _removeSBTHolder(user);
    }

    emit RoleBurned(user, tokenId, roleId);
}

// KEEP EXISTING FOR DAO
function safeMint(address to, bytes calldata roleMetadata) external onlyDAO {
    // Unchanged - DAO can still airdrop
}
```

### 3. GTokenStaking Contract (Core Staking)

#### Simplified for Registry-only
```solidity
// Authorization (only Registry can lock/unlock)
mapping(address => bool) authorizedLockers;

modifier onlyAuthorizedLocker() {
    require(authorizedLockers[msg.sender], "Not authorized");
    _;
}

// Lock with burn (Registry specifies burn amount)
function lockStake(
    address user,
    uint256 amount,
    string calldata purpose,
    uint256 entryBurn  // NEW: Registry specifies burn amount
) external onlyAuthorizedLocker {
    // Lock amount after burn
    uint256 lockAmount = amount - entryBurn;

    locks[user][msg.sender].amount = lockAmount;
    locks[user][msg.sender].lockedAt = block.timestamp;
    locks[user][msg.sender].purpose = purpose;

    // Burn tokens (Registry already transferred to this contract)
    if (entryBurn > 0) {
        IERC20(GTOKEN).transfer(BURN_ADDRESS, entryBurn);
    }

    totalLocked[user] += lockAmount;

    emit StakeLocked(user, msg.sender, lockAmount, entryBurn, purpose);
}

// Unlock with exit fee (Registry specifies fee)
function unlockStake(
    address user,
    uint256 grossAmount,
    uint256 exitFee  // NEW: Registry specifies fee
) external onlyAuthorizedLocker returns (uint256 netAmount) {
    // Deduct fee
    netAmount = grossAmount - exitFee;

    locks[user][msg.sender].amount -= grossAmount;
    totalLocked[user] -= grossAmount;

    // Transfer fee to treasury
    if (exitFee > 0) {
        IERC20(GTOKEN).transfer(treasury, exitFee);
    }

    // Transfer refund to user
    IERC20(GTOKEN).transfer(user, netAmount);

    emit StakeUnlocked(user, msg.sender, grossAmount, exitFee, netAmount);

    return netAmount;
}
```

---

## 📊 Data Changes Summary

### Registry Changes
```
REMOVE (Backward incompatible):
- registerCommunity(profile, stGTokenAmount)
- registerCommunityWithAutoStake(profile, stakeAmount)
- NodeType enum
- NodeTypeConfig struct
- communityStakes mapping

ADD:
- roleConfigs mapping (RoleConfig)
- userRoles mapping (user → roles)
- userRoleData mapping
- roleHistory mapping
- roleStats mapping
- authorizedMinters mapping
- burnRecords mapping
```

### MySBT Changes
```
REMOVE:
- mintOrAddMembership(user, meta)
- userMint(community, meta)
- mintWithAutoStake(community, meta)
- _m mapping (community memberships)
- membershipIndex mapping

ADD:
- mintForRole(user, roleId, metadata)
- burnForRole(user, roleId)
- authorizedMinters mapping
- sbtData.roles (array)
- sbtData.roleMetadata (mapping)
```

### GTokenStaking Changes
```
MODIFY:
- lockStake() → add entryBurn parameter
- unlockStake() → add exitFee parameter
- Add authorizedLockers

ADD:
- burnRecords tracking
- burnHistory mapping
```

---

## 💻 Frontend/Script Changes Required

### Scripts Affected (估计)

**Register flows**:
```
OLD:
  1. registry.registerCommunity({...}, 30 ether)
  2. mysbt.mintOrAddMembership(user, meta)

NEW:
  1. gtoken.approve(registry, 30 ether)
  2. registry.registerRole(COMMUNITY_ROLE, user, metadata)
  // Everything happens atomically
```

**ABI Changes**:
```javascript
// OLD ABI
{
  "name": "registerCommunity",
  "inputs": [
    { "name": "profile", "type": "tuple" },
    { "name": "stGTokenAmount", "type": "uint256" }
  ]
}

// NEW ABI
{
  "name": "registerRole",
  "inputs": [
    { "name": "roleId", "type": "bytes32" },
    { "name": "user", "type": "address" },
    { "name": "roleData", "type": "bytes" }
  ]
}
```

### Files to Update (Estimated)

```
scripts/
├─ gasless-test/register-operator-v2.3.3-new.js    ← CHANGE
├─ deploy/deploy-v2.3.3-nodejs.js                  ← CHANGE
└─ ... [other register-related scripts]             ← AUDIT

abis/
├─ Registry.json                                    ← REGENERATE
├─ MySBT.json                                       ← REGENERATE
└─ GTokenStaking.json                               ← REGENERATE
```

### Migration Path

```
Phase 1: Deploy new Registry, MySBT, GTokenStaking side-by-side
Phase 2: Update all scripts to use new Registry
Phase 3: Test with new ABIs
Phase 4: Deprecate old contracts (or keep for migration)
```

---

## ⚡ Gas Optimization

### Optimization Strategies

1. **Batch Operations**
   - One transaction: approve → transfer → stake → lock → burn → mint → record
   - 현재: ~5 separate calls → 신규: 1 call
   - **Gas savings: 60-70%** ✅

2. **Storage Packing**
   - RoleConfig: 32 bytes (uint256×4 + bool + address)
   - UserRoleData: packed storage
   - **Gas savings: 20-30%** ✅

3. **Loop Optimization**
   - burn history: pagination instead of full array
   - role list: bytes32[] instead of string
   - **Gas savings: 10-20%** ✅

4. **Authorization Caching**
   - authorizedMinters checked once per call
   - No repeated lookups
   - **Gas savings: 5-10%** ✅

### Estimated Gas Costs

```
registerRole (full flow):
- Current: ~450k gas (5 separate txs)
- Optimal: ~120-150k gas (1 atomic tx)
- Savings: ~70% ✅

exitRole:
- Current: ~250k gas
- Optimal: ~80-100k gas
- Savings: ~65% ✅

addRole (DAO):
- Current: N/A (not supported)
- Optimal: ~50-60k gas
- Savings: New capability ✅
```

---

## 📝 Change Impact Summary

### Breaking Changes

| Component | Change | Impact | Migration |
|-----------|--------|--------|-----------|
| Registry | `registerCommunity()` → `registerRole()` | All register flows | Update scripts + frontend |
| MySBT | `mintOrAddMembership()` → `mintForRole()` | SBT minting | Update auth + interfaces |
| GTokenStaking | `lockStake()` sig change | All lock calls | Update all callers |
| ABI | Complete regeneration | Contract interaction | Update ABI JSONs |

### Non-Breaking

✅ SuperPaymaster integration (read-only, no changes)
✅ GToken contract (only transfer/approve, no changes)
✅ MySBT `safeMint()` (DAO airdrop, unchanged)

---

## 🎯 Implementation Priority

### Phase 1: Core Refactor (Week 1)
1. Redesign Registry (RoleConfig, registerRole, exitRole)
2. Redesign MySBT (authorization, mintForRole)
3. Redesign GTokenStaking (entryBurn parameter)
4. Complete 70+ tests

### Phase 2: Integration (Week 2)
1. Update all contract references (27 locations)
2. Regenerate ABIs
3. Update scripts (register flows)
4. Integration testing

### Phase 3: Frontend (Week 3)
1. Update all script calls
2. Update ABI references
3. Test with new signatures
4. Deploy to testnet

### Phase 4: Validation (Week 4)
1. End-to-end testing
2. Gas optimization verification
3. Security review
4. Production deployment

---

## ✅ Success Criteria

- ✅ Single Registry entry point for all roles
- ✅ Atomic transactions (approve → mint in one tx)
- ✅ Dynamic role configuration (add/update via DAO)
- ✅ 70-80% gas reduction
- ✅ Complete burn/exit audit trail
- ✅ Multiple roles per SBT supported
- ✅ Zero backward compatibility issues (clean break)
- ✅ All 27 internal calls updated
- ✅ All scripts migrated
- ✅ All ABIs regenerated

---

## 📌 Recommendation

**Go with complete refactor (NOT backward compatible)**:

✅ **Pros**:
- Cleaner architecture (single entry point)
- Massive gas savings (70%)
- Future-proof (dynamic roles, flexible fees)
- Better UX (atomic operations)
- Complete audit trail

❌ **Cons**:
- Breaking changes (scripts + frontend)
- Requires migration effort (~2 weeks)
- Old contract deprecation needed

**Cost/Benefit**: Breaking changes now vs. technical debt forever. **Worth it.**

---

**Next Step**: Approve this architecture, then start Phase 1 (Week 1) refactor.

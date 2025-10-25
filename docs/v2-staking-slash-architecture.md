# SuperPaymaster v2.0 - Staking & Slash Architecture

## Overview

This document describes the staking and slashing architecture for SuperPaymaster v2.0, where all paymasters (both AOA independent mode and Super shared mode) must lock stGToken to ensure reputation and prevent malicious behavior.

## Design Principles

### 1. Separation of Concerns + Atomic Operations

```
┌─────────────────────────────────────────────────┐
│          Business Layer (Registry)              │
│  - Register communities with stGToken lock      │
│  - Monitor failures and trigger slash           │
│  - Manage community metadata and status         │
└────────────────┬────────────────────────────────┘
                 │ calls
                 ↓
┌─────────────────────────────────────────────────┐
│       Asset Layer (GTokenStaking)               │
│  - Execute lock/unlock/slash operations         │
│  - Track lock details per locker                │
│  - Provide query interfaces                     │
└─────────────────────────────────────────────────┘
```

### 2. Unified Naming Convention

- ✅ **stGToken** (staked GToken) - Aligned with DeFi standards
- ❌ ~~sGToken~~ - Deprecated

### 3. Atomic Registration + Lock

- **AOA Mode**: `Registry.registerCommunity()` calls `GTokenStaking.lockStake()` internally
- **Super Mode**: `SuperPaymasterV2.registerOperator()` calls `GTokenStaking.lockStake()` internally
- Both registration and locking happen in a single transaction

## Architecture Components

### GTokenStaking Contract (Asset Layer)

**Responsibilities:**
- Manage GToken → stGToken staking
- Execute lock/unlock operations for authorized contracts
- Execute slash operations when triggered
- Provide query interfaces for locked stakes

**New Data Structures:**

```solidity
/// @notice Lock information for each user-locker pair
struct LockInfo {
    uint256 amount;           // Amount of stGToken locked
    address locker;           // Contract that locked (Registry or SuperPaymaster)
    uint256 lockedAt;         // Timestamp when locked
    string purpose;           // Purpose description
}

// Mapping: user => locker => LockInfo
mapping(address => mapping(address => LockInfo)) public locks;

// Authorized lockers (Registry, SuperPaymaster, etc.)
mapping(address => bool) public authorizedLockers;
```

**New Functions:**

```solidity
/**
 * @notice Slash user's staked tokens (called by authorized lockers)
 * @param user User address to slash
 * @param amount Amount of stGToken to slash
 * @param reason Reason for slashing
 * @return slashedAmount Actual amount slashed
 */
function slash(
    address user,
    uint256 amount,
    string memory reason
) external onlyAuthorizedLocker returns (uint256 slashedAmount);

/**
 * @notice Get locked stake amount for a user from specific locker
 * @param user User address
 * @param locker Locker contract address
 * @return Locked stGToken amount
 */
function getLockedStake(address user, address locker)
    external view returns (uint256);

/**
 * @notice Add authorized locker contract
 * @param locker Address of locker contract (Registry or SuperPaymaster)
 */
function addAuthorizedLocker(address locker) external onlyOwner;
```

### Registry Contract (Business Layer)

**Responsibilities:**
- Register communities with metadata + stGToken lock
- Monitor transaction failures
- Trigger slash when failure threshold is reached
- Manage community status (active/paused/slashed)

**Constants:**

```solidity
uint256 public constant MIN_STAKE_AOA = 30 ether;      // AOA minimum: 30 stGToken
uint256 public constant MIN_STAKE_SUPER = 50 ether;    // Super minimum: 50 stGToken
uint256 public constant SLASH_THRESHOLD = 10;          // Slash after 10 failures
uint256 public constant SLASH_PERCENTAGE = 10;         // Slash 10% each time
uint256 public constant MAX_SLASH_PERCENTAGE = 50;     // Maximum 50% slash
```

**New Data Structures:**

```solidity
/// @notice Community staking and reputation tracking
struct CommunityStake {
    uint256 stGTokenLocked;      // Current locked stGToken
    uint256 failureCount;        // Consecutive failure count
    uint256 lastFailureTime;     // Last failure timestamp
    uint256 totalSlashed;        // Total slashed amount
    bool isActive;               // Active status
}

mapping(address => CommunityStake) public communityStakes;
```

**Enhanced registerCommunity:**

```solidity
/**
 * @notice Register a new community with stGToken lock
 * @param profile Community profile metadata
 * @param stGTokenAmount Amount of stGToken to lock
 */
function registerCommunity(
    CommunityProfile memory profile,
    uint256 stGTokenAmount
) external {
    address communityAddress = msg.sender;

    // Determine minimum stake based on mode
    uint256 minStake = (profile.mode == PaymasterMode.INDEPENDENT)
        ? MIN_STAKE_AOA
        : MIN_STAKE_SUPER;

    if (stGTokenAmount < minStake) {
        revert InsufficientStake(stGTokenAmount, minStake);
    }

    if (communities[communityAddress].registeredAt != 0) {
        revert CommunityAlreadyRegistered(communityAddress);
    }

    // Lock stGToken via GTokenStaking (atomic operation)
    GTOKEN_STAKING.lockStake(
        msg.sender,
        stGTokenAmount,
        "Registry community registration"
    );

    // Store metadata
    profile.community = communityAddress;
    profile.registeredAt = block.timestamp;
    profile.lastUpdatedAt = block.timestamp;
    profile.isActive = true;

    communities[communityAddress] = profile;
    communityStakes[communityAddress] = CommunityStake({
        stGTokenLocked: stGTokenAmount,
        failureCount: 0,
        lastFailureTime: 0,
        totalSlashed: 0,
        isActive: true
    });

    emit CommunityRegistered(
        communityAddress,
        profile.name,
        profile.ensName,
        profile.mode,
        stGTokenAmount
    );
}
```

**Slash Mechanism:**

```solidity
/**
 * @notice Report failure for a community (called by oracle/monitor)
 * @param community Community address
 */
function reportFailure(address community) external onlyOracle {
    CommunityStake storage stake = communityStakes[community];

    if (!stake.isActive) {
        revert CommunityNotActive(community);
    }

    stake.failureCount++;
    stake.lastFailureTime = block.timestamp;

    emit FailureReported(community, stake.failureCount, block.timestamp);

    // Trigger slash if threshold reached
    if (stake.failureCount >= SLASH_THRESHOLD) {
        _slashCommunity(community);
    }
}

/**
 * @notice Internal function to slash community's stGToken
 * @param community Community address to slash
 */
function _slashCommunity(address community) internal {
    CommunityStake storage stake = communityStakes[community];

    // Calculate slash amount (10% of locked stake)
    uint256 slashAmount = stake.stGTokenLocked * SLASH_PERCENTAGE / 100;

    // Execute slash via GTokenStaking
    uint256 slashed = GTOKEN_STAKING.slash(
        community,
        slashAmount,
        string(abi.encodePacked(
            "Registry slash: ",
            Strings.toString(stake.failureCount),
            " consecutive failures"
        ))
    );

    // Update state
    stake.stGTokenLocked -= slashed;
    stake.totalSlashed += slashed;
    stake.failureCount = 0;  // Reset counter after slash

    // Deactivate if stake too low
    if (stake.stGTokenLocked < MIN_STAKE_AOA / 2) {
        stake.isActive = false;
        communities[community].isActive = false;
        emit CommunityDeactivated(community, "Insufficient stake after slash");
    }

    emit CommunitySlashed(community, slashed, stake.failureCount, block.timestamp);
}

/**
 * @notice Reset failure count (called by governance/admin)
 * @param community Community address
 */
function resetFailureCount(address community) external onlyOwner {
    communityStakes[community].failureCount = 0;
    emit FailureCountReset(community, block.timestamp);
}
```

## Deployment Flow Comparison

### AOA Mode (Independent Paymaster)

```
┌─────────────────────────────────────────────────────────┐
│ Step 4: Deploy Resources                               │
│   ✓ Select MySBT                                       │
│   ✓ Deploy xPNTs via xPNTsFactory                      │
│   ✓ Stake GToken → receive stGToken                    │
├─────────────────────────────────────────────────────────┤
│ Step 5: EntryPoint Setup                               │
│   ✓ Deploy PaymasterV4.1                               │
│   ✓ Deposit ETH to EntryPoint                          │
├─────────────────────────────────────────────────────────┤
│ Step 6: Register to Registry                           │
│   ✓ Call Registry.registerCommunity(profile, 30-100)   │
│     └─> GTokenStaking.lockStake() called internally    │
│   ✓ Lock 30-100 stGToken for reputation               │
│   ✓ Store community metadata                           │
├─────────────────────────────────────────────────────────┤
│ Step 7: Complete                                        │
│   ✓ Paymaster ready for operation                      │
└─────────────────────────────────────────────────────────┘
```

### Super Mode (Shared SuperPaymaster)

```
┌─────────────────────────────────────────────────────────┐
│ Step 4: Deploy Resources                               │
│   ✓ Select MySBT                                       │
│   ✓ Deploy xPNTs via xPNTsFactory                      │
│   ✓ Stake GToken → receive stGToken                    │
├─────────────────────────────────────────────────────────┤
│ Step 5: Register to SuperPaymaster                     │
│   ✓ Call SuperPaymaster.registerOperator(50-100, ...) │
│     └─> GTokenStaking.lockStake() called internally    │
│   ✓ Lock 50-100 stGToken for reputation               │
│   ✓ Deposit aPNTs for gas backing                      │
├─────────────────────────────────────────────────────────┤
│ Step 6: Register to Registry                           │
│   ✓ Call Registry.registerCommunity(profile, 0)        │
│   ✓ No additional lock (already locked in Step 5)      │
│   ✓ Store community metadata                           │
├─────────────────────────────────────────────────────────┤
│ Step 7: Complete                                        │
│   ✓ Paymaster ready for operation                      │
└─────────────────────────────────────────────────────────┘
```

## Slash Rules & Examples

### Trigger Conditions

| Condition | Threshold | Action | Slash % |
|-----------|-----------|--------|---------|
| Consecutive failures | ≥ 10 | Slash | 10% |
| 24h failure rate | ≥ 50 | Slash | 20% |
| Manual slash (malicious) | Admin decision | Slash | 10-50% |
| Long-term inactive | 30 days | Warning | 0% |
| Critical failure | Immediate | Emergency slash | 50% |

### Example Scenarios

#### Scenario 1: Normal Operation
```
Initial stake: 100 stGToken
Failures: 0-9 → No action
Status: Active ✅
```

#### Scenario 2: Temporary Issues
```
Initial stake: 100 stGToken
Failures: 10 → Slash 10 stGToken (10%)
Remaining: 90 stGToken
Counter reset: 0
Status: Active ✅
```

#### Scenario 3: Repeated Problems
```
Initial stake: 100 stGToken
1st slash (10 failures): -10 → 90 stGToken
2nd slash (10 failures): -9 → 81 stGToken
3rd slash (10 failures): -8.1 → 72.9 stGToken
Status: Active ⚠️
```

#### Scenario 4: Critical Threshold
```
Current stake: 14 stGToken (< MIN_STAKE_AOA/2)
Next slash: -1.4 → 12.6 stGToken
Action: Deactivate ❌
Status: Inactive (needs top-up to reactivate)
```

## Security Considerations

### Access Control

```solidity
// GTokenStaking
- Only authorized lockers can call lockStake()
- Only authorized lockers can call slash()
- Only owner can add/remove authorized lockers

// Registry
- Only oracle can call reportFailure()
- Only owner can call resetFailureCount()
- Only owner can call manualSlash()
```

### Reentrancy Protection

All state-changing functions use `nonReentrant` modifier from OpenZeppelin.

### CEI Pattern (Checks-Effects-Interactions)

All functions follow the CEI pattern:
1. **Checks**: Validate inputs and conditions
2. **Effects**: Update state variables
3. **Interactions**: Call external contracts

### Slash Limits

- Maximum slash per event: 50%
- Minimum remaining stake to stay active: MIN_STAKE / 2
- Slashed tokens go to protocol treasury

## Events

### GTokenStaking

```solidity
event StakeSlashed(
    address indexed user,
    address indexed locker,
    uint256 amount,
    string reason,
    uint256 timestamp
);

event AuthorizedLockerAdded(address indexed locker);
event AuthorizedLockerRemoved(address indexed locker);
```

### Registry

```solidity
event CommunityRegistered(
    address indexed community,
    string name,
    string ensName,
    PaymasterMode mode,
    uint256 stGTokenLocked
);

event FailureReported(
    address indexed community,
    uint256 failureCount,
    uint256 timestamp
);

event CommunitySlashed(
    address indexed community,
    uint256 amount,
    uint256 failureCount,
    uint256 timestamp
);

event FailureCountReset(
    address indexed community,
    uint256 timestamp
);
```

## Testing Requirements

### GTokenStaking Tests
- ✅ Lock stake with authorized locker
- ✅ Reject lock from unauthorized locker
- ✅ Slash with sufficient locked stake
- ✅ Slash with insufficient locked stake (partial slash)
- ✅ Query locked stake
- ✅ Multiple lockers for same user

### Registry Tests
- ✅ Register with sufficient stGToken (AOA)
- ✅ Register with sufficient stGToken (Super)
- ✅ Reject registration with insufficient stGToken
- ✅ Report failure and increment counter
- ✅ Trigger slash after threshold
- ✅ Reset failure count
- ✅ Deactivate after critical stake loss

## Migration Plan

### Phase 1: Contract Updates
1. Update GTokenStaking.sol - Add slash() and getLockedStake()
2. Update Registry.sol - Add stGTokenAmount parameter and lock logic
3. Update SuperPaymasterV2.sol - Rename sGToken → stGToken
4. Deploy and verify contracts

### Phase 2: Frontend Updates
1. Update Step6_RegisterRegistry_v2.tsx - Add stGToken input field
2. Update StakeOptionCard.tsx - Update naming and requirements
3. Update walletChecker.ts - Update balance checks

### Phase 3: Testing & Documentation
1. Unit tests for all new functions
2. Integration tests for registration flows
3. Update user documentation
4. Update API documentation

## References

- Aave Safety Module: https://docs.aave.com/developers/v/2.0/guides/aave-safety-module
- MakerDAO Governance: https://docs.makerdao.com/
- EIP-4626 (Tokenized Vaults): https://eips.ethereum.org/EIPS/eip-4626

---

**Document Version**: 1.0
**Last Updated**: 2025-10-25
**Author**: AAStar Protocol Team

# MySBT v2.2 - Security Audit & Enhancement Plan

**Date**: 2025-10-28
**Auditor**: Claude Code
**Contract**: MySBT_v2.1.sol (v2.2 event-driven)
**Status**: Pre-audit review

## Executive Summary

| Category | Issues Found | Severity | Status |
|----------|--------------|----------|--------|
| Critical | 0 | 🔴 | - |
| High | 2 | 🟠 | Needs Fix |
| Medium | 4 | 🟡 | Recommended |
| Low | 3 | 🟢 | Optional |
| Gas | 5 | ⚡ | Optimization |

---

## 🔴 Critical Issues (0)

None found. Good foundation!

---

## 🟠 High Severity Issues (2)

### H-1: Missing Access Control on `recordActivity`

**Current Code**:
```solidity
function recordActivity(address user) external override {
    if (!_isValidCommunity(msg.sender)) return; // ❌ Silent fail
    // ...
}
```

**Issue**:
- Unregistered communities can spam events
- No rate limiting
- Could flood The Graph indexer

**Fix**:
```solidity
function recordActivity(address user) external override {
    // ✅ Revert instead of silent fail for better tracking
    if (!_isValidCommunity(msg.sender)) {
        revert CommunityNotRegistered(msg.sender);
    }

    // ✅ Add rate limiting
    uint256 tokenId = userToSBT[user];
    require(tokenId != 0, "No SBT");

    uint256 lastActivity = lastActivityTime[tokenId][msg.sender];
    require(
        block.timestamp >= lastActivity + MIN_ACTIVITY_INTERVAL,
        "Activity too frequent"
    );

    lastActivityTime[tokenId][msg.sender] = block.timestamp;

    emit ActivityRecorded(tokenId, msg.sender, currentWeek, block.timestamp);
}
```

**Gas Impact**: +5k gas (worth it for security)

---

### H-2: No NFT Ownership Verification in `bindCommunityNFT`

**Current Code**:
```solidity
function bindCommunityNFT(...) external nonReentrant {
    // Check NFT ownership
    if (IERC721(nftContract).ownerOf(nftTokenId) != msg.sender) {
        revert NFTNotOwned(msg.sender, nftContract, nftTokenId);
    }

    // ❌ No check if NFT was transferred after binding
}
```

**Issue**:
- User can bind NFT, transfer it, still keep reputation bonus
- NFT bonus persists even if NFT is sold

**Fix Option 1**: Add re-verification in reputation calculation
```solidity
function _calculateDefaultReputation(...) internal view returns (uint256 score) {
    score = BASE_REPUTATION;

    NFTBinding memory binding = nftBindings[tokenId][community];
    if (binding.isActive) {
        // ✅ Verify current ownership
        try IERC721(binding.nftContract).ownerOf(binding.nftTokenId) returns (address owner) {
            if (owner == sbtData[tokenId].holder) {
                score += NFT_BONUS;
            }
        } catch {
            // NFT contract error, no bonus
        }
    }
}
```

**Fix Option 2**: Add unbind hook (Requires NFT contract support)
```solidity
// NFT contract must call this on transfer
function onNFTTransfer(address from, uint256 tokenId) external {
    uint256 sbtTokenId = userToSBT[from];
    if (sbtTokenId != 0) {
        NFTBinding storage binding = nftBindings[sbtTokenId][msg.sender];
        if (binding.nftTokenId == tokenId) {
            binding.isActive = false;
            emit NFTUnbound(sbtTokenId, msg.sender, msg.sender, tokenId, block.timestamp);
        }
    }
}
```

**Recommendation**: Use Option 1 (no NFT contract modification needed)

---

## 🟡 Medium Severity Issues (4)

### M-1: Missing Pause Mechanism

**Issue**: No emergency pause for critical bugs

**Fix**:
```solidity
import "@openzeppelin/contracts/security/Pausable.sol";

contract MySBT_v2_1 is ERC721, Pausable, ReentrancyGuard, IMySBT {

    function mintOrAddMembership(...) external whenNotPaused returns (...) {
        // ...
    }

    function bindCommunityNFT(...) external whenNotPaused {
        // ...
    }

    function pause() external onlyDAO {
        _pause();
    }

    function unpause() external onlyDAO {
        _unpause();
    }
}
```

---

### M-2: Insufficient Event Data

**Current**:
```solidity
event ActivityRecorded(
    uint256 indexed tokenId,
    address indexed community,
    uint256 week,
    uint256 timestamp
);
```

**Issue**: Missing context data for indexer

**Enhanced**:
```solidity
event ActivityRecorded(
    uint256 indexed tokenId,
    address indexed community,
    uint256 week,
    uint256 timestamp,
    bytes32 activityType,    // ✅ "transaction", "governance", etc.
    bytes metadata           // ✅ Additional context
);

function recordActivity(address user, bytes32 activityType, bytes memory metadata) external override {
    // ...
    emit ActivityRecorded(tokenId, msg.sender, currentWeek, block.timestamp, activityType, metadata);
}
```

---

### M-3: No Reputation Decay Mechanism

**Issue**: Old inactive users keep high reputation forever

**Fix**:
```solidity
function getCommunityReputation(address user, address community)
    external view returns (uint256 score)
{
    // ... existing calculation

    // ✅ Add decay based on inactivity
    uint256 tokenId = userToSBT[user];
    uint256 idx = membershipIndex[tokenId][community];
    uint256 lastActive = _memberships[tokenId][idx].lastActiveTime;

    if (lastActive > 0) {
        uint256 inactiveDays = (block.timestamp - lastActive) / 1 days;
        if (inactiveDays > 30) {
            uint256 decayWeeks = inactiveDays / 7;
            uint256 decay = decayWeeks * DECAY_RATE; // e.g., 1 point per week
            score = score > decay ? score - decay : 0;
        }
    }
}
```

**Note**: With event-driven model, this should be in external calculator

---

### M-4: Missing Input Validation

**Current**:
```solidity
function mintOrAddMembership(address user, string memory metadata) {
    // ❌ No validation on user address
    // ❌ No validation on metadata length
}
```

**Fix**:
```solidity
function mintOrAddMembership(address user, string memory metadata) {
    if (user == address(0)) revert InvalidAddress(user);
    if (bytes(metadata).length > 1024) revert InvalidParameter("metadata too long");
    if (bytes(metadata).length == 0) revert InvalidParameter("metadata empty");
    // ...
}
```

---

## 🟢 Low Severity Issues (3)

### L-1: No Version Tracking

**Fix**:
```solidity
string public constant VERSION = "2.2.0";
uint256 public constant VERSION_CODE = 220;

event ContractUpgraded(uint256 oldVersion, uint256 newVersion);
```

---

### L-2: Missing NatSpec Documentation

**Issue**: Incomplete documentation for external functions

**Fix**: Add complete NatSpec to all public/external functions
```solidity
/**
 * @notice Record user activity in community (event-driven)
 * @dev v2.2: Pure event emission for gas optimization
 * @dev Silently skips if community not registered or user has no SBT
 * @param user User address to record activity for
 * @custom:security Non-critical operation, doesn't revert
 * @custom:gas ~34k gas (v2.2) vs 65k gas (v2.1)
 */
function recordActivity(address user) external override {
    // ...
}
```

---

### L-3: No Events for Admin Functions

**Fix**:
```solidity
event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
event MinLockAmountUpdated(uint256 oldAmount, uint256 newAmount);
event MintFeeUpdated(uint256 oldFee, uint256 newFee);

function setRegistry(address registry) external onlyDAO {
    address oldRegistry = REGISTRY;
    REGISTRY = registry;
    emit RegistryUpdated(oldRegistry, registry);
}
```

---

## ⚡ Gas Optimizations (5)

### G-1: Cache Array Length in Loops

**Before**:
```solidity
for (uint256 i = 0; i < _memberships[tokenId].length; i++) {
    // ...
}
```

**After**:
```solidity
uint256 length = _memberships[tokenId].length;
for (uint256 i = 0; i < length; i++) {
    // ...
}
```

**Savings**: ~100 gas per iteration

---

### G-2: Use Custom Errors Instead of Revert Strings

**Before**:
```solidity
require(tokenId != 0, "No SBT found");
```

**After**:
```solidity
if (tokenId == 0) revert NoSBTFound(user);
```

**Savings**: ~50 gas per revert

---

### G-3: Pack Struct Variables

Already done in optimization doc, implement:
```solidity
struct SBTData {
    address holder;               // slot 0: bytes 0-19
    uint96 totalCommunities;      // slot 0: bytes 20-31
    address firstCommunity;       // slot 1: bytes 0-19
    uint40 mintedAt;              // slot 1: bytes 20-24
}
```

**Savings**: ~40k gas per mint

---

### G-4: Use Unchecked for Safe Math

```solidity
function getGlobalReputation(address user) external view returns (uint256 score) {
    // ...
    uint256 length = _memberships[tokenId].length;
    unchecked {
        for (uint256 i = 0; i < length; ++i) { // ✅ ++i instead of i++
            // Safe: array access bounded by length
            score += getCommunityReputation(user, _memberships[tokenId][i].community);
        }
    }
}
```

**Savings**: ~20 gas per loop iteration

---

### G-5: Optimize Storage Reads

**Before**:
```solidity
function verifyCommunityMembership(address user, address community) {
    uint256 tokenId = userToSBT[user]; // SLOAD
    if (tokenId == 0) return false;

    uint256 idx = membershipIndex[tokenId][community]; // SLOAD
    if (idx >= _memberships[tokenId].length) return false; // SLOAD

    CommunityMembership memory membership = _memberships[tokenId][idx]; // SLOAD
    // ...
}
```

**After**:
```solidity
function verifyCommunityMembership(address user, address community) {
    uint256 tokenId = userToSBT[user];
    if (tokenId == 0) return false;

    // ✅ Single storage read for membership
    uint256 idx = membershipIndex[tokenId][community];
    CommunityMembership storage membership = _memberships[tokenId][idx];

    return idx < _memberships[tokenId].length &&
           membership.community == community &&
           membership.isActive;
}
```

**Savings**: ~2000 gas (fewer SLOADs)

---

## Implementation Priority

### Phase 1: Security Fixes (Immediate)
1. ✅ H-1: Add rate limiting to recordActivity
2. ✅ H-2: Verify NFT ownership in reputation calculation
3. ✅ M-1: Add pause mechanism
4. ✅ M-4: Input validation

### Phase 2: Enhancements (1 week)
1. ✅ M-2: Enhanced event data
2. ✅ M-3: Reputation decay (in external calculator)
3. ✅ L-3: Admin events

### Phase 3: Optimizations (As needed)
1. ✅ G-3: Storage packing (separate from v2.2)
2. ✅ G-2: Custom errors
3. ✅ G-4, G-5: Gas optimizations

---

## Estimated Gas Impact

| Change | Gas Impact | Worth It? |
|--------|------------|-----------|
| **H-1: Rate limiting** | +5k | ✅ Yes (security) |
| **H-2: NFT verification** | +3k | ✅ Yes (correctness) |
| **M-1: Pausable** | +2k | ✅ Yes (emergency) |
| **M-4: Input validation** | +1k | ✅ Yes (safety) |
| **G-2: Custom errors** | -0.5k | ✅ Yes (free optimization) |
| **G-4/G-5: Optimizations** | -2k | ✅ Yes (free optimization) |
| **Net Impact** | **+8.5k** | ✅ Acceptable for security |

---

## Testing Requirements

### Additional Test Cases Needed

1. **Rate Limiting**:
   - Test double recordActivity in same block
   - Test activity after MIN_INTERVAL

2. **NFT Verification**:
   - Test reputation after NFT transfer
   - Test reputation with invalid NFT

3. **Pause Mechanism**:
   - Test all functions when paused
   - Test only DAO can pause/unpause

4. **Input Validation**:
   - Test with address(0)
   - Test with oversized metadata
   - Test with empty metadata

---

## External Audit Recommendations

Before mainnet deployment:
1. **Formal Audit**: Trail of Bits, OpenZeppelin, or Consensys Diligence
2. **Economic Analysis**: Game theory review of reputation system
3. **The Graph Subgraph Audit**: Ensure mapping logic is correct
4. **Bug Bounty**: Immunefi program for responsible disclosure

---

**Prepared by**: Claude Code
**Review Date**: 2025-10-28
**Next Review**: After implementing Phase 1 fixes

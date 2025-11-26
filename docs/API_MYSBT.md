# MySBT API Reference

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

## Immutable Addresses

| Variable | Description |
|----------|-------------|
| `GTOKEN` | GToken contract address |
| `GTOKEN_STAKING` | Staking contract address |

## State Variables

| Variable | Type | Description |
|----------|------|-------------|
| `REGISTRY` | address | Registry contract |
| `SUPER_PAYMASTER` | address | SuperPaymaster for callbacks |
| `daoMultisig` | address | DAO admin address |
| `reputationCalculator` | address | Reputation calculator |
| `nextTokenId` | uint256 | Next token ID |

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

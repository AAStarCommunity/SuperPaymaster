# V5.1 Agent Sponsorship Policy — Removed Code Reference

**Date**: 2026-05-06  
**Branch removed from**: `main` (via PR-8 `fix/p1-sp-guarded-functions`)  
**Original development branch**: `feature/v5.1-consume-credit`  
**Reason for removal**: EIP-170 size constraint (SP at 24,564B with only 12B headroom; this code costs ~300B)

---

## Business Intent

The Agent Sponsorship Policy was designed as part of the **V5.1 agent economy**:

- Operators configure **tiered BPS discount rates** for registered ERC-8004 agents based on their on-chain reputation score
- Each tier specifies a `minReputationScore` (from `IAgentReputationRegistry`) and a `sponsorshipBPS` discount rate
- A `maxDailyUSD` cap per operator limits the total daily spend subsidized for agents
- The system allows operators to reward high-reputation agents with cheaper (or free) gas sponsorship
- Rates are resolved at transaction time via `_resolveAgentPolicy()` (a function that was planned but never fully wired up — see note below)

Example policy table an operator might set:

| Min Reputation Score | Sponsorship BPS | Max Daily USD |
|----------------------|-----------------|---------------|
| 0 (any agent)        | 0 (no discount) | $0            |
| 500                  | 500 (5%)        | $10           |
| 900                  | 2000 (20%)      | $50           |
| 9500 (elite)         | 10000 (100%)    | $100          |

---

## Why It Was Never Active

The policy storage and setters were merged to `main` as part of V5.3, but the **discount application hook `_applyAgentSponsorship` was never called** in `validatePaymasterUserOp` or `postOp`. The code existed as dead storage and dead functions. The `AgentSponsorshipApplied` event was removed in a prior cleanup (see line 169 comment in SuperPaymaster.sol).

The full wiring was intended for the **V5.1 `_consumeCredit()` kernel**, which lives in `feature/v5.1-consume-credit` worktree and was never merged to main.

---

## What Is Retained (NOT deleted)

These V5 agent integration points remain in SuperPaymaster:

- `address public agentIdentityRegistry` — ERC-8004 agent NFT registry
- `address public agentReputationRegistry` — agent reputation registry  
- `function setAgentRegistries(address, address)` — owner setter
- `function isRegisteredAgent(address)` — checks agent NFT balance > 0
- `function isEligibleForSponsorship(address)` — SBT holder OR registered agent (dual-channel)
- `_submitSponsorshipFeedback()` in postOp — calls `IAgentReputationRegistry.giveFeedback()`

---

## Code Deleted from `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol`

### Storage variables (2 slots → __gap increases by 2)

```solidity
// F1: Agent Sponsorship Policy
mapping(address => ISuperPaymaster.AgentSponsorshipPolicy[]) public agentPolicies; // operator => policies
mapping(address => mapping(uint256 => uint256)) private _agentDailySpend; // operator => day => USD spent
```

### Constants

```solidity
uint256 internal constant MAX_AGENT_POLICIES = 10;
```

### Functions

```solidity
/// @notice Set agent sponsorship policies for an operator (sorted by minReputationScore desc)
function setAgentPolicies(ISuperPaymaster.AgentSponsorshipPolicy[] calldata policies) external override {
    _requireSuperOperatorRole();
    if (policies.length > MAX_AGENT_POLICIES) revert InvalidConfiguration();
    delete agentPolicies[msg.sender];
    for (uint256 i = 0; i < policies.length; i++) {
        if (policies[i].sponsorshipBPS > BPS_DENOMINATOR) revert InvalidConfiguration();
        agentPolicies[msg.sender].push(policies[i]);
    }
    emit AgentPoliciesUpdated(msg.sender, policies.length);
}

/// @notice Get the sponsorship rate for an agent from an operator
/// @return bps Sponsorship rate in basis points (0 = no sponsorship)
function getAgentSponsorshipRate(address agent, address operator) external view override returns (uint256 bps) {
    if (!isRegisteredAgent(agent)) return 0;
    uint256 agentScore;
    address repReg = agentReputationRegistry;
    if (repReg != address(0)) {
        address[] memory empty = new address[](0);
        (, int128 avg) = IAgentReputationRegistry(repReg).getSummary(
            uint256(uint160(agent)), empty, bytes32(0), bytes32(0)
        );
        if (avg > 0) agentScore = uint256(int256(avg));
    }
    ISuperPaymaster.AgentSponsorshipPolicy[] storage policies = agentPolicies[operator];
    for (uint256 i = 0; i < policies.length; i++) {
        if (agentScore >= policies[i].minReputationScore && policies[i].sponsorshipBPS > bps) {
            bps = policies[i].sponsorshipBPS;
        }
    }
}
```

### Storage gap adjustment

```solidity
// Before deletion: __gap[34] (slots 27-28 used by agentPolicies + _agentDailySpend)
// After deletion:  __gap[36] (2 slots freed)
uint256[34] private __gap;  →  uint256[36] private __gap;
```

---

## Code Deleted from `contracts/src/interfaces/ISuperPaymaster.sol`

### Struct

```solidity
// V5: Agent Sponsorship Policy (tiered sponsorship for ERC-8004 agents)
struct AgentSponsorshipPolicy {
    uint128 minReputationScore;
    uint64  sponsorshipBPS;   // 10000 = 100%
    uint64  maxDailyUSD;      // USD * 1e6
}
```

### Event

```solidity
event AgentPoliciesUpdated(address indexed operator, uint256 policyCount);
```

### Interface functions

```solidity
function setAgentPolicies(AgentSponsorshipPolicy[] calldata policies) external;
function getAgentSponsorshipRate(address agent, address operator) external view returns (uint256 bps);
```

---

## Re-implementation Notes

When re-implementing this feature (V5.2 or later):

1. **Don't use per-operator dynamic arrays** — they're expensive to iterate on-chain and hard to paginate
2. **Consider a flat mapping**: `mapping(address operator => mapping(uint128 minScore => uint64 bps))` with a separate sorted key list
3. **Daily USD cap tracking** via `_agentDailySpend[operator][block.timestamp / 1 days]` is correct but needs explicit cleanup (or TTL-based reset) to avoid unbounded storage growth
4. **Wire up `_applyAgentSponsorship` in postOp** — the discount must reduce the aPNTs charged, not just return a BPS rate
5. **The V5.1 `_consumeCredit()` kernel** in `feature/v5.1-consume-credit` is the intended integration point — review that branch for the full billing flow

---

*This document is a reference for future re-implementation. The removed code was dead (never called in validatePaymasterUserOp or postOp) and is safe to delete without behavioral change.*

# SuperPaymaster API Reference

**Version**: `SuperPaymaster-5.4.0` (release `v5.4.0`)

> This document covers the full public API as of `v5.4.0-beta.1`, including V3/V4 baseline
> functions and all V5.x additions (agent-native gas sponsorship, x402 settlement,
> ERC-8004 dual-channel eligibility, and agent sponsorship policies).
>
> **v5.4 god-split note:** the on-chain `version()` strings are now `SuperPaymaster-5.4.0`
> and `Registry-5.4.0`. The v5.4 implementation extracts the x402 settlement functions into a
> **standalone [`X402Facilitator`](#x402facilitator-standalone-contract--v54)** contract and adds a
> standalone **[`PolicyRegistry`](#policyregistry-standalone-contracts)**, which is versioned
> independently. The `settleX402Payment*` entries below remain documented for the SP-embedded
> path but are **superseded by `X402Facilitator`** in v5.4.

---

## Contract Information

| Field | Value |
|-------|-------|
| **Version** | `SuperPaymaster-5.4.0` (release `v5.4.0`) |
| **Sepolia Proxy** | `0x030025f40d509b1a99547bAEb3795bD27F7182b7` |
| **Sepolia Impl** | `0x24a94572cfB6Ca6C8dE107431043556D461d8cFf` |
| **X402Facilitator (Sepolia)** | `0x326Fc3413c8A0185b0179B971C69813B6dFD971B` |
| **PolicyRegistry 1.0.0 (Sepolia, historical)** | `0x8c2488d46d5447418558c38AA6441720df656094` |
| **TimelockController (Sepolia)** | `0xB734df3c0A1809bc06708512363D368Ac51dF1A2` |
| **MicroPaymentChannel (Sepolia)** | `0x405851A141Cde827E33247d4D4089Af2814c2FF5` |
| **AgentIdentityRegistry (Sepolia)** | `0x8004A818BFB912233c491871b3d84c89A494BD9e` |
| **AgentReputationRegistry (Sepolia)** | `0x8004B663056A597Dffe9eCcC1965A193B7388713` |
| **EntryPoint** | v0.7 — `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |
| **Upgrade pattern** | UUPS (ERC1967Proxy) |
| **Solidity** | 0.8.33, optimizer 10,000 runs, Cancun EVM, via-IR |

---

## Data Structures

### OperatorConfig (struct)

Packed into 4 storage slots for gas efficiency.

```solidity
struct OperatorConfig {
    // Slot 0: HOT (validation critical)
    uint128 aPNTsBalance;   // gas collateral in aPNTs (cap ~3.4e38)
    uint96  exchangeRate;   // xPNTs:aPNTs rate (1e18 = 1:1)
    bool    isConfigured;
    bool    isPaused;
    // 2 bytes remaining

    // Slot 1: WARM
    address xPNTsToken;     // community gas token to charge users
    uint32  reputation;     // reputation score (max 4 billion)
    uint48  minTxInterval;  // minimum seconds between user ops (rate limit)

    // Slot 2: COLD
    address treasury;       // receives user xPNTs payments

    // Slot 3+: Stats
    uint256 totalSpent;
    uint256 totalTxSponsored;
}
```

### SlashRecord (struct)

```solidity
struct SlashRecord {
    uint256  timestamp;
    uint256  amount;
    uint256  reputationLoss;
    string   reason;
    SlashLevel level;
}
```

### AgentSponsorshipPolicy (struct) — V5

Defines a tiered sponsorship rule for ERC-8004 registered agents.

```solidity
struct AgentSponsorshipPolicy {
    uint128 minReputationScore; // minimum agent reputation to qualify
    uint64  sponsorshipBPS;     // discount in basis points (10000 = 100% free)
    uint64  maxDailyUSD;        // USD cap per day (scaled by 1e6); 0 = unlimited
}
```

### SlashLevel (enum)

```solidity
enum SlashLevel {
    WARNING,  // reputation -10, no balance slash
    MINOR,    // reputation -20, 10% balance slash (BLS: capped at 30%)
    MAJOR     // reputation -50, full balance slash, operator paused
}
```

### UserOperatorState (struct)

Packed user state per operator (1 storage slot).

```solidity
struct UserOperatorState {
    uint48 lastTimestamp; // last op timestamp for rate limiting
    bool   isBlocked;     // blacklist flag
}
```

### PriceCache (struct)

```solidity
struct PriceCache {
    int256  price;      // ETH/USD price (8 decimals)
    uint256 updatedAt;  // unix timestamp of last update
    uint80  roundId;    // Chainlink round ID (0 for DVT updates)
    uint8   decimals;   // oracle decimals (typically 8)
}
```

---

## Storage Layout — V5.3

SuperPaymaster uses UUPS upgradeable storage (OZ v5.0.2 pattern):

| Slot | Variable | Notes |
|------|----------|-------|
| 0 | `_owner` (Ownable) | traditional slot |
| 1 | `_status` (ReentrancyGuard) | traditional slot |
| 2 | `APNTS_TOKEN` | |
| 3 | `xpntsFactory` | |
| 4 | `treasury` | |
| 5 | `operators` mapping | |
| 6 | `userOpState` mapping | |
| 7 | `sbtHolders` mapping | |
| 8 | `slashHistory` mapping | |
| 9 | `aPNTsPriceUSD` | default 0.02 ether |
| 10 | `cachedPrice` (PriceCache) | 2 slots |
| 12 | `protocolFeeBPS` | default 1000 (10%) |
| 13 | `BLS_AGGREGATOR` | |
| 14 | `totalTrackedBalance` | |
| 15 | `protocolRevenue` | |
| 16 | `pendingDebts` mapping | |
| 17 | `priceStalenessThreshold` | |
| 18 | `oracleDecimals` | |
| **V5 additions (8 new slots):** | | |
| 19 | `agentIdentityRegistry` | ERC-8004 agent NFT registry |
| 20 | `agentReputationRegistry` | ERC-8004 reputation registry |
| 21 | `facilitatorFeeBPS` | default x402 facilitator fee |
| 22 | `operatorFacilitatorFees` mapping | per-operator fee override |
| 23 | `x402SettlementNonces` mapping | replay prevention |
| 24 | `facilitatorEarnings` mapping | operator => asset => amount |
| 25 | `agentPolicies` mapping | operator sponsorship tiers |
| 26 | `_agentDailySpend` mapping | daily USD spend tracker |
| 27–66 | `__gap[40]` | UUPS upgrade safety (was 50, consumed 8 for V5, then 2 for immutables note) |

> **Note:** `REGISTRY`, `ETH_USD_PRICE_FEED`, and `entryPoint` are **immutable** — stored in implementation bytecode, not proxy storage.

---

## PaymasterAndData Format

For ERC-4337 v0.7, the `paymasterAndData` field layout is:

```
| Paymaster (20) | VerificationGasLimit (16) | PostOpGasLimit (16) | Operator (20) | [MaxRate (32)] |
```

- Bytes 0–19: SuperPaymaster proxy address
- Bytes 20–51: gas limits (packed by EntryPoint v0.7)
- Bytes 52–71: operator address (`PAYMASTER_DATA_OFFSET = 52`)
- Bytes 72–103: optional `maxRate` (uint256) — rate commitment for rug-pull protection (`RATE_OFFSET = 72`)

```javascript
// viem example (no maxRate commitment):
const paymasterAndData = concat([
  SUPERPAYMASTER_ADDRESS,                              // 20 bytes
  pad(toHex(150000n), { size: 16, dir: 'left' }),     // verificationGasLimit
  pad(toHex(100000n), { size: 16, dir: 'left' }),     // postOpGasLimit
  OPERATOR_ADDRESS                                     // 20 bytes
]);

// With rate commitment:
const paymasterAndData = concat([
  SUPERPAYMASTER_ADDRESS,
  pad(toHex(150000n), { size: 16, dir: 'left' }),
  pad(toHex(100000n), { size: 16, dir: 'left' }),
  OPERATOR_ADDRESS,
  pad(toHex(maxExchangeRate), { size: 32, dir: 'left' }) // maxRate (uint256)
]);
```

---

## Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `PRICE_CACHE_DURATION` | 300 | seconds; price cache TTL reference |
| `MIN_ETH_USD_PRICE` | `100 * 1e8` | minimum valid Chainlink price |
| `MAX_ETH_USD_PRICE` | `100_000 * 1e8` | maximum valid Chainlink price |
| `PAYMASTER_DATA_OFFSET` | 52 | operator address byte offset in paymasterAndData |
| `RATE_OFFSET` | 72 | maxRate byte offset in paymasterAndData |
| `BPS_DENOMINATOR` | 10000 | basis points denominator |
| `MAX_PROTOCOL_FEE` | 2000 | 20% hardcap on protocolFeeBPS |
| `VALIDATION_BUFFER_BPS` | 1000 | 10% safety buffer applied during validation |
| `MAX_FACILITATOR_FEE` | 500 | 5% hardcap on x402 facilitator fees |
| `MAX_AGENT_POLICIES` | 10 | max sponsorship policies per operator |

---

## ERC-4337 Paymaster Functions

### validatePaymasterUserOp

Called exclusively by EntryPoint during UserOperation validation.

```solidity
function validatePaymasterUserOp(
    PackedUserOperation calldata userOp,
    bytes32 userOpHash,
    uint256 maxCost
) external returns (bytes memory context, uint256 validationData)
```

**Access:** `onlyEntryPoint`, `nonReentrant`

**Validation order:**
1. Extract operator from `paymasterAndData[52:72]`
2. Require `isConfigured && !isPaused`
3. Require `isEligibleForSponsorship(userOp.sender)` — SBT holder OR registered ERC-8004 agent (V5.3)
4. Require `!isBlocked` and enforce `minTxInterval` via `validAfter`
5. Enforce `maxRate` commitment if provided at offset 72
6. Optimistic aPNTs deduction with 10% fee + 10% validation buffer
7. Returns context `(xPNTsToken, xPNTsAmount, sender, aPNTsAmount, userOpHash, operator)` and `validUntil = cachedPrice.updatedAt + priceStalenessThreshold`

---

### postOp

Called by EntryPoint after UserOperation execution.

```solidity
function postOp(
    PostOpMode mode,
    bytes calldata context,
    uint256 actualGasCost,
    uint256 actualUserOpFeePerGas
) external
```

**Access:** `onlyEntryPoint`, `nonReentrant`

**Behavior:**
- Always updates `lastTimestamp` for rate limiting (even on revert mode)
- Skips processing if `mode == postOpReverted`
- Recalculates actual aPNTs cost with protocol fee markup
- Refunds excess to operator; records xPNTs debt to user via `IxPNTsToken.recordDebt()`
- Falls back to `pendingDebts` if debt recording fails
- Calls `_submitSponsorshipFeedback()` for registered agents (F2)

---

## Operator Functions

### configureOperator

Configure billing settings. Caller must hold `ROLE_PAYMASTER_SUPER` and `ROLE_COMMUNITY` in Registry.

```solidity
function configureOperator(
    address xPNTsToken,
    address _opTreasury,
    uint256 exchangeRate
) external
```

**Events:** `OperatorConfigured(operator, xPNTsToken, treasury, exchangeRate)`

---

### deposit

Deposit aPNTs as gas collateral (legacy pull mode — requires ERC-20 approval).

```solidity
function deposit(uint256 amount) external nonReentrant
```

**Access:** Must hold `ROLE_PAYMASTER_SUPER` in Registry

**Events:** `OperatorDeposited(operator, amount)`

---

### depositFor

Deposit aPNTs on behalf of a specific operator (secure push mode).

```solidity
function depositFor(address targetOperator, uint256 amount) external nonReentrant
```

**Events:** `OperatorDeposited(targetOperator, amount)`

---

### onTransferReceived

ERC1363 callback — handles push-mode deposits where the token calls the receiver.

```solidity
function onTransferReceived(
    address,
    address from,
    uint256 value,
    bytes calldata
) external nonReentrant returns (bytes4)
```

**Access:** Only callable by `APNTS_TOKEN` contract

**Returns:** `this.onTransferReceived.selector`

**Events:** `OperatorDeposited(from, value)`

---

### withdraw

Withdraw aPNTs collateral.

```solidity
function withdraw(uint256 amount) external nonReentrant
```

**Events:** `OperatorWithdrawn(operator, amount)`

---

### setOperatorLimits

Set minimum transaction interval for rate limiting.

```solidity
function setOperatorLimits(uint48 _minTxInterval) external
```

**Access:** Must hold `ROLE_PAYMASTER_SUPER` in Registry

**Events:** `OperatorMinTxIntervalUpdated(operator, minTxInterval)`

---

## V5.x — Agent Sponsorship Functions

### isEligibleForSponsorship

V5.3 dual-channel eligibility check. Returns `true` if the user is an SBT holder **or** a registered ERC-8004 agent NFT holder.

```solidity
function isEligibleForSponsorship(address user) external view returns (bool)
```

**Implementation:** `sbtHolders[user] || isRegisteredAgent(user)`

---

### isRegisteredAgent

Check if an address holds at least one ERC-8004 Agent NFT in the configured identity registry.

```solidity
function isRegisteredAgent(address account) external view returns (bool)
```

**Returns:** `false` if `agentIdentityRegistry == address(0)` or `balanceOf` reverts.

---

### setAgentPolicies

Set tiered agent sponsorship policies for the calling operator. Policies should be sorted by `minReputationScore` descending for optimal matching. Up to `MAX_AGENT_POLICIES` (10) entries.

```solidity
function setAgentPolicies(
    ISuperPaymaster.AgentSponsorshipPolicy[] calldata policies
) external
```

**Access:** Must hold `ROLE_PAYMASTER_SUPER` in Registry

**Events:** `AgentPoliciesUpdated(operator, policyCount)`

---

### getAgentSponsorshipRate

Query the effective sponsorship BPS for an agent from an operator, accounting for reputation and daily caps.

```solidity
function getAgentSponsorshipRate(
    address agent,
    address operator
) external view returns (uint256 bps)
```

**Returns:** Basis points discount (0 = no sponsorship, 10000 = 100% free). Returns 0 if agent is not registered, no matching policy, or daily cap exhausted.

---

## V5.x — x402 Payment Settlement Functions

> **⚠️ v5.4 god-split:** As of `v5.4.0-beta.1`, x402 settlement has been **extracted into the
> standalone [`X402Facilitator`](#x402facilitator-standalone-contract--v54)** contract (Sepolia
> `0x326Fc3413c8A0185b0179B971C69813B6dFD971B`). The functions below document the legacy
> SuperPaymaster-embedded path (still present in the impl bytecode); **new integrations should
> target `X402Facilitator`**, whose canonical signatures are documented in its own section. The
> standalone `settleX402Payment` signature additionally takes a `maxFee` argument and settles via
> EIP-3009 `receiveWithAuthorization`.

### settleX402Payment

Settle an x402 HTTP payment via EIP-3009 `transferWithAuthorization` (native USDC path, ~161K gas, 19% more efficient than Permit2).

```solidity
function settleX402Payment(
    address from,
    address to,
    address asset,
    uint256 amount,
    uint256 validAfter,
    uint256 validBefore,
    bytes32 salt,
    bytes calldata signature
) external nonReentrant returns (bytes32 settlementId)
```

**Access:** Caller must hold `ROLE_PAYMASTER_SUPER` in Registry (acts as facilitator)

**C-03 recipient binding:** the contract derives the EIP-3009 nonce as
`nonce = keccak256(abi.encode(to, salt))`. The payer signs the EIP-3009 `TransferWithAuthorization`
over **that derived nonce** (with `to = SuperPaymaster`), then the facilitator passes **`salt`**
(not a raw nonce). If a facilitator swaps `to`, a different nonce is derived and the EIP-3009
signature no longer recovers `from` → the transfer reverts.

**Parameters:**
- `from` — payer address (must have signed the EIP-3009 authorization)
- `to` — final payee / service provider address (bound into the nonce)
- `asset` — ERC-20 token implementing EIP-3009 (e.g. USDC)
- `amount` — gross transfer amount
- `validAfter`, `validBefore` — authorization time window (EIP-3009)
- `salt` — random bytes32; combined with `to` to derive the recipient-bound nonce
- `signature` — EIP-3009 authorization signature from `from` over `keccak256(abi.encode(to, salt))`

**Returns:** `settlementId = keccak256(from, to, asset, amount, nonce)` (derived nonce)

**Fee:** Deducts `facilitatorFeeBPS` (or per-operator override) from `amount` before forwarding net to `to`. Fee credited to `facilitatorEarnings[msg.sender][asset]`.

**Events:** `X402PaymentSettled(from, to, asset, amount, fee, nonce)`

**Errors:** `NonceAlreadyUsed`, `Unauthorized`

---

### settleX402PaymentDirect

Settle an x402 payment for an **xPNTs token** (factory-deployed) via `transferFrom`. Since the
SuperPaymaster holds an auto-allowance over every xPNTs holder, the consent gate lives here:
the payer **must** sign an EIP-712 `X402PaymentAuthorization` (C-02 hardening).

```solidity
function settleX402PaymentDirect(
    address from,
    address to,
    address asset,
    uint256 amount,
    uint256 maxFee,
    uint256 validBefore,
    bytes32 nonce,
    bytes calldata signature
) external nonReentrant returns (bytes32 settlementId)
```

**Access:** Caller must hold `ROLE_PAYMASTER_SUPER`, AND be on the xPNTs token's
`approvedFacilitators` whitelist (P0-12b). `asset` must be a factory-minted xPNTs (P0-12a).

**Signature (C-02, required):** `from` must sign EIP-712 `X402PaymentAuthorization(address from,address to,address asset,uint256 amount,uint256 maxFee,uint256 validBefore,bytes32 nonce)` over the SuperPaymaster proxy domain (`name:"SuperPaymaster", version:"1"`). Verified by `SignatureCheckerLib` (EOA + ERC-1271). The contract also enforces `block.timestamp <= validBefore` and `fee <= maxFee`.

**Returns:** `settlementId = keccak256(from, to, asset, amount, nonce)`

**Events:** `X402PaymentSettled(from, to, asset, amount, fee, nonce)`

**Errors:** `InvalidX402Signature`, `X402AuthExpired`, `X402FeeExceedsMax`, `InvalidConfiguration` (xpntsFactory unset), `InvalidXPNTsToken`, `NonceAlreadyUsed`, `Unauthorized`

---

### withdrawFacilitatorEarnings

Withdraw accumulated facilitator fee earnings for a given asset.

```solidity
function withdrawFacilitatorEarnings(address asset) external nonReentrant
```

**Access:** Any operator who has accumulated earnings

**Events:** `FacilitatorEarningsWithdrawn(operator, asset, amount)`

---

## Oracle & Price Functions

### updatePrice

Pull latest price from Chainlink oracle and update the internal cache.

```solidity
function updatePrice() external
```

**Access:** Public (typically called by keeper)

**Events:** `PriceUpdated(price, timestamp, by)`

**Errors:** `OracleError` — if Chainlink call fails, price out of bounds, or data is stale.

---

### updatePriceDVT

Update price via BLS/DVT consensus (Chainlink fallback path).

```solidity
function updatePriceDVT(
    int256 price,
    uint256 updatedAt,
    bytes calldata proof
) external
```

**Access:** `BLS_AGGREGATOR` or `owner()`

**Validation:**
- `updatedAt` must be strictly greater than `cachedPrice.updatedAt`
- Must be within 2 hours of current time
- Price must be within `[MIN_ETH_USD_PRICE, MAX_ETH_USD_PRICE]`
- If Chainlink is live and recent, rejects prices deviating >20% from Chainlink

**Events:** `PriceUpdated(price, updatedAt, by)`

---

## SBT Registry Functions

> **ENDUSER authorization:** a per-community MySBT membership can outlive the ENDUSER role while
> another Registry role is held. Integrators must check both
> `MySBT.verifyCommunityMembership(user, community)` and
> `Registry.hasRole(ROLE_ENDUSER, user)`. If final-role cleanup is pending, wait for every
> remaining operator role's lock (`block.timestamp >= lockedAt + roleLockDuration`; defaults to
> 30 days, with the DVT guardian-exit gate also satisfied), exit to `userRoleCount == 0`, then call
> `reconcileMembershipDeactivation(user)`. If `pendingSBTBurn` is set, unpause MySBT and call
> `reconcileSBTBurn(user)`. Sepolia has no historical `SBTBurnFailed` events; Optimism is fresh.
> A community can also grant COMMUNITY (zero default lock) or an operator role through
> `safeMintForRole`. Exit and reconciliation are separate transactions, so a sponsor that keeps
> funding grants can re-grant after each exit and delay recovery indefinitely; recovery is not
> bounded against an actively funded sponsor. All of this requires a MySBT cleanup call to have
> failed first (MySBT paused or a reverting implementation).

### updateSBTStatus

Update the global SBT holder flag for a user (called by Registry on MySBT mint/burn events).

```solidity
function updateSBTStatus(address user, bool status) external
```

**Access:** `REGISTRY` contract only

---

### updateBlockedStatus

Batch-update the user blocklist for a specific operator (called by Registry via DVT credit exhaustion sync).

```solidity
function updateBlockedStatus(
    address operator,
    address[] calldata users,
    bool[] calldata statuses
) external
```

**Access:** `REGISTRY` contract only

**Events:** `UserBlockedStatusUpdated(operator, user, isBlocked)` per entry

---

## Slash Functions

### slashOperator

Owner-governed slash with no BPS hardcap.

```solidity
function slashOperator(
    address operator,
    ISuperPaymaster.SlashLevel level,
    uint256 penaltyAmount,
    string calldata reason
) external onlyOwner
```

**Events:** `OperatorSlashed(operator, amount, level, by)`, `ReputationUpdated(operator, newScore, by)`

---

### executeSlashWithBLS

BLS-consensus-triggered slash (DVT path). Enforces 30% aPNTs slash hardcap.

```solidity
function executeSlashWithBLS(
    address operator,
    ISuperPaymaster.SlashLevel level,
    bytes calldata proof
) external
```

**Access:** `BLS_AGGREGATOR` only

**Events:** `SlashExecutedWithProof(operator, level, penalty, proofHash, timestamp)`, `OperatorSlashed(...)`, `ReputationUpdated(...)`

---

### getSlashHistory

```solidity
function getSlashHistory(address operator)
    external view
    returns (ISuperPaymaster.SlashRecord[] memory)
```

---

### getSlashCount

```solidity
function getSlashCount(address operator) external view returns (uint256)
```

---

### getLatestSlash

```solidity
function getLatestSlash(address operator)
    external view
    returns (ISuperPaymaster.SlashRecord memory)
```

**Errors:** `NoSlashHistory`

---

## Pending Debt Recovery

### retryPendingDebt

Retry recording a pending xPNTs debt that failed during `postOp`.

```solidity
function retryPendingDebt(address token, address user) external nonReentrant
```

**Events:** `PendingDebtRetried(token, user, amount)`

**Errors:** `NoPendingDebt`

---

### clearPendingDebt

Admin escape hatch to clear a stuck pending debt without recording it.

```solidity
function clearPendingDebt(address token, address user) external onlyOwner
```

**Events:** `PendingDebtCleared(token, user, amount)`

---

## View Functions

### getAvailableCredit

Get remaining credit for a user under a specific xPNTs token (aPNTs units).

```solidity
function getAvailableCredit(address user, address token)
    external view returns (uint256)
```

**Logic:** `REGISTRY.getCreditLimit(user) - debtInAPNTs` (floored at 0)

---

### operators

Get operator configuration struct.

```solidity
function operators(address operator)
    external view
    returns (
        uint128 aPNTsBalance,
        uint96  exchangeRate,
        bool    isConfigured,
        bool    isPaused,
        address xPNTsToken,
        uint32  reputation,
        uint48  minTxInterval,
        address treasury,
        uint256 totalSpent,
        uint256 totalTxSponsored
    )
```

---

### sbtHolders

```solidity
function sbtHolders(address user) external view returns (bool)
```

---

### userOpState

```solidity
function userOpState(address operator, address user)
    external view
    returns (uint48 lastTimestamp, bool isBlocked)
```

---

### pendingDebts

```solidity
function pendingDebts(address token, address user) external view returns (uint256)
```

---

### x402SettlementNonces

```solidity
function x402SettlementNonces(bytes32 nonce) external view returns (bool)
```

---

### facilitatorEarnings

```solidity
function facilitatorEarnings(address operator, address asset) external view returns (uint256)
```

---

### agentPolicies

```solidity
function agentPolicies(address operator, uint256 index)
    external view
    returns (ISuperPaymaster.AgentSponsorshipPolicy memory)
```

---

### cachedPrice

```solidity
function cachedPrice()
    external view
    returns (int256 price, uint256 updatedAt, uint80 roundId, uint8 decimals)
```

---

## Admin Functions (Owner Only)

| Function | Signature | Description |
|----------|-----------|-------------|
| `setAPNTsToken` | `(address)` | Update aPNTs token address |
| `setAPNTSPrice` | `(uint256)` | Update aPNTs USD price (18 decimals; default 0.02 ether = $0.02) |
| `setProtocolFee` | `(uint256 bps)` | Set protocol fee BPS (max 2000 = 20%) |
| `setTreasury` | `(address)` | Set protocol treasury address |
| `setXPNTsFactory` | `(address)` | Set xPNTs factory for binding verification |
| `setBLSAggregator` | `(address)` | Set trusted BLS aggregator for DVT slash |
| `setOperatorPaused` | `(address operator, bool paused)` | Emergency pause/unpause operator |
| `updateReputation` | `(address operator, uint256 score)` | Manually set operator reputation score |
| `withdrawProtocolRevenue` | `(address to, uint256 amount)` | Withdraw accumulated protocol fees |
| `setAgentRegistries` | `(address identity, address reputation)` | Set ERC-8004 agent registries (V5) |
| `setFacilitatorFeeBPS` | `(uint256 fee)` | Set default x402 facilitator fee BPS (max 500 = 5%) |
| `setOperatorFacilitatorFee` | `(address operator, uint256 fee)` | Set per-operator facilitator fee override |

---

## Events

The event signatures below reflect SuperPaymaster 5.5.2. `by` is `msg.sender` at SP,
including when the proxy delegates to the admin implementation.

Pause/unpause reason codes are `1 OWNER_PAUSE`, `2 GUARDIAN_PAUSE`,
`3 OWNER_UNPAUSE`, `4 UNDERSTAKED`, and `5 SLASH`.

`OperatorPaused`, `OperatorUnpaused`, and `SlashCancelled` are emitted on transitions
only. Repeating a pause/unpause or cancelling with no pending flag or queue record
emits no corresponding event. Clearing a legacy pending flag or an expired guardian
queue does emit `SlashCancelled`. `SBTStatusUpdated` is emitted on every successful
call to `updateSBTStatus`, even when the status is unchanged.

### Core Events

```solidity
event OperatorDeposited(address indexed operator, uint256 amount);
event OperatorWithdrawn(address indexed operator, uint256 amount);
event OperatorConfigured(address indexed operator, address xPNTsToken, address treasury, uint256 exchangeRate);
event OperatorPaused(address indexed operator, address indexed by, uint8 reason);
event OperatorUnpaused(address indexed operator, address indexed by, uint8 reason);
event OperatorMinTxIntervalUpdated(address indexed operator, uint48 minTxInterval);
event UserBlockedStatusUpdated(address indexed operator, address indexed user, bool isBlocked);
event OperatorSlashed(address indexed operator, uint256 amount, SlashLevel level, address by);
event ReputationUpdated(address indexed operator, uint256 newScore, address by);
event SBTStatusUpdated(address indexed user, bool status);
event TransactionSponsored(address indexed operator, address indexed user, uint256 aPNTsCost, uint256 xPNTsCost);
```

### Oracle Events

```solidity
event PriceUpdated(int256 indexed price, uint256 indexed timestamp, address by);
event PriceModeChanged(uint8 oldMode, uint8 newMode, address by);
event OracleFallbackTriggered(uint256 timestamp);
event APNTsPriceUpdated(uint256 oldPrice, uint256 newPrice);
```

### Slash Events

```solidity
event SlashQueued(address indexed operator, address indexed by);
event SlashCancelled(address indexed operator, address indexed by);
event SlashExecutedWithProof(
    address indexed operator,
    ISuperPaymaster.SlashLevel level,
    uint256 penalty,
    bytes32 proofHash,
    uint256 timestamp
);
```

### Debt Events

```solidity
event DebtRecordFailed(address indexed token, address indexed user, uint256 amount);
event PendingDebtRetried(address indexed token, address indexed user, uint256 amount);
event PendingDebtCleared(address indexed token, address indexed user, uint256 amount);
```

### Admin Events

```solidity
event APNTsTokenUpdated(address indexed oldToken, address indexed newToken);
event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
event BLSAggregatorUpdated(address indexed oldAggregator, address indexed newAggregator);
event ProtocolRevenueWithdrawn(address indexed to, uint256 amount);
```

### V5 Events

```solidity
event AgentPoliciesUpdated(address indexed operator, uint256 policyCount);
event X402PaymentSettled(address indexed from, address indexed to, address asset, uint256 amount, uint256 fee, bytes32 nonce);
event FacilitatorFeeUpdated(uint256 oldFee, uint256 newFee);
event AgentRegistriesUpdated(address identityRegistry, address reputationRegistry);
event FacilitatorEarningsWithdrawn(address indexed operator, address indexed asset, uint256 amount);
```

---

## Errors

```solidity
error Unauthorized();
error InvalidAddress();
error InvalidConfiguration();
error InsufficientBalance(uint256 available, uint256 required);
error DepositNotVerified();
error OracleError();
error NoSlashHistory();
error InsufficientRevenue();
error InvalidXPNTsToken();
error FactoryVerificationFailed();
error AmountExceedsUint128();
error ScoreExceedsUint32();
error NoPendingDebt();

// V5 errors
error NonceAlreadyUsed();
error InvalidFee();
```

---

## MicroPaymentChannel (Companion Contract)

The `MicroPaymentChannel` contract is a separate deployment that provides unidirectional payment channel streaming for agent-to-service-provider micropayments. It is referenced by the x402 facilitator SDK but is **not** part of SuperPaymaster's on-chain code.

**Sepolia address:** `0xbD1807328Dd654512B13d6320C9Cc78685a405Ed`

**Key functions:**

| Function | Description |
|----------|-------------|
| `openChannel(payee, token, deposit, salt, authorizedSigner)` | Open a new channel; returns `channelId` |
| `settle(channelId, cumulativeAmount, signature)` | Payee submits a cumulative voucher to collect payment |
| `topUp(channelId, amount)` | Payer adds funds to an open channel |
| `requestClose(channelId)` | Payer initiates 15-minute dispute window |
| `closeChannel(channelId, cumulativeAmount, signature)` | Payee submits final voucher during close window |
| `withdrawAfterTimeout(channelId)` | Payer withdraws remaining funds after timeout |
| `getChannel(channelId)` | View channel state |

**Channel voucher EIP-712 typehash:**

```
Voucher(bytes32 channelId, uint128 cumulativeAmount)
```

**Events:** `ChannelOpened`, `ChannelSettled`, `ChannelTopUp`, `CloseRequested`, `ChannelClosed`, `ChannelWithdrawn`

---

## X402Facilitator (Standalone Contract) — v5.4

**Version:** `X402Facilitator-1.0.0` · **Sepolia:** `0x326Fc3413c8A0185b0179B971C69813B6dFD971B`
· **Type:** Standalone, non-upgradeable (`Ownable` + `ReentrancyGuard`)

The `v5.4` god-split extracts x402 settlement out of SuperPaymaster into this dedicated contract.
It has **zero SuperPaymaster-storage dependency** — it only reads external contracts (Registry role
gate, xPNTs factory whitelist, ERC-3009/ERC-20 token transfers) and owns its own copies of the four
x402 storage vars (`facilitatorFeeBPS`, `operatorFacilitatorFees`, `x402SettlementNonces`,
`facilitatorEarnings`). Operator/facilitator calls are gated on
`Registry.hasRole(ROLE_PAYMASTER_SUPER, caller)`.

### settleX402Payment (X402Facilitator)

Settle an x402 HTTP payment via EIP-3009 `receiveWithAuthorization` (USDC-native path).

```solidity
function settleX402Payment(
    address from, address to, address asset, uint256 amount, uint256 maxFee,
    uint256 validAfter, uint256 validBefore, bytes32 salt, bytes calldata signature
) external nonReentrant returns (bytes32 settlementId)
```

- **Access:** caller must hold `ROLE_PAYMASTER_SUPER` in Registry.
- **Recipient + fee binding (C-03):** the contract derives the EIP-3009 nonce as
  `nonce = keccak256(abi.encode(to, maxFee, salt))`. The payer signs EIP-3009
  `ReceiveWithAuthorization` over that derived nonce (`to = X402Facilitator`); swapping `to` or
  `maxFee` derives a different nonce → signature no longer recovers `from` → revert.
- **Amount check:** reverts `X402AmountMismatch` if the post-transfer balance delta < `amount`.
- **Fee:** deducts `getEffectiveFacilitatorFee(msg.sender)` (per-operator override else global
  `facilitatorFeeBPS`), capped by `maxFee`; net `amount - fee` forwarded to `to`, fee credited to
  `facilitatorEarnings[msg.sender][asset]`.
- **Returns:** `settlementId = keccak256(abi.encode(from, to, asset, amount, nonce))`.
- **Events:** `X402PaymentSettled(from, to, asset, amount, fee, nonce)`.
- **Errors:** `Unauthorized`, `NonceAlreadyUsed`, `InvalidFee`, `X402FeeExceedsMax`,
  `X402AmountMismatch`.

### settleX402PaymentDirect (X402Facilitator)

Settle an x402 payment for a factory-deployed **xPNTs token** via `transferFrom` (auto-allowance).
Because xPNTs carry no token-level EIP-3009 authorization, the consent gate lives here: the payer
**must** sign an EIP-712 `X402PaymentAuthorization` (C-02).

```solidity
function settleX402PaymentDirect(
    address from, address to, address asset, uint256 amount,
    uint256 maxFee, uint256 validBefore, bytes32 nonce, bytes calldata signature
) external nonReentrant returns (bytes32 settlementId)
```

- **Access:** caller must hold `ROLE_PAYMASTER_SUPER` (P0-12), `asset` must be a factory xPNTs
  (`XPNTS_FACTORY.isXPNTs(asset)`, P0-12a), and caller must be on the xPNTs token's
  `approvedFacilitators` whitelist (P0-12b).
- **Signature (C-02, required):** `from` signs EIP-712
  `X402PaymentAuthorization(address from,address to,address asset,uint256 amount,uint256 maxFee,uint256 validBefore,bytes32 nonce)`
  over the **X402Facilitator** domain (`name:"X402Facilitator", version:"1"`), verified via
  `SignatureCheckerLib` (EOA + ERC-1271). Enforces `block.timestamp <= validBefore` and `fee <= maxFee`.
- **Returns:** `settlementId = keccak256(abi.encode(from, to, asset, amount, nonce))`.
- **Errors:** `X402AuthExpired`, `InvalidX402Signature`, `X402FeeExceedsMax`, `InvalidXPNTsToken`,
  `NonceAlreadyUsed`, `Unauthorized`, `InvalidConfiguration`.

### Fee model & admin (X402Facilitator)

| Function | Access | Purpose |
|----------|--------|---------|
| `setFacilitatorFeeBPS(uint256)` | `onlyOwner` | Global facilitator fee in BPS |
| `setOperatorFacilitatorFee(address, uint256)` | `onlyOwner` | Per-operator fee override |
| `getEffectiveFacilitatorFee(address)` → `uint256` | view | Operator override else global default |
| `withdrawFacilitatorEarnings(address asset)` | operator | Withdraw accrued fees for `asset` |
| `x402NonceKey(address asset, address from, bytes32 nonce)` → `bytes32` | pure | Off-chain nonce-key derivation helper |

**Events:** `FacilitatorFeeUpdated`, `FacilitatorEarningsWithdrawn`, `X402PaymentSettled`.

---

## PolicyRegistry standalone contracts

### HISTORICAL: PolicyRegistry 1.0.0

**Sepolia address:** `0x8c2488d46d5447418558c38AA6441720df656094`

This address runs `PolicyRegistry-1.0.0`. Integrations that use this historical deployment must use
its old ABI. In particular, it implements `getContractScope(address,address)`, not
`getTargetScope(address,address)`.

The complete 1.0.0 function set is:

| Category | Old function signatures |
|---|---|
| Constants and metadata | `DEFAULT_WINDOW()`, `ETH_SENTINEL()`, `version()`, `guardian()`, `timelock()` |
| Policy and counter reads | `checkPolicy(address,address,address,uint256,bytes4)`, `getAssetPolicy(address,address)`, `getAssetSpend(address,address)`, `getContractScope(address,address)`, `isSelectorAllowed(address,address,bytes4)`, `isFrozen(address)`, `isAuthorizedConsumer(address)` |
| Execution hook | `recordSpend(address,address,address,uint256,bytes4)` |
| Timelock mutations | `setAssetPolicy(address,address,(uint128,uint128,uint256,uint64))`, `setContractScope(address,address,(bool,bool,uint128,uint64,bytes4[]))`, `unfreezeSender(address)`, `setGuardian(address)`, `setConsumerAuthorization(address,bool)` |
| Immediate tightening | `tightenAssetPolicy(address,address,(uint128,uint128,uint256,uint64))`, `tightenContractScope(address,address,(bool,bool,uint128,uint64,bytes4[]))`, `freezeSender(address)` |

The old `getAssetSpend` output is `(uint128 spentInWindow, uint64 windowStart)`. The old
`getContractScope` output is
`(bool allowed, bool requireDVTAlways, uint128 velocityLimit, uint64 velocityWindow, bool configured)`.

### PolicyRegistry 3.0.2

**Address:** Deployed by the 5.5.0 manifest. No address is assigned yet.

**Type:** Standalone, non-upgradeable, and governed by an external `TimelockController` plus a
guardian.

PolicyRegistry 3.0.2 evaluates `(sender, target, asset, amount, selector)`. Its policy is opt-in.
An unconfigured asset or target adds no restriction, while a frozen sender always receives
`REJECT`. ETH uses `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`; `address(0)` is invalid.

#### 3.0.2 data model

- `AssetPolicy` is keyed by `(sender, asset)`. It contains `dvtTriggerAmount`,
  `perTxHardCap`, `dailyLimit`, `windowSeconds`, and `configured`.
- `ContractScope` is target-global and keyed by `(sender, target)`. It contains `allowed`,
  `requireDVTAlways`, `velocityWindow`, and `configured`.
- The target velocity limit is separate from `ContractScope`. It is keyed by
  `(sender, target, asset)` and contains `uint128 limit` plus `bool configured`.
- Asset counters are keyed by `(sender, asset)`. Target counters are keyed by
  `(sender, target, asset)`. Both use `uint256 spentInWindow` and `uint64 windowStart`.
- If a configured scope has `velocityWindow != 0`, a missing velocity entry for the requested
  asset fails closed with `REJECT`.
- A zero target velocity window disables velocity. `setTargetVelocity` and
  `tightenTargetVelocity` revert with `VelocityDisabled()` while disabled. Disabling a window
  invalidates all prior asset limits; after re-enabling, each asset needs a fresh timelocked
  `setTargetVelocity` before it can be enforced again.

`recordSpend` updates the asset counter only for a configured asset policy. It updates the target
counter only for a configured scope with a nonzero velocity window and a configured target velocity.

`getAssetSpend` and `getTargetSpend` return effective, window-aware spend: the amount is zero
after expiry. Target spend is also zero while velocity is disabled or its limit is stale.

#### 3.0.2 function selectors

The signatures use canonical ABI tuple syntax. Selectors were computed with
`~/.foundry/bin/cast sig`.

| Function signature | Selector | Return or access |
|---|---|---|
| `DEFAULT_WINDOW()` | `0x43a0c39f` | `uint64` |
| `ETH_SENTINEL()` | `0xb743be94` | `address` |
| `checkPolicy(address,address,address,uint256,bytes4)` | `0x969cb5da` | `(uint8,uint256)` |
| `recordSpend(address,address,address,uint256,bytes4)` | `0xa1a4a180` | Authorized consumer |
| `getAssetPolicy(address,address)` | `0x29210a4b` | `(uint128,uint128,uint256,uint64,bool)` |
| `getTargetScope(address,address)` | `0x7ac0774b` | `(bool,bool,uint64,bool)` |
| `getTargetVelocity(address,address,address)` | `0xcb9fa794` | `(uint128,bool)` |
| `isSelectorAllowed(address,address,bytes4)` | `0xb1655919` | `bool` |
| `getAssetSpend(address,address)` | `0x715904dd` | `(uint256,uint64)` |
| `getTargetSpend(address,address,address)` | `0x0c4752d2` | `(uint256,uint64)` |
| `isFrozen(address)` | `0xe5839836` | `bool` |
| `isAuthorizedConsumer(address)` | `0x7df732ea` | `bool` |
| `guardian()` | `0x452a9320` | `address` |
| `timelock()` | `0xd33219b4` | `address` |
| `version()` | `0x54fd4d50` | `string` |
| `setAssetPolicy(address,address,(uint128,uint128,uint256,uint64))` | `0xbe29f491` | Timelock |
| `setContractScope(address,address,(bool,bool,uint64,bytes4[]))` | `0xc28b58c1` | Timelock |
| `setTargetVelocity(address,address,address,uint128)` | `0xf8f33e86` | Timelock |
| `unfreezeSender(address)` | `0x53d8cb68` | Timelock |
| `tightenAssetPolicy(address,address,(uint128,uint128,uint256,uint64))` | `0x055b8e7b` | Guardian or timelock |
| `tightenContractScope(address,address,(bool,bool,uint64,bytes4[]))` | `0x7f6f42f0` | Guardian or timelock |
| `tightenTargetVelocity(address,address,address,uint128)` | `0xac0a0e81` | Guardian or timelock |
| `freezeSender(address)` | `0x7e19482e` | Guardian or timelock |
| `setGuardian(address)` | `0x8a0dac4a` | Timelock |
| `setConsumerAuthorization(address,bool)` | `0x6ef778ee` | Timelock |

The timelock-only setters can loosen or tighten after the external timelock delay.
`setContractScope` adds selectors without clearing the existing set. The guardian-or-timelock
functions provide the immediate tightening path. `tightenContractScope` preserves the velocity
window and removes its listed selectors. `tightenTargetVelocity` can only lower a fresh existing
limit and reverts while the window is zero.
`unfreezeSender` is timelock-only.

PolicyRegistry has no internal proposal queue. It does not implement `propose*`,
`executeProposal`, `cancelProposal`, `looseningEta`, or `LOOSEN_TIMELOCK`. The external
`TimelockController` owns scheduling, delay, execution, and cancellation.

#### 3.0.2 event topics

Topic 0 values were computed with `~/.foundry/bin/cast sig-event`.

| Event signature | Topic 0 |
|---|---|
| `AssetPolicySet(address,address,uint128,uint128,uint256,uint64)` | `0x5d9b9bcdce2cd939b17ac423b2aa97770271ecebda7bf7c45e7db25d980c52ae` |
| `ContractScopeSet(address,address,bool,bool,uint64)` | `0x9da60c6786d525ccc6003f478437c74ad59a8b556fb0fd5dec6dcd6f267c16c2` |
| `TargetVelocitySet(address,address,address,uint128)` | `0xa0cc9fdb8f54d3382e30589f0ae0733455166be350b0d2db1aa8e4f2e4b91b21` |
| `SelectorScopeSet(address,address,bytes4,bool)` | `0xdae56faaf89f401e21b133aee83453dde734ae5b8d6d672919900921f1e62780` |
| `PolicyTightened(address,address)` | `0x4d156b5f26f59392a109b67021b0a170f0ea10ac562c1538dee681f1727151e6` |
| `SenderFrozen(address,address)` | `0xbcc778b1735935d8f1de4988aa99c5a443739e2fb826dc7aa3f3bf64bb115fb8` |
| `SenderUnfrozen(address)` | `0xf70670b858d56ee8e00bdc112191de0411959259f47dcbc6977aace0aee11765` |
| `SpendRecorded(address,address,address,uint256,bytes4)` | `0xc8e3d7812ff5ee9233152255de3b82224861baad07a1550a51ccd7174f1e7f88` |
| `GuardianUpdated(address,address)` | `0x064d28d3d3071c5cbc271a261c10c2f0f0d9e319390397101aa0eb23c6bad909` |
| `ConsumerAuthorizationSet(address,bool)` | `0x5f7c8bcc9fe1f59809d268c8cf6b63a36c4aedb54e3a40628113344d5620dd45` |

#### Consumer reads

| Consumer | Required reads |
|---|---|
| SDK | Read `getAssetPolicy`, `getTargetScope`, `getTargetVelocity`, `isSelectorAllowed`, `getAssetSpend`, and `isFrozen`. Decode `spentInWindow` as `uint256`. Read pending operations from the external timelock. |
| DVT nodes | Read `getTargetScope` and `getTargetVelocity` together, plus the asset policy, selector permissions, frozen state, and `getAssetSpend` as `(uint256,uint64)`. |
| Validation and slash-policy consumers | Use `checkPolicy` and the same 3.0.1 getter schema. Authorized post-execution consumers call `recordSpend`. |

#### ABI migration from 1.0.0

- `getAssetSpend(address,address)` keeps selector `0x715904dd`, but its `spentInWindow`
  output changed from `uint128` to `uint256`. Strict ABI decoders must update despite the
  unchanged selector.
- `getContractScope(address,address)` was renamed to `getTargetScope(address,address)`.
  The new selector is `0x7ac0774b`, and the velocity limit is no longer in the returned tuple.
- `getTargetVelocity(address,address,address)`, `setTargetVelocity(address,address,address,uint128)`,
  and `tightenTargetVelocity(address,address,address,uint128)` now handle the asset-specific limit.
- The old `getContractScope` selector `0x35cefaa8`, old `setContractScope` selector
  `0x3ef43aff`, and old `tightenContractScope` selector `0xccd7129f` are absent in 3.0.1.
  Calls with those selectors revert.

---

## Version History

| Version | Key Changes |
|---------|-------------|
| `SuperPaymaster-5.4.0` (release `v5.4.0`) | **v5.4 GA:** `version()` bumped `5.3.3` → `5.4.0` (Registry also `5.4.0`). Same god-split implementation content as `v5.4.0-beta.1` — standalone `X402Facilitator-1.0.0` + `PolicyRegistry-1.0.0` + `TimelockController`. Mainnet-ready `DeployLive` (X402Facilitator + Timelock + PolicyRegistry on a fresh chain). |
| `SuperPaymaster-5.3.3` (release `v5.4.0-beta.1`) | **v5.4 god-split phase 1:** x402 settlement extracted to standalone `X402Facilitator-1.0.0`; new standalone `PolicyRegistry-1.0.0` (governance-gated spend policy) + `TimelockController`. SP `version()` string unchanged (`5.3.3`); bump to `5.4.0` deferred to GA. |
| `SuperPaymaster-5.3.0` | V5.3: ERC-8004 dual-channel sponsorship (`isEligibleForSponsorship`), agent sponsorship policies (F1), reputation feedback (F2), x402 EIP-3009 settlement (`settleX402Payment`), xPNTs direct settlement (`settleX402PaymentDirect`), `__gap` reduced 48→40 |
| `SuperPaymaster-5.0.0` | V5.1: `_consumeCredit()` kernel, `chargeMicroPayment()` EIP-712, solady EIP-712, `microPaymentNonces` |
| `SuperPaymaster-4.x` | UUPS upgradeable proxy migration (ERC1967), `BasePaymasterUpgradeable`, `initialize()` |
| `SuperPaymaster-3.2.2` | V3 baseline: Registry integration, Chainlink oracle, DVT/BLS slash, xPNTs factory binding, packed storage |

# SuperPaymaster API Reference

**Version**: `SuperPaymaster-5.3.0` (updated 2026-05-06 — EIP-170 view-function removal)

> This document covers the full public API as of v5.3.0, including V3/V4 baseline
> functions and all V5.x additions (agent-native gas sponsorship, x402 settlement,
> ERC-8004 dual-channel eligibility, and agent sponsorship policies).

> ⚠️ **SDK MAINTAINER — MANDATORY READ** (2026-05-06)
>
> Four view functions were removed from the on-chain ABI as part of the EIP-170
> bytecode compliance fix. Any SDK or off-chain tooling that calls these functions
> will receive a revert after the next deployment:
>
> | Removed Function | Migration Path |
> |-----------------|----------------|
> | `isChainlinkStale()` | Read `cachedPrice().updatedAt` and `priceStalenessThreshold`; compare off-chain |
> | `getAvailableCredit(user, token)` | Compute off-chain: `registry.getCreditLimit(user) - pendingDebts[token][user]` |
> | `getSlashHistory(operator)` → `SlashRecord[]` | Use `getSlashCount(operator)` + `getSlashRecord(operator, index)` in a loop; or index `OperatorSlashed` events via The Graph |
> | `getLatestSlash(operator)` → `SlashRecord` | `paymaster.getSlashRecord(operator, paymaster.getSlashCount(operator) - 1)` |
>
> See [Section 7 of the EIP-170 Impact Analysis](security/eip170-impact-analysis-2026-05-06.md#7-view-function-removal--sdk-migration-guide) for full migration code samples.

---

## Contract Information

| Field | Value |
|-------|-------|
| **Version** | `SuperPaymaster-5.3.0` |
| **Sepolia Proxy** | `0x829C3178DeF488C2dB65207B4225e18824696860` |
| **Sepolia Impl** | `0x3C4DE35f6391Dd07B56c70cB45A7D3dEc219855e` |
| **MicroPaymentChannel (Sepolia)** | `0x5753e9675f68221cA901e495C1696e33F552ea36` |
| **AgentIdentityRegistry (Sepolia)** | `0x400624Fa1423612B5D16c416E1B4125699467d9a` |
| **AgentReputationRegistry (Sepolia)** | `0x2D82b2De1A0745454cDCf38f8c022f453d02Ca55` |
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
| ~~18~~ | ~~`oracleDecimals`~~ | **removed** — Chainlink ETH/USD always returns 8; hardcoded |
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
7. Returns context `(xPNTsToken, user, initialAPNTs, userOpHash, operator)` (**5-field**; `xPNTsAmount` removed in EIP-170 fix) and `validUntil = cachedPrice.updatedAt + priceStalenessThreshold`

> **⚠️ SDK BREAKING CHANGE**: Context encoding changed from 6-field to 5-field — `xPNTsAmount` (index 1) was removed. Any off-chain decoder reading EntryPoint calldata must update field offsets.

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
    bytes32 nonce,
    bytes calldata signature
) external nonReentrant returns (bytes32 settlementId)
```

**Access:** Caller must hold `ROLE_PAYMASTER_SUPER` in Registry (acts as facilitator)

**Parameters:**
- `from` — payer address (must have signed the EIP-3009 authorization)
- `to` — payee / service provider address
- `asset` — ERC-20 token implementing EIP-3009 (e.g. USDC)
- `amount` — gross transfer amount
- `validAfter`, `validBefore` — authorization time window (EIP-3009)
- `nonce` — unique bytes32 nonce for replay prevention
- `signature` — EIP-3009 authorization signature from `from`

**Returns:** `settlementId = keccak256(from, to, asset, amount, nonce)`

**Fee:** Deducts `facilitatorFeeBPS` (or per-operator override) from `amount` before forwarding net to `to`. Fee credited to `facilitatorEarnings[msg.sender][asset]`.

**Events:** `X402PaymentSettled(from, to, asset, amount, fee, nonce)`

**Errors:** `NonceAlreadyUsed`, `Unauthorized`

---

### settleX402PaymentDirect

Settle an x402 payment via standard `transferFrom` (for xPNTs tokens auto-approved by factory, or any pre-approved ERC-20).

```solidity
function settleX402PaymentDirect(
    address from,
    address to,
    address asset,
    uint256 amount,
    bytes32 nonce
) external nonReentrant returns (bytes32 settlementId)
```

**Access:** Caller must hold `ROLE_PAYMASTER_SUPER` in Registry

**Parameters:** same semantics as `settleX402Payment` except no signature required (uses `transferFrom` allowance).

**Returns:** `settlementId = keccak256(from, to, asset, amount, nonce)`

**Events:** `X402PaymentSettled(from, to, asset, amount, fee, nonce)`

**Errors:** `NonceAlreadyUsed`, `Unauthorized`

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

**Events:** `PriceUpdated(price, timestamp)`

**Errors:** `OracleError` — if Chainlink call fails, price out of bounds, or data is stale.

---

### updatePriceDVT

Update price via BLS/DVT consensus (Chainlink fallback path).

```solidity
function updatePriceDVT(
    int256 price,
    uint256 updatedAt,
    bytes calldata proof,
    uint8 chainlinkRecovered   // 1 = Chainlink recovered, clears EMERGENCY mode
) external
```

**Access:** `BLS_AGGREGATOR` or `owner()`

**Validation:**
- `updatedAt` must be strictly greater than `cachedPrice.updatedAt`
- Must be within 2 hours of current time
- Price must be within `[MIN_ETH_USD_PRICE, MAX_ETH_USD_PRICE]`
- If Chainlink is live and recent, rejects prices deviating >20% from Chainlink

**`chainlinkRecovered`:** Pass `1` when BLS aggregator detects Chainlink has recovered after an EMERGENCY mode period. This clears `priceMode` back to `0` (CHAINLINK) and resets `emergencyActivatedAt`.

**Events:** `PriceUpdated(price, updatedAt)`

---

### emergencySetPrice *(P0-10 break-glass — owner only)*

Queue an emergency price when Chainlink is stale. Price must be within ±20% of the last cached price. Initiates a 1-hour timelock before it can be applied.

```solidity
function emergencySetPrice(int256 price) external onlyOwner
```

**Errors:** `ChainlinkNotStale`, `EmergencyPriceOutOfRange`, `OracleError`, `EmergencyExpired`

---

### cancelEmergencyPrice *(P0-10 break-glass — owner only)*

Cancel a queued emergency price before it is applied.

```solidity
function cancelEmergencyPrice() external onlyOwner
```

---

### executeEmergencyPrice *(P0-10 break-glass — permissionless after timelock)*

Apply the queued emergency price after the 1-hour timelock elapses.

```solidity
function executeEmergencyPrice() external
```

**Errors:** `NoEmergencyPending`, `EmergencyTimelockNotElapsed`

---

## SBT Registry Functions

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

**Events:** `OperatorSlashed(operator, amount, level)`, `ReputationUpdated(operator, newScore)`

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

### ~~getSlashHistory~~ — **REMOVED** (EIP-170 fix, 2026-05-06)

> ❌ This function has been removed from the on-chain ABI. Calls will revert.
>
> **Migration**: Use `getSlashCount(operator)` to get the count, then iterate via
> `getSlashRecord(operator, index)`. For historical queries, index `OperatorSlashed`
> events off-chain via The Graph or `eth_getLogs`.
>
> ```typescript
> // SDK migration example
> const count = await paymaster.getSlashCount(operator);
> const records = await Promise.all(
>   Array.from({ length: Number(count) }, (_, i) =>
>     paymaster.getSlashRecord(operator, i)
>   )
> );
> ```

---

### getSlashCount

```solidity
function getSlashCount(address operator) external view returns (uint256)
```

---

### getSlashRecord *(new — replaces getSlashHistory + getLatestSlash)*

Access a specific slash record by index. Solidity's auto-generated `slashHistory` mapping getter returns a tuple; this wrapper returns the fully typed `SlashRecord` struct.

```solidity
function getSlashRecord(
    address operator,
    uint256 index
) external view returns (ISuperPaymaster.SlashRecord memory)
```

**Errors:** `IndexOutOfBounds` if `index >= getSlashCount(operator)`

**Usage patterns:**

```typescript
// Get latest slash
const count = await paymaster.getSlashCount(operator);
if (count > 0n) {
  const latest = await paymaster.getSlashRecord(operator, count - 1n);
}

// Iterate all slashes
for (let i = 0n; i < count; i++) {
  const record = await paymaster.getSlashRecord(operator, i);
  // record.level, record.amount, record.reputationLoss, record.reason, record.timestamp
}
```

---

### ~~getLatestSlash~~ — **REMOVED** (EIP-170 fix, 2026-05-06)

> ❌ This function has been removed from the on-chain ABI. Calls will revert.
>
> **Migration**: `paymaster.getSlashRecord(operator, paymaster.getSlashCount(operator) - 1n)`

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

### ~~isChainlinkStale()~~ — **REMOVED** (EIP-170 fix, 2026-05-06)

> ❌ This function has been removed from the on-chain ABI. Calls will revert.
>
> **Migration**: Compute staleness off-chain using two public storage reads:
>
> ```typescript
> const [, updatedAt] = await paymaster.cachedPrice();
> const staleness = await paymaster.priceStalenessThreshold();
> const isStale = updatedAt < BigInt(Math.floor(Date.now() / 1000)) - staleness;
> ```

---

### ~~getAvailableCredit~~ — **REMOVED** (EIP-170 fix, 2026-05-06)

> ❌ This function has been removed from the on-chain ABI. Calls will revert.
>
> **Migration**: Compute off-chain from two public reads (credit limit is per-user in Registry,
> debt is in `pendingDebts`):
>
> ```typescript
> const creditLimitAPNTs = await registry.getCreditLimit(user); // from Registry
> const debtAPNTs = await paymaster.pendingDebts(token, user);
> const available = creditLimitAPNTs > debtAPNTs ? creditLimitAPNTs - debtAPNTs : 0n;
> ```

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

### Core Events

```solidity
event OperatorDeposited(address indexed operator, uint256 amount);
event OperatorWithdrawn(address indexed operator, uint256 amount);
event OperatorConfigured(address indexed operator, address xPNTsToken, address treasury, uint256 exchangeRate);
event OperatorPaused(address indexed operator);
event OperatorUnpaused(address indexed operator);
event OperatorMinTxIntervalUpdated(address indexed operator, uint48 minTxInterval);
event UserBlockedStatusUpdated(address indexed operator, address indexed user, bool isBlocked);
event OperatorSlashed(address indexed operator, uint256 amount, SlashLevel level);
event ReputationUpdated(address indexed operator, uint256 newScore);
event TransactionSponsored(address indexed operator, address indexed user, uint256 aPNTsCost, uint256 xPNTsCost);
```

### Oracle Events

```solidity
event PriceUpdated(int256 indexed price, uint256 indexed timestamp);
event OracleFallbackTriggered(uint256 timestamp);
event APNTsPriceUpdated(uint256 oldPrice, uint256 newPrice);
```

### Slash Events

```solidity
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

**Sepolia address:** `0x5753e9675f68221cA901e495C1696e33F552ea36`

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

## Version History

| Version | Key Changes |
|---------|-------------|
| `SuperPaymaster-5.3.0` | V5.3: ERC-8004 dual-channel sponsorship (`isEligibleForSponsorship`), agent sponsorship policies (F1), reputation feedback (F2), x402 EIP-3009 settlement (`settleX402Payment`), xPNTs direct settlement (`settleX402PaymentDirect`), `__gap` reduced 48→40 |
| `SuperPaymaster-5.0.0` | V5.1: `_consumeCredit()` kernel, `chargeMicroPayment()` EIP-712, solady EIP-712, `microPaymentNonces` |
| `SuperPaymaster-4.x` | UUPS upgradeable proxy migration (ERC1967), `BasePaymasterUpgradeable`, `initialize()` |
| `SuperPaymaster-3.2.2` | V3 baseline: Registry integration, Chainlink oracle, DVT/BLS slash, xPNTs factory binding, packed storage |

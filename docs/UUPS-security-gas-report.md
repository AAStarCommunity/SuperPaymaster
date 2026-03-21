# UUPS Migration Security Review & Gas Analysis Report

> Date: 2026-03-21 | Branch: `feature/uups-migration` vs `main`
> Scope: Registry, SuperPaymaster, BasePaymasterUpgradeable, GTokenStaking, MySBT, PaymasterBase, MigrateToUUPS.s.sol

---

## Executive Summary

The UUPS migration is well-implemented with correct initialization, upgrade authorization, and storage layout. **2 HIGH**, **2 MEDIUM**, and **3 LOW** findings identified.

| Severity | Count | Summary |
|----------|-------|---------|
| HIGH | 2 | Migration script compilation failure; Ownable (not Ownable2Step) for UUPS contracts |
| MEDIUM | 2 | __gap size inconsistency; pendingDebts access control |
| LOW | 3 | Silent initialization fallback; impl owner non-zero; BLS validation inconsistency |
| INFO | 5 | All passing (initialization, upgrade auth, immutables, storage, staking) |

---

## 1. Security Findings

### [HIGH-1] MigrateToUUPS.s.sol Calls Removed `setRegistry()` Functions

**Files**: `contracts/script/v3/MigrateToUUPS.s.sol` lines 167, 191, 194

**Description**: The migration script calls `staking.setRegistry()` and `MySBT.setRegistry()` at three locations, but these functions were removed in this branch (REGISTRY changed to immutable constructor parameter). The script imports the **new** Solidity types that no longer have `setRegistry`.

```solidity
// Line 167 - GTokenStaking no longer has setRegistry()
staking.setRegistry(deployer);

// Line 191
GTokenStaking(STAKING).setRegistry(address(registry));

// Line 194 - MySBT no longer has setRegistry()
MySBT(MYSBT).setRegistry(address(registry));
```

**Impact**: Migration script will fail to compile if manually invoked. Currently hidden because `foundry.toml` sets `script = "script"` (root-level), while this file is in `contracts/script/v3/`.

**Recommendation**: Define legacy interfaces for interacting with old deployed bytecode:
```solidity
interface LegacyStaking { function setRegistry(address) external; }
interface LegacyMySBT { function setRegistry(address) external; }
// Then: LegacyStaking(STAKING).setRegistry(address(registry));
```

---

### [HIGH-2] Ownable (Not Ownable2Step) for UUPS Proxy Contracts

**Files**: `contracts/src/core/Registry.sol:18`, `contracts/src/paymasters/superpaymaster/v3/BasePaymasterUpgradeable.sol:17`

**Description**: Both UUPS contracts use single-step `Ownable`. If `transferOwnership()` is called with a wrong address, ownership is permanently lost — making the contract **non-upgradeable and non-recoverable**.

**Impact**: For UUPS proxies, owner is the sole upgrade authority. Loss of ownership = permanent loss of upgrade capability. This is significantly more severe than for non-upgradeable contracts.

**Recommendation**: Migrate to `Ownable2Step` which requires the new owner to call `acceptOwnership()`, preventing accidental transfer to invalid addresses.

---

### [MEDIUM-1] Inconsistent __gap Sizes Between Contracts

**Files**: `Registry.sol` (28 vars + 50 gap = 78 total), `SuperPaymaster.sol` (19 vars + 49 gap = 68 total)

**Description**: The two UUPS contracts use different total slot reservations. While not a bug, it deviates from the standard "N vars + gap = constant" convention and increases risk of miscalculation during future upgrades.

**Current Layout**:
- Registry: slots 0-27 (variables) + slots 28-77 (__gap[50]) = 78 total
- SuperPaymaster: slots 0-18 (variables) + slots 19-67 (__gap[49]) = 68 total

**Recommendation**: Document exact slot maps for both contracts and standardize on a consistent total (e.g., both using 100 total slots).

---

### [MEDIUM-2] `retryPendingDebt` Has No Access Control

**File**: `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:932`

**Description**: Any address can call `retryPendingDebt(token, user)` to force-record a user's pending debt. While this is a "positive" operation (recording legitimate debt), it allows third parties to force debt recording at potentially inappropriate times (e.g., when xPNTs token is temporarily paused, wasting gas on repeated failures).

```solidity
function retryPendingDebt(address token, address user) external nonReentrant {
    uint256 amount = pendingDebts[token][user];
    require(amount > 0, "No pending debt");
    delete pendingDebts[token][user];
    IxPNTsToken(token).recordDebt(user, amount);  // Will revert if token is paused
    emit PendingDebtRetried(token, user, amount);
}
```

**Note**: If `recordDebt` reverts, the pending debt is already deleted — debt is lost. This is a data integrity issue.

**Recommendation**: Either (a) add `onlyOwner` access control, or (b) only delete `pendingDebts` after successful `recordDebt` call (move `delete` after the external call, using checks-effects-interactions exception since this is a trusted token).

---

### [LOW-1] Registry `_initRole` Silently Ignores Exit Fee Setup Failures

**File**: `contracts/src/core/Registry.sol:173-175`

When `initialize()` is called with `address(0)` as staking (Scheme B deployment), `_initRole()`'s `try/catch` silently swallows exit fee setup failures. If deployer forgets to call `setStaking()` afterward, exit fees remain zero.

**Impact**: By design (Scheme B), but no runtime warning.

---

### [LOW-2] Implementation Contract Owner Is Non-Zero

**File**: `contracts/src/core/Registry.sol:103`

Registry constructor calls `Ownable(msg.sender)`, setting the implementation's owner to the deployer. Since `_disableInitializers()` prevents re-initialization, this has **no security impact** — the implementation cannot be upgraded through its own `_authorizeUpgrade`.

---

### [LOW-3] `updateOperatorBlacklist` BLS Validation Is Optional

**File**: `contracts/src/core/Registry.sol:469-472`

BLS proof is only verified if `blsValidator != address(0) && proof.length > 0`. Without BLS, blacklist operations proceed with only `reputationSource` authorization. Compare to `batchUpdateGlobalReputation` which **requires** BLS when configured. This inconsistency may be intentional (emergency blacklisting) but should be documented.

---

## 2. Passing Security Checks

| Check | Status | Details |
|-------|--------|---------|
| **Initialization Safety** | PASS | Both contracts call `_disableInitializers()` in constructor; `initialize()` uses `initializer` modifier |
| **Upgrade Authorization** | PASS | `_authorizeUpgrade` restricted to `onlyOwner` in both contracts; tested in UUPSUpgrade.t.sol |
| **Storage Collision** | PASS | No slot collisions; Initializable uses ERC-7201 namespaced storage; verified via `forge inspect` |
| **Immutable Handling** | PASS | `entryPoint`, `REGISTRY`, `ETH_USD_PRICE_FEED` correctly stored in implementation bytecode |
| **Staking/MySBT Safety** | PASS | `REGISTRY` changed to immutable eliminates 2 attack surfaces (owner/DAO redirecting REGISTRY) |

---

## 3. Gas Analysis

### 3.1 Optimizer Configuration

```toml
# foundry.toml (current)
optimizer = true
optimizer_runs = 500
via_ir = true
evm_version = "cancun"
```

Note: `optimizer_runs = 500` (lower than the 10,000 documented in CLAUDE.md). Lower runs optimize deployment cost at slight runtime gas increase. This was necessary to keep Registry under the EIP-170 24,576 byte limit.

### 3.2 Key Function Gas Costs (via ERC1967Proxy)

| Function | Min | Avg | Median | Max | Calls |
|----------|-----|-----|--------|-----|-------|
| **validatePaymasterUserOp** | 83,499 | 121,445 | 128,084 | 128,468 | 7 |
| **postOp** | 61,715 | 76,358 | 80,410 | 91,642 | 7 |
| **registerRole** | 53,077 | 753,685 | 841,001 | 1,250,098 | 49 |
| **configureOperator** | 39,299 | 102,298 | 108,870 | 115,711 | 26 |
| **exitRole** | 113,370 | 179,634 | 171,906 | 235,572 | 6 |
| **deposit** (SP) | 55,709 | 121,889 | 143,710 | 144,918 | 14 |
| **configureRole** | 33,929 | 107,211 | 96,658 | 246,004 | 58 |
| **executeSlashWithBLS** | 133,199 | 143,172 | 136,232 | 174,735 | 12 |
| **hasRole** (view) | 0 | 7,472 | 8,015 | 8,015 | 260 |

### 3.3 UUPS Proxy Overhead

| Scenario | Direct Call Est. | Proxy Call Actual | Overhead |
|----------|-----------------|-------------------|----------|
| hasRole (view, warm) | ~5,400 | ~8,015 | ~2,615 (48%) |
| validatePaymasterUserOp | ~125,500 | ~128,084 | ~2,584 (2%) |
| postOp | ~77,800 | ~80,410 | ~2,610 (3.3%) |

**Conclusion**: For hot-path functions (validatePaymasterUserOp, postOp), UUPS proxy overhead is only **2-3%** — negligible in the context of ERC-4337 total gas budgets. Simple view functions show higher relative overhead (~48%) but minimal absolute cost (~2,600 gas).

### 3.4 Immutable REGISTRY Gas Savings

| Operation | Before (SLOAD) | After (PUSH20) | Savings |
|-----------|---------------|----------------|---------|
| Cold read | ~2,100 gas | ~3 gas | ~2,097 gas |
| Warm read | ~100 gas | ~3 gas | ~97 gas |

These savings apply to every `onlyRegistry` modifier call in GTokenStaking and MySBT (~8 high-frequency functions).

### 3.5 PaymasterBase Oracle Validation

V4 PaymasterBase added oracle bounds validation:
- Price range: $100 — $100,000 (reasonable for ETH)
- `oracleDecimals` cached to avoid repeated external calls
- `try/catch` defaults to 8 decimals if `decimals()` fails (Chainlink ETH/USD feeds all use 8)

---

## 4. Recommendations Summary

| Priority | Issue | Recommendation |
|----------|-------|----------------|
| **HIGH** | MigrateToUUPS.s.sol compilation | Use legacy interface for `setRegistry` calls |
| **HIGH** | Ownable → Ownable2Step | Prevent irreversible owner loss for UUPS contracts |
| **MEDIUM** | __gap inconsistency | Standardize and document slot maps |
| **MEDIUM** | retryPendingDebt data loss | Move `delete` after `recordDebt` or add access control |
| **LOW** | optimizer_runs mismatch | Document intent (500 vs 10,000) |
| **LOW** | BLS validation inconsistency | Document or enforce consistent policy |

---

## 5. Test Coverage Summary

- **332 total tests**, 0 failures
- **19 UUPS-specific tests** in `contracts/test/v3/UUPSUpgrade.t.sol`
- Tests cover: initialization, re-initialization prevention, upgrade authorization, state persistence across upgrades, double upgrade, non-UUPS target rejection
- E2E Sepolia tests: 3/3 gasless transfer tests passing
- Full regression (`run_full_regression.sh --force`): PASSING

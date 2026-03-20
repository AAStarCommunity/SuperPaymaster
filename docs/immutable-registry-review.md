# Immutable REGISTRY Refactoring — Security & Performance Review

**Date**: 2026-03-20
**Scope**: GTokenStaking, MySBT, IGTokenStaking, Registry
**Version Bumps**: Staking-3.2.0, MySBT-3.1.3, Registry-4.1.0

---

## 1. Security Review

### 1.1 Attack Surface Reduction

| Attack Vector | Before | After |
|---|---|---|
| `GTokenStaking.setRegistry()` — owner can redirect REGISTRY to malicious contract | **Exposed** (onlyOwner) | **Eliminated** (immutable) |
| `MySBT.setRegistry()` — DAO can redirect REGISTRY to malicious contract | **Exposed** (onlyDAO) | **Eliminated** (immutable) |
| Registry address forgery via compromised owner key | Possible via setter | Impossible — requires redeployment |
| `onlyRegistry` modifier bypass via `setRegistry(attacker)` | Possible if owner compromised | Impossible |

**Verdict**: The immutable pattern eliminates 2 setter-based attack surfaces entirely. No new attack vectors introduced.

### 1.2 Constructor Zero-Address Validation

| Contract | Validation |
|---|---|
| GTokenStaking | `if (_registry == address(0)) revert("Invalid Registry");` ✅ |
| MySBT | `require(_r != address(0))` ✅ |

### 1.3 Scheme B Deployment Safety

**Flow**: Registry proxy(placeholder) → GTokenStaking(proxy) → MySBT(proxy) → `setStaking()` → `setMySBT()`

| Concern | Analysis |
|---|---|
| Registry `initialize(deployer, address(0), address(0))` | Safe — `_initRole()` skips `setRoleExitFee()` when `GTOKEN_STAKING == address(0)` |
| Exit fee sync gap | Resolved — `setStaking()` calls `_syncExitFees()` automatically |
| `_syncExitFees()` failure | Uses `try/catch` — cannot revert `setStaking()` |
| GTokenStaking deployed before Registry is fully wired | Safe — REGISTRY immutable is the proxy address (permanent) |

### 1.4 MigrateToUUPS.s.sol Compatibility

The migration script operates on **already-deployed contracts** (old bytecode with `setRegistry()`). Since the migration script calls the old contracts' ABI, it is **unaffected** by this refactoring. No changes needed.

---

## 2. Gas Performance

### 2.1 SLOAD → Immutable Inline

| Operation | Before (SLOAD) | After (immutable) | Savings |
|---|---|---|---|
| Read `REGISTRY` | ~2100 gas (cold) / ~100 gas (warm) | 3 gas (PUSH20) | **~97-2097 gas per read** |

### 2.2 Functions Affected (per call)

| Function | REGISTRY reads | Est. savings |
|---|---|---|
| `GTokenStaking.lockStake()` | 1 (onlyRegistry) | ~100 gas |
| `GTokenStaking.unlockAndTransfer()` | 1 (onlyRegistry) | ~100 gas |
| `GTokenStaking.topUpStake()` | 1 (onlyRegistry) | ~100 gas |
| `GTokenStaking.slash()` | 1 (msg.sender check) | ~100 gas |
| `MySBT.mintForRole()` | 1 (onlyRegistry) | ~100 gas |
| `MySBT.airdropMint()` | 1 (onlyRegistry) | ~100 gas |
| `MySBT.burnSBT()` | 1 (onlyRegistry) | ~100 gas |
| `MySBT._isValid()` | 2 (zero check + hasRole call) | ~200 gas |

### 2.3 Storage Slot Freed

- GTokenStaking: `REGISTRY` slot freed → `treasury` shifted from slot 3 → slot 2
- MySBT: `REGISTRY` slot freed → `daoMultisig` shifted from slot 15 → slot 14

Both are non-proxy contracts (fresh deploy), so storage shift is safe.

---

## 3. Storage Layout Compatibility

### 3.1 GTokenStaking (Non-proxy — safe to change)

| Slot | Before | After |
|---|---|---|
| 0 | `_status` (ReentrancyGuard) | `_status` (ReentrancyGuard) |
| 1 | `_owner` (Ownable) | `_owner` (Ownable) |
| 2 | `REGISTRY` | `treasury` ← shifted up |
| 3 | `treasury` | `stakes` ← shifted up |
| ... | ... | ... |

**Impact**: None — GTokenStaking is deployed fresh, not upgradeable via proxy.

### 3.2 MySBT (Non-proxy — safe to change)

`REGISTRY` removed from storage (was between `GTOKEN_STAKING` and `daoMultisig`). All subsequent slots shift up by 1.

**Impact**: None — MySBT is deployed fresh, not upgradeable via proxy.

### 3.3 Registry (UUPS Proxy — no storage change)

Registry storage layout is **unchanged**. The only additions are:
- `_syncExitFees()` — internal function (no storage)
- `setStaking()` — modified behavior only (calls `_syncExitFees` after setting)

**Impact**: None — safe for UUPS upgrade from Registry-4.0.0 to Registry-4.1.0.

---

## 4. Deployment Order Verification

### 4.1 Anvil Dry-Run Result: **PASSED** ✅

All 9 steps completed successfully:
1. ✅ Deploy Foundation (Scheme B)
2. ✅ Deploy Foundation Modules
3. ✅ Pre-register Deployer as COMMUNITY
4. ✅ Deploy aPNTs via Factory
5. ✅ Deploy Core (SuperPaymaster UUPS Proxy)
6. ✅ Deploy Other Modules
7. ✅ The Grand Wiring
8. ✅ Register Deployer as SuperPaymaster
9. ✅ Final Verification — "All Wiring Assertions Passed!"

### 4.2 Test Suite: **318 tests, 0 failures** ✅

- 3 new immutable REGISTRY tests added
- 2 obsolete `setRegistry` tests removed
- All 11 test setUp functions updated to Scheme B

---

## 5. Findings & Recommendations

### 5.1 No Issues Found

The refactoring is clean and safe. No actionable findings.

### 5.2 Design Consistency Achieved

All core infrastructure contracts now follow the same immutable reference pattern:

| Contract | Immutable References |
|---|---|
| SuperPaymaster | `entryPoint`, `REGISTRY`, `ETH_USD_PRICE_FEED` |
| GTokenStaking | `GTOKEN`, `REGISTRY` |
| MySBT | `GTOKEN`, `GTOKEN_STAKING`, `REGISTRY` |
| ReputationSystem | `REGISTRY` |
| DVTValidator | `REGISTRY` |
| BLSAggregator | `REGISTRY` |
| PaymasterV4 | `REGISTRY` |

---

## 6. Conclusion

**APPROVED** — Ready for Sepolia deployment.

- Zero security regressions
- Gas savings on every REGISTRY read (~100 gas/call)
- Consistent immutable pattern across all contracts
- Storage layout safe for both fresh deploy and UUPS upgrade
- Full test coverage maintained (318/318 pass)

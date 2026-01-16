# SuperPaymaster V3 Audit Report
**Date:** January 8, 2026
**Target:** SuperPaymaster V3 Codebase (Stable-V2 Branch)
**Auditor:** Gemini AI (Autonomous Agent)

## 1. Executive Summary

A comprehensive security and logical audit was performed on the SuperPaymaster V3 codebase. The V3 architecture introduces a robust "Registry-Centric" model, effectively decoupling identity (`MySBT`), security (`GTokenStaking`), and service (`SuperPaymaster`). 

**Overall Health:** 🟢 **Good**, with specific localized risks.
The core wiring is verified, and the removal of legacy dependencies (e.g., `MySBT`'s direct dependence on `SuperPaymaster`) has improved modularity. However, critical inconsistencies in staking accounting and role exit logic pose risks to protocol integrity if not addressed before mainnet launch.

## 2. Architectural Review

### Registry-Centric Design (V3)
The shift to `Registry.sol` as the single source of truth is architecturally sound.
-   **Pros:** Centralized role management simplifies permissioning. The "Wiring" pattern reduces circular dependencies (mostly).
-   **Cons:** The Registry is a "God Object." Initialization order is brittle (e.g., `GTokenStaking` requires `Registry` to be set to accept exit fee configs, but `Registry` constructor tries to set them immediately).

### Credit-First Gas Abstraction
The `xPNTs` model (Credit-First) works well with the `SuperPaymaster`.
-   **Flow:** Users accrue debt (xPNTs) -> Auto-repaid on mint -> Paymaster verifies credit limits via Registry reputation.
-   **Risk:** Requires reliable price feeds (`aPNTsPriceUSD`) which are currently hardcoded or Owner-controlled, creating a centralization vector.

## 3. Critical Findings (High Severity)

### [H-01] Staking Accounting Inconsistency
**Location:** `contracts/src/core/GTokenStaking.sol`
**Description:** The contract mixes two different accounting models for slashing:
1.  **`slash()` (Registry/Owner):** Uses a "Contra-Account" model. It increases `info.slashedAmount` and decreases `totalStaked`, but leaves `info.amount` (principal) unchanged. `balanceOf` is calculated as `amount - slashedAmount`.
2.  **`slashByDVT()` (Validator):** Uses a "Direct Reduction" model. It decreases `info.amount` and `totalStaked` directly.

**Impact:** If a user is slashed via `slash()` (creating `slashedAmount > 0`) and subsequently slashed via `slashByDVT()`, the reduction in `info.amount` could cause `info.amount < info.slashedAmount`. This would cause `balanceOf()` to revert (underflow) due to checked arithmetic, permanently locking the user's remaining stake and preventing any interaction or exit.

**Recommendation:** Standardize on the "Direct Reduction" model for all slashing actions to ensure `info.amount` always reflects the actual remaining principal. Remove `slashedAmount` state variable entirely if possible, or strictly synchronize logic.

### [H-02] Incomplete Role Exit for Multi-Community Users
**Location:** `contracts/src/core/Registry.sol` (`exitRole`)
**Description:** `ROLE_ENDUSER` allows users to join multiple communities. However, `roleMetadata[ROLE_ENDUSER][user]` is a single slot that gets overwritten with the *latest* registration data.
When `exitRole(ROLE_ENDUSER)` is called:
1.  It retrieves the *latest* metadata.
2.  It deactivates the membership for that specific community in `MySBT`.
3.  It burns the user's stake and removes the role.

**Impact:** If a user joined Community A, then Community B:
-   `metadata` holds Community B.
-   `exitRole` deactivates B.
-   **Community A membership remains active** in `MySBT`, even though the user has exited the `ENDUSER` role and withdrawn/burned their stake. The user retains SBT benefits for A without having a valid role/stake.

**Recommendation:** `Registry` should either:
1.  Track a list of active community memberships for each user (gas expensive).
2.  Or `MySBT` should expose a "deactivate all memberships" function callable by Registry upon role exit.

## 4. Medium Findings

### [M-01] Initialization Circularity Risk
**Location:** `Registry.sol` (Constructor) vs `GTokenStaking.sol`
**Description:** The `Registry` constructor calls `_initRole`, which attempts `GTokenStaking.setRoleExitFee`. However, `GTokenStaking` typically requires the caller to be the `REGISTRY` address to allow configuration. During `Registry` construction, `GTokenStaking` likely hasn't had `setRegistry(address(this))` called yet (impossible circularity in atomic deploy without separate setters).
**Mitigation:** The code currently wraps this in a `try/catch` block (`try GTOKEN_STAKING.setRoleExitFee...`), preventing deployment failure. However, this means **initial roles will have default (zero/incorrect) exit fees** in the Staking contract until manually synchronized.

### [M-02] Hardcoded Oracle Dependency
**Location:** `SuperPaymaster.sol` / `xPNTsFactory.sol`
**Description:** `aPNTsPriceUSD` is hardcoded or set via owner transaction. In a volatile market, or if the backing asset of xPNTs fluctuates, the gas pricing (credit deduction) will be incorrect.
**Recommendation:** Integrate a Chainlink feed or a TWAP oracle for `aPNTs` price if it is intended to float, or explicitly document it as a stablecoin-like fixed asset.

## 5. Low / Informational Findings

### [L-01] Unused Legacy Interfaces
**Location:** `contracts/src/tokens/MySBT.sol`
**Description:** The contract defines `interface IRegistryLegacy` but barely uses it except for a fallback check. `setSuperPaymaster` was correctly removed, but cleanup of legacy artifacts could be more thorough to save bytecode size.

### [L-02] Gas Inefficiency in Registry
**Location:** `Registry.sol` (`getUserRoles`)
**Description:** The function iterates through a fixed array of 7 role bytes to find user roles. While currently cheap, if roles expand significantly, this O(N) scan per user view could become costly.
**Recommendation:** Low priority. Current list is small fixed size.

## 6. Conclusion & Next Steps

The system is secure enough for testnet trials but **NOT ready for mainnet** until [H-01] and [H-02] are resolved.

1.  **Immediate Action:** Refactor `GTokenStaking.slash` to match `slashByDVT`'s direct accounting.
2.  **Immediate Action:** Modify `MySBT` to allow `Registry` to `burnSBT` or `deactivateAll` upon `exitRole`, ensuring complete state cleanup.
3.  **Process:** Run the regression suite again after applying these fixes.

---
*End of Audit Report*

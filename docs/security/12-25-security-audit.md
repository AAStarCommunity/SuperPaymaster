# 🛡️ Security Audit Report (2025-12-25)

**Target Scope:** `core`, `modules`, `tokens`, `paymasters`, `accounts`
**Severity Levels:** 🔴 High, 🟠 Medium, 🟡 Low/Gas

---

#### 🔴 High Severity (Critical Vulnerabilities)

**1. Paymaster V4 Overcharging (No Gas Refund)**
*   **File:** `contracts/src/paymasters/v4/PaymasterV4Base.sol`
*   **Issue:** The `validatePaymasterUserOp` function calculates and transfers the token amount based on `cappedMaxCost` (the *maximum* gas limit set by the user). Crucially, **`postOp` is empty and performs no refund**.
*   **Impact:** Users are **always charged 100% of the gas limit** they set, even if the transaction uses only 10%. This effectively makes the Paymaster unusable for production as it severely penalizes users for setting safe gas buffers.
*   **Recommendation:** Implement refund logic in `postOp` to return the difference between `maxCost` and `actualGasCost` to the user, similar to the logic in `SuperPaymasterV3`.

**2. Mocked Security in BLS Monitoring**
*   **File:** `contracts/src/modules/monitoring/BLSAggregatorV3.sol`
*   **Issue:** The `_checkSignatures` function is currently a placeholder (mocked).
*   **Impact:** The "consensus" mechanism for slashing malicious operators is non-functional. The `DVT_VALIDATOR` or `owner` can slash anyone without actual BLS signature verification from the network, centralizing trust completely.
*   **Recommendation:** Implement real BLS signature verification or restrict the `DVT_VALIDATOR` role strictly until implemented.

**3. BLS Verification Bypass in Registry**
*   **File:** `contracts/src/core/Registry.sol`
*   **Issue:** In `batchUpdateGlobalReputation`, if `proof.length` is 0, the BLS verification is skipped entirely.
*   **Impact:** A compromised or malicious `ReputationSource` can submit arbitrary reputation updates without any cryptographic proof if they simply omit the proof data.
*   **Recommendation:** Enforce `proof.length > 0` or a specific verification check even for empty proofs if that is a valid state (unlikely).

**4. Empty Account Contract**
*   **File:** `contracts/src/accounts/SimpleAccount.sol`
*   **Issue:** The file contains only `import "account-abstraction/accounts/SimpleAccount.sol";` but **does not define a contract**.
*   **Impact:** If deployment scripts reference this file expecting a local `SimpleAccount` artifact, the deployment will fail or behave unexpectedly.
*   **Recommendation:** Define a contract that inherits from the imported file: `contract SimpleAccount is SimpleAccount { ... }` or use the library path directly in deployment scripts.

---

#### 🟠 Medium Severity (Logic & UX Risks)

**1. Auto-Repayment Side Effects**
*   **File:** `contracts/src/tokens/xPNTsToken.sol`
*   **Issue:** The `_update` function triggers auto-repayment (burning tokens) on *every* transfer if the user has debt.
*   **Impact:** This breaks standard ERC20 behavior. Third-party protocols (like DEXs or lending pools) expecting to receive `amount` will actually receive `amount - debt_payment`, causing transaction reverts or accounting errors.
*   **Recommendation:** Decouple debt repayment from standard transfers, or clearly document this non-standard behavior as it breaks composability.

**2. Centralized Price Control**
*   **File:** `contracts/src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol`
*   **Issue:** The `aPNTsPriceUSD` is manually set by the `owner` via `setAPNTSPrice`.
*   **Impact:** The owner has complete control over gas pricing. A malicious or accidental update to a very low/high value can either drain user funds or DoS the system.
*   **Recommendation:** Use an on-chain Oracle (like the `xpntsFactory` used in V4) or a TWAP for `aPNTs` pricing to remove this centralization vector.

**3. Circular Initialization Dependency**
*   **File:** `contracts/src/core/Registry.sol`
*   **Issue:** The system requires `GTokenStaking` to be initialized with `Registry`, but `Registry` might need `GTokenStaking` for role checks during its own initialization.
*   **Impact:** Complex deployment order prone to failure or uninitialized states.

---

#### 🟡 Low Severity & Gas Optimizations

**1. Inefficient Slashing Mechanism**
*   **File:** `contracts/src/core/GTokenStaking.sol`
*   **Issue:** `slash` only updates a counter (`slashedAmount`). Funds are not moved until the user explicitly exits.
*   **Impact:** Slashed funds sit idle instead of being moved to the treasury immediately, potentially delaying protocol revenue.

**2. Gas Heavy Token Transfers**
*   **File:** `contracts/src/tokens/xPNTsToken.sol`
*   **Issue:** The auto-repayment logic adds significant gas overhead (state reads/writes) to every `transfer` and `transferFrom`.
*   **Impact:** Higher costs for users even when they have no debt.

**3. Loop in Validation**
*   **File:** `contracts/src/paymasters/v4/PaymasterV4Base.sol`
*   **Issue:** `validatePaymasterUserOp` iterates through `supportedSBTs` and `supportedGasTokens`.
*   **Impact:** While capped by `MAX_SBTS` (5) and `MAX_GAS_TOKENS` (10), this adds linear gas overhead to every validation.

---
*Audit completed on 2025-12-25.*

# SuperPaymaster V3 Refactor & Security Architecture

Status: **Planned**  
Date: 2025-12-18  
Version: 3.1-Draft  

## 1. Overview & Motivation

SuperPaymaster V3's initial design focused on extreme simplicity, stripping away business logic (registration, staking, reputation) to external components. While optimized, this "Pre-charge" model introduced usability frictions (users must deposit before use) and security gaps (reliance on central trust for `burnFromWithOpHash`).

This refactor aims to re-introduce a **Credit-Based Post-Payment Model** and a **Decentralized Security Layer**, combining the efficiency of V3 with the robust features of V2.3.3.

---

## 2. Core Feature Restoration & Enhancements

| Feature Module | V3 Current State | V3.1 Refactored State | Source/Legacy Reference |
| :--- | :--- | :--- | :--- |
| **Payment Model** | **Pre-charge** (Atomic Burn in Validation). Fails if balance < cost. | **Credit-Based**. Checks `Credit > Cost`. Records Debt on failure. | *V2.3.3 Logic (userDebts)* |
| **Reputation** | Simple field in `OperatorConfig`. Manual updates only. | **Hybrid Auto-Reputation**. Off-chain calculation (Validators), On-chain storage (Registry). | *IReputationCalculator.sol* |
| **Slashing** | Owner-only `slashOperator`. Centralized. | **DVT-based Decentralized Slashing**. Validator consensus via BLS proofs. | *V2.3.3 `executeSlashWithBLS`* |
| **Security** | Trust-based `burnFromWithOpHash`. No verification of hash validity. | **Fraud Proof System**. Validators verify hashes off-chain & slash for forgery. | *New Logic* |

---

## 3. Detailed Architecture

### 3.1 Registry Enhancement (Global Truth)

The Registry becomes the central source for **Role**, **Stake**, and **Reputation**.

**New Storage:**
```solidity
// In Registry.sol

// Global Reputation (aggregated from all sources)
mapping(address => uint256) public globalReputation;

// Reputation Sources Whitelist (Paymaster, Validator Aggregator, etc.)
mapping(address => bool) public isReputationSource;
```

**New Interfaces:**
```solidity
// Batch update for gas efficiency
function batchUpdateGlobalReputation(
    address[] calldata users, 
    uint256[] calldata newScores, 
    bytes calldata proof // BLS Proof from Validator Set
) external;
```

### 3.2 Credit-Based Payment Flow (Revolving Credit)

**Concept**: Users have a `MaxCredit` limit based on their Global Reputation. They can spend up to this limit. Deposits automatically repay Debt.

**Workflow:**
1.  **Validation ( `validatePaymasterUserOp` )**:
    *   Calculate `MaxCredit = ReputationToCredit(user.Reputation)`.
    *   Check `user.Balance + (MaxCredit - user.Debt) >= Cost`.
    *   **Pass** if credit is sufficient, even with 0 balance.
2.  **Execution**: UserOp executes.
3.  **Post-Op ( `postOp` )**:
    *   Attempt `burnFromWithOpHash(user, cost)`.
    *   **Success**: Done.
    *   **Failure (Revert)**: Catch error.
        *   `user.Debt += cost`.
        *   `emit DebtRecorded(user, cost)`.
        *   (Optional) `Registry.slashReputation(user, minor_penalty)`.

**Legacy Reference**: Protocol Debt logic from `SuperPaymasterV2_3.sol`.

### 3.3 Hybrid Reputation System

**Architecture**:
*   **Data Sources (Local)**: Community A (Events), Community B (NFTs), Paymaster (Gas Usage).
*   **Aggregator (Off-chain Validator)**:
    *   Listens to events (`UserReputationAccrued`, `ActivityRecorded`).
    *   Applies DAO-configured weights: `GlobalRep = Σ (Source_i * Weight_i)`.
    *   Prevents Double Counting via **Epoch/Nonce mechanism**.
*   **Settlement (On-chain)**: Validators submit batch updates to Registry.

**Legacy Reference**: 
*   `contracts/src/paymasters/v2/interfaces/IReputationCalculator.sol`
*   `contracts/src/paymasters/v2/extensions/MySBTReputationAccumulator.sol`

### 3.4 Security & Slashing (The "Guardian" Layer)

**Objective**: Prevent Paymaster from forging `userOpHash` to burn user funds maliciously.

**Mechanism**:
1.  **Trust but Verify**: Token contract trusts Paymaster (as per V3 design).
2.  **Watchtowers (Validators)**: Monitor `Burn(user, amount, opHash)` events.
3.  **Fraud Detection**:
    *   Query Bundler/Mempool for `opHash`.
    *   If `opHash` effectively "does not exist" (no valid matching UserOp found) OR `UserOp` failed but Burn happened (mismatch).
    *   **Slashing Condition Met**.

**Slashing Logic Extensions**:
*   **Invalid Burn**: burn without valid UserOp.
*   **Censorship/DoS**: Failing "Canary" probes from Validators.
*   **Liveness**: Paymaster offline > N Epochs.

**Circuit Breaker (Melt-down)**:
*   If `TotalSlashed > 30% InitialStake`:
    *   **Force Freeze**: Operator status set to `FROZEN`.
    *   **Manual Intervention Required** to unfreeze.

**Legacy Reference**:
*   `SuperPaymasterV2_3.sol` -> `executeSlashWithBLS(address operator, SlashLevel level, bytes proof)`
*   `DVT_AGGREGATOR` variable.

---

## 4. Implementation Plan & Legacy Asset Recovery

We will strictly reuse existing high-quality V2 code where possible.

### Step 1: Recover Legacy Contracts
We have identified the following key files to be restored/adapted:

1.  **DVT/Slashing Logic**:
    *   **Source**: `contracts/src/paymasters/superpaymaster/v2/SuperPaymasterV2_3.sol`
    *   **Action**: Extract `executeSlashWithBLS` and `DVT_AGGREGATOR` logic into a mixin `SecurityModule.sol`.
2.  **Reputation Interfaces**:
    *   **Source**: `contracts/src/paymasters/v2/interfaces/IReputationCalculator.sol`
    *   **Source**: `contracts/src/paymasters/v2/extensions/MySBTReputationAccumulator.sol`
    *   **Action**: Move to `contracts/src/core/reputation/` and update to V3 Solidity version `^0.8.23`.
3.  **Debt Management**:
    *   **Source**: `SuperPaymasterV2_3.sol` (search for `userDebts`).
    *   **Action**: Port logic to `SuperPaymasterV3.sol`'s `postOp`.

### Step 2: Registry Upgrade
*   Add `mapping(address => uint256) globalReputation`.
*   Add `mapping(address => bool) trustedReputationUpdaters` (for Validators).
*   Add `function batchUpdateReputation(...)`.

### Step 3: SuperPaymaster V3.1
*   Implement `postOp` with `try/catch` burn.
*   Integrate `SecurityModule` (Slashing).
*   Integrate `CreditLibrary` (Rep -> Credit mapping).

---

## 5. Security Checklist (User Confirmed)

- [ ] **Validator Safety**: Use BLS Multi-sig to prevent single validator malice.
- [ ] **Anti-Replay**: Use Epoch/Nonce in Reputation updates.
- [ ] **Circuit Breaker**: Auto-freeze at 30% slash threshold.
- [ ] **Normalization**: Convert xPNTs usage to aPNTs (Standard Value) before calculating Reputation.


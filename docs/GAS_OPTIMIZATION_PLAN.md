# Gas Optimization Strategy: Hybrid Cache + Keeper

## 1. Core Logic Structure

We will transition from a "Always-Realtime" model to a "Hybrid Optimistic Cache" model to save ~6000+ Gas per transaction.

### Logic Flow Diagram

```mermaid
graph TD
    A[UserOperation] -->|Validate| B{Cache Fresh?}
    B -->|Yes| C[Use Cache (Cheap)]
    B -->|No| D[Revert / Fail Validation]
    
    E[PostOp Execution] --> F{Is Cache Fresh?}
    F -->|Yes < 4h| G[Use Cached Price (SLOAD)]
    F -->|No > 4h| H[Fallback: Call Chainlink]
    
    H --> I[Update Cache Storage]
    I --> J[Calculate Cost using New Price]
    G --> J
    
    K[Off-chain Keeper] -->|Monitor| L{Vol > 1% OR > 4h?}
    L -->|Yes| M[Call updatePrice()]
    M --> I
```

---

## 2. API & Permission Design

### A. Public / Keeper API (`updatePrice`)
*   **Access**: `external` (Anyone).
*   **Logic**: Reads `Chainlink.latestRoundData()`, verifies price > 0, updates `cachedPrice`.
*   **Use Case**:
    1.  **Keepers**: Scheduled updates (e.g., every 4h or 1% deviation).
    2.  **Users/Developers**: "I want to ensure my tx uses the absolute latest price."

### B. Operator Override API (`forceUpdatePrice`)
*   **Access**: `onlyOwner` (Operator).
*   **Logic**: Sets `cachedPrice` to a manual value.
*   **Use Case**:
    1.  **Emergency**: Chainlink is broken/stuck/hacked.
    2.  **Pegged Environment**: Testing or stablecoin-like pegging.

---

## 3. Contract Modification Plan (Minimal Changes)

We need to modify `PaymasterBase.sol`.

### 1. `_calculateTokenCost`
**Current**: Uses `bool useRealtime`.
**New**: Accepts a strategy flag or auto-detects.
- If `useRealtime == true` (PostOp):
    - Check `block.timestamp - cachedPrice.updatedAt`.
    - **IF** < `priceStalenessThreshold` (e.g., 4h): Use Cache (Optimization!).
    - **ELSE**: Call `_updatePriceFromOracle()` internal helper (Fallback).

### 2. `getRealtimeTokenCost` (View)
- Needs to remain `view`.
- Cannot update storage.
- If stale, it performs the static call to Chainlink but *cannot* write key. This is fine for simulation.

### 3. `postOp` (Write)
- Remove `view` constraint logic (it is already writing `balances`).
- Calls logic that *permits* storage update if stale.

---

## 4. Analysis of "Paymaster Eats Gas"
When `postOp` performs the fallback Oracle update:
1.  **Gas Used**: Increases by ~6k-10k.
2.  **Billing**: The `actualGasCost` parameter passed to `postOp` *excludes* the current `postOp` execution.
    - However, the Bundler charges the Paymaster for the *Total Transaction Gas*.
    - Result: Paymaster pays ETH for the extra work.
    - User Deduction: Since `actualGasCost` passed to internal logic allows us to charge tokens, we *could* attempt to add overhead.
    - **Decision**: Keep it simple. Paymaster absorbs the occasional fallback cost (amortized across thousands of cheap txs, it's negligible).

---

## 5. SDK Additions

### Operator SDK
```typescript
// Maintenance
static async updatePrice(wallet); // Public wrapper
static async forceUpdatePrice(wallet, price); // Owner wrapper
```

### Keeper Bot Logic (Pseudo)

---

## 6. Resilience & Safety Analysis

This architecture provides a "Triple Safety Net" for Price Availability:

### Layer 1: Keeper (Primary & Most Robust)
- **Mechanism**: Calls `setCachedPrice` or `updatePrice`.
- **Logic**: Updates if price deviates > 1% or stales > 4h.
- **Advantage**: Can source prices from *anywhere* (Binance, Coinbase, Uniswap).
- **Resilience**: **Immune to Chainlink Downtime**. If Chainlink freezes, Keeper continues to push CEX prices via `setCachedPrice`.

### Layer 2: On-Chain Fallback (Keeper Down)
- **Mechanism**: `postOp` detects staleness and calls `updatePrice()`.
- **Logic**: Forces a refresh from Chainlink Oracle.
- **Cost**: User pays ~6k-10k extra Gas (roughly once every 4 hours).
- **Resilience**: Covers Keeper outages.

### Layer 3: Emergency Stale Cache (Total Failure)
- **Mechanism**: If `updatePrice()` fails (Chainlink Reverts/Broken) inside `postOp`.
- **Logic**: The contract catches the error and **defaults to the existing (stale) cache**.
- **Result**: **Transaction Succeeds**. 
- **Risk**: Paymaster relies on potentially old prices, but service availability is preserved (Liveness > Accuracy in emergency).

> **Conclusion**: This model achieves the "Sweet Spot" of:
> *   **Low Gas**: 99% usage (Cache).
> *   **High Accuracy**: 1% deviation updates (Keeper).
> *   **Max Availability**: Works even if Keeper AND Chainlink both have issues.

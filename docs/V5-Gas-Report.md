# SuperPaymaster V5.2 Gas Consumption Report

**Date**: 2026-03-22
**Version**: SuperPaymaster-5.2.0
**Contract Size**: 24,039 bytes (24,576 limit, 537 remaining)
**Network**: Sepolia (Chain ID: 11155111)
**Compiler**: Solidity 0.8.33, optimizer 10,000 runs, via-IR, Cancun EVM

---

## 1. V5.2 New Feature Gas Costs (Forge Unit Tests)

| Function | Min | Avg | Median | Max | Calls |
|----------|-----|-----|--------|-----|-------|
| `setAgentPolicies` | 12,767 | 50,183 | 60,008 | 83,611 | 8 |
| `getAgentSponsorshipRate` (view) | 8,832 | 22,483 | 25,233 | 29,086 | 7 |
| `isRegisteredAgent` (view) | 4,117 | 7,677 | 9,457 | 9,457 | 3 |
| `setAgentRegistries` | 3,211 | 29,521 | 31,683 | 31,683 | 29 |
| `settleX402PaymentPermit2` | 21,293 | 102,555 | 137,598 | 159,903 | 5 |
| `setFacilitatorFeeBPS` | 2,544 | 23,268 | 25,969 | 25,969 | 30 |
| `setOperatorFacilitatorFee` | 3,877 | 15,523 | 16,089 | 26,039 | 4 |
| `withdrawFacilitatorEarnings` | 26,233 | 26,233 | 26,233 | 26,233 | 1 |

### Analysis

- **`settleX402PaymentPermit2`**: Median 137,598 gas. Includes nonce check + Permit2 `permitWitnessTransferFrom` + ERC20 `safeTransfer` + event. The min (21,293) reflects early-revert cases (unauthorized/replay).
- **`setAgentPolicies`**: Median 60,008. Scales with policy count (min covers delete-only, max covers writing 3+ policies).
- **`getAgentSponsorshipRate`**: View-only, 25K avg. Involves external calls to reputation registry + policy array iteration.

---

## 2. Core SuperPaymaster Operations (Forge, All Tests)

| Function | Min | Avg | Median | Max | Calls |
|----------|-----|-----|--------|-----|-------|
| `configureOperator` | 13,165 | 76,058 | 78,223 | 89,658 | 41 |
| `deposit` | 29,917 | 97,813 | 116,482 | 119,166 | 24 |
| `depositFor` | 47,527 | 61,862 | 47,527 | 121,473 | 58 |
| `withdraw` | 542 | 20,805 | 21,787 | 39,104 | 4 |
| `updatePrice` | 76,624 | 77,475 | 76,646 | 81,030 | 94 |
| `updatePriceDVT` | 26,814 | 64,270 | 76,756 | 76,756 | 4 |
| `setAPNTsToken` | 3,946 | 8,089 | 7,703 | 10,503 | 12 |
| `setProtocolFee` | 3,160 | 7,203 | 8,085 | 9,485 | 4 |
| `setOperatorPaused` | 4,190 | 13,164 | 10,456 | 27,556 | 8 |
| `setOperatorLimits` | 14,794 | 14,794 | 14,794 | 14,794 | 5 |
| `slashOperator` | 3,974 | 136,332 | 171,870 | 171,870 | 7 |
| `withdrawProtocolRevenue` | 3,519 | 31,221 | 31,221 | 58,923 | 2 |
| `version` (view) | 922 | 922 | 922 | 922 | 3 |

---

## 3. Gasless Transfer Gas (Sepolia E2E, On-Chain)

Real on-chain gas estimates for ERC-4337 UserOperation gasless transfers:

| Scenario | Estimated Gas | Status | Notes |
|----------|--------------|--------|-------|
| PaymasterV4 + aPNTs transfer | 412,311 | PASS | Direct paymaster, 1 aPNTs transfer |
| SuperPaymaster + xPNTs1 (Anni operator) | 448,200 | PASS | Via operator routing, 1 aPNTs transfer |
| SuperPaymaster + xPNTs2 (Anni operator) | 448,200 | PASS | Via operator routing, 1 aPNTs transfer |
| **x402 Permit2 Settlement (1 USDC)** | **200,083** | **PASS** | **Permit2 + witness + fee split, 2% fee** |

### Gas Overhead Analysis

| Metric | Value |
|--------|-------|
| PaymasterV4 (direct) | ~412K gas |
| SuperPaymaster (routing) | ~448K gas |
| **Routing overhead** | **~36K gas (+8.7%)** |

The 8.7% overhead covers: operator config lookup, xPNTs exchange rate calculation, aPNTs balance deduction, protocol fee calculation, and reputation accrual.

---

## 4. Admin Operation Gas (Sepolia E2E, On-Chain)

| Operation | Gas Used | Category |
|-----------|----------|----------|
| `setOperatorLimits(60)` | 43,802 | Operator Config |
| `setOperatorPaused(true)` | 36,808 | Operator Config |
| `setOperatorPaused(false)` | 36,797 | Operator Config |
| `deposit(10 aPNTs)` | 77,166 | Deposit/Withdraw |
| `depositFor(5 aPNTs)` | 76,701 | Deposit/Withdraw |
| `withdraw(3 aPNTs)` | 62,357 | Deposit/Withdraw |
| `updatePrice()` | 66,975 | Oracle |
| `setAPNTSPrice(0.03)` | 36,469 | Pricing |
| `setProtocolFee(500)` | 35,490 | Fees |
| `slashOperator(WARNING)` | 119,419 | Slash |
| `updateReputation(100)` | 37,211 | Reputation |
| `setCreditTier(7, 5000)` | 52,088 | Credit |
| `setRule("E2E_ACTIVITY")` | 154,834 | Reputation Rules |

---

## 5. Gas Cost Breakdown by Category

### Low-Cost Operations (< 50K gas)
- View calls, admin setters, pause/unpause
- Typical cost: $0.003–$0.008 at 30 gwei / $2,000 ETH

### Medium-Cost Operations (50K–120K gas)
- `deposit`, `withdraw`, `updatePrice`, `configureOperator`
- Typical cost: $0.008–$0.020

### High-Cost Operations (> 120K gas)
- `settleX402PaymentPermit2`: ~138K (median)
- `slashOperator`: ~172K (with state changes)
- `setRule` (ReputationSystem): ~155K (string storage)
- Gasless UserOp (full ERC-4337 flow): ~412K–448K
- Typical cost: $0.020–$0.070

---

## 6. Deployment Gas

| Component | Gas | Size |
|-----------|-----|------|
| SuperPaymaster implementation | 5,367,019 | 24,871 bytes |
| ERC1967 Proxy | 306,287 | 936 bytes |
| UUPS upgrade (`upgradeToAndCall`) | ~16,001 | — |

UUPS upgrade cost: **~5.4M gas** (new impl deploy) + **~16K gas** (proxy upgrade call) = total ~5.42M gas.
At 30 gwei / $2,000 ETH: ~$0.33 for deployment.

---

## 7. E2E Test Summary

| Phase | Tests | Passed | Failed |
|-------|-------|--------|--------|
| Phase 0: Preflight | 2 | 2 | 0 |
| Phase 1: Registry | 2 | 2 | 0 |
| Phase 2: Operator | 2 | 2 | 0 |
| Phase 3: Negative | 2 | 2 | 0 |
| Phase 4: Reputation | 2 | 2 | 0 |
| Phase 5: Pricing | 2 | 2 | 0 |
| Phase 6: Staking | 2 | 2 | 0 |
| Phase 7: Gasless | 3 | 2 | 1* |
| **Total** | **17** | **16** | **1** |

**\*** Single failure is `replacement transaction underpriced` (Sepolia nonce collision), not a contract bug.

### Verification Status
- SuperPaymaster version confirmed: `SuperPaymaster-5.2.0`
- All existing functionality preserved (backward compatible)
- UUPS proxy upgrade successful (v5.0.0 → v5.2.0)

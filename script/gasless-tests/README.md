# SuperPaymaster E2E Test Suite

On-chain end-to-end tests covering all deployed contract ABIs on Sepolia.

## Quick Start

```bash
cd script/gasless-tests

# Fast: gasless UserOp core tests only (TC1-TC4, ~5 min)
./run-all-tests.sh

# Full: all 34 test groups across 12 phases (~30–60 min)
./run-all-e2e-tests.sh
```

Both scripts read configuration from `.env.sepolia` in the project root.

## Test Scripts

### `run-all-tests.sh` — Core Gasless Tests

Runs the 4 gasless UserOp test cases that verify the complete ERC-4337 flow
with real on-chain transactions. Includes a pre-flight step that refreshes
the Chainlink price cache before testing (prevents `AA32 paymaster expired`).

| Test | Contract | Flow |
|------|----------|------|
| TC1: PaymasterV4 + xPNTs | Paymaster v4 | depositFor → UserOp → burn xPNTs |
| TC2: SuperPaymaster xPNTs1 | SuperPaymaster | configureOperator → UserOp → burnFromWithOpHash |
| TC3: SuperPaymaster xPNTs2 | SuperPaymaster | Same flow, different AA account |
| TC4: SP Credit/Debt Path | SuperPaymaster | recordDebtWithOpHash (zero-balance account) |

**Result file**: `results/<timestamp>_run-all-tests.md` — includes TX hashes and Etherscan links.

### `run-all-e2e-tests.sh` — Full ABI Coverage Suite

Runs all 34 test groups covering every public write function in the deployed contracts.

| Phase | Groups | Description |
|-------|--------|-------------|
| 0 | Check Contracts, Check Balances | Preflight: versions, balances |
| 1 | A1, A2 | Registry: roles, queries |
| 2 | B1–B5 | Operator config, deposit/withdraw, SP governance, dry-run |
| 3 | C1, C2 | Negative / boundary cases |
| 4 | D1, D2 | Reputation rules, credit tiers |
| 5 | E1–E4 | Pricing, protocol fees, exchange rate accounting, repayDebt |
| 6 | F1–F3 | Staking queries, slash history, staking/registry admin |
| 7 | G1–G3 | V5.3 agent economy scenarios |
| 8 | H1, H2 | DVT / BLS / Reputation infrastructure |
| 9 | Gasless TC1–TC4 | Real UserOp transactions (same as run-all-tests.sh) |
| 10 | MicroPaymentChannel, x402 | Streaming vouchers, EIP-3009 settlement |
| 11 | P2 | PaymasterV4 lifecycle (activate/deactivate, deposit, withdraw) |
| 12 | X1 | xPNTs token admin (limits, spenders, exchange rate) |

**Result file**: `results/<timestamp>_run-all-e2e-tests.md` — markdown table with PASS/SKIP/FAIL per group.

## Result Files

All results are saved to `script/gasless-tests/results/` with timestamp prefixes:

```
results/
  2026-05-30_10-49-51_run-all-e2e-tests.md   ← Full suite result
  2026-05-30_09-00-00_run-all-tests.md        ← Core gasless result
```

Each file contains:
- Environment: network, contract addresses
- Per-test status table (PASS ✅ / FAIL ❌ / SKIP ⏭️)
- TX hashes and Etherscan links for on-chain transactions
- Summary counts

## ABI Coverage Map

| Contract | Test Groups |
|----------|-------------|
| **SuperPaymaster** | B1–B5, C1, E1–E4, F2, G1–G3, Gasless TC2/TC3/TC4 |
| **Registry** | A1, A2, D1, D2, F3 |
| **xPNTsToken** | B2, E3, E4, X1 |
| **GTokenStaking** | F1, F3 |
| **PaymasterV4** | B2, C2, E1, P2, Gasless TC1 |
| **ReputationSystem** | D1, H2 |
| **BLSAggregator / DVTValidator** | H1, H2 |
| **MicroPaymentChannel** | Phase 10 MicroPaymentChannel |

## Exit Code Convention

All test scripts use this convention:

| Code | Meaning |
|------|---------|
| `0` | PASS — test ran and all assertions passed |
| `1` | FAIL — test ran but assertion(s) failed |
| `2` | SKIP — precondition not met (zero balance, RPC error, config missing) |

> Never use bare `return` in an async main — it exits 0 and gives a false PASS.
> Always use `process.exit(2)` for skip paths.

## Prerequisites

1. Contracts deployed to Sepolia (`./deploy-core sepolia`)
2. Test accounts set up (`./prepare-test sepolia`)
3. AA accounts funded with aPNTs tokens (`node transfer-tokens.js`)
4. `.env.sepolia` with: `SEPOLIA_RPC_URL`, `OWNER_PRIVATE_KEY`, `TEST_AA_ACCOUNT_ADDRESS_A`, `OPERATOR_ADDRESS`

## Common Failures

| Error | Cause | Fix |
|-------|-------|-----|
| `AA32 paymaster expired or not due` | Chainlink price cache stale | Run `node setup-gasless.js` first |
| `SKIP: Account A has no available credit` | creditTierConfig[1]=0, no reputation | TC4 now auto-sets tier via Registry.setCreditTier |
| `Function.prototype.apply on undefined` | Function not in ethers ABI | Check ABI.SuperPaymaster in test-helpers.js |
| `missing revert data (data=null)` | Wrong function name (wrong selector) | Check deployed ABI vs test ABI (cast sig) |

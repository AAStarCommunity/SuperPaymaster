# E2E Test Suite for SuperPaymaster v4.1.x

Comprehensive on-chain E2E tests for all major contract flows on Sepolia.

## Overview

| Group | Name | Type | Tests | Description |
|-------|------|------|-------|-------------|
| -- | check-contracts | Preflight | -- | Verify all 13 contracts deployed + version strings |
| -- | check-balances | Preflight | -- | Token balances + EntryPoint ETH deposits |
| A1 | Registry Roles | Write | 7 | Register community, enduser, SBT verification |
| A2 | Registry Queries | Read | 6 | Role constants, configs, member counts, credit tiers, wiring |
| B1 | Operator Config | Write | 6 | configureOperator, limits, pause/unpause cycle |
| B2 | Operator Deposit/Withdraw | Write | 6 | deposit, depositFor, withdraw, excess revert |
| C1 | SuperPaymaster Negative | Read | 4 | No SBT, paused operator, unconfigured operator, userOpState |
| C2 | PaymasterV4 Negative | Read | 3 | Zero-balance user, supported tokens query |
| D1 | Reputation Rules | Write | 7 | setRule, computeScore, entropyFactor, communityReputation |
| D2 | Credit Tiers | Write | 6 | setCreditTier, levelThresholds, getCreditLimit |
| E1 | Pricing & Oracle | Write | 6 | cachedPrice, updatePrice, setAPNTSPrice, Chainlink, V4 |
| E2 | Protocol Fees | Write | 4 | setProtocolFee, MAX revert, revenue queries |
| F1 | Staking Queries | Read | 7 | totalStaked, stakes, lockedStake, previewExitFee, wiring |
| F2 | Slash History | Write | 6 | getSlashCount, slashOperator WARNING, updateReputation |
| -- | Gasless Test 1 | E2E TX | -- | PaymasterV4 + aPNTs gasless transfer |
| -- | Gasless Test 2 | E2E TX | -- | SuperPaymaster + aPNTs gasless transfer |
| -- | Gasless Test 3 | E2E TX | -- | SuperPaymaster + aPNTs (different AA account) |

**Total: ~68 test points across 17 test groups.**

## Contract Addresses

All addresses are loaded dynamically from `deployments/config.sepolia.json`. No hardcoded addresses in test scripts.

## Environment Configuration

All test scripts read from `.env.sepolia` in the project root (override via `ENV_FILE`):

- `SEPOLIA_RPC_URL`: Sepolia RPC endpoint
- `DEPLOYER_PRIVATE_KEY` / `PRIVATE_KEY`: Deployer private key
- `OPERATOR_ADDRESS`: SuperPaymaster operator (Anni)
- `TEST_AA_ACCOUNT_ADDRESS_A/B/C`: SimpleAccount (AA) addresses

**Important**: Private keys and RPC URLs are NOT committed to the repo.

## Running Tests

### Prerequisites

```bash
# Install dependencies (ethers v6 + dotenv)
cd script/gasless-tests && pnpm install ethers dotenv
```

### Run full E2E suite

```bash
./script/gasless-tests/run-all-e2e-tests.sh
```

Executes all tests in dependency order across 7 phases. Each failure does NOT abort the run; a summary table is printed at the end.

### Run individual test groups

```bash
# Read-only tests (safe, no state changes)
node script/gasless-tests/test-group-A2-registry-queries.js
node script/gasless-tests/test-group-F1-staking-queries.js

# Write tests (modify on-chain state, then restore)
node script/gasless-tests/test-group-D1-reputation-rules.js
node script/gasless-tests/test-group-E1-pricing-oracle.js
```

### Legacy gasless transfer tests

```bash
node script/gasless-tests/test-case-1-paymasterv4.js
node script/gasless-tests/test-case-2-superpaymaster-xpnts1-fixed.js
node script/gasless-tests/test-case-3-superpaymaster-xpnts2.js
```

## Dependency Order

```
test-helpers.js <- all test scripts

Independent (read-only): A2, F1
A1 (registry roles) -> B1 (needs ROLE_COMMUNITY)
B1 (operator config) -> B2 (needs configured operator)
B1 + B2 -> C1 (needs operator with balance)
A1 -> D1 (needs ROLE_COMMUNITY for rules)
B1 -> F2 (needs operator for slash)
Independent: C2, D2, E1, E2
```

## Safety & Idempotency

- **Read before write**: Already-registered roles are skipped
- **Restore after modify**: Price/fee changes are reverted after test
- **No Anni mutation**: Anni's config is only read, never modified
- **WARNING-level slash**: Uses 0-penalty WARNING slash, restores reputation after
- **Timestamped names**: Community names include timestamp to avoid conflicts
- **Nonce management**: Explicit nonce tracking prevents TX conflicts on rapid sends

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `could not coalesce error` | Nonce conflict from rapid TX sends | Wait for pending TXs, re-run |
| `replacement fee too low` | Duplicate nonce with lower gas | Wait for pending TX to confirm |
| `AA34 paymaster validation failed` | Expected in negative tests (C1/C2) | This IS the expected behavior |
| `AA21 didn't pay prefund` | Paymaster ETH balance insufficient | Deposit ETH to Paymaster |

## Directory Structure

```
script/gasless-tests/
├── test-helpers.js                              # Shared: ABIs, roles, display, assertions, TX wrapper
├── test-group-A1-registry-roles.js              # Registry role lifecycle
├── test-group-A2-registry-queries.js            # Registry view queries
├── test-group-B1-operator-config.js             # Operator configuration
├── test-group-B2-operator-deposit-withdraw.js   # Operator deposits & withdrawals
├── test-group-C1-gasless-negative.js            # SuperPaymaster negative cases
├── test-group-C2-paymasterv4-negative.js        # PaymasterV4 negative cases
├── test-group-D1-reputation-rules.js            # Reputation rules & scoring
├── test-group-D2-credit-tiers.js                # Credit tier configuration
├── test-group-E1-pricing-oracle.js              # Pricing & oracle
├── test-group-E2-protocol-fees.js               # Protocol fee configuration
├── test-group-F1-staking-queries.js             # Staking queries
├── test-group-F2-slash-queries.js               # Slash history & tests
├── run-all-e2e-tests.sh                         # Full test runner (dependency-ordered)
├── load-config.js                               # Config loader
├── check-contracts.js                           # Contract deployment check
├── check-balances.js                            # Token balance check
├── mint-tokens.js                               # Mint aPNTs utility
├── transfer-tokens.js                           # Transfer aPNTs utility
├── test-case-1-paymasterv4.js                   # Legacy: PaymasterV4 gasless
├── test-case-2-superpaymaster-xpnts1.js         # Legacy: SuperPaymaster gasless
├── test-case-2-superpaymaster-xpnts1-fixed.js   # Legacy: SuperPaymaster gasless (fixed)
├── test-case-3-superpaymaster-xpnts2.js         # Legacy: SuperPaymaster gasless
└── README.md                                    # This file
```

# PaymasterV4.3 Changelog — Token Management & Stablecoin Support

**Version**: PMV4-Deposit-4.3.0
**Date**: 2026-03-04
**Branch**: `v4-refine-stablecoin`

---

## New Features

### 1. Token Tracking System (`PaymasterBase.sol`)

Added on-chain tracking of supported tokens with O(1) lookup and bounded storage:

- **`_supportedTokens`** (private array) — Ordered list of supported token addresses
- **`_tokenIndex`** (private mapping) — 1-based index for O(1) existence check
- **`MAX_GAS_TOKENS = 10`** — Hard cap prevents unbounded gas in view calls

### 2. Token Management Functions

| Function | Access | Description |
|----------|--------|-------------|
| `removeToken(address)` | Owner | Remove token via swap-and-pop; clears price, decimals, and tracking |
| `getSupportedTokens()` | View | Returns all supported token addresses |
| `isTokenSupported(address)` | View | O(1) check if token is currently supported |
| `getSupportedTokensInfo()` | View | Returns (addresses[], prices[], decimals[]) in one call |

### 3. Multi-Chain Stablecoin Configuration

Created `deployments/stablecoins.json` with verified token addresses for:

| Chain | USDC | USDT | Notes |
|-------|------|------|-------|
| Ethereum (1) | `0xA0b8...eB48` | `0xdAC1...1ec7` | Native |
| Optimism (10) | `0x0b2C...Ff85` | `0x94b0...e68` | Native USDC + bridged USDT |
| Arbitrum (42161) | `0xaf88...5831` | `0xFd08...cbb9` | Native |
| Base (8453) | `0x8335...2913` | `0xfde4...b2` | Native USDC + bridged USDT |
| Polygon (137) | `0x3c49...3359` | `0xc213...8e8F` | Native |
| Sepolia (11155111) | `0x1c7D...7238` | Mock (deploy) | Circle testnet faucet |
| OP Sepolia (11155420) | `0x5fd8...30D7` | — | Circle testnet |

### 4. Deployment Scripts

- **`ConfigureStablecoins.s.sol`** — Batch configure USDC/USDT on deployed paymaster via env vars
- **`TestStablecoinSepolia.s.sol`** — Full E2E: deploy impl + proxy, configure tokens, deposit, verify
- **`DeployAndTestV4.s.sol`** — Standalone 13-test regression covering all V4.3 features

---

## Modified

### `setTokenPrice(address token, uint256 price)` — Enhanced

- **Added**: `token == address(0)` validation → `Paymaster__ZeroAddress`
- **Added**: `price == 0` validation → `Paymaster__InvalidOraclePrice`
- **Added**: Automatic `_supportedTokens` tracking (push + index on first add, skip on update)
- **Breaking**: `setTokenPrice(token, 0)` now reverts. Use `removeToken()` to disable tokens.

---

## New Errors & Events

| Type | Name | Trigger |
|------|------|---------|
| Error | `Paymaster__MaxTokensReached` | `setTokenPrice` when 10 tokens already configured |
| Error | `Paymaster__TokenNotInList` | `removeToken` for token not in list |
| Event | `TokenRemoved(address indexed token)` | After successful `removeToken` |

---

## Tests Added

### Unit Tests (`PaymasterV4.t.sol`) — 10 new tests

1. `test_SupportUSDT_DepositAndValidate` — USDT deposit + UserOp validation
2. `test_USDT_FullFlow_ValidateAndPostOp` — Full lifecycle with refund
3. `test_GetSupportedTokens_Empty` — Empty initial state
4. `test_SetTokenPrice_AddsToList` — Multi-token registration
5. `test_SetTokenPrice_UpdateDoesNotDuplicate` — Price update, no array duplicate
6. `test_RemoveToken` — Swap-and-pop with state cleanup verification
7. `test_RemoveToken_RevertIfNotInList` — Error case
8. `test_RemoveToken_DepositReverts` — Deposit blocked after removal
9. `test_GetSupportedTokensInfo` — Multi-return view function
10. `test_MaxTokensReached` — 10-token limit enforcement

### Sepolia On-Chain Tests (`DeployAndTestV4.s.sol`) — 13 tests

T1–T13 covering: deploy+init, token config, list queries, EntryPoint deposit, Chainlink price cache, MockUSDT deposit, USDC deposit, withdraw, removeToken, re-add token, price update no-dup, admin setters, pause state.

**Result**: 12 passed, 0 failed, 1 skipped (USDC faucet balance)

---

## Security Review

See `docs/Security-Review-V4.3-TokenManagement.md`

- **0 Critical / 0 High / 0 Medium** vulnerabilities
- 2 Low (by-design behaviors), 2 Info
- Swap-and-pop index logic verified correct for all edge cases
- Access control: all mutations require `onlyOwner`
- No reentrancy vectors in new code

---

## Migration Notes

1. **`setTokenPrice(token, 0)` no longer works** — use `removeToken(token)` instead
2. **Storage layout**: New variables appended at end — compatible with EIP-1167 Clones
3. **No ABI breaking changes** for existing functions (`depositFor`, `withdraw`, `validatePaymasterUserOp`, `postOp`)

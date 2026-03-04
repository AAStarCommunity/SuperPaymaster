# PaymasterV4.3 Security Review — Token Management

**Date**: 2026-03-04
**Scope**: `contracts/src/paymasters/v4/PaymasterBase.sol` — Token tracking, `removeToken`, view functions
**Reviewer**: Claude Code (automated)
**Branch**: `v4-refine-stablecoin`

---

## 1. Summary of Changes

| Change | Type | Lines |
|--------|------|-------|
| `_supportedTokens` array + `_tokenIndex` mapping | New storage | 93–96 |
| `setTokenPrice` — zero checks, token tracking | Modified | 482–503 |
| `removeToken` — swap-and-pop removal | New function | 507–526 |
| `getSupportedTokens` | New view | 529–531 |
| `isTokenSupported` | New view | 534–536 |
| `getSupportedTokensInfo` | New view | 542–557 |
| `Paymaster__MaxTokensReached` / `Paymaster__TokenNotInList` | New errors | 112–113 |
| `TokenRemoved` event | New event | 128 |

---

## 2. Security Analysis

### 2.1 Access Control — PASS

| Function | Modifier | Verdict |
|----------|----------|---------|
| `setTokenPrice` | `onlyOwner` | Correct |
| `removeToken` | `onlyOwner` | Correct |
| `getSupportedTokens` | `view` (public) | Correct |
| `isTokenSupported` | `view` (public) | Correct |
| `getSupportedTokensInfo` | `view` (public) | Correct |

All state-changing functions restricted to owner. View functions are safe for public access.

### 2.2 Reentrancy — PASS

- `setTokenPrice`: Only external call is `IERC20Metadata(token).decimals()` inside a `try/catch`. This is a `view` call with no state mutation risk. Owner-only, so attacker cannot inject malicious token addresses.
- `removeToken`: Pure storage manipulation — no external calls. No reentrancy vector.
- View functions: Read-only, inherently safe.

### 2.3 Swap-and-Pop Correctness — PASS

```solidity
uint256 idx = _tokenIndex[token] - 1;     // 0-based
uint256 lastIdx = _supportedTokens.length - 1;
if (idx != lastIdx) {
    address lastToken = _supportedTokens[lastIdx];
    _supportedTokens[idx] = lastToken;
    _tokenIndex[lastToken] = idx + 1;      // 1-based
}
_supportedTokens.pop();
delete _tokenIndex[token];
```

Verified edge cases:
- **Single element**: `idx == 0`, `lastIdx == 0` → no swap, just pop. Correct.
- **Remove last element**: `idx == lastIdx` → no swap, just pop. Correct.
- **Remove middle element**: Swaps with last, updates index of moved element. Correct.
- **Underflow**: `_tokenIndex[token] - 1` is safe because `_tokenIndex[token] == 0` is checked and reverted prior.
- **Index consistency**: After swap, `_tokenIndex[lastToken]` is updated to `idx + 1` (1-based). Correct.

### 2.4 Duplicate Prevention — PASS

`setTokenPrice` checks `_tokenIndex[token] == 0` before pushing to the array. If the token already exists, it skips the array push and only updates price/decimals. Verified by unit test `test_SetTokenPrice_UpdateDoesNotDuplicate`.

### 2.5 Bounded Array Growth — PASS

`MAX_GAS_TOKENS = 10` limits `_supportedTokens` to 10 elements. This bounds:
- `getSupportedTokens()` return size
- `getSupportedTokensInfo()` loop iterations (max 10)
- Storage slot usage

No risk of unbounded gas consumption in view functions.

### 2.6 Token Re-addition After Removal — PASS

After `removeToken`:
- `_tokenIndex[token]` is deleted (→ 0)
- `tokenPrices[token]` is deleted (→ 0)
- `tokenDecimals[token]` is deleted (→ 0)

Calling `setTokenPrice` again correctly detects `_tokenIndex[token] == 0` and pushes a fresh entry. No stale index issues. Verified by unit test `test_RemoveToken` + Sepolia T10.

### 2.7 Storage Layout (Proxy Safety) — PASS

New storage variables `_supportedTokens` and `_tokenIndex` are appended to the end of PaymasterBase storage layout. The contract uses **EIP-1167 Minimal Proxy (Clones)** pattern, where each clone has its own independent storage. No storage slot collision risk.

Note: If migrating to UUPS upgradeable proxy in the future, storage layout must be preserved. Current append-only approach is forward-compatible.

### 2.8 Breaking Change: `setTokenPrice(token, 0)` — INFO

Previously, `setTokenPrice` accepted `price == 0` which implicitly disabled a token. The new version reverts with `Paymaster__InvalidOraclePrice()` when `price == 0`.

**Migration**: Use `removeToken(token)` to disable a token. This is a safer, more explicit API.

**Impact**: Low — only affects admin operations, not user funds. Existing deployments with old code are unaffected (new code deployed fresh).

---

## 3. Potential Issues

### 3.1 [LOW] User Balances Persist After Token Removal

When `removeToken` is called, users with existing deposits still retain internal balances. The `withdraw()` function does NOT check `tokenPrices[token]`, so users **can** withdraw after token removal.

**Verdict**: This is correct and intentional. Users should always be able to withdraw deposited funds. No action needed.

### 3.2 [LOW] Treasury Revenue in Removed Tokens

After `removeToken`, the treasury may still hold accrued revenue in that token (from past `postOp` calls). The treasury can still withdraw these funds via `withdraw()`.

**Verdict**: Working as designed. No funds locked.

### 3.3 [INFO] Malicious Token `decimals()` Gas Consumption

A malicious ERC20's `decimals()` function could consume excessive gas. This is mitigated by:
1. `setTokenPrice` is `onlyOwner` — attacker cannot inject arbitrary tokens
2. The call is inside `try/catch` — failure defaults to 18 decimals
3. Validator gas limit provides natural bound

**Verdict**: No action needed. Owner is trusted for token configuration.

### 3.4 [INFO] No `whenNotPaused` on Admin Functions

`setTokenPrice` and `removeToken` work even when the contract is paused. This is intentional — admin should be able to reconfigure tokens during emergency pause.

---

## 4. Test Coverage

| Test | Description | Status |
|------|-------------|--------|
| `test_GetSupportedTokens_Empty` | Empty list returns `[]` | PASS |
| `test_SetTokenPrice_AddsToList` | Multi-token add | PASS |
| `test_SetTokenPrice_UpdateDoesNotDuplicate` | Price update, no dup | PASS |
| `test_RemoveToken` | Swap-and-pop, state cleanup | PASS |
| `test_RemoveToken_RevertIfNotInList` | Revert on non-existent | PASS |
| `test_RemoveToken_DepositReverts` | Deposit blocked after removal | PASS |
| `test_GetSupportedTokensInfo` | Multi-return correctness | PASS |
| `test_MaxTokensReached` | 10 token limit enforced | PASS |
| `test_SupportUSDT_DepositAndValidate` | USDT 6-decimal deposit + validate | PASS |
| `test_USDT_FullFlow_ValidateAndPostOp` | USDT full lifecycle with refund | PASS |

**Sepolia on-chain verification**: 12/13 tests passed (1 skipped — USDC faucet balance). See `DeployAndTestV4.s.sol`.

---

## 5. Conclusion

| Severity | Count | Details |
|----------|-------|---------|
| Critical | 0 | — |
| High | 0 | — |
| Medium | 0 | — |
| Low | 2 | Stranded balances (by design), treasury revenue (by design) |
| Info | 2 | Breaking change documentation, `decimals()` gas |

**Overall Assessment**: The token management changes are **secure**. No vulnerabilities found. The swap-and-pop pattern is correctly implemented, access control is properly enforced, and all edge cases are covered by tests. The code is ready for production use.

# Wave 3 — Tokens & V4 Paymaster (P0 fixes)

**Branch**: `fix/p0-wave3-tokens-v4`
**Base**: `main` (f23bd43)
**Spec**: `docs/security/2026-04-26-p0-prelaunch.md` (audit branch) §3

## Scope

5 P0 items affecting xPNTs token, V4 paymaster, and validation UX:

| # | ID | File | Status |
|---|---|---|---|
| P0-5 | B5-H1 | `Paymaster.sol::deactivate/activate` (V4) | TODO |
| P0-6 | B5-H2 | `PaymasterBase.sol::pause/unpause` (V4) | DOING |
| P0-7 | B4-H1 | `xPNTsToken.sol::emergencyRevokePaymaster` | TODO |
| P0-8 | B4-H2 | `xPNTsToken.sol::burn` (per-spender daily cap) | TODO |
| P0-15 | J2-BLOCKER-1 | `SuperPaymaster.sol::dryRunValidation` | TODO |

## Design (locked per 2026-04-28 user decisions)

### P0-5: V4 Paymaster deactivate via Registry.exitRole
- Replace `Registry.deactivate/activate` calls (functions don't exist on V3 Registry) with `Registry.exitRole(ROLE_PAYMASTER_AOA)` / `Registry.assignRole(...)`
- Verify operator support workflow

### P0-6: V4 Paymaster pause setter (DOING)
Code already has:
- `bool public paused;` field (line 83)
- `whenNotPaused` modifier (line 165)
- `Paused` / `Unpaused` events (lines 121-122)
- Constructor sets `paused = false`

But NO `pause()` / `unpause()` setters. Add them as `onlyOwner` and emit defined events.

### P0-7: xPNTs emergencyDisabled flag
- `bool public emergencyDisabled` storage var
- `emergencyRevokePaymaster()` sets `emergencyDisabled = true` AND clears autoApprovedSpenders[currentSP]
- New `unsetEmergencyDisabled()` (community owner) — clears flag after recovery
- `burnFromWithOpHash` (path 1) and autoApproved `burn` (path 2) both gated by `!emergencyDisabled`
- Recovery via existing `setSuperPaymasterAddress(newSP)` (already exists at line 399)

### P0-8: Per-spender daily burn cap
- Storage: `mapping(address => SpenderRateLimit) spenderRateLimit` { dailyBurnTotal, windowStart }
- `uint256 public spenderDailyCapTokens` (default 50_000 ether ≈ $1000 @ $0.02; community multisig adjustable)
- `_checkSpenderRateLimit(spender, amount)` invoked in autoApproved burn path
- Unauthorized burn variant from non-owners must enforce `_spendAllowance` (the original B4-H2 also-fixes)

### P0-15: dryRunValidation view
- `function dryRunValidation(PackedUserOperation calldata, uint256 maxCost) external view returns (bool ok, bytes32 reasonCode)`
- Mirrors all 6 silent-reject paths in `validatePaymasterUserOp`
- Reason codes: `OPERATOR_NOT_CONFIGURED`, `OPERATOR_PAUSED`, `USER_NOT_ELIGIBLE`, `USER_BLOCKED`, `RATE_LIMITED`, `INSUFFICIENT_BALANCE`, `RATE_COMMITMENT_VIOLATED`, `STALE_PRICE`
- Emit `ValidationFailed(userOpHash, reasonCode)` in actual validation as well (off-chain logs)

## Execution order

1. **P0-6** (smallest — 2 functions + emit events) — DOING FIRST
2. **P0-5** (related to P0-6, V4 Registry interface)
3. **P0-15** (mirror checks, no new logic)
4. **P0-8** (per-spender rate limit + burn allowance)
5. **P0-7** (emergencyDisabled flag — touches many burn paths, do last in this wave)

## Tests required

Per `docs/security/2026-04-25-review.md` §5.4.1:

- [ ] `test_PaymasterV4_PauseUnpauseOnlyOwner`
- [ ] `test_PaymasterV4_DeactivateThroughRegistry`
- [ ] `test_xPNTs_EmergencyRevoke_BlocksBurn`
- [ ] `test_xPNTs_EmergencyDisabled_GatesAllBurnPaths`
- [ ] `test_xPNTs_BurnAddressUint_RespectsAllowance`
- [ ] `test_xPNTs_SpenderDailyCap_Enforced`
- [ ] `test_xPNTs_SpenderDailyCap_ResetsAfter24h`
- [ ] `test_DryRunValidation_ReturnsReasonCode` (8 paths)

## Status log

- 2026-04-28: branch created from main; plan documented; starting with P0-6

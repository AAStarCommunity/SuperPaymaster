# Wave 2 — Funds & Price (P0 fixes)

**Branch**: `fix/p0-wave2-funds-price`
**Base**: `main` (f23bd43)
**Spec**: `docs/security/2026-04-26-p0-prelaunch.md` (audit branch) §3

## Scope

8 P0 items affecting funds, price, and x402 settlement:

| # | ID | File | Status |
|---|---|---|---|
| P0-9 | B2-N1 | `SuperPaymaster.sol::setAPNTsToken` | TODO |
| P0-10 | B2-N2 + P3-H2 | `SuperPaymaster.sol::updatePriceDVT` (D8) | TODO |
| P0-11 | B2-N3 + B4-M2 + P3-H1 | 3 price setters across SP / xPNTsFactory / PaymasterBase | TODO |
| P0-12a | B2-N4 (D4 part 1) | `SuperPaymaster.sol::settleX402PaymentDirect` | TODO |
| P0-12b | D4 part 2 | xPNTs `approvedFacilitators` + xPNTsFactory | TODO |
| P0-13 | B3-N3 + B2-N8 | `SuperPaymaster.sol::x402SettlementNonces` | DOING |
| P0-14 | H-01 | `Registry.sol` + `GTokenStaking.sol` slash sync | TODO |
| P0-16 | Codex B-N1 | 3 cache writers (SP + PaymasterBase) | TODO |

## Design (locked per 2026-04-28 user decisions)

### P0-9: setAPNTsToken with timelock + cancellation
- 7-day timelock; owner can cancel within window
- Execute requires `totalTrackedBalance == 0 && protocolRevenue == 0` at execute time
- Storage: `pendingAPNTsToken`, `pendingAPNTsTokenSetAt`
- 3 functions: `setAPNTsToken` (queue), `cancelAPNTsTokenChange` (revoke), `executeAPNTsTokenChange` (commit)

### P0-10: Chainlink break-glass tightening (D8)
- `enum PriceMode { CHAINLINK, EMERGENCY }`
- `emergencySetPrice(newPrice)`: only when `_chainlinkStale()` (1h threshold) + ±20% bound + 1h timelock
- Multisig 2/3 controls owner address (off-chain)
- Off-chain keeper monitors Chainlink + CEX, alerts via Slack webhook

### P0-11: Per-setter inline bounds (NOT shared mixin)
Three independent setters, each with own MIN/MAX/DELTA:
- `SP.setAPNTsPriceUSD`: aPNTs unit-of-account scale
- `xPNTsToken.updateExchangeRate`: xPNTs:aPNTs exchange rate (already P1-14 + 24h timelock; verify bounds present)
- `PaymasterBase.setCachedPrice`: ETH/USD oracle cache

### P0-12a: x402 Direct path → asset must be xPNTs
- `require(xPNTsFactory.isXPNTs(asset), "Direct: must be xPNTs")`
- Add `xPNTsFactory.isXPNTs(address) view` mapping populated on every `deployToken`

### P0-12b: Community-approved facilitator whitelist (D4)
- `xPNTsToken.approvedFacilitators` mapping
- `addApprovedFacilitator` / `removeApprovedFacilitator` (community multisig only)
- `xPNTsFactory.deployToken` accepts `address[] initialApprovedFacilitators`
- `settleX402PaymentDirect` requires `IXPNTsToken(asset).approvedFacilitators(msg.sender)`

### P0-13: x402 nonce per-asset triple key (DOING)
- Change key from `nonce` (global) to `keccak256(asset, from, nonce)` (per-(asset, from))
- Internal helper `_x402NonceKey(asset, from, nonce)`
- All sites that read/write `x402SettlementNonces` updated

### P0-14: Slash sync Registry ↔ Staking
- Staking is single source of truth
- `GTokenStaking.slashByDVT` + `unlockAndTransfer` callback `Registry.syncStakeFromStaking(user, role, newAmount)`
- Registry callback `onlyStaking`
- Add view `Registry.getEffectiveStake(user, role)` (prefer Staking)

### P0-16: Future timestamp guard
- `SP.updatePriceDVT`: `require(updatedAt <= block.timestamp)`
- `PaymasterBase.setCachedPrice`: same
- `PaymasterBase` postOp: safe subtraction (no underflow)

## Execution order

1. **P0-13** (smallest, isolated nonce key change) — DOING FIRST
2. **P0-16** (3-line require guard)
3. **P0-12a + P0-12b** (related, x402 settle hardening)
4. **P0-9** (timelock state machine)
5. **P0-10** (D8 break-glass — most complex)
6. **P0-11** (per-setter bounds — multiple files)
7. **P0-14** (cross-contract callback — needs careful test)

## Tests required

Per `docs/security/2026-04-25-review.md` §5.4.1:

- [ ] `test_X402Direct_RequiresXPNTs`
- [ ] `test_X402Direct_RequiresApprovedFacilitator`
- [ ] `test_Nonce_PerAssetPerFromIsolation`
- [ ] `test_SetAPNTsToken_RevertsWhenBalanceNonZero`
- [ ] `test_SetAPNTsToken_TimelockRespected`
- [ ] `test_SetAPNTsToken_CanCancelDuringTimelock`
- [ ] `test_DVTUpdate_RejectsExcessiveDeviation`
- [ ] `test_EmergencySetPrice_RequiresChainlinkStale`
- [ ] `test_EmergencySetPrice_Within20PercentBound`
- [ ] `test_PriceSetter_RejectsBelowMin` (3 surfaces)
- [ ] `test_FutureTimestamp_Rejected` (3 surfaces)
- [ ] `test_SlashSyncsRegistryRoleStakes`
- [ ] `test_SlashSync_RegistryCacheMatchesStaking`

Plus invariant:
- [ ] `INV_RegistryStakeMatchesStaking` (Echidna)

## Status log

- 2026-04-28: branch created from main; plan documented; starting with P0-13

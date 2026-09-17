# Slither + Aderyn Static Analysis Triage — 2026-09-17 (post D5b / D5c-1)

**Date**: 2026-09-17
**Source tree**: `HEAD` = `be170a48` (`Merge pull request #437 from AAStarCommunity/feat/a6-collector-mechanism`)
**Tools**: Slither 0.11.5 (`slither . --config-file slither.config.json`), Aderyn (`aderyn .`)
**Scope — Slither**: `contracts/src/**` per `slither.config.json` (excludes `lib/`, `test/`, `mocks/`, `script/`)
**Scope — Aderyn**: whole repo tree as configured by its own default include rules; in practice this run also picked up `contracts/src/mocks/*.sol`, which Slither's config excludes — noted per-finding below.
**Solc**: 0.8.33, via-ir, evm=cancun
**Raw artifacts**: `docs/security/slither-d5c2-2026-09-17.json` (19 MB, 248 detector results), `docs/security/aderyn-d5c2-2026-09-17.json` (137 KB), human-readable twins `slither-d5c2-2026-09-17.log` / `aderyn-d5c2-2026-09-17.log`.

**This report supersedes `docs/security/slither-report-2026-06-28.md` (SuperPaymaster-5.4.1-rc.1) for findings against the current source tree.** That report is the house-style baseline and remains authoritative for any finding this document explicitly marks "same as June baseline, unchanged, see that report" — those are not reproduced here. This document covers everything that changed since then: the D5b core/extension storage split (`SuperPaymasterStorage.sol`/`SuperPaymasterAdmin.sol`/`SuperPaymaster.sol`, `xPNTsV2Base.sol`/`xPNTsTokenV2.sol`/`xPNTsTokenV2Ext.sol`), the D5c-1 Halmos token-invariant work, and everything new in between (`LivenessRegistry.sol`, `PolicyRegistry.sol`, the BLSAggregator guardian-slash/guardian-exit machinery). **Aderyn is new to this repo's security docs** — the June baseline only ran Slither.

---

## Summary

| Tool | Severity | Total | Real (needs future PR) | Fixed since June | False Positive |
|---|---|---|---|---|---|
| Slither | High | 22 | 0 | — | 22 |
| Slither | Medium | 70 | 8 | 5 | 57 |
| Slither | Low | 114 | 0 (style/gas only) | — | 114 |
| Slither | Optimization | 42 | 0 (gas-only, deferred) | — | 42 |
| Aderyn | High | 10 | 0 | — | 10 |
| Aderyn | Low | 14 groups (~611 instances) | 1 group (zero-address-check, 13 instances) | — | 13 groups |
| **Total** | | **272 findings / groups** | **9 real items flagged for a future PR** | **5 confirmed fixed since June** | **the rest** |

Headline: nothing in this run is a fund-loss-now bug. The most important result is negative-but-good news — **June's M-12 Chainlink staleness fix (`answeredInRound >= roundId`) and its sibling M-15 are confirmed applied** in `SuperPaymasterAdmin.updatePrice`, `SuperPaymasterAdmin.updatePriceDVT`, `PaymasterBase.updatePrice`, and `PaymasterBase._calculateTokenCost` — all four now explicitly check `answeredInRound < roundId ⇒ revert`. The unused-return findings Slither still raises against those same functions are a different, shallower complaint (see M-Medium §unused-return below), not a regression of M-12.

The dominant new noise source is the D5b core/extension storage split: 19 of the 22 Slither High findings and 1 Aderyn High finding are `uninitialized-state` false positives because Slither/Aderyn analyze `xPNTsV2Base.sol` / `SuperPaymasterStorage.sol` (the storage-holding base contracts) without following writes made by sibling contracts (`xPNTsTokenV2.sol`, `xPNTsTokenV2Ext.sol`, `SuperPaymasterAdmin.sol`) that share the same storage layout via inheritance. This is a known, mechanical tool limitation for the diamond-storage / core-extension split pattern, not a design flaw — confirmed by grep below.

Nothing was fixed in this pass. Real, security-relevant, trivially-fixable findings are flagged "NOT fixed in this pass — needs its own PR" per the task scope; nothing under `contracts/src/` was modified.

---

## Slither — HIGH Findings

### H-S1 `reentrancy-balance` — X402Facilitator / MicroPaymentChannel (3 instances)
**Files**: `X402Facilitator.sol:246-257`, `MicroPaymentChannel.sol:184-226` (openChannel), `MicroPaymentChannel.sol:263-285` (topUpChannel)
**Verdict**: ✅ Same as June baseline H-1/H-2/H-3, unchanged. See that report — deliberate fee-on-transfer detection (`balBefore`/`received` pattern), no exploitable reentrancy window.

### H-S2 `uninitialized-state` — SuperPaymasterStorage / xPNTsV2Base (19 instances)
**Files**: `SuperPaymasterStorage.sol` (7 vars: `priceStalenessThreshold`, `sbtHolders`, `cachedPrice`, `_gasParams`, `paused`, `agentIdentityRegistry`, `_pendingSlash`), `xPNTsV2Base.sol` (12 vars: `community`, `communityName`, `communityENS`, `_tokenName`, `_tokenSymbol`, `emergencyDisabled`, `spenderDailyCapOverride`, `renewalMode`, `spenderDisabled`, `creditReq`, `creditPolicy`, `policyEpoch`)
**Verdict**: ✅ FALSE POSITIVE (new detector-type since June; June's High section had zero `uninitialized-state` findings because the core/extension split didn't exist yet)
**Reason**: `SuperPaymasterStorage.sol` and `xPNTsV2Base.sol` are pure storage-declaring base contracts in the D5b core/extension split. Every one of these 19 variables IS written — just from a *sibling* contract that inherits the same storage layout, which Slither's intraprocedural `uninitialized-state` detector doesn't follow. Verified by grep, e.g.:
- `SuperPaymasterStorage.paused` ← written at `SuperPaymasterAdmin.sol:108` (`paused = isPaused;`)
- `SuperPaymasterStorage.cachedPrice` ← written at `SuperPaymasterAdmin.sol:456,485`
- `SuperPaymasterStorage._pendingSlash` ← written at `SuperPaymasterAdmin.sol:537,556,573,603`
- `SuperPaymasterStorage.agentIdentityRegistry` ← written at `SuperPaymasterAdmin.sol:266`
- `xPNTsV2Base.community`/`communityName`/`communityENS`/`_tokenName` ← written at `xPNTsTokenV2.sol:76-79` (in `initialize`)
- `xPNTsV2Base.creditPolicy` ← written at `xPNTsTokenV2Ext.sol:172`; `emergencyDisabled` ← `xPNTsTokenV2Ext.sol:270,314`; `spenderDailyCapOverride[spender]` ← `xPNTsTokenV2Ext.sol:402`

This is the exact same mechanical FP pattern for every instance; no individual instance needs separate write-up. Anyone re-running this scan after a future storage/extension refactor should expect a similar batch unless the detector improves cross-contract-in-same-inheritance-chain tracking.

---

## Slither — MEDIUM Findings

### divide-before-multiply (2 instances)

**M-Med1 `xPNTsToken._update`** (`tokens/xPNTsToken.sol:612-641`) — ✅ Same as June baseline M-1, unchanged, NOT fixed in this pass. See that report for the fix (`Math.mulDiv` with explicit rounding). Real issue, needs its own PR.

**M-Med2 `xPNTsV2Base._update`** (`tokens/v2/xPNTsV2Base.sol:234-259`) — NEW (v2 token line did not exist in June).
**Verdict**: ⚠️ Real issue, same root cause as M-Med1, NOT fixed in this pass.
**Issue**: Identical pattern — `mintedAPNTs = (value * 1e18) / rate` (line 246) then `repayXPNTs = (repayAPNTs * rate + 1e18 - 1) / 1e18` (line 249) with `repayAPNTs = mintedAPNTs` (line 248) in between. Same sub-`rate` precision loss on the repay leg as the v1 token.
**Fix**: Same as M-Med1 — compute `repayXPNTs` via `Math.mulDiv(value, rate, 1e18, Math.Rounding.Ceil)` directly from `value`, not from the already-rounded `mintedAPNTs`.

### incorrect-equality (12 instances) — all sentinel/guard checks, same family as June's grouped FP note

**Verdict for all 12**: ✅ FALSE POSITIVE (extends June's "incorrect-equality (`== 0`/`address(0)`) — intentional zero-value guards, not strict balance checks" grouped note)
Every instance is a "has this ever been set" sentinel check, not a strict-equality balance comparison:

| Instance | Sentinel meaning |
|---|---|
| `MicroPaymentChannel.openChannel`/`topUpChannel` `received == 0` | fee-on-transfer zero-received guard (same as H-S1 family) |
| `SuperPaymasterAdmin.executeEmergencyPrice` `emergencyQueuedAt == 0` | "no emergency price queued" guard |
| `SuperPaymasterAdmin.priceValidUntil` `cachedPrice.updatedAt == 0` | "no price cached yet" guard |
| `LivenessRegistry.isOffline` `last == 0` | "never attested" sentinel |
| `xPNTsTokenV2Ext.activateSpender` `eta == 0` | "not yet proposed" sentinel |
| `BLSAggregator.cancelGuardianExit`/`consumeGuardianExit` `readyAt == 0` | "no exit queued" sentinel |
| `BLSAggregator.applyFraudProofVerifier` `readyAt == 0` | "not yet queued" sentinel |
| `ReputationSystem.updateNFTHoldStart` `balance == 0` | "holds no NFT" sentinel |
| `GTokenAuthorization._execute` (×2) `address(mySBT)==address(0) \|\| balanceOf(to)==0`, `xPNTsToken==address(0) \|\| !factory.isXPNTs(...) \|\| balanceOf(to)==0` | zero-address/not-yet-holding guards |

None of these compare a mutable balance against an attacker-influenced exact amount in a way that could be bypassed by dust; they are all "has this timestamp/counter ever been touched" checks. `LivenessRegistry`, `xPNTsTokenV2Ext`, and the `BLSAggregator` guardian-exit functions are new since June but follow the identical, already-reviewed pattern.

### reentrancy-no-eth (16 instances)

All 16 functions carry the `nonReentrant` modifier (verified by reading each signature). Breakdown:

**Real, unfixed since June (2)**:
- **`xPNTsFactory.deployxPNTsToken`** (`tokens/xPNTsFactory.sol:228-275`) — ✅ Same as June baseline M-3, unchanged, **confirmed still NOT fixed**: `communityToToken[msg.sender] = token;` (line 262) still executes after `newToken.initialize(...)`/`setSuperPaymasterAddress`/`addAutoApprovedSpender` (lines 248-256), and no `nonReentrant` modifier guards this function. Real issue, needs its own PR.
- **`xPNTsFactoryV2.deployxPNTsToken`** (`tokens/v2/xPNTsFactoryV2.sol:244-287`) — NEW sibling of the above with the identical CEI ordering and the identical absence of `nonReentrant`. Same fix as M-3.

**Real but low-risk / monitor, unchanged from June (1)**:
- **`MicroPaymentChannel.closeChannel`** (`paymasters/superpaymaster/v3/MicroPaymentChannel.sol:314-350`) — ✅ Same as June baseline M-4, unchanged. `delete _channels[channelId]` still executes after the two `safeTransfer` calls. Low actual risk (xPNTs is not ERC-777, `nonReentrant` is present), but violates CEI — see June's report for the "Monitor" priority classification, not re-derived here.

**False positive — protected by `nonReentrant`, extends June's grouped FP note (13)**:
- `Registry.registerRole` (×2 elements), `Registry.exitRole`, `Registry.safeMintForRole`, `BLSAggregator.executeGuardianSlash`, `BLSAggregator.verifyAndExecute`, `BLSAggregator.executeProposal`, `SuperPaymaster.postOp` — all `nonReentrant`-guarded; call targets are trusted internal protocol contracts (`GTOKEN_STAKING`, `ISuperPaymaster`, `IxPNTsTokenV2`), not attacker-supplied. `Registry.exitRole`'s new `IGuardianExitGate(blsAggregator).consumeGuardianExit(msg.sender)` call (added post-June for the guardian-exit integration) sits before `hasRole[...]=false` is cleared, but `blsAggregator` is an admin-configured system contract, not user-controlled, and the function is `nonReentrant`. `BLSAggregator.executeProposal` specifically checked: `executedProposals[proposalId]` is read-checked *before* `target.call(callData)` and the function is `nonReentrant`, so even a malicious `target` re-entering `executeProposal` cannot double-execute — confirmed by reading the function body.
- `GTokenStaking.topUpStake` — `nonReentrant onlyRegistry`; `GTOKEN` is a fixed, non-malicious ERC20.
- `MicroPaymentChannel.openChannel`/`topUpChannel`/`withdrawChannel` — `nonReentrant`; same fee-on-transfer-detection pattern as H-S1, extended to the `reentrancy-no-eth` detector on the same functions.
- `xPNTsTokenV2Ext._transferAndCall` — the flagged "state write after external call" (`_reentrancyStatus = 1`) IS the reentrancy guard's own unlock, written intentionally at the very end of the function after the protected `onTransferReceived` callback. This is the textbook reentrancy-guard-unlock FP pattern.

### uninitialized-local (13 instances)

**Same as June baseline, unchanged (2)**:
- `Registry.exitRole.exitFee` (`core/Registry.sol:403`) — same as June M-5.
- `GTokenStaking.slash.totalDeducted` (`core/GTokenStaking.sol:301`) — same as June M-6.

**New instances (11) — all FALSE POSITIVE, standard "Solidity zero-defaults + assigned on every path before use" non-issue**:
`PaymasterBase.postOp.actualTokenCost`, `PolicyRegistry.checkPolicy.requireDVT`, `xPNTsTokenV2Ext.proposeSP.byFactory`, `BLSAggregator._computeSignersCommitment.n`/`.k`, `BLSAggregator.executeGuardianSlash.released`, `BLSAggregator._requireCommitteeSurvivesExit.remaining`/`.leavingEligible`, `Registry.batchUpdateGlobalReputation.backfill`/`.aggregateRelease`/`.aggregateUplift`.
Spot-checked two representative instances: `PaymasterBase.postOp.actualTokenCost` is assigned in both the `try` and `catch` branches before any read (`PaymasterBase.sol:346-350`); `PolicyRegistry.checkPolicy.requireDVT` is a boolean flag correctly relying on its Solidity-guaranteed `false` default, only flipped to `true` inside a guarded branch (`PolicyRegistry.sol:161-174`). None of these touch fund-accounting/fee math the way June's M-5/M-6 did, so they don't get the same "real" classification June gave those two.

### unused-return (27 instances)

**Chainlink `latestRoundData()` family — confirms June M-12/M-15 FIX applied, current findings are a DIFFERENT/shallower complaint (5 instances, all FALSE POSITIVE)**:
`SuperPaymasterAdmin._isChainlinkStale`, `SuperPaymasterAdmin.updatePrice`, `SuperPaymasterAdmin.updatePriceDVT`, `PaymasterBase.updatePrice`, `PaymasterBase._calculateTokenCost`. Read all five: every one already has `if (answeredInRound < roundId) revert ...` — June's real M-12 fix is in place. The current unused-return complaint is a distinct, narrower artifact: each of these decomposes a 5-element tuple with one or more anonymous `,`-placeholder slots (e.g. `_isChainlinkStale`'s `try ... returns (uint80, int256, uint256, uint256 chainlinkUpdatedAt, uint80)`), and Slither's `unused-return` detector flags the call as "ignored" whenever any tuple element is dropped via blank placeholder, regardless of whether the meaningful elements are used. Verdict: FALSE POSITIVE, and worth recording that the real fix (M-12/M-15) is confirmed live.

**`GTokenAuthorization` — differs from June M-13's description; fresh analysis, FALSE POSITIVE (2 instances)**:
`cancelAuthorization` (`tokens/GTokenAuthorization.sol:204`) and `_execute` (`tokens/GTokenAuthorization.sol:257`) both do `(address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);` followed immediately by `if (err != ECDSA.RecoverError.NoError || recovered != authorizer/from) revert InvalidSignature();`. Both meaningful fields (`recovered`, `err`) are checked; only the anonymous third tuple element (raw error data, rarely useful) is dropped. June's M-13 described "`_execute` ignores `cancelAuthorization` return" — a different claim (a caller ignoring `cancelAuthorization`'s own return value) that doesn't match what's flagged here post-refactor. Verdict: FALSE POSITIVE, not a carry-over of M-13.

**`roleLocks()` partial-tuple consumption family — consistent with June M-10's "informational" framing (8 instances)**:
`Registry.exitRole` (`core/Registry.sol:408`, `(,,lockedAt,,) = GTOKEN_STAKING.roleLocks(...)`) is ✅ same as June baseline M-10, unchanged, P3/informational — see that report.
Seven NEW instances discard *every* field except `amount` (`(amount,None,None,None,None) = staking.roleLocks(...)`): `BLSAggregator._reconstructPkAgg`, `BLSAggregator._requireDVTStake`, `BLSAggregator._requireCommitteeSurvivesExit`, `BLSAggregator.executeGuardianSlash`, `DVTValidator.pruneValidator`, `DVTValidator._requireActiveValidator`, `DVTValidator.addValidator`. `roleLocks()` returns `(amount, ticketPrice, lockedAt, roleId_, metadata)` (`interfaces/v3/IGTokenStaking.sol:220-232`); all seven only need `amount` for a stake-eligibility check, so discarding the rest is intentional partial-tuple consumption, consistent with June's grouped FP note "unused-return on ... tuple destructuring — Return is checked via the struct, not the bool." Verdict: FALSE POSITIVE for all seven.

**Lens/view partial-tuple consumption — same family, FALSE POSITIVE (6 instances)**:
`SuperPaymasterLens._minPostOpGas` (ignores 2nd field of `s.gasParams()`), `SuperPaymasterAdminCalls.gasParams` (same), `SuperPaymasterLens.dryRunValidation` (×3: ignores 2nd field of `previewLock`, 3rd field of `cachedPrice()`, several fields of `operators()`), `xPNTsToken.backingValueUSD`/`xPNTsTokenV2Ext.backingValueUSD` (ignore most fields of `operators()`, only need `staked`/`isConfigured`/`linkedToken`). All are `view`/lens-style read paths that only need a subset of a multi-field return; no state-mutating or security-decision field is silently dropped in any of the six.

**`SuperPaymaster.postOp` ignoring `settleLocked`/`settleCredit` returns — FALSE POSITIVE by explicit design (2 instances)**:
Both calls (`SuperPaymaster.sol:419,421`) sit directly under the comment "B-1 §10.1 ①: NO try/catch. A failed settlement reverts postOp → EntryPoint rolls back the user's execution". The functions are called without try/catch specifically so that any failure reverts the whole transaction; there is no success/failure boolean to meaningfully check on the happy path. Documented, intentional design — not a gap.

**Same as June baseline, unchanged (4)**:
`Registry.safeMintForRole` ignoring `MYSBT.airdropMint` return (same as June M-9), `Registry.registerRole` ignoring `MYSBT.mintForRole` return (part of the June M-9/M-11 SBT-mint-return family), `Registry._firstTimeRegister` ignoring `GTOKEN_STAKING.lockStakeWithTicket` return (part of the June M-11 family — note the specific external call underlying M-11 shifted with the refactor, but the "Registry ignores a staking/SBT call's return value" theme is unchanged). Per instructions these are cited from baseline rather than re-derived; June's P3/informational priority applies.

---

## Slither — LOW Findings (grouped by detector)

| Detector | Count | Verdict | Reason |
|---|---|---|---|
| `timestamp` | 48 | ✅ FALSE POSITIVE | Standard `block.timestamp` comparisons for staleness/timelock/expiry checks throughout the D5b/D5c timelock, guardian-exit, credit-epoch and price-cache machinery. Miner ~15s manipulation window is immaterial at the multi-hour/day granularities these checks operate on (48h timelocks, 2h price staleness, etc.) |
| `calls-loop` | 21 | ✅ FALSE POSITIVE | External calls inside bounded loops (role-member iteration, BLS signer-commitment loops, slash proportional-distribution loop) — all loops are bounded by protocol-controlled array sizes (`MAX_VALIDATORS`, active role-member counts), not attacker-growable to unbounded length |
| `reentrancy-benign` | 19 | ✅ FALSE POSITIVE | Slither's own "benign" bucket — state writes after external calls where no exploitable cross-function state exists; subset of the same functions already covered under Medium `reentrancy-no-eth` above (all `nonReentrant`-protected) |
| `reentrancy-events` | 13 | ✅ FALSE POSITIVE | Events emitted after external calls — ordering only affects off-chain log ordering, never on-chain state; not security-relevant |
| `missing-zero-check` | 10 | ✅ FALSE POSITIVE (Slither's Low tier, distinct from Aderyn's overlapping `zero-address-check` below) | These are Slither's own lower-confidence subset of address-zero-check findings on setter parameters, all `onlyOwner`/`onlyRegistry`-gated — see the Aderyn `zero-address-check` group below for the fuller cross-tool list, which is the one carried forward as a real-but-low action item |
| `shadowing-local` | 2 | ✅ FALSE POSITIVE | Both instances are interface method parameter names shadowing another interface method's name (`ISBT.exists(uint256).exists`, `IPolicyRegistry.setGuardian(address).guardian`) — interfaces have no function bodies, so there is no actual variable-shadowing risk |
| `return-bomb` | 1 | ⚠️ Real but low, already primarily mitigated, not urgent | `xPNTsTokenV2._tierOf` (`tokens/v2/xPNTsTokenV2.sol:352-360`) bounds the external tier-source call to `gas: TIER_SOURCE_GAS` (100,000), which is the primary mitigation Slither is (correctly, cautiously) flagging as incomplete — a malicious `tierSource` could still return a moderately large payload within that gas budget, costing the caller extra `RETURNDATACOPY` gas. Not fund-moving (view-only tier lookup). Consider adding an explicit `returndatasize()` bound as defense-in-depth in a future PR; not blocking. |

## Slither — OPTIMIZATION Findings (grouped)

| Detector | Count | Verdict |
|---|---|---|
| `constable-states` | 40 | Gas-only (state vars that could be `constant`/`immutable`); deferred — not a correctness or security concern |
| `cache-array-length` | 2 | Gas-only (`.length` re-read in loop); deferred |

---

## Aderyn — HIGH Findings

All 10 Aderyn High groups were checked against source and are **FALSE POSITIVE** (Aderyn is a newer/different heuristic engine than Slither and, on this tree, produced zero real High-severity findings not already covered by other tools):

### A-H1 `avoid-abi-encode-packed` (1 instance)
`SuperPaymasterAdmin.sol:628` — `reason = string(abi.encodePacked(reason, " (Capped at 30%)"))`. This builds a human-readable event/log message string; it is never passed into `keccak256()` or any hash function, so the packed-encoding hash-collision concern the detector describes does not apply. ✅ FALSE POSITIVE.

### A-H2 `arbitrary-transfer-from` (5 instances)
`GTokenStaking.sol:148,156,196`, `X402Facilitator.sol:324`, `xPNTsToken.sol:461`. All five already carry an explicit `// slither-disable-next-line arbitrary-send-erc20` comment plus a written justification: `GTokenStaking`'s three are `onlyRegistry`-gated with `payer` supplied by the trusted Registry (which must already hold an allowance); `X402Facilitator`'s is gated on an EIP-712-signed `X402PaymentAuthorization` (the signature IS the `from` address's authorization); `xPNTsToken.sol:461` is `super.transferFrom(from, to, value)` — the contract's own OZ ERC20 base implementation inside a standard allowance-checked override, not an arbitrary pull. Aderyn doesn't honor `slither-disable-next-line` comments (different tool), hence it still flags these. ✅ FALSE POSITIVE, all five already reasoned about and suppressed for Slither.

### A-H3 `unprotected-initializer` (4 instances)
`Registry.sol:205` (`_initRole`), `SuperPaymasterAdminCalls.sol:93` (`initBLSAggregator`), `PaymasterBase.sol:198` (`_initializePaymasterBase`), `PaymasterFactory.sol:111` (`_initAndVerify`). All four are `internal` helper functions, not external upgradeable-proxy entry points — Aderyn's name-substring heuristic ("contains init") false-matches them. Each contract's real external `initialize(...)` carries the OZ `initializer` modifier (confirmed for `Registry.sol:90`, `SuperPaymaster.sol:109`); these internal helpers can only be reached from within that already-protected call. ✅ FALSE POSITIVE.

### A-H4 `unsafe-casting-detector` (3 instances)
- `GTokenStaking.sol:322` — `dLock.amount -= uint128(take)`; `take` is computed as `min(dust, dLock.amount)` where `dLock.amount` is already `uint128`, so the cast is bounded by construction.
- `xPNTsTokenV2.sol:305` — `CreditRes(uint128(aPNTs), msg.sender)`; reached only after `_creditDecision` confirms `aPNTs <= maxSingleTxLimit`, and `maxSingleTxLimit` is hard-capped at `MAX_SINGLE_TX_LIMIT_CAP` (≤ `PROTOCOL_MAX_CAP = 50_000 ether = 5e22`) in `setMaxSingleTxLimit` — the exact `I4` invariant documented at `xPNTsV2Base.sol:37-39` and previously verified in the D5c-1 Halmos work (`< 2^128`, no truncation possible).
- `xPNTsTokenV2Ext.sol:157` — `r.approvedCap = uint112(c)` where `c = min(capAPNTs, r.requestedCap)` and `r.requestedCap` is itself declared `uint112` — bounded by construction.
✅ FALSE POSITIVE, all three are provably-bounded downcasts, one of them (`xPNTsTokenV2.sol:305`) corresponding to an already-documented, previously-audited invariant.

### A-H5 `incorrect-shift-order` (1 instance, crypto code — verified with extra care)
`utils/BLS.sol:309` — `mstore(o, shl(240, 256))`. Checked deliberately carefully given this is BLS12-381 hash-to-curve (`expand_message_xmd`) code. Yul's `shl(x, y)` shifts `y` left by `x` bits (shift amount first, per EVM `SHL` opcode semantics) — here `256` (the message-length-in-bits value, `0x0100`) is shifted left by `240` bits, placing it in the top 2 bytes of a 32-byte word (32 − 2 = 30 bytes = 240 bits from the low end). Both arguments are literals; the shift-amount (`240`) is correctly in the first position per Yul/EVM convention, matching the standard DST (domain-separation-tag) length-suffix construction used by RFC 9380 hash-to-curve implementations. ✅ FALSE POSITIVE — verified correct, not just assumed.

### A-H6 `uninitialized-state-variable` (4 instances)
`SuperPaymasterStorage.sol:117` (`agentIdentityRegistry`) — same instance and same root cause as the Slither `uninitialized-state` H-S2 group above (written from `SuperPaymasterAdmin.sol:266`). `PaymasterFactory.sol:56` (`totalDeployed`) — an incrementing counter correctly relying on its `0` default. `mocks/MyNFT.sol:7`, `mocks/TestSBT.sol:10` (`_nextTokenId`) — same "counter defaults to 0" non-issue, and both files are test/mock contracts outside Slither's configured scope (Aderyn's scan wasn't filtered the same way, hence they only appear here). ✅ FALSE POSITIVE.

### A-H7 `yul-return` (2 instances)
`SuperPaymaster.sol:146` and `xPNTsTokenV2.sol:63` — both are the standard EIP-1167-adjacent proxy `fallback() external { assembly { ... delegatecall ... return(0, returndatasize()) } }` dispatch pattern to an `EXTENSION` contract. The detector's stated rationale ("causes execution to halt... including code following the assembly block") assumes there is meaningful Solidity code after the assembly block that would be skipped — in both instances, the assembly block IS the entire function body. ✅ FALSE POSITIVE, textbook proxy-fallback idiom.

### A-H8 `unchecked-return` (3 instances)
`Registry.sol:455`, `SuperPaymaster.sol:419`, `SuperPaymaster.sol:421` — these are the same three code sites already analyzed under Slither Medium `unused-return` above (`Registry._firstTimeRegister`/`lockStakeWithTicket`, `SuperPaymaster.postOp`/`settleLocked`+`settleCredit`). Same verdicts apply: `Registry.sol:455` is part of the June-baseline-cited "Registry ignores staking/SBT return" family (informational); the two `SuperPaymaster.postOp` sites are FALSE POSITIVE by explicit no-try/catch design (see that section for the comment citation).

### A-H9 `weak-randomness` (1 instance)
`GTokenStaking.sol:177` — `return uint256(keccak256(abi.encode(user, roleId, block.number, totalStaked)));`. Generates a deterministic lock-record identifier/handle, not a security- or financially-significant random outcome (no lottery, no winner selection, no fee/reward distribution gated on unpredictability). An attacker predicting this ID gains nothing, since the ID is not secret-dependent — it's a pointer, and the surrounding comment confirms this ("Ticket-only path creates no lock → return 0. Only stake locks have meaningful identifiers."). ✅ FALSE POSITIVE — classic keccak(block.number,...) pattern-match without usage-context awareness.

### A-H10 `contract-locks-ether` (2 instances)
`BasePaymasterUpgradeable.sol:19`, `PaymasterBase.sol:22`. Both contracts DO define withdraw functions in the very same file the detector flagged: `BasePaymasterUpgradeable.sol` has `withdrawTo` (line 55) and `withdrawStake` (line 67); `PaymasterBase.sol` has `withdraw(address,uint256)` (line 637), `withdrawStake` (694), and `withdrawTo` (695). Confirmed by grep — the detector simply didn't look far enough down the same file. ✅ FALSE POSITIVE.

---

## Aderyn — LOW Findings (grouped)

| Detector | Count | Verdict | Notes |
|---|---|---|---|
| `centralization-risk` | 131 | ✅ FALSE POSITIVE / by design | `onlyOwner`/access-control-gated admin functions are the intended governance model for this system (two-step ownership, timelock-gated upgrades — see `docs/security/CC48-*` series); not a bug |
| `constants-instead-of-literals` | 167 | Deferred, gas/style only | Not a correctness or security concern |
| `unindexed-events` | 165 | Deferred, gas/observability only | Would improve off-chain indexing ergonomics but is not a security gap |
| `useless-public-function` | 12 | Deferred, gas only (`public`→`external`) | — |
| `useless-error` | 15 | Real but trivial, not urgent | Genuinely-unused custom errors (dead declarations, likely refactor leftovers or reserved for future use — e.g. `utils/BLS.sol` has 7 of the 15). Code-cleanliness only, no security implication; safe to leave for a routine cleanup pass |
| `large-numeric-literal` | 58 | Deferred, style only | — |
| `inconsistent-type-names` | 5 | Deferred, style only (`uint` vs `uint256`) | — |
| `unsafe-oz-erc721-mint` | 2 | Low relevance | Need to confirm scope, but consistent with mock/test SBT/NFT contracts (`_mint` vs `_safeMint`) rather than production paths |
| `useless-modifier` | 3 | Deferred, style only | — |
| `empty-block` | 3 | Deferred, style only | — |
| `redundant-statements` | 1 | ✅ FALSE POSITIVE | `SuperPaymasterAdmin.sol:427` — `proof;` inside `updatePriceDVT` is a deliberate no-op expression statement documenting that the `proof` parameter is intentionally unused in this function (verification already happened upstream in `BLSAggregator`, per the adjacent comment "verified by BLSAggregator before it calls this function") — an idiom to silence unused-parameter warnings, not an accidental leftover |
| `unsafe-erc20-functions` | 1 | ✅ FALSE POSITIVE | `xPNTsToken.sol:461` — `super.transferFrom(from, to, value)` calls the contract's own inherited OZ ERC20 implementation (standard override-chain pattern), not an unguarded raw call to an arbitrary external token that would need `SafeERC20` |
| `non-reentrant-before-others` | 9 | ✅ FALSE POSITIVE (spot-checked) | Pure modifier-ordering style rule; only matters if a modifier preceding `nonReentrant` performs an external call before the reentrancy lock is set. Checked two representative instances (`SuperPaymaster.sol:225`: `onlyEntryPoint nonReentrant`; `PaymasterBase.sol:252`: `onlyEntryPoint whenNotPaused nonReentrant`) — the preceding modifiers are simple `require`-based access/pause checks with no external calls, so there is no actual reentrancy window regardless of ordering |
| **`zero-address-check`** | **13** | ⚠️ **Real, low-priority, NOT fixed in this pass — needs its own PR** | See below |

### A-L1 `zero-address-check` — the one real Aderyn Low finding (13 instances)
**Files**: `Registry.sol:94,95`, `BLSAggregator.sol:1608`, `DVTValidator.sol:308`, `SuperPaymaster.sol:119`, `SuperPaymasterAdmin.sol:72`, `PaymasterFactory.sol:132`, `MySBT.sol:520`, `xPNTsFactoryV2.sol:198,200,388`, `xPNTsTokenV2Ext.sol:320`, `xPNTsFactory.sol:184`
**Verdict**: Real but low severity, not urgent — flagged for a future PR, not fixed here.
**Reason it's real (not FP)**: these are genuine missing-input-validation gaps — `address` state variables assigned from setter/initializer parameters without an explicit `!= address(0)` guard. Unlike the `incorrect-equality`/`missing-zero-check` groups above (which are guard *checks* Slither flags as "dangerous," i.e. code that already validates something), this is the *absence* of validation.
**Why it's low priority, not urgent**: every one of the 13 sites is inside an `onlyOwner`/`onlyCommunityOwner`/initializer-gated function, so exploitation requires the already-trusted admin/owner to misconfigure their own contract — an operational-hygiene risk, not an attacker-exploitable one. Recommended defensive fix for a future PR: add `if (x == address(0)) revert InvalidParam();` at each of the 13 sites before storing.

---

## Cross-check against the June 2026-06-28 baseline

| June ID | Status in this run |
|---|---|
| H-1/H-2/H-3 | Unchanged, same false-positive verdict (§ H-S1 above) |
| M-1 | Unchanged, still real, NOT fixed (§ divide-before-multiply) |
| M-2 (`PaymasterFactory.deployPaymaster`/`deployPaymasterDeterministic`) | **No longer flagged by Slither** — consistent with the CEI fix having been applied since June (not independently re-verified line-by-line in this pass; flagged here as a positive signal worth a footnote, not a confirmed fix) |
| M-3 | Unchanged, still real, NOT fixed; new sibling `xPNTsFactoryV2.deployxPNTsToken` has the same gap |
| M-4 | Unchanged, same low-risk/monitor verdict |
| M-5, M-6 | Unchanged, cited as-is per instructions (Registry `exitFee`, GTokenStaking `totalDeducted`) |
| M-7 (`Registry._initRole`/`_syncExitFeeForRole` unchecked low-level call) | Not present in this run's Medium list — not independently re-verified; worth a spot-check in a future pass |
| M-8 (`SuperPaymaster._recordDebt` CEI) | `_recordDebt` no longer exists as a standalone function post-D5b-split; the closest surviving analogue is `SuperPaymaster.postOp` (§ reentrancy-no-eth above), now FALSE POSITIVE by nonReentrant protection |
| M-9 through M-15 (unused-return family) | M-9, M-10, M-11 (SBT/staking return family) cited unchanged; **M-12 and M-15 (Chainlink staleness) confirmed FIXED** — see § unused-return; M-13 re-analyzed fresh and reclassified FALSE POSITIVE (the underlying flagged call changed with the refactor); M-14 re-analyzed fresh and reclassified FALSE POSITIVE (flagged call is now `roleLocks()`, not `EnumerableSet.add`) |

---

## Real findings needing a future PR (not fixed in this pass)

1. **`xPNTsToken._update` divide-before-multiply** (June M-1, unchanged) — `tokens/xPNTsToken.sol:612-641`
2. **`xPNTsV2Base._update` divide-before-multiply** (new, same root cause) — `tokens/v2/xPNTsV2Base.sol:234-259`
3. **`xPNTsFactory.deployxPNTsToken` CEI/reentrancy** (June M-3, unchanged) — `tokens/xPNTsFactory.sol`
4. **`xPNTsFactoryV2.deployxPNTsToken` CEI/reentrancy** (new sibling of #3) — `tokens/v2/xPNTsFactoryV2.sol`
5. **`MicroPaymentChannel.closeChannel` CEI** (June M-4, unchanged, low-risk/monitor) — `paymasters/superpaymaster/v3/MicroPaymentChannel.sol`
6. **`Registry.exitRole.exitFee` uninitialized-local** (June M-5, unchanged) — `core/Registry.sol`
7. **`GTokenStaking.slash.totalDeducted` uninitialized-local** (June M-6, unchanged) — `core/GTokenStaking.sol`
8. **`Registry.exitRole`/`registerRole`/`safeMintForRole`/`_firstTimeRegister` unused-return on staking/SBT calls** (June M-9/M-10/M-11 family, unchanged, informational priority) — `core/Registry.sol`
9. **13× missing zero-address checks on admin-set address state variables** (Aderyn A-L1, new) — see file list above

None of these are fund-loss-today bugs; all are either already-scoped/low-priority per the June baseline or newly-flagged low-severity hardening items.

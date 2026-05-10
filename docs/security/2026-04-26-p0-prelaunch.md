# P0 Pre-Launch Fix List (Stage 1)

**Date**: 2026-04-26
**Branch**: `security/audit-2026-04-25`
**Goal**: Optimism mainnet beta launch in 1-2 weeks → 1-3 month internal beta with experimental funds → public mainnet
**Related**:
- `docs/security/2026-04-25-review.md` (full audit, 2057 lines)
- `docs/security/2026-04-26-decision-records.md` (D1-D8 user decisions)
- `docs/security/2026-04-26-threat-model.md` (trust model + 24 threat scenarios)

---

## 1. Categorization Methodology

The 18 audit P0 items + 32 P1 + ~70 P2/P3 (from review.md §5.3) are split into 3 stages, applying user's framing:

| Stage | Phase | Window | Loss tolerance | Fix gating |
|---|---|---|---|---|
| **Stage 1: Pre-Launch** | Before Optimism mainnet beta | 1-2 weeks | None — anonymous attacker exists | All must merge before deploy |
| **Stage 2: Beta Phase** | Internal Optimism beta | 1-3 months | Low — experimental funds, ≤ N partners | UUPS upgrades during beta |
| **Stage 3: Hitchhike** | Continuous | Long-term | None — non-functional | Ride along Stage 1/2 PRs |

### 1.1 Stage 1 (Pre-Launch) inclusion rule

**Must satisfy ANY ONE** of:
1. **Anonymous-callable** — bug exploitable by `address(0)` / no role / no stake
2. **Permanent damage** — once triggered, no on-chain recovery (contract bricked, governance permanently DoS'd, accounting permanently broken)
3. **Existing-approval drain** — exploits a side-effect of normal user behavior (e.g., user did `approve(facilitator, MAX)` for USDC as is standard)
4. **Cryptographic broken** — bypasses signature/proof verification entirely
5. **Trust boundary violation** — actor crosses their declared trust level (per threat-model §3.1)

### 1.2 Stage 2 (Beta) demotion rule

**Can defer** if ALL of:
1. Requires governance action to exploit (multisig role, `onlyOwner` setter)
2. UUPS upgrade can fix without state migration
3. Manual workaround exists (defund, multisig veto, off-chain monitor + halt)
4. Bounded loss in beta (limited user count + experimental funds)

### 1.3 Stage 3 (Hitchhike) inclusion rule

- Non-security: code style / docs / comments / event emission
- Performance under low contention (gas optimization, not blocking)
- Storage-layout cleanup that doesn't change behavior
- Naming / API renames that are SDK-facing only

---

## 2. P0 Pre-Launch List Summary

After D1-D8 + Codex Phase 6 review, **proposed 17 items** (one item P0-12 has 2 sub-fixes):

| # | ID | Source | Codex | Threat | Title | Recommendation |
|---|---|---|---|---|---|---|
| P0-1 | B6-C1a | review §B6 | 🆕 Refined | T-01 | BLS aggregate signature forgery | **KEEP** |
| P0-2 | B6-C1b | review §B6 | ✅ | T-02 | Validator registration without stake | **KEEP** |
| P0-3 | B6-C2 | review §B6 | ⚠️ +Codex B-N4 | T-04 | Blacklist forging + cross-chain replay | **KEEP** |
| P0-4 | B6-H1 | review §B6 | ✅ | T-04 | `executeWithProof` unauthorized | **KEEP** |
| P0-5 | B5-H1 | review §B5 | ✅ | T-11 | V4 Paymaster deactivate broken | **KEEP** (V4 launches with V3) |
| P0-6 | B5-H2 | review §B5 | ✅ | T-12 | V4 Paymaster pause never triggers | **KEEP** (V4 launches with V3) |
| P0-7 | B4-H1 | review §B4 | ✅ | T-13 | xPNTs emergencyRevoke incomplete | **KEEP** |
| P0-8 | B4-H2 | review §B4 | ✅ | T-14 | xPNTs burn firewall bypass | **KEEP** |
| P0-9 | B2-N1 | review §B2 | ✅ | T-10 | `setAPNTsToken` arbitrary swap | **KEEP** |
| P0-10 | B2-N2 + P3-H2 | review §B2 + §P3 | ⚠️ Refined (D8) | T-06 | Chainlink break-glass + price deviation | **KEEP** (per D8) |
| P0-11 | B2-N3 + B4-M2 + P3-H1 | multi | ✅ | T-16 | Multiple price setters unbounded | **KEEP** (V4 PaymasterBase price exposed) |
| P0-12a | B2-N4 (D4 part 1) | review §B2 | ✅ | T-05 | x402 Direct path: asset must be xPNTs | **KEEP** |
| P0-12b | (D4 new) | decision-records D4 | 🆕 D4 | T-05 | x402 Direct path: community-approved facilitator whitelist | **KEEP** |
| P0-13 | B3-N3 + B2-N8 | review §B3 + §B2 | ✅ | T-15 | x402 nonce DoS (per-asset triple key) | **KEEP** |
| P0-14 | H-01 | review §H + B1 | ✅ | T-07 | Slash sync Registry ↔ Staking | **KEEP** |
| P0-15 | J2-BLOCKER-1 | review §J2 | ✅ | T-17 | `dryRunValidation` missing | **CANDIDATE-BETA** |
| P0-16 | Codex B-N1 | review §6.B | 🆕 Codex | T-08 | Future timestamp staleness bypass | **KEEP** |
| P0-17 | Codex B-N5 | review §6.B | 🆕 Codex | T-09 | DVT `proposalId` pre-poison | **KEEP** |

**Recommendation breakdown** (after V4 launch decision 2026-04-28):
- **KEEP in Stage 1 (17 items)**: P0-1 through P0-14, P0-16, P0-17 + P0-12 split into 12a/12b
- **CANDIDATE-BETA (1 item)**: P0-15 (`dryRunValidation` is pure UX, not security)

So **17 firm Stage 1** + **1 UX item for discussion**.

> **Discussion process**: We go through these one-by-one. For each item I provide bug evidence + Codex status + business scenario + necessity reasoning. You decide whether it stays in Stage 1, moves to Stage 2, or is cut entirely. After all 17-18 items decided, this doc becomes the final Stage 1 fix list.

---

## 3. Per-Item Deep Dive

> Format per item: source / file:line / Codex verification / threat scenario / what's the bug / business scenario / necessity / recommendation / fix / effort / open Q

---

### P0-1: BLS aggregate signature forgery

**Source**: B6-C1a (review.md §Phase 2 B6)
**File:Line**: `contracts/src/modules/monitoring/BLSAggregator.sol` — entire `verify()` function
**Codex Phase 6**: 🆕 Confirmed independently (T-01)
**Threat scenario**: T-01

**What's the bug**:
`BLSAggregator.verify(message, signerMask, pkAgg, sig)` accepts `pkAgg` (aggregate public key) as a **caller-supplied parameter**. The pairing equation `e(pk_agg, H(m)) == e(g1, sig)` is mathematically satisfiable for ANY pair (sig, pkAgg) the caller chooses freely. There is no cross-check that `pkAgg` was actually derived from the on-chain `blsPublicKeys[validator]` array selected by `signerMask`.

**Code evidence**:
```solidity
// BLSAggregator.sol — current behavior (paraphrased)
function verify(bytes32 message, bytes32 signerMask, bytes pkAgg, bytes sig) {
    // Pairing check uses caller-supplied pkAgg directly
    require(BLS12_381.pairing(pkAgg, H(message), G1, sig));
    // ❌ Never reconstructs pkAgg from on-chain validator PKs
}
```

**Business scenario**:
Anonymous attacker calls `Registry.updateOperatorBlacklist(operator=victim, proof=forged)`. Aggregator returns true. Victim operator is blacklisted → cannot serve users. Attacker repeats for `executeSlashWithBLS` to drain victim's GToken stake. **Single attacker, no stake, no role, can wipe out any operator's funds.**

**Necessity**:
- **Type**: Cryptographic broken (rule #4) + Anonymous-callable (rule #1)
- **Anonymous?** Yes — `verify()` has no access control
- **Permanent?** Slash + blacklist are permanent state changes
- **Loss bound**: Per-operator stake + service uptime; aggregated across all operators = catastrophic
- **Recoverable?** Owner can manually re-list operator + restore stake via governance, but reputation/SLA damage is real
- **Detectable?** Yes (events fire), but irrelevant — damage is instant

**Recommendation**: ✅ **KEEP IN STAGE 1** — anyone, anytime, no cost.

**Fix proposal**: BLSAggregator must reconstruct `pkAgg` itself from `signerMask` + on-chain `blsPublicKeys`:
```solidity
function verify(bytes32 message, uint256 signerMask, bytes sig) {
    bytes memory pkAgg = _reconstructPkAgg(signerMask);
    require(BLS12_381.pairing(pkAgg, H(message), G1, sig));
}
```
+ Delete `BLSValidator.sol` entirely (per review.md P0-1 fix).

**Effort**: 1-2 days code + 2-3 days fuzz/invariant test (BLS pairing edge cases)

**Open question**: None — clearly must fix. ❓ But: do we use the existing aggregate-PK helper from solady/audited library, or hand-roll?

---

### P0-2: Validator registration without stake

**Source**: B6-C1b (review.md §Phase 2 B6)
**File:Line**: `contracts/src/modules/monitoring/DVTValidator.sol::addValidator`, `BLSAggregator.sol::registerValidator`
**Codex Phase 6**: ✅ Confirmed
**Threat scenario**: T-02

**What's the bug**:
`addValidator(addr, blsPK)` is `onlyOwner` and accepts any address. There's NO check that `addr` holds `ROLE_DVT` in Registry, or that `GTokenStaking.roleLocks[addr][ROLE_DVT].amount >= minStake`. An owner (or compromised admin) can add unbonded validators; combined with P0-1, even bonded validators have no economic accountability because forging works regardless.

**Business scenario**:
- Owner adds 7 stake-less keys → quorum is 7 keys, none have skin in game
- Or: owner adds friendly validators who aren't bonded → economic security collapses
- Even if owner is honest, the lack of stake-gate means **the design itself doesn't enforce skin-in-the-game**

**Necessity**:
- **Type**: Trust boundary violation (rule #5) — DVT validator is "PARTIAL TRUST" per threat-model §3.1; partial trust requires stake gating
- **Anonymous?** No (owner action)
- **But**: combined with P0-1, becomes anonymous-exploitable
- **Permanent?** No — owner can remove validators (P1-25 adds removal)
- **Recoverable?** Yes via governance

**Recommendation**: ✅ **KEEP IN STAGE 1** — defense-in-depth must hold even if owner acts well-meaning. Without stake gate, the entire DVT economic security is theatre.

**Fix proposal**:
```solidity
function addValidator(address addr, bytes blsPK) onlyOwner {
    require(registry.hasRole(addr, ROLE_DVT), "not DVT role");
    require(staking.roleLocks(addr, ROLE_DVT).amount >= minStake, "stake too low");
    // ... existing logic
}
```

**Effort**: 4 hours code + 1 day tests

**Open question**: What's the **minStake floor** for DVT role? Currently configured per-role in Registry but no audit-validated number. Recommendation: at least 10× expected slash amount to make slashing economically meaningful.

---

### P0-3: Blacklist forging + cross-chain replay

**Source**: B6-C2 (review.md) + Codex B-N4 (review.md §6.B)
**File:Line**: `contracts/src/core/Registry.sol:377-393` (`updateOperatorBlacklist`)
**Codex Phase 6**: ⚠️ Refined — Codex added cross-chain replay vector (B-N4)
**Threat scenario**: T-04 + T-19

**What's the bug**:
1. (Original B6-C2) `updateOperatorBlacklist` accepts empty `proof` if `BLS_AGGREGATOR_ADDRESS == address(0)`, AND any caller (no `onlyBLSAggregator`)
2. (Codex B-N4) Even when proof is required, the BLS message hash doesn't include `chainId` / `proposalId` / `nonce` → a valid blacklist proof on chain A can be replayed on chain B (e.g., Optimism → Base) since same operator address might exist on both

**Business scenario**:
- (Pre-Codex) Anonymous user calls `updateOperatorBlacklist(victim, true, "")` → victim censored
- (Codex addition) Multi-chain deployment scenario: attacker grabs a legitimate proof from one chain (e.g., a real slash proposal on Optimism testnet), replays it on Optimism mainnet against the same operator address → mainnet blacklist applied without proper governance vote

**Necessity**:
- **Type**: Anonymous-callable (rule #1) + Cross-chain replay (subset of rule #4)
- **Anonymous?** Yes (current code)
- **Permanent?** Blacklist is reversible by owner, but real damage is service-uptime hit
- **Loss bound**: Per-operator service uptime × victim count
- **Recoverable?** Yes (owner reverse), but reactive

**Recommendation**: ✅ **KEEP IN STAGE 1** — both vectors anonymous-exploitable.

**Fix proposal**:
```solidity
function updateOperatorBlacklist(address op, bool flag, bytes proof) external {
    require(msg.sender == BLS_AGGREGATOR_ADDRESS, "only aggregator");
    require(proof.length > 0, "proof required");
    // BLS message includes chainId + proposalId + nonce
    bytes32 msgHash = keccak256(abi.encode(
        block.chainid,
        proposalId,
        op,
        flag,
        proposalNonce++ // monotonic
    ));
    require(blsAggregator.verify(msgHash, signerMask, sig));
    // ...
}
```

**Effort**: 4 hours code + 1 day tests

**Open question**: Should we use a global `proposalNonce` per (operator, flag) tuple, or a single global counter? Global is simpler; per-tuple prevents griefing-by-burning-nonces.

---

### P0-4: `executeWithProof` unauthorized

**Source**: B6-H1 (review.md §Phase 2 B6)
**File:Line**: `contracts/src/modules/monitoring/DVTValidator.sol:86-105`
**Codex Phase 6**: ✅ Confirmed
**Threat scenario**: T-04 (related)

**What's the bug**:
`executeWithProof(proposalId, target, data, proof)` has no caller restriction. Combined with P0-1 (BLS forgery) and P0-2 (no stake), an anonymous caller can submit any forged proof to execute arbitrary `target.call(data)` actions in the DVT context.

**Business scenario**:
Attacker forges proof → calls `executeWithProof(proposalId, RegistryAddress, slashCalldata, forgedProof)` → arbitrary slash action triggered. Even without P0-1 fixed, the lack of `onlyValidator` / `onlyBLSAggregator` means any caller with a "valid-looking" proof can drive DVT actions.

**Necessity**:
- **Type**: Anonymous-callable (rule #1) + Trust boundary violation (rule #5)
- **Anonymous?** Yes
- **Permanent?** Depends on `target.call(data)` — could be permanent if it triggers slash/blacklist
- **Loss bound**: Anything DVT can do (essentially: protocol-wide governance actions)

**Recommendation**: ✅ **KEEP IN STAGE 1** — depth-defense for P0-1.

**Fix proposal**:
```solidity
modifier onlyAuthorizedExecutor() {
    require(
        msg.sender == BLS_AGGREGATOR_ADDRESS ||
        registry.hasRole(msg.sender, ROLE_DVT),
        "not authorized"
    );
    _;
}
function executeWithProof(...) external onlyAuthorizedExecutor { ... }
```

**Effort**: 2 hours

**Open question**: Should `executeWithProof` only be callable by BLSAggregator (single-source) or by any DVT role member? Single-source is cleaner; multi-source allows backup paths if aggregator down.

---

### P0-5: V4 Paymaster `deactivate/activate` broken

**Source**: B5-H1 (review.md §Phase 2 B5)
**File:Line**: `contracts/src/paymasters/v4/Paymaster.sol:82-91`
**Codex Phase 6**: ✅ Confirmed
**Threat scenario**: T-11

**What's the bug**:
PaymasterV4 calls `Registry.deactivate(...)` and `Registry.activate(...)` — these functions **don't exist** on V3 Registry. The V3 API uses `exitRole(roleId)` / `assignRole(...)`. Every call from V4 to deactivate/activate **silently reverts**.

**Business scenario**:
- AOA-mode operator (community runs own PaymasterV4) detects a security incident → wants to deactivate to stop bleeding
- Calls `paymaster.deactivate()` → revert
- Operator must manually drain own deposit (multi-tx) and unregister via Registry → minutes of continued bleeding
- In Stage 2 (beta with experimental funds + ≤ N partners), operator can do manual workaround if they know

**Necessity**:
- **Type**: Design (rule #5 mismatch with V3 interface)
- **Anonymous?** No
- **Permanent?** No — manual workaround
- **Loss bound**: Bleeding during incident response window (minutes to hours)
- **Recoverable?** Yes (manual)

**Recommendation**: ✅ **KEEP IN STAGE 1** — User confirmed 2026-04-28: V4 launches alongside V3 in Optimism beta. AOA-mode communities need on-chain emergency stop from day 1.

**Fix proposal**:
```solidity
function deactivate() external onlyOwner {
    registry.exitRole(uint256(keccak256("PAYMASTER_AOA")));
    emit Deactivated();
}
```

**Effort**: 2 hours

**Open question**: None — V4 launch decision locked.

---

### P0-6: V4 Paymaster `pause()` never triggers

**Source**: B5-H2 (review.md §Phase 2 B5)
**File:Line**: `contracts/src/paymasters/v4/PaymasterBase.sol:83/165/207` (modifier `whenNotPaused`)
**Codex Phase 6**: ✅ Confirmed
**Threat scenario**: T-12

**What's the bug**:
`whenNotPaused` modifier exists on validation/postOp paths, but there's NO `pause()` / `unpause()` setter to flip the boolean. The modifier is permanently false-checking — i.e., "paused" can never be set to true. Effectively dead code that misleads operators into thinking emergency pause exists.

**Business scenario**:
Same as P0-5: operator wants to halt during incident → no on-chain primitive available → must do manual deposit drain.

**Necessity**:
Same as P0-5.

**Recommendation**: ✅ **KEEP IN STAGE 1** — same reasoning as P0-5; V4 launches in beta.

**Fix proposal**:
```solidity
bool public paused;
event Paused();
event Unpaused();
function pause() external onlyOwner { paused = true; emit Paused(); }
function unpause() external onlyOwner { paused = false; emit Unpaused(); }
```

**Effort**: 2 hours

**Open question**: None — V4 launch decision locked.

---

### P0-7: xPNTs `emergencyRevokePaymaster` incomplete

**Source**: B4-H1 (review.md §Phase 2 B4)
**File:Line**: `contracts/src/tokens/xPNTsToken.sol:437-444 + 298-319`
**Codex Phase 6**: ✅ Confirmed
**Threat scenario**: T-13

**What's the bug**:
`emergencyRevokePaymaster()` clears `autoApprovedSpenders[currentSP] = false` but **doesn't zero `SUPERPAYMASTER_ADDRESS`**. The compromised SP can still call `burnFromWithOpHash(user, amount, opHash)` because that path checks `msg.sender == SUPERPAYMASTER_ADDRESS`, not the autoApproved mapping.

**Business scenario**:
- SP exploit detected (compromise of SP private key or upgrade exploit)
- Community owner calls `emergencyRevokePaymaster()` to halt damage
- Compromised SP keeps burning user xPNTs (within $100/tx firewall, but sustained)
- Community operator confused — thought revoke worked

**Necessity**:
- **Type**: Incident response capability (rule #5 — trust boundary violation: SP is BOUNDED TRUST after compromise)
- **Anonymous?** No (compromised SP)
- **Permanent?** No, but ongoing damage until full diagnosis
- **Loss bound**: $100/tx × calls/min × time-to-diagnose

**Recommendation**: ✅ **KEEP IN STAGE 1** — incident response is critical even in beta. If SP is compromised during beta, operators need ONE call to halt completely.

**Fix proposal**:
```solidity
function emergencyRevokePaymaster() external onlyCommunityOwner {
    autoApprovedSpenders[SUPERPAYMASTER_ADDRESS] = false;
    SUPERPAYMASTER_ADDRESS = address(0); // ← add this line
    emit EmergencyRevoked();
}
```

OR add `bool public emergencyDisabled` and gate burn paths:
```solidity
function burnFromWithOpHash(...) external {
    require(!emergencyDisabled, "emergency stop");
    // ...
}
```

**Effort**: 2 hours code + 1 day tests

**Open question**: After revoke, how does the community **upgrade to a new SP**? Is there a `setNewSuperPaymaster()` after revoke, or does the xPNTs token need redeploy? This is a runbook question.

---

### P0-8: xPNTs `burn(address, uint256)` firewall bypass

**Source**: B4-H2 (review.md §Phase 2 B4)
**File:Line**: `contracts/src/tokens/xPNTsToken.sol:476-492`
**Codex Phase 6**: ✅ Confirmed
**Threat scenario**: T-14

**What's the bug**:
The `burn(address user, uint256 amount)` overload (the address-uint variant) bypasses `_spendAllowance` for autoApproved spenders. An autoApproved spender can call `burn(victimUser, amount)` and burn arbitrary user balance without explicit allowance check, up to MAX_SINGLE_TX_LIMIT ($100).

**Business scenario**:
- Compromised facilitator (autoApproved spender) calls `burn(user1, $100)` → `burn(user2, $100)` → ... in rapid sequence
- Each call within firewall ($100/tx) but cumulative is unbounded
- Until community detects + revokes (P0-7), $100 × N users gone

**Necessity**:
- **Type**: Anonymous-by-spender (rule #5 trust boundary — facilitator is BOUNDED TRUST, but bound is per-tx not cumulative)
- **Anonymous?** No, but spender is bounded-trust actor
- **Permanent?** Burns are permanent (ERC20 supply reduced)
- **Loss bound**: $100 × number_of_users × time before revoke

**Recommendation**: ✅ **KEEP IN STAGE 1** — combined with P0-7 (revoke incomplete), this is a real drain vector.

**Fix proposal**:
```solidity
function burn(address from, uint256 amount) external {
    if (from != msg.sender) {
        _spendAllowance(from, msg.sender, amount); // ← always enforce
    }
    _burn(from, amount);
    require(amount <= MAX_SINGLE_TX_LIMIT);
}
```

**Effort**: 2 hours

**Open question**: Should we add **per-user-per-day cumulative cap** (e.g., $500/user/day across all autoApproved spenders)? This would limit the "burn many users sequentially" pattern. Recommend: yes, add it.

---

### P0-9: `setAPNTsToken` arbitrary swap

**Source**: B2-N1 (review.md §Phase 2 B2)
**File:Line**: `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:250-255`
**Codex Phase 6**: ✅ Confirmed
**Threat scenario**: T-10

**What's the bug**:
Owner can call `setAPNTsToken(newToken)` even when `protocolRevenue + Σ aPNTsBalance > 0`. After swap, the new token has zero balances; old balances are stranded → all operators frozen out of their deposits.

**Business scenario**:
- Owner accidentally calls `setAPNTsToken(wrongAddress)` (typo / phishing / multisig coordination error)
- Or: malicious owner swaps to drain operators' service capacity, then asks for ransom to swap back
- All registered operators lose access to their deposited aPNTs simultaneously
- **Permanent fund stranding** unless owner manually transfers all balances

**Necessity**:
- **Type**: Permanent damage (rule #2)
- **Anonymous?** No (owner action — but multisig minority + owner key compromise scenarios apply)
- **Permanent?** Effectively yes — recovery requires manual migration of every operator
- **Loss bound**: All operator deposits

**Recommendation**: ✅ **KEEP IN STAGE 1** — even if owner is multisig + timelock (per D5-bis), the timelock window is during a hot incident; this guard prevents both accident + abuse.

**Fix proposal**:
```solidity
function setAPNTsToken(address newToken) external onlyOwner {
    require(totalTrackedBalance == 0 && protocolRevenue == 0, "balances exist");
    APNTS_TOKEN = newToken; // (or use migration with explicit transfer)
    emit APNTsTokenChanged(newToken);
}
```

OR with migration helper:
```solidity
function setAPNTsTokenWithMigration(address newToken) external onlyOwner {
    require(timelocked24h);
    // explicitly migrate balances
    // ...
}
```

**Effort**: 4 hours code + 1 day tests

**Open question**: Is `setAPNTsToken` ever expected to be called in production? Per D3 (Code Launch), aPNTs is fixed. If never expected, we can make it `revert` post-deploy (use immutable + UUPS impl swap if migration ever needed).

---

### P0-10: Chainlink break-glass + price deviation (per D8)

**Source**: B2-N2 + P3-H2 (review.md §Phase 2 B2 + §Phase 3)
**File:Line**: `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:342-376` (`updatePriceDVT`)
**Codex Phase 6**: ⚠️ Refined — Codex argued my original "reject when down" defeats break-glass; user D8 chose "(b) tighten + don't disable"
**Threat scenario**: T-06

**What's the bug**:
1. (B2-N2) `updatePriceDVT` has owner break-glass path that bypasses Chainlink deviation check
2. (P3-H2) When Chainlink itself is stale, deviation check is meaningless → break-glass effectively unbounded
3. (Codex refinement) Reject-when-down is wrong direction — should tighten not disable

**Business scenario**:
- **Scenario A (oracle outage)**: Chainlink mainnet outage (historical: 2-3 times). Without break-glass, paymaster stops sponsoring → user transactions fail → operator SLA broken.
- **Scenario B (oracle attack)**: Chainlink poisoned (BNB 2022 case). Paymaster auto-uses bad price → operator drained.
- **Scenario C (governance abuse)**: Multisig minority calls `updatePriceDVT` with extreme price during legitimate Chainlink outage → drains via skewed prices.

D8 decision: keep break-glass, tighten with ±20% bound + 1h emergency timelock + state machine.

**Necessity**:
- **Type**: Trust boundary violation (rule #5) — owner trust is bounded; without bounds, "BOUNDED TRUST" is fictional
- **Anonymous?** No (owner action)
- **Permanent?** No (next legitimate oracle update overrides)
- **Loss bound**: Per-update skew × volume during emergency window

**Recommendation**: ✅ **KEEP IN STAGE 1** — D8 already locked in this fix direction. Without it, beta operators are exposed to governance abuse during oracle outages.

**Fix proposal** (per D8):
```solidity
enum PriceMode { CHAINLINK, EMERGENCY }
PriceMode public priceMode;
uint256 public emergencyQueuedAt;
uint256 public emergencyPendingPrice;

function emergencySetPrice(uint256 newPrice) external onlyOwner {
    require(_chainlinkStale(), "chainlink fresh, no emergency");
    require(newPrice >= cachedPrice * 80 / 100, "below ±20% bound");
    require(newPrice <= cachedPrice * 120 / 100, "above ±20% bound");
    emergencyPendingPrice = newPrice;
    emergencyQueuedAt = block.timestamp;
    emit EmergencyPriceQueued(newPrice);
}

function executeEmergencyPrice() external {
    require(block.timestamp >= emergencyQueuedAt + 1 hours, "timelock");
    cachedPrice = emergencyPendingPrice;
    priceMode = PriceMode.EMERGENCY;
    emit EmergencyPriceExecuted(emergencyPendingPrice);
    // off-chain Slack webhook listener
}
```

**Effort**: 2-3 days code + 2 days tests

**Open question**:
- ❓ What's the "Chainlink stale" threshold? 1h? 4h? (Recommend: 1h for normal operations, manual override for owner)
- ❓ Multisig requirement for emergencySetPrice or just `onlyOwner`? (Recommend: 5/7 multisig + 1h timelock)

---

### P0-11: Multiple price setters unbounded

**Source**: B2-N3 + B4-M2 + P3-H1 (review.md §B2 + §B4 + §P3)
**File:Line**:
- `SuperPaymaster.sol:260-265` (`setAPNTsPriceUSD`)
- `xPNTsFactory.sol:337-344` (price-related setter)
- `PaymasterBase.sol:474-478` (`setCachedPrice`)
**Codex Phase 6**: ✅ Confirmed
**Threat scenario**: T-16

**What's the bug**:
Three separate price setters across SP/Factory/PaymasterBase have no MIN/MAX bounds, no per-tx delta cap, no timelock. Owner (or compromised owner) can set arbitrary prices instantly.

**Business scenario**:
- Same scenarios as P0-10 but for multiple surfaces
- Inconsistency: each setter behaves differently → confusing for operators

**Necessity**:
- **Type**: Design (rule #5)
- **Anonymous?** No (owner action)
- **Permanent?** No
- **Loss bound**: Per-update skew

**Recommendation**: ✅ **KEEP IN STAGE 1** — User confirmed 2026-04-28: V4 launches in beta. Since V4 PaymasterBase price path is one of the three exposed setters, leaving it unprotected = direct V4 attack surface. Unify all three into `BoundedPriceFeed` module in one PR with P0-10.

**Fix proposal**:
```solidity
contract BoundedPriceFeed {
    uint256 public price;
    uint256 public lastUpdate;
    uint256 public constant MIN = 1e16;   // $0.01
    uint256 public constant MAX = 1e20;   // $100
    uint256 public constant DELTA_BPS = 1000; // ±10% per update

    function setPrice(uint256 newPrice) external onlyOwner {
        require(newPrice >= MIN && newPrice <= MAX);
        if (price != 0) {
            require(newPrice >= price * (10000 - DELTA_BPS) / 10000);
            require(newPrice <= price * (10000 + DELTA_BPS) / 10000);
        }
        // 24h timelock for non-emergency
        price = newPrice;
        lastUpdate = block.timestamp;
    }
}
```

Apply to all 3 setters via inheritance / module composition.

**Effort**: 3-4 days code + 2 days tests

**Open question**: None — V4 launch decision locks this Stage 1.

---

### P0-12a: x402 Direct path — asset must be xPNTs

**Source**: B2-N4 (review.md) + D4 user decision
**File:Line**: `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:1161-1169`
**Codex Phase 6**: ✅ Confirmed
**Threat scenario**: T-05

**What's the bug**:
`settleX402PaymentDirect(asset, from, to, amount, ...)` calls `IERC20(asset).transferFrom(from, to, amount)` without checking that `asset` is a registered xPNTs token. A user who has done standard `approve(facilitator, MAX)` for USDC (a totally normal pattern) can be drained via Direct path if facilitator is compromised.

**Business scenario**:
- User approves facilitator for USDC (e.g., for x402 standard payments)
- Facilitator key leaks
- Attacker calls `settleX402PaymentDirect(USDC, victim, attacker, victim's_balance)` → drains
- xPNTs are protected by firewall + $100/tx limit; **USDC has no such protection** in current code

**Necessity**:
- **Type**: Existing-approval drain (rule #3) — exploits normal user behavior
- **Anonymous?** No (facilitator) but facilitator key compromise is BOUNDED TRUST per threat-model
- **Permanent?** No — user can re-approve, but funds gone
- **Loss bound**: Up to user's USDC approval (often unlimited)

**Recommendation**: ✅ **KEEP IN STAGE 1** — even with limited beta partners, USDC drain is real risk if any beta user does standard infinite-approve.

**Fix proposal** (per D4):
```solidity
function settleX402PaymentDirect(address asset, ...) external {
    require(xPNTsFactory.isXPNTs(asset), "Direct: asset must be xPNTs");
    // ...
}
```

Plus add `xPNTsFactory.isXPNTs(address)` view (record on every `deployToken` call).

**Effort**: 4 hours

**Open question**: None — D4 already locked.

---

### P0-12b: x402 Direct path — community-approved facilitator whitelist

**Source**: D4 user decision (decision-records.md)
**File:Line**: New requirement on `settleX402PaymentDirect` + `xPNTsToken`
**Codex Phase 6**: 🆕 New (D4-driven)
**Threat scenario**: T-05 (extension)

**What's the bug**:
Per D4: each xPNTs token should let community owner specify which facilitators are approved. Currently, autoApprovedSpenders is a single mapping with no community-controlled rotation interface.

**Business scenario**:
- Community A deploys xPNTs A. Community wants to use AAStar's default facilitator + their own backup facilitator
- Community B uses only their own facilitator
- D4 model: per-xPNTs `approvedFacilitators[]` controlled by community multisig

Without this fix:
- All xPNTs auto-trust any single global facilitator → cross-community blast radius

**Necessity**:
- **Type**: Trust boundary violation (rule #5) — community trust scope leak
- **Anonymous?** No (facilitator action)
- **Permanent?** No
- **Loss bound**: Per-community xPNTs × all approved facilitators

**Recommendation**: ✅ **KEEP IN STAGE 1** — D4 lock-in.

**Fix proposal**:
```solidity
// xPNTsToken
mapping(address => bool) public approvedFacilitators;
function addApprovedFacilitator(address f) external onlyCommunityMultisig {
    approvedFacilitators[f] = true;
    emit FacilitatorApproved(f);
}
function removeApprovedFacilitator(address f) external onlyCommunityMultisig {
    approvedFacilitators[f] = false;
    emit FacilitatorRemoved(f);
}

// xPNTsFactory.deployToken — add initialApprovedFacilitators param
function deployToken(..., address[] calldata initialFacilitators) external returns (address) {
    // ... clone and init ...
    for (uint i; i < initialFacilitators.length; i++) {
        token.addApprovedFacilitator(initialFacilitators[i]);
    }
}

// SuperPaymaster
function settleX402PaymentDirect(address asset, ...) external {
    require(xPNTsFactory.isXPNTs(asset), "must be xPNTs");
    require(IXPNTsToken(asset).approvedFacilitators(msg.sender), "facilitator not approved by community");
    // ...
}
```

**Effort**: 1-2 days code + 1 day tests

**Open question**:
- ❓ Default facilitator on community deployment — auto-add AAStar's? Empty by default + community must explicitly add?
- ❓ What's the **community multisig** for new community deploys? Does each community deploy their own Safe, or use a template?

---

### P0-13: x402 nonce DoS (per-asset triple key)

**Source**: B3-N3 + B2-N8 + L-03 (review.md §B3 + §B2)
**File:Line**: `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:1148-1157` (`x402SettlementNonces`)
**Codex Phase 6**: ✅ Confirmed
**Threat scenario**: T-15

**What's the bug**:
`x402SettlementNonces[nonce] = true` keys nonces in a global namespace. Anonymous attacker can pre-burn nonces for legitimate settlements: attacker observes pending settlement intent → submits x402 settlement first with same nonce in different (asset, from) context → legitimate settlement reverts as "nonce used".

**Business scenario**:
- User signs EIP-3009 settlement with nonce = `0xabcd...`
- Attacker observes via mempool / off-chain channel
- Attacker submits dummy settlement with `(asset=anything, from=anyone, nonce=0xabcd...)` first
- User's legitimate settlement now reverts → DoS

**Necessity**:
- **Type**: Anonymous-callable (rule #1) DoS
- **Anonymous?** Yes
- **Permanent?** No (per-tx)
- **Loss bound**: Per-transaction griefed

**Recommendation**: ✅ **KEEP IN STAGE 1** — anonymous DoS during beta is unacceptable, will harm launch credibility.

**Fix proposal**:
```solidity
mapping(bytes32 => bool) public x402SettlementNonces; // unchanged structure
function _x402NonceKey(address asset, address from, bytes32 nonce) pure returns (bytes32) {
    return keccak256(abi.encode(asset, from, nonce));
}

// in settle:
bytes32 key = _x402NonceKey(asset, from, nonce);
require(!x402SettlementNonces[key], "nonce used");
x402SettlementNonces[key] = true;
```

**Effort**: 2 hours

**Open question**: None — clear fix.

---

### P0-14: Slash sync Registry ↔ Staking

**Source**: H-01 (review.md Phase 1) + B1-confirmed (Phase 2 B1)
**File:Line**: `Registry.sol:211-213` + `GTokenStaking.sol::slashByDVT` (and friends)
**Codex Phase 6**: ✅ Confirmed
**Threat scenario**: T-07

**What's the bug**:
When `GTokenStaking.slashByDVT(user, role, amount)` reduces `roleLocks[user][role].amount`, `Registry.roleStakes[user][role]` is NOT updated. `Registry.topUpStake` reads stale Registry value, which can over-count what's actually backed by Staking.

**Business scenario**:
- Operator A has 1000 GToken locked in Staking.roleLocks
- Operator A misbehaves → DVT slashes 500 → Staking.roleLocks = 500
- Registry.roleStakes still says 1000
- Operator A calls `Registry.topUpStake(role, 100)` → Registry adds 100 → reads 1100
- Reality: only 600 backed by Staking → 500 over-counted
- If `topUpStake` is permission-bounded by current stake (e.g., role assignment), op gets unfair advantage

Also: any UI / SDK reading Registry.roleStakes shows wrong value → user trust broken.

**Necessity**:
- **Type**: Accounting integrity (rule #2 permanent damage if state diverges)
- **Anonymous?** No
- **Permanent?** Until manual resync
- **Loss bound**: Per-slash drift × number of stale-read uses
- **Detectable?** Yes (off-chain query diff)

**Recommendation**: ✅ **KEEP IN STAGE 1** — INV-12 (Registry == Staking) is one of the 4 invariants Codex flagged as "highest-impact failures". Drift here is silent and compounds.

**Fix proposal**:
```solidity
// GTokenStaking.slashByDVT
function slashByDVT(address user, uint256 role, uint256 amount) external onlyAuthorized {
    // ... existing slash logic ...
    roleLocks[user][role].amount -= amount;

    // NEW: callback to Registry
    IRegistry(REGISTRY).syncStakeFromStaking(user, role, roleLocks[user][role].amount);
}

// Registry
function syncStakeFromStaking(address user, uint256 role, uint256 newAmount) external {
    require(msg.sender == address(staking), "only staking");
    roleStakes[user][role] = newAmount;
    emit StakeSyncedFromStaking(user, role, newAmount);
}
```

**Effort**: 4-6 hours code + 2 days tests + invariant test

**Open question**: Should `topUpStake` ALSO read from Staking instead of Registry storage? This makes Staking the single source of truth (preferred). Registry.roleStakes becomes a cache.

---

### P0-15: `dryRunValidation` missing (UX)

**Source**: J2-BLOCKER-1 (review.md §Phase 4 J2)
**File:Line**: `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:738-795` (`validatePaymasterUserOp` 6 silent reject paths)
**Codex Phase 6**: ✅ Confirmed; Codex suggested encoding reason bits in validationData high bits
**Threat scenario**: T-17

**What's the bug**:
`validatePaymasterUserOp` returns SIG_FAILURE in 6 different paths (config not found, paused, ineligible user, blocked, rate-limited, insufficient balance) — all looking identical to bundlers/UI. No way to diagnose why a tx was rejected.

**Business scenario**:
- User submits userOp via dApp
- Bundler simulates, gets SIG_FAILURE
- Returns generic "paymaster validation failed"
- Operator can't debug, user can't recover, dApp can't show actionable error
- → **bad UX, but not security**

**Necessity**:
- **Type**: Performance / UX
- **Anonymous?** N/A (UX)
- **Permanent?** No
- **Loss bound**: User confusion / support tickets

**Recommendation**: ⚠️ **CANDIDATE-BETA** — UX issue, not security. Can ship Stage 1 with logging + add proper view in Stage 2.

**Counter-argument for KEEPING in Stage 1**: Beta has limited users; without dryRun, every failed tx becomes a debug session for SP team. Time cost > fix cost.

**Fix proposal**:
```solidity
function dryRunValidation(PackedUserOperation calldata userOp, uint256 maxCost)
    external view returns (bool ok, bytes32 reasonCode)
{
    // mirror all checks in validatePaymasterUserOp
    if (!config.isConfigured) return (false, "OPERATOR_NOT_CONFIGURED");
    if (config.isPaused) return (false, "OPERATOR_PAUSED");
    if (!isEligibleForSponsorship(sender)) return (false, "USER_NOT_ELIGIBLE");
    // ... etc
    return (true, "");
}
```

Plus event-based reason emission in validatePaymasterUserOp:
```solidity
emit ValidationFailed(userOpHash, reasonCode);
```

**Effort**: 1 day code + 1 day tests + SDK integration

**Open question**:
- ❓ Stage 1 (necessary for beta UX) or Stage 2 (just observability)?
- ❓ If Stage 2: do we need event logging in Stage 1 at minimum?

---

### P0-16: Future timestamp staleness bypass (Codex finding)

**Source**: Codex B-N1 (review.md §6.B)
**File:Line**:
- `SP.updatePriceDVT:347` (cache write)
- `PaymasterBase.setCachedPrice:474` (cache write)
- `PaymasterBase:299` (postOp underflow risk)
**Codex Phase 6**: 🆕 New finding (Codex independent)
**Threat scenario**: T-08

**What's the bug**:
Cache updates accept arbitrary `updatedAt` timestamps. If caller writes `updatedAt = far_future`, the staleness check `block.timestamp - updatedAt < threshold` always passes → old or arbitrary price used indefinitely. Worse, in `PaymasterBase:299` postOp does subtraction that underflows when `updatedAt > block.timestamp`, **bricking** postOp permanently for that operator.

**Business scenario**:
- DVT validator with permission to call `updatePriceDVT` accidentally or maliciously sets future timestamp
- Subsequent transactions: stale price used (until next legit update)
- Worse: postOp underflow brick = operator's ALL future transactions revert at postOp → sponsorship breaks

This is **a permanent brick attack** disguised as a parameter mistake.

**Necessity**:
- **Type**: Permanent damage (rule #2) + Trust boundary violation (rule #5)
- **Anonymous?** No (DVT validator) but PARTIAL TRUST per threat-model
- **Permanent?** YES — postOp brick is permanent until UUPS upgrade
- **Loss bound**: Operator's entire service availability

**Recommendation**: ✅ **KEEP IN STAGE 1** — Codex's most surgical finding; tiny fix prevents permanent contract brick.

**Fix proposal**:
```solidity
function updatePriceDVT(int256 newPrice, uint8 newDecimals, uint256 updatedAt) external {
    require(updatedAt <= block.timestamp, "future timestamp not allowed");
    cachedPrice = PriceCache(newPrice, newDecimals, updatedAt);
}
// + same guard in setCachedPrice (PaymasterBase:474)
// + safe subtraction in PaymasterBase:299
```

**Effort**: 2 hours code + 1 day tests

**Open question**: None — clear fix.

---

### P0-17: DVT `proposalId` pre-poison (Codex finding)

**Source**: Codex B-N5 (review.md §6.B)
**File:Line**: `contracts/src/modules/monitoring/DVTValidator.sol:59/73/86` (`markProposalExecuted`, `createProposal`)
**Codex Phase 6**: 🆕 New finding (Codex independent)
**Threat scenario**: T-09

**What's the bug**:
`markProposalExecuted(proposalId)` sets `executed[proposalId] = true` for ANY proposalId. Anonymous caller can pre-poison arbitrary proposalIds. Later, when legitimate proposal X is created and tries to execute, `if (executed[X]) revert AlreadyExecuted()` — proposal can NEVER execute. `createProposal` doesn't reset `executed[id] = false`.

**Business scenario**:
- Attacker spams `markProposalExecuted(0x000...000)` through `markProposalExecuted(0xfff...fff)` — entire 256-bit proposalId space marked "executed"
- Later, legitimate slash proposal can never execute (collision in proposalId space)
- Workaround: use very-large random proposalId, but spam can target specific upcoming IDs if attacker observes
- **Permanent governance DoS** for any proposalId attacker pre-poisons

**Necessity**:
- **Type**: Anonymous-callable (rule #1) + Permanent damage (rule #2)
- **Anonymous?** Yes (`markProposalExecuted` no access control)
- **Permanent?** YES — once executed=true, no way to flip back
- **Loss bound**: Specific proposalId DoS

**Recommendation**: ✅ **KEEP IN STAGE 1** — Codex finding, anonymous-callable, permanent. Simple fix.

**Fix proposal**:
```solidity
// Option A: restrict caller
function markProposalExecuted(uint256 proposalId) external onlyAuthorizedExecutor {
    require(proposalExists[proposalId], "proposal not created");
    require(!executed[proposalId], "already executed");
    executed[proposalId] = true;
}

// Option B: createProposal asserts uniqueness
function createProposal(uint256 proposalId, ...) external {
    require(!proposalExists[proposalId], "id already used");
    proposalExists[proposalId] = true;
    // ...
}
```

(Recommend both A and B for defense-in-depth.)

**Effort**: 2 hours code + 1 day tests

**Open question**: None — clear fix.

---

## 4. Recommended Execution Order (within Stage 1)

After all P0 items are confirmed, execute in this order to minimize integration risk:

### Wave 1 — Consensus & Identity (week 1)
1. P0-1 BLS forgery (kernel)
2. P0-2 Validator stake gate (depends on P0-1 design)
3. P0-3 Blacklist forging + chain replay
4. P0-4 executeWithProof auth
5. P0-17 proposalId pre-poison (DVT-related, same area)

→ All BLS/DVT consensus fixed. Run focused fuzz/invariant tests.

### Wave 2 — Funds & Price (week 1.5)
6. P0-9 setAPNTsToken guard
7. P0-10 break-glass tightening (per D8)
8. P0-11 BoundedPriceFeed (if KEPT)
9. P0-16 future timestamp guard
10. P0-12a x402 asset whitelist
11. P0-12b x402 community facilitator
12. P0-13 x402 nonce per-asset triple
13. P0-14 slash sync Registry ↔ Staking

→ Run `INV-03` (revenue conservation), `INV-12` (registry/staking equality), x402 invariant tests.

### Wave 3 — Tokens & V4 (week 2)
14. P0-7 xPNTs emergencyRevoke
15. P0-8 xPNTs burn firewall
16. P0-5 V4 deactivate (if KEPT)
17. P0-6 V4 pause (if KEPT)
18. P0-15 dryRunValidation (if KEPT)

→ Sepolia deploy + full E2E test suite.

### Tier 1 Codex re-review
- After all Wave 1-3 merged, send to Codex for full re-pass before mainnet beta.

---

## 5. Summary Table — KEEP / CANDIDATE-BETA Decisions

For your one-by-one review:

| # | Title | My Rec | Your Choice | Note |
|---|---|---|---|---|
| P0-1 | BLS forgery | KEEP | __ | catastrophic anon |
| P0-2 | Validator stake gate | KEEP | __ | depth defense |
| P0-3 | Blacklist forging + replay | KEEP | __ | anon censor |
| P0-4 | executeWithProof auth | KEEP | __ | anon DVT exec |
| P0-5 | V4 deactivate | KEEP | ✅ | V4 launches with V3 (2026-04-28) |
| P0-6 | V4 pause | KEEP | ✅ | V4 launches with V3 (2026-04-28) |
| P0-7 | xPNTs emergencyRevoke | KEEP | __ | incident response |
| P0-8 | xPNTs burn bypass | KEEP | __ | sustained drain |
| P0-9 | setAPNTsToken | KEEP | __ | permanent brick |
| P0-10 | Chainlink break-glass | KEEP (D8) | __ | D8 locked |
| P0-11 | Multi-price setters | KEEP | ✅ | V4 PaymasterBase exposed (2026-04-28) |
| P0-12a | x402 asset whitelist | KEEP | __ | USDC drain |
| P0-12b | x402 community facilitator | KEEP (D4) | __ | D4 locked |
| P0-13 | x402 nonce DoS | KEEP | __ | anon DoS |
| P0-14 | Slash sync | KEEP | __ | invariant break |
| P0-15 | dryRunValidation | CANDIDATE-BETA | __ | UX |
| P0-16 | Future timestamp | KEEP | __ | permanent brick |
| P0-17 | proposalId pre-poison | KEEP | __ | anon perm DoS |

**Open questions to resolve during one-by-one discussion**:
1. (P0-2) DVT minStake floor amount
2. ~~(P0-5/6) V4 launch in mainnet beta~~ ✅ **RESOLVED 2026-04-28: V4 launches with V3**
3. (P0-7) Post-revoke recovery: redeploy xPNTs or upgrade SP path?
4. (P0-8) Add per-user-per-day cumulative cap?
5. (P0-9) Will `setAPNTsToken` ever be called post-deploy?
6. (P0-10) Chainlink stale threshold (1h? 4h?)
7. (P0-10) Multisig requirement for emergencySetPrice?
8. (P0-12b) Default facilitator on community deploy — auto-add AAStar's?
9. (P0-12b) Per-community multisig template
10. (P0-14) Make Staking single source of truth (Registry as cache)?
11. (P0-15) Stage 1 (full dryRun) or Stage 2 (just events)?

---

## 6. Annex — Stage 2 (Beta Phase) and Stage 3 (Hitchhike) preview

### 6.1 Stage 2 Beta Phase candidates

Includes:
- **All P1 items** from review.md §5.3.2 (32 items) — operator UX, V4 cleanup, V5.3 Agent removal per D1, MPC channel improvements
- **Codex P1-41/42** (from review.md §6.B) — GTokenStaking exit fee owner bypass + Chainlink price >0 check
- **D5-bis (a) implementation**: governance slash via owner multisig + timelock
- **D3 implementation**: aPNTsSaleContract design + deployment
- **D7**: sbtHolders → eligibleHolders rename (SDK breaking change, batch with other ABI changes)
- **CANDIDATE-BETA P0 items if user demotes**: P0-15 (only — P0-5/6/11 elevated to Stage 1 on 2026-04-28)

Detailed list will go in `2026-04-26-p1-beta.md` once Stage 1 list is finalized.

### 6.2 Stage 3 Hitchhike candidates

Includes:
- **All P3 items** from review.md §5.3.4 — comments, NatSpec, storage layout cleanup, naming
- **All P2 items** that are pure docs/style — `B2-N18..29`, `B3-N14..17/N18/N19`, `B5-N6..N9`, `L-04 / I-01..04`, `B1-N12..15`
- **EIP-1153 transient cache documentation removal** (per D2)
- **Agent sponsorship code removal** (per D1) — actually this is bigger than hitchhike, but no new functionality added; goes with Stage 2 Wave

---

## 7. Process

1. **Now**: You read this doc and pick one item to discuss first (recommend starting with KEEP items to confirm, then CANDIDATE-BETA items where you decide).
2. **Per item**: I provide additional business context if needed; you decide PRE-LAUNCH / BETA / NOT-NEEDED.
3. **After all 17 items**: This doc is updated with final decisions. Open Qs are resolved.
4. **Before execution**: Run Codex re-review on the final P0 list (per your preference).
5. **Execution**: Wave 1 → Wave 2 → Wave 3, each with focused tests.
6. **Final**: Codex re-review → Sepolia deploy → Optimism mainnet beta.

---

## 8. Revision Log

- 2026-04-26 (initial): split based on D1-D8 + Codex Phase 6 + threat-model.md; 14 KEEP + 4 CANDIDATE-BETA proposed
- 2026-04-28 (V4 launch decision): user confirmed V4 (AOA-mode) launches alongside V3 in Optimism beta; P0-5, P0-6, P0-11 elevated to KEEP. Final: **17 KEEP + 1 CANDIDATE-BETA (P0-15 dryRun only)**
- 2026-04-28 (per-item finalization): 6 design points confirmed by user:
  - **P0-1**: framing corrected — anonymous-catastrophic only via P0-1 + P0-4 combo (P0-4's `executeWithProof` is the unauthenticated entry); fix uses `_reconstructPkAgg(signerMask)` from on-chain PKs via solady BLS helper
  - **P0-2**: DVT `minStake` = 20 → **200 ether GToken** via `Registry.configureRole` (no contract change, just deploy-time config). `addValidator` reads minStake from staking config dynamically
  - **P0-3**: caller restricted to `msg.sender == blsAggregator` (not `isReputationSource`); proof always required; message includes `chainId + proposalId + nonce` (anti-replay)
  - **P0-7**: use `emergencyDisabled` flag (NOT zero address) — gates both burn paths; recovery via existing `setSuperPaymasterAddress` + new `unsetEmergencyDisabled`
  - **P0-8**: **per-spender daily cap** (not per-user); default 50_000 ether xPNTs (~$1000 @ $0.02), community multisig configurable. User burden: 0
  - **P0-11**: inline `require()` per setter (NOT shared `BoundedSetter` mixin); 3 prices have independent semantics
  - **P0-15**: stays Stage 1 (beta UX necessary — full `dryRunValidation` view)
- 2026-04-28 (execution kickoff): 3 parallel git worktrees + branches set up: `fix/p0-wave1-consensus`, `fix/p0-wave2-funds-price`, `fix/p0-wave3-tokens-v4`. All from `main`. Audit branch `security/audit-2026-04-25` stays for docs.

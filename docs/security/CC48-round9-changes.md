# CC-48 round-9 — a bound that cannot be left behind by the thing it bounds

Branch `codex/repcredit-e2e-evidence-20260823`, range `32b3bd3d..HEAD`. Verdict being
answered: **pr-daemon REQUEST_CHANGES on PR #375 — 1 HIGH / 1 MEDIUM-HIGH / 3 LOW**
(reviews `5018887741` and `5018907810` by `clestons`, routed to `repo:sp` by `a50be004`).

This document **supersedes** §1 and §3 of `docs/security/CC48-round8-changes.md` insofar as
they describe `totalCreditExposure` as an incremental counter and the migration baseline as
an operator-supplied number. Everything the reviewer confirmed closed on `32b3bd3d` —
storage-layout append-only safety, domain separation, the governance owner gate, the
Timelock batch atomicity, `_requireCommitteeSurvivesExit`, the ±100 clamp, the real-4.3.0
unblock, the 7702 classification, the ABI-generator controls — is unchanged and still
regressed.

| # | Finding | Sev | Status |
|---|---|---|---|
| B1 | `setCreditTier` / `setLevelThresholds` change every user's real credit limit without touching `totalCreditExposure` | HIGH | fixed in-contract |
| B3 | the migration baseline was an operator-typed aPNT number whose documented derivation is wrong by construction | MEDIUM-HIGH | fixed: there is no number to type any more |
| B4 | `totalCreditExposure` NatSpec claims a stock over all users; the implementation summed proposal deltas | LOW | fixed on both sides — the claim is now true AND states what it does not cover |
| B5 | every suite zeroed tier 1 in `setUp`, hiding this whole class from 1318 green tests | LOW | fixed: a new suite runs on the `initialize` defaults |
| B6 | `setCreditTier` had no monotonicity validation despite the `initialize` invariant | LOW | fixed on both setters |

Not asked for, but forced by the above and reported here because it changes a number the
reviewer verified: **EIP-170**. See §6.

---

## 1. B1 — the schedule cannot walk away from the ledger

**The finding, as measured by the reviewer.** Two users at rep 100, ledger and reality both
1,200 aPNT. One `setCreditTier(4, 9999 ether)` — one owner call, no proposal, no BLS proof —
and reality became 19,998 while the ledger stayed 1,200. `TotalCreditExposureExceeded` then
guarded a number with no relationship to the credit users could actually draw. The reviewer
was explicit that this is not an authorization bug: a perfectly correct M-of-N Safe produces
the same decoupling, because the missing thing is a recomputation, not a permission.

**Why the obvious fix is not available.** Recomputing needs the set of users, and this
contract has no enumerable user set. Two designs that do work were built and measured:

1. *per-level headcounts* — track how many tracked users sit at each level, derive exposure
   as `Σ count[l] · (tier[l] − tier[1])`, and re-derive inside every setter. Correct, and it
   keeps the path open across a tier re-price.
2. *invalidate-and-re-count* — the setters discard the stock and shut the reputation path
   until governance re-counts from on-chain reputation.

(1) did not fit: it left `Registry` at **25,078 bytes**, 502 over EIP-170, and no
optimizer setting recovered that (runs=1 still measured 24,840). (2) is what shipped. The
trade is stated plainly rather than buried: **a tier re-price now costs a re-count**, and
between the two the protocol issues no new reputation credit. Existing credit is untouched —
`getCreditLimit` keeps answering — because shutting issuance is not the same as revoking it.

**What the code does now** (`contracts/src/core/Registry.sol`):

- `setCreditTier` and `setLevelThresholds` both end in `_invalidateCreditPopulation()`:
  epoch bumped, headcount zeroed, `totalCreditExposure` zeroed, `creditPopulationSeededAt`
  back to zero.
- `updateGlobalReputation` reverts with `CreditPopulationNotSeeded` while that flag is zero.
- Bumping one epoch un-counts every address at once, which is what removes the need for an
  enumerable user set. The per-address marker is `epoch + 1`, never the raw epoch — see §3.
- A write that does not change the price returns before invalidating: an idempotent call
  must not cost a governance outage.
- Nothing counted yet ⇒ no invalidation. A deployment prices its tiers before it has users,
  and shutting a path with nothing to re-count would be pure damage. The branch is sound
  because `creditPopulationTotal == 0` holds **iff** no address carries the current marker.

**Evidence.** `contracts/test/security/CC48CreditScheduleControls.t.sol`
`test_TierRepriceCannotSilentlyDecoupleTheLedger` reproduces the reviewer's probe D on the
`initialize` defaults, asserts the round-8 outcome is gone, and asserts the re-counted ledger
equals a sum recomputed **in the test** from the public getters — not from the implementation
under test. `test_ThresholdMoveCannotSilentlyDecoupleTheLedger` is the same for `:601`.
`V3_DynamicLevelThresholds` now exercises the shut-and-re-count cycle in its main flow.

---

## 2. B3 — the baseline is not a better number, it is no number

**The finding.** `CREDIT_EXPOSURE_BASELINE` was an aPNT total nothing on-chain could check,
and its documented derivation — sum `GlobalReputationUpdated` — omits every address still
holding the `initialize` tier-1 default. Following the documentation correctly produced a
wrong number.

**The fix.** The parameter is gone from `setCreditPolicy`, from
`RegistryUpgradeBatchLib.buildBatch`, and from the migration runbook. What governance
declares now is **membership**:

```solidity
function seedCreditPopulation(address[] calldata users, uint256 expectedPopulationTotal, bool finalize)
```

The contract reads each member's level out of its own `globalReputation` storage, so no
operator arithmetic can misstate a tier. Three properties make the remaining trusted input —
the address list — safe to depend on:

- **fail-closed**: an unseeded proxy issues nothing at all (`CreditPopulationNotSeeded`).
- **checked**: the declared headcount must equal what the contract actually counted, so a
  truncated calldata batch cannot be finalized (`CreditPopulationCountMismatch`), and the
  derived stock is measured against the ceiling on *every* batch, not just the last.
- **self-healing**: a promoted member the list missed is not lost. The first proposal that
  touches them books their whole standing above-floor limit, booked as `backfill` rather
  than as uplift so it cannot spuriously trip the per-proposal cap.

Addresses that were never promoted may be omitted **safely and provably**: they sit at level
1 and contribute exactly zero (§3). That is what dissolves the reviewer's "the event scan
misses tier-1 holders" objection — under the corrected measure, the event scan is complete.

**Fresh deployments** are seeded in `initialize`, where the population provably *is* empty,
so `DeployAnvil` / `DeployRepCreditSepolia` need no baseline and never did.

**Live migration** now runs as a four-call atomic batch (`RegistryUpgradeBatchLib`):
upgrade → re-point aggregator → `setCreditPolicy(caps)` → `seedCreditPopulation(users, n, true)`.
Seeding is ordered *after* the caps because finalizing checks the derived stock against the
ceiling: a migration whose real exposure exceeds the cap it declared fails atomically instead
of going live and wedging. `UpgradeRegistryTo570.s.sol` re-derives the same figure over RPC
from the live `globalReputation`, prints it, rejects duplicate addresses, cross-checks the
declared headcount, and refuses to emit a batch that does not fit under the ceiling.

**Evidence.** `RegistryUpgradeTo570.t.sol`
`test_AtomicBatchUpgradesRewiresAndDerivesTheBaseline` runs the shipped batch against a proxy
whose 5.8.0 slots have been zeroed to look genuinely pre-upgrade, and asserts the contract
arrives at 1,200 aPNT **without that number appearing anywhere in the batch**.
`test_SeedMissingAUserSelfHealsOnNextTouch`, `test_UpgradedProxyWithoutPolicyHaltsIssuance`
and `test_CeilingBelowLiveExposureIsRefused` cover the failure directions;
`CC48CreditScheduleControls` covers batching, idempotency and the headcount check.

---

## 3. B4 — what the number measures, said correctly

`totalCreditExposure` measures exposure **above the permissionless level-1 floor**, summed
over every address. Two things follow, and the NatSpec now says both:

- It is a genuine **stock over all addresses**, because a never-promoted address contributes
  exactly zero to it. The reviewer's counterexample (counter 500e18, real holdings 800e18)
  is not a defect under this measure; it is the measure.
- It **does not and cannot** bound the floor. `creditTierConfig[1]` is granted to every
  address by construction, including addresses that do not exist yet, so no counter in this
  contract can bound that population. Saying otherwise is what made the old docstring false.
  The floor is bounded elsewhere — per-operator deposits and debt limits in SuperPaymaster,
  and the tier-1 economics themselves.

`test_UntouchedAddressHoldsTheFloorAndContributesNothing` and
`test_TheFloorIsNotAndCannotBeBoundedByTheCap` pin both halves, the second by setting the
ceiling to zero and showing fresh addresses still hold drawable tier-1 credit.

**A bug this class of test found.** The first implementation stored the raw epoch as the
per-address "counted" marker. On a genuinely pre-5.8.0 proxy both that slot and
`creditPopulationEpoch` read zero, so every never-counted address looked **already counted**:
the migration seed would have counted nobody and reverted on the headcount check. Fail-closed,
but a migration that could not be performed. The marker is `epoch + 1` for exactly this
reason, and the reason is written at the slot.

---

## 4. B5 — the suites that could not see any of this

`RepCreditIssuanceAndExitControls.t.sol:51` and `CC48CoreFixes.t.sol` both call
`setCreditTier(1, 0)` in `setUp`. With the floor at zero, "every address holds a floor that
never enters the ledger" is unobservable — which is why 1,318 green tests, an Opus review and
a Codex review all passed over B1 and B4.

`contracts/test/security/CC48CreditScheduleControls.t.sol` (new, 21 tests) runs entirely on
the `initialize` defaults and asserts them explicitly, so a silent change to the bootstrap
tiers fails a test rather than re-basing every number in the file. The pre-existing suites
keep their zeroed floor — they test different properties and the zero is load-bearing there —
but they are no longer the only place this behaviour is exercised.

---

## 5. B6 — monotonicity, from both sides

`initialize` has always claimed the tier table is monotonic "so higher reputation never
*lowers* credit". It is enforced now, and enforcing it on `setCreditTier` alone would have
been half a fix:

- `setCreditTier` checks the immediate neighbours (sufficient by induction, since every
  level is written through it) and rejects level 0 and anything past the hard 21-level
  ceiling.
- `setLevelThresholds` checks the **resulting** table. Growing the schedule onto a level
  whose price is still zero would put the highest-reputation users below the level under
  them — the same invariant broken from the other side.

The two rules meet in the middle: **a level's price must exist before the level does.**
Pre-pricing an unreachable level is therefore allowed, and growing onto an unpriced one is
not. Four existing tests that grew the schedule first now price first; that ordering change
is the only externally visible consequence.

---

## 6. EIP-170 — a number the reviewer verified, so a number that must be re-reported

The reviewer measured `Registry` at 23,771 bytes with **805** to spare and recorded the
margin as a release residual. The credit work in this round costs ~1.1 KB, which does not fit.

Rather than lower `optimizer_runs` (which buys ~440 bytes and taxes every Registry call), the
seven `_initRole(...)` call sites in `initialize` were collapsed into one call site driven by
a memory table. `via_ir` had been inlining that callee at every site, at **~552 runtime bytes
each** — about 3.8 KB spent writing seven rows of a table.

| | before (32b3bd3d) | after |
|---|---|---|
| `Registry` runtime | 23,771 | **23,029** |
| margin to EIP-170 | 805 | **1,547** |

`foundry.toml` is untouched; both figures are `[profile.default]`, the profile `deploy-core`
ships under. The refactor is behaviour-preserving by construction and asserted field-by-field
by `test_RoleBootstrapMatrixUnchanged`, which checks all eleven fields of all seven roles
against the values the seven original call sites passed. The archived checklist item "split
modules before the next core expansion" is **not** discharged by this — it is deferred with
more room than it had.

---

## 7. Interface, storage and migration impact

**Version:** `Registry-5.7.0` → **`Registry-5.8.0`**. `BLSAggregator-4.10.0` unchanged.

**ABI (breaking, `repo:sdk` / `repo:dvt`):**

| change | shape |
|---|---|
| changed | `setCreditPolicy(uint256,uint256,uint256,bool)` → `setCreditPolicy(uint256,uint256)` |
| added | `seedCreditPopulation(address[],uint256,bool)` |
| added | `creditPopulationTotal()`, `creditPopulationSeededAt()` |
| added | `CreditExposureResynced(uint256)` |
| added | `CreditTiersNotMonotonic()`, `CreditPopulationNotSeeded()`, `CreditPopulationCountMismatch()` |
| unchanged | `setCreditTier(uint256,uint256)`, `setLevelThresholds(uint256[])`, `getCreditLimit`, `totalCreditExposure`, `maxTotalCreditExposure` |

`abis/Registry.json` and `abis/abi.config.json` regenerated. The generator itself needed a
fix first: since round 3 added the `registry-size` compiler profile, a contract compiled
under two profiles is emitted as `<C>.default.json`, so `find out -name "<C>.json"` could not
locate `TimelockController` and the generator could not run to completion on this branch at
all. It now falls back to the **named** default-profile artifact.

*Disclosed, not fixed here:* running the generator regenerates twelve unrelated ABIs
(`xPNTsToken`, `X402Facilitator`, `PolicyRegistry`, …) with different bytecode, i.e. the
committed copies were produced from a different build profile. That is pre-existing and
out of scope for a security PR; only `Registry.json` is updated here, and the manifest is
consistent with the files actually on disk.

**Storage layout — append-only, verified:**

```
slots 0..26   unchanged (26 = maxTotalCreditExposure)
slot 27       creditPopulationTotal        (new)
slot 28       creditPopulationEpochOf      (new, internal)
slot 29       creditPopulationEpoch        (new, internal)
slot 30       creditPopulationSeededAt     (new)
__gap         uint256[47] @ 27  ->  uint256[43] @ 31
last slot     27 + 47 = 74  ==  31 + 43 = 74
```

`python3 scripts/check_storage_layout.py` → OK for both proxies after the snapshot update.

**Migration (live proxy):** new env contract for `UpgradeRegistryTo570.s.sol` —
`CREDIT_POPULATION_USERS` (comma-separated, every `GlobalReputationUpdated` subject,
de-duplicated) and optional `CREDIT_POPULATION_EXPECTED`. `CREDIT_EXPOSURE_BASELINE` is
removed; supplying it does nothing. An upgraded proxy issues no reputation credit until the
seed finalizes, so a migration that stops half-way is a halt, never a silent under-bound.

**Operational note for `repo:dvt`:** any governance action that re-prices a tier or moves a
threshold now requires a follow-up `seedCreditPopulation(...)` before reputation proposals
resume. Monitors should watch `CreditExposureResynced(0)` as the signal that the reputation
path has been shut.

---

## 8. Verification

| gate | result |
|---|---|
| `forge test` (Cancun) | **1339 passed / 0 failed / 38 skipped** (was 1318/0/38) |
| `forge test --evm-version prague` | **1251 passed / 0 failed / 20 skipped** (was 1231/0/20) |
| `forge build --sizes` | exit 0; `Registry` 23,029 / margin **1,547** |
| `python3 scripts/check_storage_layout.py` | OK, OK |
| `git diff --check` | clean |
| ABI regeneration | clean run; scoped to `Registry.json` + manifest |

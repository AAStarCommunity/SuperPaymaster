# CC-48 round-5 — the gates around the fix

> Scope: `ac4d3ad6` → this commit. Round-4's core change (freeze the guardian-slash
> **verdict**, not the verifier address) was accepted by the independent reviewer as
> correct and complete. Everything below is the layer **outside** it: the migration
> preflight, the cross-repo conformance gate, the remedy the contract actually offers
> against a bad verifier, and the artifact-generation gate.
>
> Supersedes §6 of [`CC48-round4-changes.md`](./CC48-round4-changes.md) (migration gates)
> and the "Threat this deliberately does not address" remedy paragraph in §2.

| Finding | Severity | Status |
|---|---|---|
| HIGH-1 — migration preflight cannot run against the real predecessor; the only unlock silently disables the tainted-key gate | HIGH | fixed |
| MEDIUM-1 — conformance fixture pins domain binding but not guardian-set completeness | MEDIUM | fixed |
| MEDIUM-2 — declared remedy against a bad verifier stronger than the contract's actual capability | MEDIUM | fixed |
| MEDIUM-3 — `abis/abi.config.json` trailing whitespace, root cause in the generator | MEDIUM | fixed |
| LOW-1 — `CLAUDE.md` still says `optimizer 10000 runs` | LOW | fixed |
| LOW-2 — `registerBLSPublicKey` inline comment still says PoP "is not inspected" on the owner path | LOW | fixed |
| LOW-3 — `queueGuardianSlash` NatSpec says "two-day window"; the constant is 4 days | LOW | fixed |
| LOW-4 — redundant length checks / `resolvedCount` after expiry | LOW | kept, both now explained in-code |

---

## 1. HIGH-1 — the preflight was un-runnable, and its escape hatch disarmed a second gate

### What was actually on chain

> **CORRECTED IN ROUND-6.** The table below originally listed ONE guardian-slash getter
> and drew a whole-surface conclusion from it. All five are now shown, and the 4.3.0 row
> does not say what round-5 assumed it said. See
> [`CC48-round6-changes.md`](./CC48-round6-changes.md) §1.

Read-only `cast call` against Sepolia (two independent RPCs —
`ethereum-sepolia-rpc.publicnode.com` and `1rpc.io/sepolia` — agreeing):

| Probe | `0x174b60bB…0158` (`config.sepolia.blsAggregator`) | `0xF51c0298…8B13` (`blsAggregatorPrev`) |
|---|---|---|
| `version()` | `BLSAggregator-4.3.0` | `BLSAggregator-4.1.0` |
| `MAX_VALIDATORS()` | 13 ✅ | 13 ✅ |
| `pendingGuardianSlashCount(address)` | **reverts — selector absent** | **reverts — selector absent** |
| `guardianSlashCases(uint256)` | **reverts — selector absent** | **reverts — selector absent** |
| `GUARDIAN_SLASH_CASE_WINDOW()` | **reverts — selector absent** | **reverts — selector absent** |
| `guardianExitRequests(address)` | **reverts — selector absent** | **reverts — selector absent** |
| `fraudProofVerifier()` | **`0x128847cF…6D51` — ANSWERS, 32 bytes** | **reverts — selector absent** |

The last row is the one round-5 never probed. `fraudProofVerifier` shipped with CC-89's
queue-less direct-execute path (`BLSAggregator-4.2.0`), TWO minor versions before the case
machine, so 4.3.0 sits in the gap where it answers that getter and none of the other four.
Treating all five as one feature is what made the real predecessor `Ambiguous`.

`pendingGuardianSlashCount` arrived with the guardian-slash feature (CC-89). Round-3 made
`UpgradeRegistryTo570` call `BLSKeyScanLib.requireNoPendingCases(OLD_BLS_AGGREGATOR)`
first and unconditionally, so:

1. `OLD_BLS_AGGREGATOR=0x174b60bB…` (the truth) → preflight reverts on a missing selector,
   before `requireNoTaintedKeyCarriedOver` ever runs.
2. `OLD_BLS_AGGREGATOR=0` (the only value that lets the script complete) → **both** checks
   are skipped, and the script prints
   `OLD_BLS_AGGREGATOR = 0: declared first-ever deployment, no predecessor checks` —
   a line that reads like a normal success path.

The check skipped in (2) is the only on-chain thing that stops the experiment stack's
publicly-known keys (scalars 1/2/3) from being re-onboarded onto the new aggregator, i.e.
the sole enforcement point of the "old stack is DO-NOT-REFERENCE" decision.

CI never caught it because both relevant cases in `CC48KeyScanPreflight.t.sol` used
`_freshAggregator()` — a **current-version** aggregator — as the "old" one. The legacy
shape had zero coverage, so a fully green suite hid a migration that could not run at all.

### The fix

**a) The pending check is capability-aware, and the skip is proven, not assumed.**
`BLSKeyScanLib.guardianSlashCapability(address)` classifies a predecessor from its
deployed ABI surface:

- **`Present`** — `pendingGuardianSlashCount(address)` decodes ⇒ full enumeration, nothing
  skipped.
- **`Absent`** — that selector *and* all four remaining guardian-slash getters
  (`guardianSlashCases`, `fraudProofVerifier`, `GUARDIAN_SLASH_CASE_WINDOW`,
  `guardianExitRequests`) are missing. They ship in the same feature as
  `queueGuardianSlash`, the **only** function that can create a pending case, so their
  joint absence is positive evidence that no case can exist. The pending check — and only
  the pending check — is skipped, with a `WARNING` line naming the address and version.
- **`Ambiguous`** — anything in between: a partial surface (unrecognised build), or a
  contract whose fallback answers probes with empty/short returndata. Reverts with
  `AmbiguousGuardianSlashCapability`. Silence is never read as "feature absent".

**b) The key scan runs first and unconditionally.** In `UpgradeRegistryTo570`,
`requireNoTaintedKeyCarriedOver` now runs *before* `requireNoPendingCases`. It is the
irreversible one — a publicly-known key re-onboarded onto production cannot be
un-published — and it works fine against 4.3.0's ABI (`MAX_VALIDATORS`, `validatorAtSlot`,
`getBLSPublicKey`, `blsKeyOwner` are all compatible; that was never what failed).

**c) `OLD_BLS_AGGREGATOR` is bound to the live wiring.**
`BLSKeyScanLib.requireDeclaredPredecessor(registryProxy, declared)` reads
`Registry.blsAggregator()` and requires equality. A live migration can no longer declare
itself first-ever, and a stale/typo'd predecessor (which would scan the wrong contract and
report clean) is caught by the same check. `0` is accepted only when the live Registry
genuinely has no aggregator wired — verified against the chain, not taken on the
operator's word.

### Regression coverage

| Property | Test |
|---|---|
| legacy 4.3.0 shape is classified `Absent` from its ABI alone | `CC48MigrationPreflight.test_LegacyShapeIsProvablyIncapableOfHoldingACase` |
| a modern predecessor is still fully scanned | `CC48MigrationPreflight.test_ModernShapeIsScannedNotSkipped` |
| a catch-all fallback is `Ambiguous`, not `Absent` | `…test_AFallbackContractIsAmbiguousNotAbsent` |
| a half-migrated surface is `Ambiguous` | `…test_APartialGuardianSurfaceIsAmbiguous` |
| declaring first-ever on a wired Registry is rejected | `…test_DeclaringFirstEverOnALiveRegistryIsRejected` |
| a wrong/stale predecessor is rejected | `…test_DeclaringTheWrongPredecessorIsRejected` |
| genuine first-ever still works | `…test_FirstEverIsAcceptedOnlyWhenRegistryHasNoAggregatorWired` |
| **end-to-end**: against a real 4.3.0-shaped predecessor holding scalars 1/2/3, the preflight completes AND the tainted carry-over still reverts | `CC48KeyScanPreflight.test_LegacyPredecessorIsScannableAndStillBlocksATaintedCarryOver` (Prague) |

`Legacy43AggregatorStub` forwards 4.3.0's real key-table surface to a live aggregator and
has **no fallback**, so every guardian-slash selector reverts on it exactly as it does
on-chain. The capability/predecessor tests deliberately run under **Cancun** — they are
pure ABI/staticcall properties, and confining them to the Prague-gated suite is how the
legacy shape went uncovered in the first place.

---

## 2. MEDIUM-1 — domain binding does not imply set binding

`FraudProofVerifierConformance.assertDomainBound` asserted three things, all about the
domain. A verifier that recomputes `fraudProofDigest(id, guardians)` from the arguments it
was handed passes all three **and accepts any strict subset** — it simply re-derives a
matching digest for the smaller set. The reference implementation
(`DomainBoundFraudProofVerifier`) is set-bound only by accident of its pre-image;
evidence-checking verifiers — the shape `OverIssueFraudProofVerifier` will have — are
subset-lenient *by construction*.

**Why that is exploitable here specifically.** `fraudProofId` is single-use **for ever**
(`status != 0` blocks re-opening, and 2=executed / 3=expired block it as permanently as
1=pending), `queueGuardianSlash` is permissionless, and the accused set is chosen by the
caller. A colluder who sees an honest watcher's `queueGuardianSlash(id, {A,B,C}, proof)`
in the mempool front-runs it with `queueGuardianSlash(id, {A}, proof)`: the case opens on
`{A}`, executes, burns `id`, and B and C are permanently immune to that evidence — with an
on-chain record saying the matter was adjudicated.

**`assertSetBound(verifier, aggregator, fraudProofId, guiltyGuardians, fraudProof)`** is
added. For the same `(id, proof)`, and recomputing each candidate set's own digest from the
aggregator exactly as `queueGuardianSlash` would:

1. ACCEPTS the exact committed set (no false negative)
2. REJECTS every strict subset of size *n−1* (each guardian dropped in turn)
3. REJECTS the superset with one extra address — the mirror-image mistake, where an
   innocent is appended and loses 100% of its lock
4. REJECTS an unrelated set of the same size

It requires ≥ 2 guardians (a 1-element set has no non-empty strict subset, and the
aggregator rejects the empty one), and the synthetic addresses for (3)/(4) are **derived**
from the committed set, not hard-coded, so a verifier cannot allow-list a known test
address.

`IFraudProofVerifier`'s NatSpec now states exact-set binding as a contract requirement and
gives the single-use/front-running reason, rather than leaving it to be inferred.

Fixture discrimination is proved in-repo, so it cannot be vacuous:

| Verifier shape | `assertDomainBound` | `assertSetBound` |
|---|---|---|
| `DomainBoundFraudProofVerifier` (reference) | pass | pass |
| `DomainIgnoringFraudProofVerifier` | **fail** | — |
| `SubsetLenientEvidenceVerifier` (new) | **pass** | **fail** (`VerifierAcceptsGuardianSubset`) |
| `SupersetLenientEvidenceVerifier` (new) | **pass** | **fail** (`VerifierAcceptsGuardianSuperset`) |
| always-false | **fail** | **fail** |

### For repo:dvt

`contracts/test/helpers/FraudProofVerifierConformance.sol` is the file to import verbatim.
Byte-exact provenance for this commit:

```
sha256(contracts/test/helpers/FraudProofVerifierConformance.sol)
  = 8ab33b49f5304ebbde3cc8d7c6c95041c5fbfc0bd64502d4bfa57af132a916b7
```

Both `assertDomainBound` **and** `assertSetBound` must pass in DVT CI before
`fraudProofVerifier` leaves `address(0)` in production. `verify`'s selector is unchanged
(`0x61077735`); the 4.9.0 bump is the aggregator's own ABI, not this seam's.

---

## 3. MEDIUM-2 — the declared remedy vs. the actual one

Round-4 documented governance's remedy against a bad verifier as "rotation + the bounded
4-day window + permissionless expiry". The contract's only off-switch was
`proposeFraudProofVerifier(0)` → `VERIFIER_ROTATION_DELAY` (= `GUARDIAN_SLASH_CASE_WINDOW`
= 4 days) → `applyFraudProofVerifier`. A compromised verifier can open a case and have it
executed for 100% of every accused guardian's lock **in a single block**, so a four-day
remedy was not a remedy; the write-up was more optimistic than the code.

**`emergencyDisarmFraudProofVerifier()` (onlyOwner, immediate)** clears the active
verifier **and** any in-flight rotation.

> **THE JUSTIFICATION BELOW IS RETRACTED — see
> [`CC48-round6-changes.md`](./CC48-round6-changes.md) §3.** The last bullet ("a stolen
> owner gains nothing new") is false in the only dimension that matters for an immediate
> call: TIME. This function **does** give the owner a new power — immediate, unannounced
> censorship of every future accusation, including by front-running a watcher's
> `queueGuardianSlash` out of the mempool. The power is kept, because a compromised
> verifier can slash 100% of every accused guardian's lock in one block, but it is a trade,
> not a free win, and the residual risk sits entirely on the owner being a Safe multisig.

- It can only ever *reduce* authority — the post-state is exactly the fail-closed dormant
  state the feature ships in. It cannot install, replace, or point at anything. *(True.)*
- **Re-arming is not shortened.** There is no counterpart that sets a non-zero verifier;
  coming back on-line still costs a full propose → 4 days → apply cycle. Disarm is not a
  fast path to a verifier of the owner's choosing. *(True.)*
- **Already-queued cases are unaffected, by construction rather than by promise.** Since
  round-4, `executeGuardianSlash` / retry / expire read only the verdict frozen in
  `guardianSlashCases[id]` and never touch `fraudProofVerifier`. The owner may stop future
  accusations and may **not** rescue an accused colluder. *(True — and it is only half of
  the asymmetry. The other half, "may stop future accusations", is the new power.)*
- ~~A stolen `owner` gains nothing new: `proposeFraudProofVerifier(0)` + 4 days reached the
  same terminal state, and a stolen owner has strictly stronger moves available anyway.~~
  **RETRACTED.** Same terminal state, different latency, and latency is the whole point.

It reverts (`VerifierAlreadyDisarmed`) rather than emitting a "disarmed" trail that took
nothing away, and emits `FraudProofVerifierEmergencyDisarmed` alongside the routine
`FraudProofVerifierUpdated` / `FraudProofVerifierRotationCancelled` so monitors can tell an
emergency stop from a scheduled rotation landing.

### Corrected NatSpec / threat model

- `fraudProofVerifier` storage comment: `address(0)` blocks **new** cases only. It does
  **not** stop an in-flight slash — the pre-round-5 text said it did, which would have led
  an operator to believe zeroing the verifier halts an in-flight case.
- `proposeFraudProofVerifier` delay rationale: the original justification ("so an owner
  cannot swap in an always-false verifier mid-case") has been provided structurally by the
  frozen verdict since round-4. What the delay still buys is that **arming or replacing**
  the authority behind a 100%-of-lock slash is publicly visible for four days before it can
  act. It is deliberately not applied to disarming.
- Round-4 §2's remedy paragraph is corrected in place to point here.

### Regression coverage — `CC48VerifierDisarmTest`

| Property | Test |
|---|---|
| takes effect in the same block; no new case can be opened, ever, without a re-arm | `test_DisarmIsImmediateAndStopsNewCases` |
| an in-flight rotation is cleared and cannot mature later | `test_DisarmAlsoClearsAnInFlightRotation` |
| re-arming still costs the full 4-day delay | `test_ReArmingStillCostsAFullRotationDelay` |
| a queued case still executes on its frozen verdict — even with the old verifier now returning false | `test_AQueuedCaseStillExecutesOnItsFrozenVerdictAfterDisarm` |
| disarm neither shortens nor extends a queued case's deadline; expiry still works | `test_DisarmDoesNotChangeAQueuedCaseDeadline` |
| owner-only (a public panic button would be a cheap 4-day denial of the deterrent) | `test_DisarmIsOwnerOnly` |
| refuses to no-op when already dormant | `test_DisarmRevertsWhenAlreadyDormant` |
| still clears a pending rotation when there is no active verifier | `test_DisarmWorksWithOnlyAPendingRotationToClear` |
| emits the routine events plus a distinct emergency marker | `test_DisarmEmitsTheRoutineEventsAndAnEmergencyMarker` |

---

## 4. MEDIUM-3 — trailing whitespace: the file was never the bug

`git diff --check <range> -- abis/abi.config.json` reported trailing whitespace on the
`buildTime` and `totalHash` lines. The root cause is `scripts/extract_v3_abis.sh`, which
emitted a literal trailing space inside four `echo` strings (`description`, `source`,
`buildTime`, `totalHash`), so hand-cleaning the file was undone by the next
`forge build && ./scripts/extract_v3_abis.sh`.

- All four emitting lines fixed at source.
- The generator now **self-checks**: after writing, it greps every artifact in `abis/` for
  trailing blanks (spaces *and* tabs) and exits non-zero with the instruction to fix the
  emitting line rather than the file. It also re-validates the manifest as JSON, since the
  emitting lines are hand-quoted.
- `git diff --check` over the full commit range is **0** for this commit — the check that
  matters, since a bare `git diff --check` in a clean tree compares the worktree to the
  index and proves nothing.

### Pre-existing drift found while re-running the generator — NOT fixed here

A full `./scripts/extract_v3_abis.sh` run rewrites ten artifacts that are still bare ABI
arrays into the current `{abi, bytecode}` shape: `GToken`, `GTokenStaking`, `MySBT`,
`xPNTsToken`, `xPNTsFactory`, `MicroPaymentChannel`, `PolicyRegistry`,
`TimelockController`, `X402Facilitator`, `GTokenAuthorization`. They predate the current
generator and were last written by `a871c9e5` / `050f56b3` / `7678308a`; every previous
manifest is self-consistent with them, so nothing is broken today.

Normalising them is a **breaking shape change for any consumer that reads those files as an
array** (`repo:sdk`), which makes it a change with its own notice — not something to sweep
into a security commit. So this commit regenerates **only** `BLSAggregator.json` (the sole
contract whose ABI it changes) plus the manifest, using the generator's new optional
subset argument (`./scripts/extract_v3_abis.sh BLSAggregator`); the manifest is still
generated, never hand-edited, and `totalHash` is recomputed over the whole directory.

Follow-up owed: decide the target shape, regenerate all ten, and notify `repo:sdk` in the
same change. Tracked here so it is not re-discovered as a surprise.

---

## 5. LOW

- **LOW-1** `CLAUDE.md` §Compiler Settings said `optimizer enabled (10000 runs)`. All three
  profiles are `optimizer_runs = 500` with `Registry.sol` further restricted to 200. The
  stale number is the one that builds SuperPaymaster at 27,597 B and BLSAggregator at
  25,860 B — both over EIP-170 — so the line now carries the measurement and a
  "measure, don't restore" warning.
- **LOW-2** `registerBLSPublicKey`'s inline comment still said the owner path is "the
  permissioned default; popSignature is not inspected", contradicting the unconditional
  `_verifyPoP` 15 lines below and the round-3 NatSpec above it. Rewritten: authorization is
  the *only* thing that differs between the two paths.
- **LOW-3** `queueGuardianSlash` NatSpec said "a bounded two-day window";
  `GUARDIAN_SLASH_CASE_WINDOW` is 4 days. Now names the constant instead of restating a
  number.
- **LOW-4** (kept, both explained in-code):
  - the `length == 0` / `> MAX_VALIDATORS` checks at the top of `executeGuardianSlash`
    duplicate `_validateGuardianSet`, but run *before* the case lookup and deadline check.
    They are pure calldata comparisons, cost gas only on the revert path, and keep the
    failure mode stable if the checks below are ever reordered. Redundancy, not dead code.
  - `expireGuardianSlashCase` deliberately does not advance `resolvedCount`: it counts
    guardians settled by **execution**, and conflating it with expiry would make
    "fully executed" and "expired after a partial execution" indistinguishable afterwards.
    **Decoders must read `status == 3 && resolvedCount < guardianCount` as "expired with
    `guardianCount − resolvedCount` accused released unjudged"** — matching the
    `GuardianSlashed` / `GuardianSlashSkipped` event trail.

---

## 6. Version / ABI / storage record

| Artifact | Before | After | Notes |
|---|---|---|---|
| `BLSAggregator.version()` | `BLSAggregator-4.8.0` | `BLSAggregator-4.9.0` | ABI additions below; not upgradeable — fresh deployment |
| `Registry.version()` | `Registry-5.7.0` | `Registry-5.7.0` | unchanged |
| BLSAggregator storage layout | — | **unchanged** | no new state variables; disarm only writes existing slots |
| Registry / SuperPaymaster storage layout | 28 / 37 slots | 28 / 37 slots | unchanged (`scripts/check_storage_layout.py` green) |
| BLSAggregator runtime size | 22,854 B | **23,192 B** (headroom 1,384) | `[profile.default]`, the profile that ships |
| SuperPaymaster / Registry runtime | 23,569 / 23,771 B | unchanged | untouched this round |
| `abis/BLSAggregator.json` sha256 | — | `228c529f322f304c04f59e8afa294b50418458e9846aed5130a485b7658006e1` | byte-exact vs. a clean `[profile.default]` rebuild |
| `abis/abi.config.json` `totalHash` | `4b93ecb4…5678` | `ac908549296a042b4cbb80586a99f6c97ba28521fb95c08e09e53ca2cbd9df40` | recomputed over the whole directory |

### BLSAggregator ABI delta (4.8.0 → 4.9.0)

**Additive only — no existing signature, tuple or event changed.**

| Kind | Signature |
|---|---|
| function (new) | `emergencyDisarmFraudProofVerifier()` — `onlyOwner` |
| event (new) | `FraudProofVerifierEmergencyDisarmed(address indexed clearedVerifier, address indexed clearedPending)` |
| error (new) | `VerifierAlreadyDisarmed()` |

`guardianSlashCases(uint256)` still returns the 7-tuple introduced in 4.8.0
(`guardiansHash, fraudProofHash, deadline, status, guardianCount, resolvedCount, verifier`);
`verify(bytes32,uint256,address[],bytes)` is still `0x61077735`.

Version pins updated in `UpgradeRegistryTo570.s.sol`, `DeployRepCreditSepolia.s.sol`,
`DeployBLSAggregatorSepolia.s.sol` and the three `version()` assertions in the test tree.

---

## 6b. Full verification run at this commit

| Check | Result |
|---|---|
| `forge test` (Cancun) | **1294 passed / 0 failed / 38 skipped** (was 1270/0/36; +24 new tests, +2 Prague-only skips) |
| `forge test --evm-version prague` (real EIP-2537) | **1207 passed / 0 failed / 20 skipped** (was 1181/0/20; +26) |
| `forge test --evm-version prague --match-path "contracts/test/paper7/*"` | **39 passed / 0 failed / 0 skipped** — no suite skipped itself, i.e. real precompiles |
| new suites | `CC48MigrationPreflight` 9/9, `CC48VerifierDisarmTest` 9/9, `CC48VerifierConformance` 11/11 (6 new), `CC48KeyScanPreflight` 9/9 (2 new) |
| `forge build` (`[profile.default]`, the shipping profile) | clean |
| `FOUNDRY_PROFILE=v3-only forge build` | clean |
| `scripts/check_storage_layout.py` | SuperPaymaster 37 slots OK / Registry 28 slots OK |
| EIP-170 | BLS 23,192 (hr 1,384) / SP 23,569 (hr 1,007) / Registry 23,771 (hr 805) |
| ABI regeneration | `abis/BLSAggregator.json` byte-exact vs. `jq '{abi,bytecode}'` of the fresh artifact; manifest `totalHash` recomputes to the recorded value |
| `git diff --check` over the commit range | **0** |

---

## 7. Cross-repo actions

| Repo | Action | Blocking? |
|---|---|---|
| `repo:dvt` | `FraudProofVerifierConformance.assertSetBound` is **new and mandatory** alongside `assertDomainBound`. Do not start `OverIssueFraudProofVerifier` against a guess — import the fixture at this commit | **release gate**: `fraudProofVerifier` stays `address(0)` in production until both pass in DVT CI |
| `repo:dvt` | evidence-checking verifiers are subset-lenient by construction; the verifier must reject any set that is not exactly the committed one | same gate |
| `repo:sdk` | re-sync `abis/BLSAggregator.json` for 4.9.0 (additive: one function, one event, one error). Existing decoders keep working; `guardianSlashCases` is unchanged since 4.8.0 | before any release that surfaces the new event |
| `repo:sdk` | decode `status == 3 && resolvedCount < guardianCount` as "expired with unjudged accused" (LOW-4) | documentation-level |

---

## 8. Migration gates (supersedes round-4 §6)

`UpgradeRegistryTo570.s.sol` and `DeployRepCreditSepolia.s.sol` now require
`version() == BLSAggregator-4.9.0`. Otherwise everything in
[`CC48-round3-changes.md`](./CC48-round3-changes.md) §1.5 / §3.3 still holds — the
Prague-only weak-key scan, the `ALLOW_EOA_OWNER ⇒ chainid == 31337` gate, `OLD_BLS_AGGREGATOR`
having no default — **with these two changes**:

1. `OLD_BLS_AGGREGATOR` must equal `Registry.blsAggregator()` as it reads at run time.
   `0` no longer works as a way to make the preflight pass.
2. The pending-case check may be skipped **only** for a predecessor proven incapable of
   holding a case from its own ABI surface, and that skip never affects the
   tainted/weak/duplicate key carry-over scan, which now runs first and unconditionally.

For the real Sepolia cutover this means: `OLD_BLS_AGGREGATOR=0x174b60bB…0158` (a
`BLSAggregator-4.3.0`, capability `Absent`) → the preflight runs, logs the skip with a
warning naming the version, and enforces the key scan against it.

> **CORRECTED IN ROUND-6.** That conclusion was right about the intent and wrong about the
> code as shipped in `fc0ca825`: `0x174b60bB…0158` classified as **`Ambiguous`**, not
> `Absent`, because `fraudProofVerifier()` was in the absence probe set and the live 4.3.0
> answers it. With `requireDeclaredPredecessor` also refusing `0`, NO value of
> `OLD_BLS_AGGREGATOR` could complete the script. Round-6 removes that probe from the
> absence set and pins the real shape with a fixture; the sentence above is true from
> round-6 onwards. See [`CC48-round6-changes.md`](./CC48-round6-changes.md) §1.

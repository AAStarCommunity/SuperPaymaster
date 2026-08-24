# CC-48 round-6 — the fixture was green about a shape that does not exist

> Scope: `fc0ca825` → this commit. Round-5's three MEDIUMs (set-bound conformance,
> emergency disarm, ABI generator root cause) were confirmed closed by the independent
> reviewer. What follows is the BLOCKER that round-5's own fix introduced, the threat-model
> correction it owed, and four LOWs.
>
> Supersedes: §1's on-chain table and §1's migration conclusion, and §3's monotonicity
> argument, in [`CC48-round5-changes.md`](./CC48-round5-changes.md). Those sections are
> annotated in place rather than deleted, because the *wrong* claim is the interesting part
> of the record.
>
> **SUPERSEDED BY ROUND 7** — [`CC48-round7-changes.md`](./CC48-round7-changes.md) replaces
> §3 of this document in full (the gate checked `code.length > 0`, which a 7702-delegated
> EOA and a 1-of-1 forwarder both satisfy, while every phrasing here said "Safe multisig"),
> and adds the operational prerequisites missing from §1's conclusion. Both places are
> annotated in place below.

| Finding | Severity | Status |
|---|---|---|
| BLOCKER-1 — the real 4.3.0 predecessor classifies `Ambiguous`; the preflight has NO runnable `OLD_BLS_AGGREGATOR` | BLOCKER | fixed |
| HIGH-1 — `emergencyDisarmFraudProofVerifier` gives `owner` a new power that its own NatSpec denied | HIGH | fixed (argument corrected + deployment gate added) |
| MEDIUM-1 — `_probe` is fail-open in the `Present` direction; a 32-byte fallback is read as a real answer | MEDIUM | fixed |
| LOW-1 — `_versionOrUnknown` reverts on a malformed ABI head, inside a pure warning path | LOW | fixed |
| LOW-2 — synthetic guardian sets are only probabilistically distinct; overflow at a maximal `fraudProofId` | LOW | fixed |
| LOW-3 — no coverage for partial execution → disarm → retry | LOW | fixed |
| LOW-4 — the generator's JSON validation silently skips when `jq` is missing | LOW | fixed |

---

## 1. BLOCKER-1 — the absence probe included a getter from a different feature

### What is actually on chain

Two independent RPCs agree (read-only `cast call`; the corrected table also replaces §1 of
round-5, which listed only one of the five getters):

| Probe | `0x174b60bB…0158` = `config.sepolia.blsAggregator` | `0xF51c0298…8B13` |
|---|---|---|
| `version()` | `BLSAggregator-4.3.0` | `BLSAggregator-4.1.0` |
| `pendingGuardianSlashCount(address)` | reverts | reverts |
| `guardianSlashCases(uint256)` | reverts | reverts |
| `GUARDIAN_SLASH_CASE_WINDOW()` | reverts | reverts |
| `guardianExitRequests(address)` | reverts | reverts |
| `fraudProofVerifier()` | **`0x128847cF…6D51` — answers, 32 bytes** | reverts |

### Why 4.3.0 has that one getter and not the other four

Git history, not inference:

- `address public fraudProofVerifier` arrived in `75b3f9f4` — CC-89's guardian-slash **thin
  entry**, a queue-less `executeGuardianSlash` that slashes inside one call and writes **no
  case storage at all**. That commit's `version()` is `BLSAggregator-4.2.0`.
- `pendingGuardianSlashCount`, `guardianSlashCases`, `GUARDIAN_SLASH_CASE_WINDOW` and
  `guardianExitRequests` arrived in `daa1d1ec` / `2c0ed76b` — CC-48's **case machine**,
  together with `queueGuardianSlash`.

`4.3.0` sits exactly between the two. Round-5's premise — "these five getters ship in the
same feature, so their joint absence is positive evidence" — is false for one of the five,
and it is false for the specific contract the migration must actually read.

### The deterministic consequence in `fc0ca825`

```
_probe(pendingGuardianSlashCount) → reverts   → pendingOk = false        (not Present)
_probe(guardianSlashCases)        → reverts   → ok = false
_probe(GUARDIAN_SLASH_CASE_WINDOW)→ reverts   → ok = false
_probe(guardianExitRequests)      → reverts   → ok = false
_probe(fraudProofVerifier)        → 32 bytes  → ok && decodable → anyOther = true
                                              → Ambiguous
requireNoPendingCases → revert AmbiguousGuardianSlashCapability(0x174b60bB…)
```

And because round-5 *also* (correctly) made `requireDeclaredPredecessor` reject
`OLD_BLS_AGGREGATOR=0` on a Registry that has an aggregator wired, the other value reverts
with `PredecessorMismatch`. **No value of `OLD_BLS_AGGREGATOR` could complete the script**,
which never reached its `new Registry()` broadcast, so the governance calldata could not be
produced at all. Fail-closed, so nothing unsafe shipped — but a commit titled "make the
migration preflight runnable" left it un-runnable against its only real target.

The realistic operational risk was human: an operator hitting
`AmbiguousGuardianSlashCapability` in a release window reads "unrecognised build / possible
catch-all fallback", concludes the *contract* is broken, and edits the probe list or
comments the line out — dismantling the gate that had just been built.

### The fix (narrow; the state machine is untouched)

1. **`fraudProofVerifier` is out of the absence set.** The remaining four are the case
   machine, and the argument is now the true one: the ONLY function that can create a
   pending case is `queueGuardianSlash`, which landed in the SAME commit as those four
   getters. All four missing ⇒ no `queueGuardianSlash` ⇒ no case store ⇒ nothing for the
   pending scan to find. 4.3.0's `executeGuardianSlash` is CC-89's queue-less path and
   writes no case storage, so skipping the pending check is sound for it.
2. **A fixture with the real shape.** `Legacy43RealShapeStub` (Cancun) and the reworked
   `Legacy43AggregatorStub` (Prague) both **expose `fraudProofVerifier()` returning
   `0x128847cF…6D51`** and expose none of the four, and both assert `Absent`. Each test
   first asserts `fraudProofVerifier() != 0`, so the fixture cannot silently drift back
   into the shape that has never existed on chain.
3. **Documentation corrected at all three sites**: round-5's on-chain table (five rows now,
   not one), round-5's migration conclusion, and `Legacy43AggregatorStub`'s NatSpec — which
   claimed the absence of `fraudProofVerifier` had been "verified by cast call against
   0x174b60bB…0158". It had not; that claim was true only of `4.1.0`.

> **ROUND-7 CORRECTION (MEDIUM-2).** Everything above is true at the CAPABILITY-PROBE
> level and was re-verified against chain by the round-6 reviewer. It is **not** true of
> *running* `UpgradeRegistryTo570` against the live Sepolia stack: read-only calls confirm
> that the Registry (`0xf5Bf37ca…8E71`, `Registry-5.4.2`) and the 4.3.0 aggregator
> (`0x174b60bB…0158`) are **both owned by an EOA** (`0xb5600060…df0e`, `eth_getCode` = `0x`),
> so the script stops at the governance gate and never reaches the probe. That is not a
> regression — Registry's owner has had to be a contract since round 3 — but the commit
> title "unblock the real 4.3.0 predecessor" and this conclusion did not say it.
> Prerequisites for a real migration: **(1)** `Registry.owner()` = Safe-compatible M-of-N
> or a `TimelockController` with `getMinDelay() > 0` — **no script in this repo does this,
> it is a manual ops step**; **(2)** `NEW_BLS_AGGREGATOR.owner()` = Safe-compatible M-of-N;
> **(3)** a Prague RPC; **(4)** `OLD_BLS_AGGREGATOR == Registry.blsAggregator()`. See
> [`CC48-round7-changes.md` §3](./CC48-round7-changes.md) and the
> [Safe onboarding runbook](./CC48-safe-onboarding-runbook.md).

| Property | Test |
|---|---|
| the real 4.3.0 shape (verifier present, case machine absent) is `Absent`, and the pending check completes | `test_TheRealSepolia43ShapeIsAbsentNotAmbiguous` (Cancun) |
| same, end-to-end, with the real weak-key scan still biting on a tainted carry-over | `test_LegacyPredecessorIsScannableAndStillBlocksATaintedCarryOver` (Prague) |
| a fully-featured aggregator is still scanned, not skipped | `test_ModernPredecessorStillGetsTheFullPendingScan` |

---

## 2. MEDIUM-1 — `_probe` was fail-open in the `Present` direction

`decodable = ret.length >= minReturnLength` closed only one half of the catch-all problem.
A fallback returning **zero** bytes was rejected (that is `test_AFallbackContractIsAmbiguous
NotAbsent`); a fallback returning **32+** bytes — the ordinary shape of a proxy delegating
to an implementation with a different ABI — satisfied `>= 32`, classified `Present`, and
sent the enumeration off to read a fabricated `pendingGuardianSlashCount`. Direction of the
failure: a fabricated non-zero reverts (safe); a fabricated **zero** reports "no pending
cases" for a contract that was never actually asked. That was the single fail-open surface
in the function.

Two changes:

- **A guaranteed-absent selector is probed FIRST.** `BLSKeyScanLib.CATCH_ALL_SENTINEL` is
  derived from a string no build implements. If it *answers at all* — any returndata,
  empty or 32+ bytes — the contract has a catch-all fallback and every later answer is
  fabricated, so the result is unconditionally `Ambiguous` before a single real getter is
  consulted.
- **Widths are exact.** `decodable = ret.length == expectedReturnLength`. Every probed
  getter returns a static head, so each has exactly one valid encoding; anything else is a
  contract that is not what its ABI claims.

That the sentinel does not collide with a real function is not asserted by hand: a genuine
`BLSAggregator` classifying `Present` in `test_ModernPredecessorStillGetsTheFullPendingScan`
is only reachable when the sentinel probe reverted against it. A collision would turn every
aggregator `Ambiguous` and fail there first.

| Property | Test |
|---|---|
| a fallback returning a full word is `Ambiguous`, not `Present` (with the fixture asserting it really does answer 32 bytes) | `test_AWideReturningFallbackIsAmbiguousNotPresent` |
| a wrong-width answer to the pending getter is `Ambiguous` | `test_AWrongWidthPendingAnswerIsAmbiguous` |
| an empty-returndata fallback is still `Ambiguous` | `test_AFallbackContractIsAmbiguousNotAbsent` |
| an address with no code is still `Ambiguous` | `test_AnEmptyAddressIsAmbiguous` |

**Stated limitation**, in the NatSpec too: every probe is a `staticcall`, so a fallback that
*writes* state reverts on all of them and classifies `Absent`. Such a contract also cannot
answer the pending scan, and `requireDeclaredPredecessor` confines the target to the one
address Registry is actually wired to.

---

## 3. HIGH-1 — the disarm is kept; the argument that it costs nothing is retracted

The function stays. The reasoning for it is accepted and unchanged: a compromised verifier
can open a case and have it executed for 100% of every accused guardian's lock **inside a
single block**, so a four-day `propose(0) → apply` was never a remedy.

What was wrong is the self-justification, which DVT and operations would otherwise have
consumed as the threat model.

### The claim, and why it is false

> "an attacker who steals `owner` gains nothing from this that it did not already have:
> `proposeFraudProofVerifier(0)` + 4 days reached the same terminal state"

Same terminal state, **different latency** — and latency is the only property an immediate
call has. Auditing all eleven `onlyOwner` entry points against `queueGuardianSlash`'s
preconditions (`verifier != 0`, `verifier.code.length != 0`, `fraudProofId != 0`,
`status == 0`, `_validateGuardianSet`, `verify()`):

- `_validateGuardianSet` is `pure`, so `revokeBLSPublicKey` / `releaseKeyBinding` cannot
  block a case from opening.
- No other owner entry point touches any of those preconditions.

**Before 4.9.0, no owner call could block `queueGuardianSlash` in the same block. After
4.9.0, one can.** Concretely: an honest watcher's `queueGuardianSlash(id, {A,B,C}, proof)`
sits in the mempool; a colluding or compromised owner front-runs it with
`emergencyDisarmFraudProofVerifier()`; the watcher reverts with `FraudProofVerifierNotSet`.
Repeating costs one transaction each time. On 4.8.0 the same owner needed
`propose(0)` + **four publicly visible days**, during which watchers could still open cases
that round-4's frozen verdict then protected. That window is what this function removes.

### What is unchanged, and what carries the risk

- **Already-queued cases are out of reach.** `fraudProofVerifier` has exactly one
  non-governance read in the whole repo — inside `queueGuardianSlash`. Execution, retry and
  expiry read only the verdict frozen at queue time. The owner may stop future accusations
  and may not rescue an accused colluder.
- **Re-arming still costs the full 4 days.** There is no counterpart that sets a non-zero
  verifier, so disarm is not a fast path to a verifier of the owner's choosing.
- **A TimelockController does NOT cover this path.** A timelocked emergency stop is not an
  emergency stop; the two are semantically exclusive. So for the disarm path the **Safe
  multisig is the only governance defence**, not defence in depth. Round-5's
  "…that is defence in depth, no longer the only defence" is corrected accordingly, and
  scoped to `proposeFraudProofVerifier` where it is true.

### The gate that makes "owner should be a multisig" mean something

> **SUPERSEDED BY ROUND 7 (HIGH-1).** This subsection is wrong about what the gate
> ENFORCES, and it is the wrongness that matters: the gate checked `ownerAddr.code.length >
> 0` and logged *"owner is a contract (Safe/Timelock)"*, while this text, the revert
> strings, the `GovernanceOwnerGate` NatSpec and `BLSAggregator`'s disarm NatSpec all said
> a **multisig** had been required. An **EIP-7702 delegated EOA** (23 bytes of code, the
> private key still signs everything) and a **1-of-1 forwarder** both passed. Round 7
> replaces the criterion with a Safe-compatible M-of-N check — reject `0xef0100`,
> `getThreshold() >= 2`, `getOwners()` an exactly-decoded array of distinct non-zero owners
> with `length >= threshold` — and restricts every phrasing to **"Safe-compatible
> M-of-N"**, because none of this proves the owner is a *canonical* Safe. The table of
> entry points below is still accurate; the criterion applied at each of them is not. Read
> [`CC48-round7-changes.md` §1](./CC48-round7-changes.md) instead of this subsection.
>
> Round 7 also replaces the test list at the end of this subsection: the env-reading cases
> were merged into one `test_GateBehaviourAcrossChainsAndOwnerShapes`, because `forge` runs
> a contract's tests in parallel and `vm.setEnv` is a process global — split apart, they
> failed in a different combination on every run.

Reviewing every entry point that can create or re-point a `BLSAggregator` owner found that
**none** enforced anything: the constructor sets `owner = msg.sender`, and every deploy
script left the deployer EOA in place. `contracts/script/checks/GovernanceOwnerGate.sol`
closes that:

- `requireGovernanceOwner` — anvil (31337) is free; on any other chain the owner must be a
  **contract**. The one exception is a **known testnet** with an explicit
  `TESTNET_EOA_OWNER_ACK=true`, which exists because the RepCredit evidence stack and the
  CC-89 E2E aggregator genuinely need a hot owner and a gate that blocks them would simply
  be commented out. There is **no acknowledgement that works on a production chain**.
- `requireGovernanceOwnerStrict` — no acknowledgement at all outside anvil. Used by the
  migration entry point: a rehearsal whose ownership model differs from production
  rehearses the wrong system.
- `declaredGovernanceOwner()` reads `GOVERNANCE_OWNER`; deploy scripts transfer ownership to
  it as their **last** owner-gated action, so every earlier owner-only wiring step still
  runs under the deployer.

| Entry point | Gate |
|---|---|
| `UpgradeRegistryTo570.s.sol` (migration) | strict, on **both** Registry owner and `NEW_BLS_AGGREGATOR`'s owner |
| `DeployLive.s.sol` (production) | transfer to `GOVERNANCE_OWNER`, then `requireGovernanceOwner` |
| `DeployStandardV3.s.sol` | same |
| `DeployNewBLSModules.s.sol` | same |
| `deployment/07b_DeployBLSModules.s.sol` | same |
| `DeployBLSAggregatorSepolia.s.sol` (testnet E2E) | same (ack path available on Sepolia) |
| `DeployRepCreditSepolia.s.sol` (experiment) | same (ack path available on Sepolia) |
| `DeployAnvil.s.sol` (local) | same call; a no-op on 31337 by construction |

**Scope, stated plainly:** this gate covers the **disarm authority** — `BLSAggregator` —
plus the Registry owner the 5.7.0 migration already gated. It does not re-own GToken,
staking or SuperPaymaster; that is a separate change with its own blast radius, and
pretending otherwise here would be exactly the kind of over-claim §3 exists to correct.

| Property | Test |
|---|---|
| a production chain refuses an EOA owner **even with** `TESTNET_EOA_OWNER_ACK=true` | `test_ProductionChainRefusesAnEoaOwnerEvenWithTheTestnetAck` |
| a contract owner passes (the gate is not "always reverts off anvil") | `test_ProductionChainAcceptsAContractOwner` |
| a testnet refuses an EOA owner by default, and names the one way to proceed | `test_TestnetRefusesAnEoaOwnerWithoutTheExplicitAck` |
| an acknowledged experiment stack may still run | `test_TestnetAllowsAnEoaOwnerWithTheExplicitAck` |
| the migration's strict gate cannot be unlocked by an env var | `test_StrictGateHasNoTestnetAcknowledgement` |
| anvil is unaffected by either variant | `test_AnvilIsUnaffected`, `test_StrictGateIsStillANoOpOnAnvil` |
| partial execution → disarm → retry still completes on the frozen verdict, with no double-count and the disarm still holding | `test_PartialExecutionSurvivesADisarmAndStillRetries` (LOW-3) |
| the nine round-5 disarm properties | `CC48VerifierDisarmTest`, unchanged |

---

## 4. LOW-1 — a warning path must not be the thing that reverts

`_versionOrUnknown` did `abi.decode(ret, (string))` on any return of 64+ bytes. A
predecessor returning a malformed dynamic head (offset or length outside the returndata)
made the decoder revert **inside a view library**, turning the informational line printed
next to a skipped pending-case check into an unexplained failure. The head is now
bounds-checked by hand — exactly as the ABI decoder would — and degrades to
`<malformed version() return>`.

Covered by `test_AMalformedVersionReturnDegradesInsteadOfReverting`, with a stub for each
malformed shape (out-of-range offset, out-of-range length).

## 5. LOW-2 — the synthetic sets are now distinct by construction, not by luck

`assertSetBound`'s unrelated set was built as
`_syntheticGuardian(guiltyGuardians, fraudProofId + 1 + i)`:

- each element was checked only against the **accused** set, so pairwise distinctness — and
  distinctness from the superset's `extra` — was probabilistic. A collision would have
  silently shrunk "n unrelated addresses" into a smaller multiset, weakening assertion (4)
  with nothing failing;
- `fraudProofId + 1 + i` **overflows** for any id within `n + 1` of `type(uint256).max`. The
  id is caller-chosen and single-use for ever, so "nobody picks one that big" is a hope, not
  a property — and a DVT repo running the gate on such an id would have got an arithmetic
  revert from the fixture instead of a verdict on its verifier.

Both are gone: one generator (`syntheticSets`, now `internal` so the fixture's own tests can
assert its output rather than argue about it) draws every address against a **growing**
exclusion list, and the per-index salt is a hash. Covered by
`test_SyntheticSetsArePairwiseDistinctByConstruction` and
`test_SetBoundHandlesAMaximalFraudProofId`.

## 6. LOW-4 — the generator's JSON check failed open

`scripts/extract_v3_abis.sh` validated the manifest only `if command -v jq`. On a machine
without `jq` the one check guarding the hand-quoted `echo` lines did nothing, and "silently
did nothing" is indistinguishable from "passed" in CI output. It is now fail-closed: `jq`
if present, `python3 -c 'json.load(...)'` as an equivalent fallback, and a hard error if
neither exists.

`buildTime` still makes `abis/abi.config.json` non-byte-reproducible **by design** — it is a
build stamp. Content reproducibility is what the manifest asserts, and it holds:
regenerating `abis/BLSAggregator.json` is byte-exact, and both the per-file hashes and
`totalHash` recompute to the committed values.

---

## 7. Cross-repo status (unchanged by this round)

- **@repo:dvt — still blocked.** `assertDomainBound` **and** `assertSetBound` must both pass
  in DVT's own CI before `fraudProofVerifier` may leave `address(0)`. `verify` selector
  remains `0x61077735`; import the fixture, do not re-type it. Consume it only after this
  round clears independent review.
- **CC-49 / CC-50** remain open on their own threads.
- No merge, no tag, no release, no Sepolia write in this round.

# CC-48 round-3 — change record, migration gates, and runbooks

Scope: `BLSAggregator 4.6.0 → 4.7.0`. Registry is **unchanged** (stays `Registry-5.7.0`,
no storage additions, no ABI change).

This document is the authoritative record for the version / ABI / storage-layout
consequences of round-3, and the runbook for the two operational hazards it introduces
or documents. It is written for the downstream repos (`repo:dvt`, `repo:sdk`) as much as
for this one.

---

## 1. What changed and why

### 1.1 HIGH — a queued guardian-slash case now pins its verifier

> **SUPERSEDED by round-4** — see [`CC48-round4-changes.md`](./CC48-round4-changes.md).
> Pinning the verifier ADDRESS does not survive an upgradeable verifier: a UUPS /
> Transparent / Beacon proxy keeps the same address *and* the same `extcodehash` across an
> implementation swap, so the timing attack below still works one indirection deeper.
> `BLSAggregator-4.8.0` freezes the VERDICT instead — `fraudProofHash =
> keccak256(fraudProof)` alongside `guardiansHash` — and `executeGuardianSlash` no longer
> calls a verifier at all. `GuardianSlashVerifierGone` and `GuardianSlashVerifierPinned`
> are gone; `verifier` in the struct is audit-only. The rest of this section is kept as the
> record of what round-3 shipped and why it was not sufficient.

**The defect.** Round-2 introduced `VERIFIER_ROTATION_DELAY` (= `GUARDIAN_SLASH_CASE_WINDOW`
= 4 days) and claimed it made a queued case immune to a governance verifier swap. It did
not. The delay bounds `propose → apply`. Nothing bounds `matured → apply`, and
`applyFraudProofVerifier()` is permissionless by design. So:

```
T0                owner: proposeFraudProofVerifier(evil)      readyAt = T0 + 4d
T0+4d             rotation matures — and is left UNAPPLIED (a loaded gun)
T0+4d+X           watcher: queueGuardianSlash(id)             deadline = T0+4d+X+4d
T0+4d+X+1 block   anyone: applyFraudProofVerifier()           evil is now live
...               executeGuardianSlash re-read the LIVE verifier → false, forever
T0+8d+X           case expires; expireGuardianSlashCase is permissionless, so the
                  accused releases their own freeze and walks
```

**The fix.** `GuardianSlashCase` gained an `address verifier` field, written at
`queueGuardianSlash` time. `executeGuardianSlash` reads `slashCase.verifier`, never
`fraudProofVerifier`. A rotation can no longer decide a case that was already open —
which removes the timing argument entirely rather than tightening it.

Supporting rules:

- `queueGuardianSlash` rejects an EOA verifier (`VerifierNotContract`) — a snapshot must
  point at code to mean anything.
- `executeGuardianSlash` reverts `GuardianSlashVerifierGone` if the pinned verifier no
  longer has code. It does **not** fall back to the live verifier: a case is decided by
  the authority that opened it or not at all. The freeze then lifts through normal
  expiry.
- Expiry is verifier-independent and unchanged, so pinning cannot make a case immortal.
- A case opened *after* a rotation pins the *new* verifier. Pinning is per case.

Regression coverage: `contracts/test/security/CC48CoreFixes.t.sol`
(`CC48GuardianSlashRetryTest`) — pre-armed rotation, retry-after-rotation, expiry
interleave, verifier-gone fail-closed, EOA rejection, dormant-at-queue. Real-precompile
version: `contracts/test/paper7/CC48PragueStateMachine.t.sol`.

### 1.2 Proof-of-possession is now mandatory on BOTH registration paths

The owner path previously skipped PoP, justified by "a compromised owner is game-over
anyway". That argument covers *authorization*; it does not cover this property.
`blsKeyOwner` is a permanent, deliberately irreversible binding, so the exemption meant:

- one mistyped address bound a third party's public key **forever**, and
- an owner could pre-empt a validator's own self-registration by binding its key first
  (no PoP needed), permanently denying that validator the use of its key.

Now every entry in the key table is backed by a signature from the holder of the
corresponding secret key. This is a **breaking change for onboarding tooling**: the owner
must collect a real PoP from each validator, signed against the target aggregator's
domain.

### 1.3 `releaseKeyBinding` — recovery for a binding created in error

`releaseKeyBinding(bytes32 keyHash)` is owner-only and refuses while **any** active slot
holds that key (`KeyBindingStillActive`). It scans the active table rather than trusting
the address the binding names, so a key that was rotated to a different holder is still
protected. Combined with mandatory PoP, reaching its precondition means the key is
registered nowhere.

`revokeBLSPublicKey` still does **not** release the binding — that is intentional and
unchanged; releasing on revoke would let a revoked key be re-claimed by a second address,
which is the duplicate-key condition itself.

### 1.4 Slash-only proposal shape is pinned from both sides

- `repUsers.length == 0 && newScores.length != 0` → `CombinedProposalNotSupported`. The
  slash pre-image does not commit to `newScores`, so a non-empty value was
  caller-controlled input that survived a signature check without being signed. Unused
  today; rejected so it cannot become used-but-unsigned later.
- `operator == 0 && slashLevel == 0 && repUsers.length == 0` → `EmptyProposalNotSupported`.
  A no-op proposal burned a `proposalId` in two contracts. It always required a real
  quorum, so this is a protocol-rule cleanup, not a vulnerability fix.

### 1.5 Migration / deployment gates are now enforced, not commented

`contracts/script/checks/BLSKeyScanLib.sol` holds the validator-set health checks, and
`contracts/script/v3/UpgradeRegistryTo570.s.sol` calls them **unconditionally**:

| Check | Failure it prevents |
|---|---|
| `newAggregator.REGISTRY() == proxy` | domains can never agree; reputation path halts |
| recomputed post-batch Registry separator `==` aggregator's | same, at byte level, checked instead of printed |
| `version() == BLSAggregator-4.7.0` (round-4: `4.8.0`) | wrong build wired in |
| distinct **active** keys `>=` max of `defaultThreshold`, `minThreshold`, `slashThresholds[0..2]` | cutting over to an aggregator with too few signers → every BLS path reverts until onboarding finishes; undoing costs another timelock cycle |
| no duplicate keys | N slots on one key ⇒ pkAgg = N·pk ⇒ one sk holder signs an N-of-N quorum |
| no publicly-known scalar keys | the exact state the RepCredit experiment stack was in |
| no tainted key carried from `OLD_BLS_AGGREGATOR` to the new one | "fresh deployment, fresh keys" becomes enforceable |
| no pending case on `OLD_BLS_AGGREGATOR` | a live freeze silently lifted by the cutover |
| `ALLOW_EOA_OWNER ⇒ chainid == 31337` | the governance-owner gate was opt-out on any chain |

`OLD_BLS_AGGREGATOR` has **no default** — forgetting it fails loudly. Set it to `0` only
to declare a first-ever deployment with no predecessor.

The weak-key scan recomputes `g1·s`, so the preflight requires an EIP-2537 (Prague) RPC
and **fails closed** (`EIP2537Unavailable`) rather than reporting "clean" when it could
not run.

**Known limitation, stated plainly:** `requireNoPendingCases` enumerates guardians via
`validatorAtSlot`. An accused address whose key was already revoked holds no slot and is
not enumerable on-chain; watchers must cross-check `GuardianSlashQueued` events over the
case window before scheduling the batch.

### 1.6 Prague test matrix

`forge test --evm-version prague` is now **green with zero failures** and is a CI gate
(`.github/workflows/security.yml`, Stage 2).

Previously 15 tests failed there — all `vm.etch: cannot use precompile ... as an argument`,
i.e. harness failures, not defects. But a red gate cannot distinguish the two. Suites that
require precompile injection now step aside via
`contracts/test/helpers/MockedPrecompiles.sol`, and the paths they cover are covered
under real pairings in `contracts/test/paper7/`:

| Path | Real-precompile coverage |
|---|---|
| domain separation / cross-aggregator replay | `RepCreditDomainReplay.t.sol` |
| reputation pipeline, threshold, replay, exited signer | `BLSGasMeasurement.t.sol` (`RepCreditPragueE2E`) |
| exit notice + cancel/cooldown | `CC48PragueStateMachine.t.sol` |
| protocol-wide credit-exposure ceiling | `CC48PragueStateMachine.t.sol` |
| guardian slash incl. pre-armed rotation, ejection, Registry exit freeze | `CC48PragueStateMachine.t.sol` |
| migration key-scan gate incl. fail-closed without EIP-2537 | `CC48KeyScanPreflight.t.sol` |

### 1.7 Build profiles

`[profile.tokens]` shared `out/`/`cache/` with `profile.default` while compiling at
`optimizer_runs = 10000` with no Registry size restriction — one run left an
over-EIP-170 `Registry`/`SuperPaymaster` in `out/`, which `deploy-core`'s ABI sync reads
by `find out -name`. Settings are now aligned with the shipping profile. `CLAUDE.md`
also now states what actually ships: `deploy-core` never sets `FOUNDRY_PROFILE`, so
`[profile.default]` is the deployment profile.

---

## 2. Version / ABI / storage record

| Artifact | Before | After | Notes |
|---|---|---|---|
| `BLSAggregator.version()` | `BLSAggregator-4.6.0` | `BLSAggregator-4.7.0` (round-4: `4.8.0`) | not upgradeable — fresh deployment |
| `Registry.version()` | `Registry-5.7.0` | `Registry-5.7.0` | unchanged this round |
| Registry storage layout | 28 slots | 28 slots | unchanged; `scripts/check_storage_layout.py` green |
| SuperPaymaster | untouched | untouched | — |

### BLSAggregator ABI delta (all additive except one struct getter)

**BREAKING for decoders:** `guardianSlashCases(uint256)` now returns **6** fields, not 5
(round-4 makes it **7**, with `fraudProofHash` inserted at index 1 — see the round-4 doc;
decoders should skip straight to the 7-field shape):

```
(bytes32 guardiansHash, uint64 deadline, uint8 status,
 uint16 guardianCount, uint16 resolvedCount, address verifier)
```

Anything that destructures this tuple positionally must be updated — `repo:sdk` and any
DVT watcher decoding it. The new field is appended, so a decoder that reads the first
five by name/position still gets the same values, but a strict 5-tuple decode reverts.

Added:

- `function releaseKeyBinding(bytes32 keyHash) external` (owner-only)
- `event BLSKeyBindingReleased(bytes32 indexed keyHash, address indexed previousOwner)`
- `event GuardianSlashVerifierPinned(...)` — **removed again in round-4**, replaced by
  `GuardianSlashJudgmentFrozen(uint256,address,bytes32,bytes32)`
- `error GuardianSlashVerifierGone(...)` — **removed in round-4**; the condition can no
  longer block execution
- `error VerifierNotContract(address verifier)`
- `error KeyBindingStillActive(bytes32 keyHash, address boundTo)`
- `error EmptyProposalNotSupported()`

Unchanged (explicitly, because it is the cross-repo seam):

- `IFraudProofVerifier.verify(bytes32,uint256,address[],bytes)` — selector `0x61077735`.
  Pinned by a test (`CC48VerifierConformance.test_VerifierSelectorIsPinned`) so a future
  change to this signature fails here rather than silently in a deployed DVT verifier.

Behavioural change with no ABI change: `registerBLSPublicKey` now reverts `InvalidPoP()`
on the owner path when `popSignature` does not verify. Same signature, stricter contract.

---

## 3. Runbooks

### 3.1 Onboarding a validator (4.7.0)

1. Validator generates a BLS keypair. **Never** a small/publicly-known scalar — the
   preflight scan rejects `1..32` explicitly, and that check exists because it already
   happened once.
2. Validator computes `popDigest(validatorAddress, publicKey)` **against the target
   aggregator** and signs it: `pop = sk · H_pop(popDigest)`. A PoP is bound to
   (domain name, chainid, aggregator, registry, validator address, key) — it does not
   transfer between aggregators or chains.
3. Validator stakes and holds `ROLE_DVT` in Registry.
4. Either the owner calls `registerBLSPublicKey(validator, pk, slot, pop)` (PoP now
   verified), or — with `permissionlessBLSRegistration` on — the validator self-registers
   and the contract assigns the slot.
5. After the set is complete, run the scan:
   `BLS_AGGREGATOR=0x… forge script contracts/script/checks/ScanDuplicateBLSKeys.s.sol --rpc-url $RPC` (Prague RPC required).

### 3.2 A key was bound to the wrong address

Symptom: `DuplicatePublicKey(keyHash, boundTo)` where `boundTo` is not the real holder.

1. `revokeBLSPublicKey(wrongHolder)` if a slot is active for it.
2. Confirm `getBLSPublicKey(x).isActive == false` for every holder of that key.
3. `releaseKeyBinding(keyHash)` (owner / governance).
4. Re-register with a PoP from the real holder.

If `releaseKeyBinding` reverts `KeyBindingStillActive`, some active slot still holds the
key — find it before forcing anything. There is no path that releases a live signer's
binding, and that is deliberate.

### 3.3 Migration to a new aggregator

```
OLD_BLS_AGGREGATOR=0x…            # 0 only if there is genuinely no predecessor
NEW_BLS_AGGREGATOR=0x…            # 4.7.0, keys already re-filed, slasher authorized
REGISTRY_PROXY=0x…
CREDIT_PER_PROPOSAL_CAP=… CREDIT_TOTAL_CAP=… CREDIT_EXPOSURE_BASELINE=…
forge script contracts/script/v3/UpgradeRegistryTo570.s.sol --rpc-url $PRAGUE_RPC
```

Order matters and the script enforces it: **onboard validators onto the new aggregator
first**, then schedule the batch. Wiring an empty aggregator into Registry is a
governance outage whose fix is another full timelock cycle.

Resolve or expire every pending guardian-slash case on the old aggregator before
cutting over — the freeze does not migrate.

---

## 4. Open cross-repo items

| Item | Owner | State |
|---|---|---|
| `OverIssueFraudProofVerifier` must genuinely bind `domainDigest`, proven by `FraudProofVerifierConformance.assertDomainBound` in the DVT repo's CI | `repo:dvt` | **open** — `fraudProofVerifier` stays dormant (`address(0)`) in production until this lands |
| `guardianSlashCases` 5→6 tuple in decoders / ABI pin (round-4: 6→**7**) | `repo:sdk` | **open** |
| `fraudProofId` id-space re-open semantics; CC-29 auto-jail boundary | `repo:dvt` | still unanswered from round-2 |

SP cannot enforce the first item from this repo — it can only make it a one-line import,
which it now is (`contracts/test/helpers/FraudProofVerifierConformance.sol`, with a
working reference implementation and a deliberately-broken anti-reference proving the
fixture discriminates).

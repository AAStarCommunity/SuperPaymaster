# CC-48 round-4 — the guardian-slash verdict is frozen, not the verifier

Scope: `BLSAggregator 4.7.0 → 4.8.0`. Registry, SuperPaymaster, PaymasterV4 and every
other contract are **unchanged** (`Registry-5.7.0` stays as-is; no storage additions
anywhere else, no ABI change anywhere else).

This supersedes §1.1 of [`CC48-round3-changes.md`](./CC48-round3-changes.md). Everything
else in that document (mandatory PoP, `releaseKeyBinding`, slash-only proposal shape,
migration gates, Prague matrix, build profiles) still stands as written; only the
verifier-pinning mechanism described there has been replaced.

---

## 1. The defect round-3 left open

Round-3 stored the verifier **address** in `GuardianSlashCase` at queue time and had
`executeGuardianSlash` re-verify against that address instead of the live
`fraudProofVerifier`. That closed the *rotation* variant of the attack. It did not close
the general one.

If the verifier is an upgradeable contract — UUPS, Transparent, Beacon, or a hand-rolled
delegatecall proxy — then across an implementation swap:

| Observable | Before upgrade | After upgrade |
|---|---|---|
| address | `0xV` | `0xV` |
| `address.code.length` | *n* | *n* |
| `extcodehash` | `H` | `H` |
| answer to `verify(...)` | `true` | `false` |

So the round-3 timeline survives one indirection deeper:

```
T0        watcher: queueGuardianSlash(id)     verifier says TRUE, case opens, accused frozen
T0+1      admin:   proxy.upgradeTo(alwaysFalse)   same address, same codehash
T0+1..    executeGuardianSlash → verifier says FALSE → InvalidFraudProof, forever
T0+4d     case expires; expireGuardianSlashCase is permissionless, the accused releases
          their own freeze and walks with the full ROLE_DVT stake
```

The same shape covers the non-adversarial variants: a verifier that selfdestructs, or is
upgraded to a reverting/OOG implementation, or is simply down between a partial execution
and its retry, could also strand a case until expiry.

**No on-chain check on the address can fix this.** `code.length`, an address snapshot and
`extcodehash` all witness *bytes at an address*, and the bytes of a proxy do not move when
its meaning does. Round-3's own fail-closed rule (`GuardianSlashVerifierGone`) made the
outage variant *worse*, not better: it converted "verifier gone" into "accused released".

## 2. The fix — freeze the verdict

`queueGuardianSlash` already calls the verifier exactly once. That call is now the **only**
time any verifier is consulted about a case. Its result is frozen into the case:

```solidity
struct GuardianSlashCase {
    bytes32 guardiansHash;   // keccak256(abi.encode(guiltyGuardians))
    bytes32 fraudProofHash;  // NEW — keccak256(fraudProof), the approved evidence
    uint64  deadline;
    uint8   status;          // 0=none, 1=pending, 2=executed, 3=expired
    uint16  guardianCount;
    uint16  resolvedCount;
    address verifier;        // AUDIT ONLY as of round-4 — never read for a decision
}
```

`executeGuardianSlash` now checks, in order: case pending → not past deadline →
`_validateGuardianSet(guiltyGuardians) == guardiansHash` → `keccak256(fraudProof) ==
fraudProofHash`. Then it runs the same per-guardian slash loop as before. **There is no
external verifier call on that path at all.**

Consequences, each covered by a test:

| After a case is queued… | Result |
|---|---|
| verifier rotated (`applyFraudProofVerifier`) | case unaffected |
| verifier proxy upgraded to always-false, same address + codehash | case unaffected — **the round-4 regression** |
| verifier proxy upgraded to a reverting implementation | case unaffected |
| verifier selfdestructed / code wiped | case unaffected (round-3 stranded it) |
| executor substitutes different proof bytes | `FraudProofMismatch` |
| executor substitutes a different guardian set | `GuardianSetMismatch` |
| deadline passes | `GuardianSlashCaseExpiredError`; `expireGuardianSlashCase` releases — unchanged |

What did **not** change:

- **Queue-time authority is still the live verifier.** While it rejects, no case can be
  opened (`InvalidFraudProof`), and with no verifier wired the feature is still fully
  dormant (`FraudProofVerifierNotSet`). The freeze only ever captures a verdict the
  verifier actually gave.
- `VerifierNotContract` still rejects an EOA verifier at queue time — a call to an EOA
  succeeds with empty returndata, and nothing about that outcome belongs near a verdict
  that is then frozen for the life of the case.
- Rotation delay, exit-notice interaction, partial/retryable execution, per-guardian
  freeze accounting and expiry semantics are all untouched.

### Why the proof bytes are still a parameter

The executor must re-present the exact bytes the verifier approved. Dropping the parameter
would have been smaller, but it also removes the evidence from the transaction that
consumes it: with the check in place, `executeGuardianSlash` calldata is a self-contained
record of *which* proof took the stake, verifiable against the queue-time event by anyone
replaying the chain. The check is one `keccak256` over calldata.

### Threat this deliberately does not address

A verifier that was **already** malicious/compromised at queue time can open a bogus case,
and freezing its verdict makes that case durable. That is unchanged from every previous
round and is the design premise of the seam: the verifier IS the authority on fraud.
Round-4 narrows *when* that authority applies (once, at queue time, on the record) rather
than leaving it open-ended for the life of the case. Governance's remedy against a bad
verifier is rotation — which stops it opening *new* cases — plus the bounded 4-day window
and permissionless expiry on the cases it already opened.

---

## 3. Version / ABI / storage record

| Artifact | Before | After | Notes |
|---|---|---|---|
| `BLSAggregator.version()` | `BLSAggregator-4.7.0` | `BLSAggregator-4.8.0` | not upgradeable — fresh deployment |
| `Registry.version()` | `Registry-5.7.0` | `Registry-5.7.0` | unchanged |
| Registry storage layout | 28 slots | 28 slots | `scripts/check_storage_layout.py` green |
| SuperPaymaster storage layout | 37 slots | 37 slots | `scripts/check_storage_layout.py` green |
| `GuardianSlashCase` | 3 slots | 4 slots | mapping value, never deployed — see below |
| BLSAggregator runtime size | — | 22,854 B (headroom 1,722) | `[profile.default]`, the profile that ships |
| SuperPaymaster / Registry runtime | — | 23,569 / 23,771 B | untouched this round |

`guardianSlashCases` is a mapping introduced in this same unreleased branch (`2c0ed76b`),
so growing its value struct is not an in-place layout change to anything that exists
on-chain: **4.7.0 was never deployed anywhere**. `BLSAggregator` is not upgradeable in any
case — it is redeployed and re-wired through the Registry batch.

### BLSAggregator ABI delta (4.7.0 → 4.8.0)

**BREAKING for decoders:** `guardianSlashCases(uint256)` now returns **7** fields, not 6,
and the new field is inserted at **index 1**, not appended:

```
(bytes32 guardiansHash, bytes32 fraudProofHash, uint64 deadline, uint8 status,
 uint16 guardianCount, uint16 resolvedCount, address verifier)
```

A positional decoder written for the 6-tuple will mis-read every field from index 1 on —
this is not a tail-tolerant change. Regenerate from `abis/BLSAggregator.json`.

| Change | Item |
|---|---|
| added | `error FraudProofMismatch(uint256 fraudProofId, bytes32 expected, bytes32 provided)` |
| added | `event GuardianSlashJudgmentFrozen(uint256 indexed fraudProofId, address indexed verifier, bytes32 fraudProofHash, bytes32 guardiansHash)` |
| removed | `event GuardianSlashVerifierPinned(uint256 indexed fraudProofId, address indexed verifier)` — replaced by the above |
| removed | `error GuardianSlashVerifierGone(uint256 fraudProofId, address verifier)` — the condition it signalled can no longer block execution |
| changed | `guardianSlashCases(uint256)` tuple, 6 → 7 fields (see above) |

Unchanged, explicitly, because it is the cross-repo seam:

- `IFraudProofVerifier.verify(bytes32,uint256,address[],bytes)` — selector `0x61077735`,
  still pinned by `CC48VerifierConformance.test_VerifierSelectorIsPinned`. **DVT verifiers
  do not need to be rebuilt for round-4.** They are simply called once per case now.
- `queueGuardianSlash(uint256,address[],bytes)` and
  `executeGuardianSlash(uint256,address[],bytes)` signatures.
- `expireGuardianSlashCase`, `pendingGuardianSlashCount`, `guardianSlashed`,
  `guardianCaseResolved`, and all exit-notice functions.

---

## 4. Regression coverage

| Property | Test |
|---|---|
| a proxy upgrade is invisible to address / `code.length` / `extcodehash` (the premise) | `CC48MutableProxyVerifierTest.test_ProxyUpgradeIsInvisibleToAddressAndCodehash` |
| queue true → same-address upgrade to false → execute still slashes | `…test_QueuedCaseSurvivesAnImplementationSwapAtTheSameAddress` |
| upgrade to a **reverting** implementation cannot veto a frozen verdict | `…test_QueuedCaseSurvivesAnUpgradeToARevertingImplementation` |
| substituted proof (incl. empty) is refused, then the real proof works | `…test_ExecutionRejectsASubstitutedProof` |
| substituted proof refused even when the live verifier would approve it | `…test_SubstitutedProofIsRefusedEvenIfTheLiveVerifierWouldApproveIt` |
| partial execution → upgrade → retry with the same proof settles the rest | `…test_PartialRetryAfterUpgradeUsesTheSameFrozenProof` |
| expiry unchanged by the freeze and by an upgrade (no immortal case) | `…test_ExpiryIsUnchangedByTheFrozenVerdictAndByAnUpgrade` |
| rotation after queueing still cannot touch an open case | `…test_RotationAfterQueueingStillCannotTouchAnOpenCase` |
| guardian set still pinned alongside the proof | `…test_GuardianSetIsStillPinnedAlongsideTheProof` |
| queue still honours the LIVE implementation (no case from a rejecting verifier) | `…test_QueueStillHonoursTheLiveImplementation` |
| verifier disappearing no longer strands a case | `CC48GuardianSlashRetryTest.test_ExecutionSurvivesThePinnedVerifierDisappearing` |
| the verifier that opened a case is recorded, then ignored | `CC48GuardianSlashRetryTest.test_ANewCaseAfterRotationRecordsTheNewVerifierAndThenIgnoresIt` |
| **all of the above under real EIP-2537 pairings**, ending in real ejection | `CC48PragueStateMachine.test_Prague_MutableProxyVerifierCannotUndoAQueuedCase` |

The proxy in these tests is a real delegatecall proxy (`CC48UpgradeableVerifierProxy` /
`PragueMutableVerifierProxy`), not a mock with a boolean flag — the flag version cannot
demonstrate the property, because the whole point is that the *code at the address* is
unchanged.

### Test matrix at `ebc05663 + round-4`

| Run | Result |
|---|---|
| `forge test` (Cancun) | 1270 passed, 0 failed, 36 skipped (was 1260/0/35 at `ebc05663`) |
| `forge test --evm-version prague` | 1181 passed, 0 failed, 20 skipped (was 1170/0/20 at `ebc05663`) |
| `python3 scripts/check_storage_layout.py` | SuperPaymaster 37 slots OK, Registry 28 slots OK |
| `forge build` (`[profile.default]`, the shipping profile) | clean; sizes above |

---

## 5. Cross-repo actions

| Repo | Action | Blocking? |
|---|---|---|
| `repo:sdk` | `guardianSlashCases` decoder 6 → **7** fields, new field at **index 1**; re-sync `abis/BLSAggregator.json`; watch `GuardianSlashJudgmentFrozen` instead of `GuardianSlashVerifierPinned`; drop `GuardianSlashVerifierGone` handling | before any release that decodes this tuple |
| `repo:dvt` | **No verifier rebuild.** `verify` selector `0x61077735` unchanged. Watchers must persist the exact `fraudProof` bytes used at queue time — `executeGuardianSlash` now rejects anything else (`FraudProofMismatch`), including a re-serialised-but-equivalent proof | before operating a watcher |
| `repo:dvt` | `OverIssueFraudProofVerifier` domain-binding conformance (`FraudProofVerifierConformance.assertDomainBound` in DVT CI) | **still the release gate** — `fraudProofVerifier` stays `address(0)` in production until it lands |
| `repo:dvt` | `fraudProofId` id-space re-open semantics; CC-29 auto-jail boundary | open since round-2 |

Note for DVT watchers: because the verifier is called exactly once, a verifier that is
non-deterministic across blocks (reads mutable state, prices, or its own upgrades) now
produces a verdict fixed at queue time. That is the intended semantics; verifiers should
be pure functions of `(domainDigest, fraudProofId, guiltyGuardians, fraudProof)`.

---

## 6. Migration gates

`contracts/script/v3/UpgradeRegistryTo570.s.sol` and
`contracts/script/v3/DeployRepCreditSepolia.s.sol` now require
`version() == BLSAggregator-4.8.0`. Everything else in
[`CC48-round3-changes.md` §1.5 / §3.3](./CC48-round3-changes.md) is unchanged, including
`OLD_BLS_AGGREGATOR` having no default, the Prague-only weak-key scan, the
`ALLOW_EOA_OWNER ⇒ chainid == 31337` gate, and the "no pending case on the old aggregator"
requirement.

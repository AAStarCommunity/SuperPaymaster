# rc.8 Daybreak fix set — 2026-11-09

Branch `cc125/rc8-daybreak-fixes`.
Input: `C4-report.md`, `C2-report.md`, `C1-report.md` in
the Daybreak review archive (2026-11-09, held by the maintainer and DSR).
The initial `git diff 8de39026 -- contracts/src` was empty. No network, chain,
key access, commits, or Git metadata writes were performed.
The pre-existing OpenZeppelin v5.1.0 `package-lock.json` edit was preserved.

## Implementation

### C4-H-01: separate signing cutoff and withdrawal readiness

`BLSAggregator-4.14.0` retains the two-day public notice. For request time `t`:

- `readyAt = t + 2 days`: signing stops, exactly as before.
- `withdrawAt = readyAt + GUARDIAN_FRAUD_CHALLENGE = t + 3 days`.
- `expiresAt = withdrawAt + GUARDIAN_EXIT_WINDOW = t + 4 days`.
- Withdrawal is permitted at both endpoints `[withdrawAt, expiresAt]`, absent a
  pending case. `GuardianExitNotReady` now reports `withdrawAt`.
- `GUARDIAN_SLASH_CASE_WINDOW = 5 days > 2 + 1 + 1 days`.
  `VERIFIER_ROTATION_DELAY` remains tied to that constant and becomes five days.

Every other use of the notice fields was checked:

- `_reconstructPkAgg` is unchanged: a nonzero notice excludes its key from
  `readyAt`, including throughout the challenge period and after `expiresAt`.
  Expiry never silently restores a potentially fraudulent signer.
- `_requireCommitteeSurvivesExit` already excludes all other announced exits,
  even before their cutoff. It conservatively checks the eventual signer set;
  delaying withdrawal does not change the set or weaken the quorum floor.
- Cancellation deletes the notice, restores signing eligibility, and starts the
  existing one-day cooldown. Pending cases still prohibit cancellation and new
  notices. A cancelled notice cannot be consumed; a fresh notice incurs the full
  notice and challenge again. Expired notices still require cancellation and
  cooldown before replacement.
- `consumeGuardianExit` still checks pending cases before timing, so a case queued
  during the challenge freezes the guardian even after withdrawal would mature.
  Successful consumption deletes the notice atomically with Registry role exit.
- Any notice already open when a case is queued expires before that case's
  five-day deadline. New notices are forbidden during a pending case. The old
  comment suggesting an accused guardian could open a notice after queueing was
  corrected rather than retained.
- Fraud-verifier rotation retains its full-case-window delay and verdict pinning.
  Request structs, event fields and storage layout are unchanged; the public
  `readyAt` event/getter field still means signing cutoff, not withdrawal time.

Regression coverage includes a real Prague BLS signature executed at `readyAt-1`,
Registry exits rejected at `readyAt` and the last challenge second, a fraud case
queued during the challenge and enforced after maturity, and a subsequent actual
stake slash. EVM-independent Registry/staking tests cover clean withdrawal at
exact maturity, withdrawal at exact new expiry, and rejection one second later.
Existing cutoff, cancellation, cooldown, expired-key exclusion and committee-floor
tests remain in place; existing withdrawal/expiry timings were updated.

### C4-L-01 and C4-L-02 fixed in rc.8 (BLSAggregator-4.14.0)

C4-L-02: generic `executeProposal` stores the signer commitment after signature verification and before
calling the arbitrary target (test_GenericCommitmentIsStoredBeforeTargetCall,
test_Prague_GenericProposalRecordsSigners).

C4-L-01: generic and slash proposals no longer share one id space. This supersedes the 11-09 note that
deferred C4-L-01 to 5.5.1; DSR then ruled it into rc.8, together with the typed keys and
MAX_VALIDATORS = 64 (commit "typed replay/commitment keys, anchored signer commitments, MAX_VALIDATORS 64").
- The generic path keys replay protection and its commitment by
  `uint256(keccak256(abi.encode(TAG_PROPOSAL, proposalId)))`. The `markProposalExecuted` callback to
  DVTValidator is removed, so a generic id can no longer pre-consume a slash id that DVTValidator allocates
  later.
- Raw slash and reputation ids must be below 2^128 (`InvalidProposalId`), which separates them from the
  keccak-derived generic and queue keys by 128 bits.
- Each path stores its commitment under its own key, and the commitment also binds
  `blockhash(block.number - 1)`. Every write emits `SignersCommitted(key, signerMask)`.
- MAX_VALIDATORS is 64, and slot 65 reverts with `SlotOutOfRange`.

Tests that run on Prague with genuine keys:
- both paths keep both commitments: test_QueueSlashGeneric_OverlappingInputsKeepAllCommitments;
- the crafted collision: test_SlashRawIdEqualToGenericKeyCannotOverwriteGenericCommitment;
- slot 65: test_RegisterBLSPublicKey_SlotAboveMax_Reverts, test_Verify_RejectsBitsBeyondMaxValidators;
- the typed key per path in the recompute: test_QueueSlashGeneric_OverlappingInputsKeepAllCommitments,
  test_GenericCommitmentIsStoredBeforeTargetCall.

Version: `BLSAggregator-4.14.0`. Main had already carried `4.13.0` for the build with C4-L-01 deferred.
That build was never deployed, but two bytecodes must not share a version.

### C2-01: invalidate stale standby roles

`_setCurrentSP` clears a matching designated standby and emits `StandbyInvalidated`.
It separately clears a matching pending standby **and ETA**, emitting
`StandbyProposalCancelled`. No storage was added. Designation activation rechecks
both current SP and emergency-revoked SP after the timelock and before designation.
Tests cover normal promotion of a designated standby, simultaneous mature SP and
standby proposals, cancellation events/ETA clearing, and both activation guards.
The latter seed stale state explicitly, since normal promotion now clears it.

### C1-L-01: report the applied slash penalty

`_slash` returns its final capped/clamped penalty. `executeSlashWithBLS` emits that
value in `SlashExecutedWithProof`. The regression deposits 1,000 aPNTs and checks
that a MAJOR slash emits 300, leaves 700, credits 300 revenue and records 300 in
history. SuperPaymaster core/Admin storage is untouched.

### Registry ENDUSER membership cleanup

`MySBT.deactivateAllMemberships` cannot attribute a membership to the role that
created it: it iterates every membership stored for the user's SBT and deactivates
every active entry. Therefore `Registry.exitRole(ROLE_ENDUSER)` calls it only when
`userRoleCount[user] == 0` after role removal. If another role remains, all
memberships remain intact. In particular, a per-community membership can outlive
the ENDUSER role while another role is held. Integrators must not treat
`MySBT.verifyCommunityMembership(user, community)` as sufficient authorization;
they must also require `Registry.hasRole(ROLE_ENDUSER, user)`.

A later final-role exit burns the SBT and deactivates its memberships through
`MySBT.burnSBT`. If a final non-ENDUSER exit occurs while MySBT is paused, the burn
fails non-fatally and sets `pendingSBTBurn`; after unpausing MySBT, anyone can call
`reconcileSBTBurn(user)`. The permissionless
`reconcileMembershipDeactivation` retry applies the same zero-role condition, so
a stale pending flag cannot deactivate memberships while any role remains. If a
third party adds COMMUNITY, ANODE, DVT, KMS, PAYMASTER_AOA, or PAYMASTER_SUPER
(e.g. via a community's `safeMintForRole`) before that retry, recovery requires
the holder to exit every remaining role. COMMUNITY has a zero default lock; the
operator roles use `block.timestamp >= lockedAt + 30 days` (and DVT also requires
its guardian-exit authorization). Exit and reconciliation are separate
transactions, so a sponsor that keeps funding grants can re-grant a role after
each exit and before the retry, delaying recovery indefinitely while it keeps
paying; recovery is therefore not bounded against an actively funded sponsor.
Precondition for any of this: a MySBT cleanup call must first have FAILED
(e.g. MySBT paused or replaced by a reverting implementation). Once `userRoleCount == 0`, call
`reconcileMembershipDeactivation(user)`; if the final burn also failed, unpause
MySBT and call `reconcileSBTBurn(user)`. ENDUSER registration remains blocked until
the membership-cleanup flag is cleared.

This is the documented fallback because the targeted cleanup implementation did
not fit EIP-170: the round-6 Registry measured 24,509 B, a behavior-preserving
counter simplification reclaimed 29 B (24,480 B), and the minimal implementation
then measured 25,002 B, 426 B over the 24,576 B limit. The attempted code and
reclamation were reverted.

REG-R5-02 does not require a migration: the Sepolia Registry has never emitted
`SBTBurnFailed` (verified by the evidence script on `cc125/rc8-reg-evidence`), and
the Optimism deployment is fresh.

### PolicyRegistry velocity and spend reads

PolicyRegistry 3.0.2 rejects `setTargetVelocity` and `tightenTargetVelocity` while
the target velocity window is zero. Disabling a window invalidates all prior
per-asset limits; re-enabling it remains fail-closed until each asset receives a
fresh timelocked `setTargetVelocity`, which also starts a fresh target counter.
`getTargetVelocity` reports stale/disabled entries as unconfigured, and no setter
or tightening event is emitted for a rejected zero-window call.

`getAssetSpend` now returns effective spend (zero once its configured window has
expired). The new `getTargetSpend(sender, target, asset)` returns the same
window-aware value for target velocity, including zero for disabled, stale, or
expired entries.

### I3 release requirement

Any future validation-time consumer of `PolicyRegistry` must pass the ERC-7562
tracer gate before release. This is a documented release requirement even when
the consumer's direct unit and integration tests pass.

### Version propagation (historical; superseded by the reviewed redesign below)

- BLSAggregator: 4.12.0 → 4.13.0.
- SuperPaymaster: stays `SuperPaymaster-5.5.0`. Its ABI is unchanged; 5.5.0 has never been deployed on a live chain, and build identity is the commit plus runtime codehash (03-final-spec §6), not the version string.
- xPNTsTokenV2: XPNTs-4.0.0 → XPNTs-4.0.1.
- SuperPaymasterLens: stays `SuperPaymasterLens-1.2.0` (its SP-version gate stays 5.5.0).
- xPNTsFactoryV2: 3.0.0-v2 → 3.0.1-v2; its exact template-version gate follows 4.0.1.
- PolicyRegistry: 3.0.1 → 3.0.2; ABI adds `getTargetSpend(address,address,address)`
  and `VelocityDisabled()` while preserving existing function signatures.

The last two changes are required to keep diagnostics and token creation working
with the new versions. Current-version assertions and the experimental
ProfilePaymaster test helper were updated; historical deployment fixtures remain
historical. Downstream DVT/SDK consumers need the new withdrawal timing and ABI
constant/events before release. No downstream notifications were sent.

## BLS round 4

### DVT proposal-id rotation

`DVTValidator-0.8.0` takes `(registry, firstProposalId)`; there is no predecessor
argument or state. `firstProposalId` is nonzero and below `2^128`. The retained
BLSAggregator-4.14.0 owns a monotonic `proposalFloor`. Activation atomically
captures the outgoing DVT's next allocation, including pending IDs, and validates
the successor's aggregator and Registry pointers. Every allocation reads that
floor once. Empty intermediates and A→B→A rollback cannot reuse allocated IDs.
The ordinary setter fails closed if the outgoing counter cannot be read. The
explicit-floor recovery operation requires governance to supply an audited upper
bound on all allocated IDs; it must never lower the stored floor. This recovery
is an immediate owner authority, not automatic discovery of missing history.

Pending slash and aggregator-routed reputation proposals executed through the
current DVT need fresh IDs and proofs after rotation, including after reactivation.
The floor does not revoke owner-direct `verifyAndExecute` with caller-chosen IDs,
generic proofs, authorized direct Registry reputation proofs or unused consensus
queue pre-flags; see the disclosed M1 residuals below. Full-width hashed
ReputationSystem IDs remain valid on the direct Registry route.

### Validator-removal quorum floor

The survival check protects each currently reachable configured threshold:
`minThreshold`, `defaultThreshold`, and every severity threshold. With one
eligible signer leaving, crossing a threshold is exactly equality with the
pre-exit committee count. Higher unreachable thresholds do not hide lower working
ones; caller-selected generic thresholds above `minThreshold` are not standing
configured quorums. At an exactly reachable N-of-N quorum, seat a replacement or
change policy before voluntary exit or DVT removal. Direct owner revocation and
suspension are explicit emergency overrides.

Suspension is authoritative on the retained aggregator and is checked both during
registration and while reconstructing every aggregate key. It survives rotation
and rollback and can be set even without local admission or an active key. Use
owner `revokeAndSuspend` for atomic emergency eviction. Reinstatement requires
explicit owner clearance on the aggregator; DVT admission alone cannot clear it.

The DVT and aggregator owners must remain the same Safe-compatible M-of-N owner.
Rotation delegates key-registration authority as well as proposal forwarding;
it is therefore more than the owner's existing direct execution permission.
Verifier rotation separately retains its contract-enforced five-day delay.

### Reputation rule disablement

`Reputation-0.6.0` records rule existence and active state separately. A configured
zero-base rule contributes no score and does not receive the default. Only an
unconfigured first rule receives the default. Re-enabling does not duplicate an
active rule. The additional mappings belong to a directly deployed contract;
there is no proxy migration or automatic backfill claim.

### NFT boost semantics

NFT boost eligibility means **registration age plus current ownership**. The
seven-day timestamp is not proof of uninterrupted ownership: a third-party NFT
can be transferred away and reacquired before a permissionless watcher calls
`resetNFTHoldStart`. Strict continuity is impossible here without collection
transfer hooks, checkpoints, escrow, or authenticated acquisition history.

### Raw-id separation wording

Raw proposal ids remain below `2^128`. Their separation from unrestricted
Keccak-derived generic and queue keys is a 128-bit cryptographic guarantee, not
an absolute structural impossibility.

## BLS round 7 — Daybreak re-review #4

R4-01, R4-03, and R4-04 move to the dedicated manifest/executor PR. All scoped
executor, schema, adapter, test, and release-design changes were restored to
`origin/main`. The retained contract, deployment, test, historical-template,
and security-report changes no longer reference that split implementation.

R4-02 is fixed in every deployment path that previously transferred only the
BLSAggregator owner: `DeployNewBLSModules`, `07b_DeployBLSModules`, and
`DeployStandardV3` now transfer the paired DVTValidator to the same declared
governance owner and assert `dvt.owner() == bls.owner()`. The other scripts that
instantiate DVTValidator were checked: DeployLive, DeployAnvil, and
DeployRepCreditSepolia already transfer both owners. Archive scripts contain no
one-sided governance transfer; a fresh paired deployment leaves both contracts
with the same broadcaster owner. A script-level regression covers
DeployNewBLSModules. Removing its DVT transfer makes the test fail with
`DeployNewBLSModules: DVT owner != BLS owner`.

R4-05 provenance below was regenerated from final Cancun artifacts after the
round-7 edits. No BLSAggregator contract code was changed in this round.

## Verification

Engine: forge 1.7.1, Solidity 0.8.33, default profile.
`FOUNDRY_OFFLINE=true` keeps compiler resolution offline. Test runs explicitly set
`SEPOLIA_FORK_RPC=''` so the opt-in Sepolia fork suites cannot connect to a chain.
`nice -n 10` was attempted but the sandbox returned
`nice: setpriority: Operation not permitted`; subsequent commands omit it.
Dependency revision warnings were present in the baseline and final builds; no
submodules were fetched or repaired. Plain `git status` also encounters a broken
Solady submodule gitdir, so review commands use `--ignore-submodules`.

The baseline artifact's source keccak was checked against `git show 8de39026`.
Baseline BLSAggregator runtime: **24,345 B**, EIP-170 headroom **231 B**.
FIX 1 only, same default compiler settings: **24,367 B**, headroom **209 B**.

Historical round-7 results (superseded by `.rv-redesign.md`) are recorded below; round-7 raw logs are in `/tmp/rc8-bls-r7-*.log`.

The first full Cancun run exposed two stale expectations: the central release
version table still named the old SP/Lens versions, and the invariant handler's
independent model retained a standby after promotion. The release readback
constants (including token/factory bootstrap and BLS deployment readback) were
updated. The invariant model now clears a promoted standby and independently
asserts that standby is never current SP. No production behavior was weakened to
satisfy the old model. Subsequent final results are recorded below.

Historical round-7 BLSAggregator runtime (superseded): **24,551 B**, headroom **25 B**. The final release
artifacts for BLSAggregator, DVTValidator, and ReputationSystem all record
Solidity **0.8.33+commit.64118f21**, optimizer enabled with **500 runs**, **via-IR
enabled**, and EVM version **Cancun** in artifact metadata. Prague outputs/cache
are isolated under `out/prague` and `cache/prague`; the size gate reads only
default/Cancun artifacts and verifies source hashes and compiler settings.

| Deployable | Runtime bytes | EIP-170 headroom |
|---|---:|---:|
| BLSAggregator | 24,551 | 25 |
| DVTValidator | 6,448 | 18,128 |
| ReputationSystem | 7,675 | 16,901 |
| SuperPaymaster | 13,744 | 10,832 |
| SuperPaymasterAdmin | 17,975 | 6,601 |
| SuperPaymasterLens | 5,413 | 19,163 |
| Registry | 23,306 | 1,270 |
| xPNTsTokenV2 | 20,008 | 4,568 |
| xPNTsTokenV2Ext | 22,543 | 2,033 |

The historical source files used for those three superseded artifacts are bound by SHA-256:

| Artifact | Source file SHA-256 |
|---|---|
| BLSAggregator | `011cdd40a146ee0edcae99173598bafc8c144607d5c6449e1b4b6e85f86f26b5` |
| DVTValidator | `6ed802f84b3a49fe8488f3ed20f1d93493d867c0e0f3aa3bc76fdf1a07b936ab` |
| ReputationSystem | `597060791537136711ed0e413884f4ccc6dba4456378ecbbdd9e88fa9d75e714` |

- `abis/BLSAggregator.json`: new `GUARDIAN_FRAUD_CHALLENGE()` getter and bytecode.
- `abis/xPNTsTokenV2.json`, `abis/xPNTsTokenV2Ext.json`,
  `abis/xPNTsTokenV2.full.json`: new `StandbyInvalidated(address)` and
  `StandbyProposalCancelled(address)` events; core/extension bytecode changes.
- `abis/SuperPaymaster.json`, `abis/SuperPaymasterAdmin.json`,
  `abis/SuperPaymasterLens.json`, `abis/xPNTsFactoryV2.json`: unchanged ABI
  signatures, changed embedded bytecode/version behavior.
- `abis/SuperPaymaster.full.json`: combined ABI signatures remain unchanged,
  its note names 5.5.0, which stays correct.

## Release ABIs (historical round-7 evidence; superseded)

Current redesigned release evidence, sizes, source identity and ABI checks are in
`.rv-redesign.md`. The following records the earlier run, not the current bundle.


The release ABIs and manifest were regenerated from the final Cancun artifacts.
F-07 changes only view implementation behavior, so ReputationSystem's ABI and
`Reputation-0.5.0` version are unchanged; its embedded bytecode was refreshed.
The BLSAggregator and DVTValidator bundles include the earlier round changes.
`pnpm gen:abi-docs` regenerated the reference and selector documents, and both
`pnpm gen:abi-docs:check` and `node scripts/check-abi-bundle.mjs` pass.

`abis/BLSAggregator-4.11.0.deployed.json` is historical deployed evidence and must
remain unchanged. This task does not regenerate deployment manifests or historical
rehearsal evidence; old release-specific Python runners still pin their old
versions and are not an rc.8 deployment plan.

## Files changed by this task

- `contracts/script/v3/DeployRepCreditSepolia.s.sol`
- `contracts/script/v3/SPReleaseVersion.sol`
- `contracts/script/v3/V55Bootstrap.sol`
- `contracts/src/modules/monitoring/BLSAggregator.sol`
- `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol`
- `contracts/src/paymasters/superpaymaster/v3/SuperPaymasterAdmin.sol`
- `contracts/src/paymasters/superpaymaster/v3/SuperPaymasterLens.sol`
- `contracts/src/tokens/v2/xPNTsFactoryV2.sol`
- `contracts/src/tokens/v2/xPNTsTokenV2.sol`
- `contracts/src/tokens/v2/xPNTsTokenV2Ext.sol`
- `contracts/src/tokens/v2/xPNTsV2Base.sol`
- `contracts/test/helpers/ProfilePaymaster.sol`
- `contracts/test/modules/BLSAggregatorLiveness.t.sol`
- `contracts/test/modules/BLSAggregatorUnit.t.sol`
- `contracts/test/modules/GenericDVTProposal.t.sol`
- `contracts/test/modules/GuardianSlash.t.sol`
- `contracts/test/paper7/BLSGasMeasurement.t.sol`
- `contracts/test/paper7/CC48PragueStateMachine.t.sol`
- `contracts/test/rams/RamsARouteRehearsal.t.sol`
- `contracts/test/security/CC48CoreFixes.t.sol`
- `contracts/test/security/RepCreditIssuanceAndExitControls.t.sol`
- `contracts/test/v2/SuperPaymasterV55.t.sol`
- `contracts/test/v2/SuperPaymasterV55GasParams.t.sol`
- `contracts/test/v2/xPNTsTokenV2.t.sol`
- `contracts/test/v2/xPNTsTokenV2Invariant.t.sol`
- `contracts/test/v3/DVTSlash.t.sol`
- `contracts/test/v3/SuperPaymasterV5Features.t.sol`
- `contracts/test/v3/UUPSUpgrade.t.sol`
- `docs/security/rc8-daybreak-fixes.md`

The dependency lockfile already modified when the task started is excluded from this list.

## Historical round-7 verification results (verbatim; superseded)

All commands below exited 0. The ordinary build uses `FOUNDRY_PROFILE=default`;
all Forge commands use `FOUNDRY_OFFLINE=true`. Test runs set `SEPOLIA_FORK_RPC`
to an empty string. Prague runs additionally set `FOUNDRY_OUT=out/prague` and
`FOUNDRY_CACHE_PATH=cache/prague` to preserve default/Cancun artifacts.

forge build (final cached confirmation)

```text
No files changed, compilation skipped
```

python3 scripts/check-sp-size.py

```text
OK: SuperPaymaster core headroom 10832 B >= 1024; all 7 deployables <= EIP-170
```

forge test --match-path contracts/test/scripts/DeployLiveGovernance.t.sol (Cancun)

```text
Ran 1 test suite in 7.37ms (3.59ms CPU time): 2 tests passed, 0 failed, 0 skipped (2 total tests)
```

forge test (full tree, Cancun)

```text
Ran 167 test suites in 92.09s (530.18s CPU time): 1892 tests passed, 0 failed, 72 skipped (1964 total tests)
```

forge test --evm-version prague --match-path contracts/test/scripts/DeployLiveGovernance.t.sol

```text
Ran 1 test suite in 9.25ms (2.87ms CPU time): 2 tests passed, 0 failed, 0 skipped (2 total tests)
```

forge test --evm-version prague (full tree)

```text
Ran 167 test suites in 87.12s (431.25s CPU time): 1758 tests passed, 0 failed, 49 skipped (1807 total tests)
```

python3 scripts/check-sp-layout.py

```text
OK: SuperPaymaster core and SuperPaymasterAdmin storage layouts identical (42 entries, last = __gap@41)
```

python3 scripts/check-xpnts-v2-layout.py

```text
OK: core and extension storage layouts identical (57 entries)
```

python3 scripts/check_storage_layout.py

```text
OK  SuperPaymaster storage layout = snapshot + 2 allowed appended entries (42 entries)
OK  Registry storage layout = deployed 5.9.0 snapshot + 2 allowed appended mappings (34 entries)
```

The forced default build that compiled the production fixes reported
`Compiler run successful with warnings:`; the final cached build confirms the
final tree. ABI verification ended with `abis/ matches the compiled contracts
(full shape, not just names)`.

Historical round-7 skip accounting (superseded): EVM-specific precompile/artifact guards and opt-in fork suites. The later M1 and reviewed replay regressions also intentionally skip on Cancun; they must execute on Prague. Whole-suite setup skips account for the different total test counts across EVMs. The two allowed appended SP storage entries predate that verification round; its results are superseded where the re-review #3 addendum below differs. `git diff --check --ignore-submodules` passed.

The requested fixes, both conditional C4 lows, version propagation and all specified local verification are complete. The only execution adjustment was omitting `nice` after the sandbox refused it. No chain or deployment validation was attempted, as requested.

## Delivery split — SP-a / SP-b

The SuperPaymaster fixes recorded from here to the end of this file shipped in two PRs. SP-a
(#619) carried all of them except four price-path changes in `SuperPaymasterAdmin.sol`, which
SP-b carries together with their tests:

1. `setAPNTSPrice`: the 10% lower limit rounds upward (re-review #7).
2. `_checkEmergencyPrice`: the 20% lower limit rounds upward (re-review #7).
3. `updatePriceDVT`: the per-update ±20% movement cap against the cached price, applied only when
   `msg.sender == BLS_AGGREGATOR && msg.sender != owner()`.
4. `updatePriceDVT`: the Chainlink deviation check is exact in bps instead of a truncated integer
   percentage.

No tag was cut between the two PRs. `SuperPaymasterLens-1.2.2`, including the `uint96`
reservation ceiling, is in SP-a because it mirrors SP-a's validation. Test counts and byte sizes
quoted below were measured on the combined tree, which is the tree after SP-b.

## Daybreak re-review #3 — SP-551-07 through SP-551-11

A slash now reverts with `SlashBlockedByInflight` while the operator has any counted reservation.
Consequently every successful owner or BLS slash uses the liquid balance, which at that point equals
total collateral. BLS MINOR and MAJOR derive their percentage from that same balance. The guardian
can only queue a freeze; it cannot execute a separate penalty route.

Validation does not inspect slash state: `_isSlashPending` depends on `block.timestamp`, which
ERC-7562 OP-011 forbids in every validation entity. A reservation is live only in its originating
`handleOps` transaction. After that transaction it is stale and `releaseStaleSponsorship(opHash)` is
callable by any address immediately. The owner path exposes the atomic
`slashOperatorAfterReleasing` variant: it releases supplied stale hashes, retains the same
`SlashBlockedByInflight` check, and slashes in one transaction. Hashes are recoverable from public
`handleOps` calldata; omitting a live or unknown stale record fails closed at the aggregate guard.

`Inflight.counted` was appended after the original packed fields. Records created before 5.5.1 read
`false`, so settling or releasing one cannot subtract from the new aggregate. New records set it to
`true` and decrement exactly once. This changes an internal mapping-value layout only; top-level UUPS
slots and the storage gap are unchanged. `totalSpent` retains its 5.5.0 meaning: validation adds the
reserved `a0`, and settlement never adds it again.

Superseded by "Amsterdam gas floors (SP-c)" below: `GP_CPOSTOP_MIN` is now 450,000 and the release
tuple is `(500000,450000,5000,450000)`; 480,000 is rejected. The pre-SP-c text (cPostop floor 180,000,
release tuple `(480000,450000,5000,450000)`) is kept only as history and must not be executed. `SuperPaymasterLens.version()` and the
release pin now report `SuperPaymasterLens-1.2.1`.

The OP-011-corrected remeasurement is lower but does not relax that conservative floor: validation uses
272,723 of the 1,150,000 verification budget (877,277 headroom), and the measured worst postOp path
uses 132,091 gas. Its 15% requirement is 151,905, so release `cPostop=450000` has 317,909 raw gas
headroom (24,067 bps over the measured path). The maximum measured entry-guard bound is 462,035,
leaving 17,965 under the then-proposed `minPostOpGas=480000` (superseded: release is 500,000).

## Critical OP-011 correction — 2026-11-10

The earlier SP L-01 claim is withdrawn. Validation no longer writes
`userOpState[operator][sender].lastTimestamp`; doing so executed `TIMESTAMP`, which ERC-7562 OP-011
forbids regardless of stake and caused real bundlers to reject every sponsored UserOp. `postOp`
remains the sole timestamp writer. Validation computes `validAfter` from that stored value, matching
the pre-rc.8 V3.6 behavior.

The author formally approved this best-effort behavior as the 5.5.1 release scope on 2026-11-10.
The reason is that strict validation-time timestamp accounting would execute `TIMESTAMP`, which
ERC-7562 OP-011 forbids. The accepted residual is that a malicious bundler or a staked sender can
admit two same-sender operations in one bundle before either `postOp` stores the timestamp; every
admitted operation still reserves and pays independently. Honest bundlers include at most one
operation per unstaked sender in a bundle. The regression demonstrates the residual through direct
EntryPoint v0.7 `handleOps` and checks that both operations settle and are charged.

An optional per-`(operator, sender)` `TSTORE` same-bundle marker is deferred to 5.5.x. It is gated on
a real ERC-7562 bundler validation tracer accepting the complete `TLOAD`/`TSTORE` path; it must not be
added based only on a local opcode hand trace.

An opcode-level Foundry trace now covers `minTxInterval` zero/nonzero, queued-slash admission, and
credit fallback through real EntryPoint v0.7. It scans the SP proxy validation frame and its complete
call/delegatecall closure for OP-011 opcodes, and enforces OP-012 by allowing `GAS` only immediately
before a CALL-family opcode.

## Daybreak re-review #4 — SP-R4

### BLS slash surface and reservation race (SP-R4-H-01)

`executeSlashWithBLSAfterReleasing` has been removed from SP, its admin-call shim, ABI and tests.
The sole BLS penalty route is `executeSlashWithBLS`, which reverts
`SlashBlockedByInflight(reserved)` while any counted reservation is live. Any address may first call
`releaseStaleSponsorship(opHash)`. This is intentionally not atomic with the BLS slash: a colluding
operator can delay a BLS slash by creating a new stale record before each attempt, but each delay
attempt costs a UserOperation whose `postOp` must fail. The owner route
`slashOperatorAfterReleasing` remains atomic and is `onlyOwner`; tests prove both the configured
`BLS_AGGREGATOR` and an arbitrary non-owner are rejected.

The exact source-derived SP/SPAdmin selector set whose access decision admits `BLS_AGGREGATOR` is:

- `0xad1c98d7` — `queueSlash(address)`
- `0x53afb8be` — `updatePriceDVT(int256,uint256,bytes,uint8)`
- `0x079d2d42` — `executeSlashWithBLS(address,uint8,bytes)`

`SuperPaymasterBLSSelectorSurface.t.sol` parses both `SuperPaymaster.sol` and
`SuperPaymasterAdmin.sol`, enumerates every function body that combines `msg.sender` with
`BLS_AGGREGATOR`, and asserts that this is the complete set.
The integrated tree must compare the BLSAggregator generic-path denylist against these three
selectors; that denylist is owned by the BLS worktree.

### Deployed storage baseline and no legacy inflight state (SP-R4-H-02 / M-02)

The live Sepolia implementation is SuperPaymaster 5.4.2. The deployed tag evidence is
`git show v5.4.2:storage-layout/SuperPaymaster.json`: `_blsSlashCdFloor` is slot 36 and
`uint256[28] __gap` begins at slot 37. There is no `_inflight` mapping in that layout. OP is a fresh
deployment. Therefore no target chain can contain a pre-5.5.1 `_inflight` record, and
`inflightReserved == 0` genuinely means no reservation on both targets.

The defensive 5.5.0 context/record decoder branches remain because removing them would add churn
across settlement compatibility code without improving target-chain safety. They are unreachable on
the target chains. In particular, target-chain `Inflight.counted` is always written `true`; a false
value can arise only on a non-target fork that actually ran the unreleased 5.5.0 shape.

The layout gate now pins that exact v5.4.2 snapshot (SHA-256
`ac3d211c58b59bd03cb4fb23e52b3dccd25de75b1b00fc9b612affd13d905d87`) and allowlists exactly:
slot 37 `_inflight` (including appended member `Inflight.counted`), slot 38 `_gasParams`, slot 39
`_pendingGasParams`, slot 40 `guardian`/`paused`, slot 41 `pendingWithdrawals`, slot 42
`slashQueues`, and slot 43 `inflightReserved`. The gap shrinks to `uint256[21]` at slot 44, so its
end remains slot 65. Scope aliases normalize only `SuperPaymasterStorage` to the old
`SuperPaymaster` declaring name. The self-test mutates a struct member and removes
`Inflight.counted`; both mutations are rejected.

### Amsterdam gas floors (SP-c)

Governance floors now equal the release tuple `(MIN, SETTLE, C_WRAP, C_POSTOP) = (500k, 450k, 5k, 450k)`.
The old gasleft-delta metric under-counted EIP-8037: bisected real-handleOps requirements are
BALANCE 375,528 and CREDIT 379,828, so `ceil(W x 1.15) = 436,803`; the old floor tuple is rejected.
The release tuple settles on Amsterdam with 30,651 headroom (469,349 required vs 500,000).
MIN must also cover `SETTLE + floor(SETTLE / 63) + 20,000`: EIP-150 retained gas plus ~12.2k call overhead and ~7.8k margin.
The release spacing is 477,142, below the unchanged 500,000 absolute floor; the old 620k/600k tuple is rejected.
Real-EntryPoint BALANCE/CREDIT tests validate the exact governance minimum at SETTLE 450k, 600k and 1M.
Zero-slot defaults changed with the floors: MIN 200k -> 500k, SETTLE 160k -> 450k, C_POSTOP 180k -> 450k
(C_WRAP stays 5k). An all-zero slot therefore behaves exactly like the release tuple; the manifest still
writes the tuple explicitly. LEGACY constants are unchanged.

`LEGACY_SETTLE_GAS_BOUND = 160k` and `LEGACY_C_WRAP_GAS = 30k` are unchanged. They apply only to an
unreleased 5.5.0 352-byte context that could survive only within one `handleOps` transaction.
Sepolia upgrades from 5.4.2, whose tag source emits a 160-byte context, so that legacy path is
unreachable across the 5.4.2 -> 5.5.1 upgrade. The executor's own minimum still admits 480k; that is
raised to 500k in the separate manifest PR under `script/upgrade`. A release run before that PR lands
would queue a tuple the contract rejects (`InvalidConfiguration` at queue), so that PR is a release
prerequisite, not a follow-up.

Migration and integrator notes (release procedure):
- `_gpRaw` substitutes the defaults only for an all-zero slot. A proxy that already stores a tuple
  keeps it until governance queues a new one (48 h timelock). Sepolia's 5.4.2 proxy has a zero slot, so
  it gets the release values on upgrade; any other proxy must be read first.
- Floors are checked at queue and at execute, so a pending tuple below the new floors can no longer be
  executed after the upgrade: cancel it and re-queue a valid one.
- UserOps with `paymasterPostOpGasLimit < 500000` are rejected at validation. SDK/bundler integrators
  must send at least 500,000.

### Validation trace and identity configuration (SP-R4-M-01 / L-02)

The opcode tests fail if Foundry has no debug tracer (the verification command must initialize it
with `-vvvv`); they never skip. They assert the exact ordered executor/opcode/selector closure, not
only banned-opcode absence. Coverage includes SBT false / agent true through
`MockAgentIdentityRegistry`, and credit fallback through a UUPS production `Registry` proxy and its
real `getCreditLimit` implementation.

Agent-registry compatibility is conditional. Before any nonzero identity registry is configured,
the release manifest must bind its runtime hash and archive an opcode/storage trace proving that
`isRegisteredAgent(sender)` uses no ERC-7562-banned opcode and reads only sender-associated storage.
The interface and SP's `try/catch` do not establish those properties.

### Re-review #4 verification (verbatim final lines)

The five trace tests run separately at `-vvvv` because that is what initializes Foundry's debug
step recorder. The full-tree partitions exclude only the exact prefix
`test_OP011_validation_trace`; those five tests are therefore run once, not skipped. Prague uses
isolated `out/prague` and `cache/prague` directories.

```text
Ran 1 test suite in 474.60ms (293.97ms CPU time): 45 tests passed, 0 failed, 0 skipped (45 total tests)
Ran 167 test suites in 70.65s (365.52s CPU time): 1885 tests passed, 0 failed, 71 skipped (1956 total tests)
Ran 1 test suite in 211.88ms (132.67ms CPU time): 5 tests passed, 0 failed, 0 skipped (5 total tests)
Ran 167 test suites in 54.28s (253.73s CPU time): 1763 tests passed, 0 failed, 43 skipped (1806 total tests)
```

The first line is the Cancun V5.5 suite, including all five trace tests; the second is the Cancun
full-tree partition. The third is the five Prague trace tests; the fourth is the Prague full-tree
partition.

```text
No files changed, compilation skipped
OK: SuperPaymaster core headroom 8325 B >= 1024; all 7 deployables <= EIP-170
OK: SuperPaymaster core and SuperPaymasterAdmin storage layouts identical (45 entries, last = __gap@44)
OK: core and extension storage layouts identical (57 entries)
OK  SuperPaymaster storage layout = snapshot + 8 allowed appended entries (45 entries)
OK  Registry storage layout = snapshot (unchanged) (32 entries)
abis/ matches the compiled contracts (full shape, not just names)
```

The injected-layout negative control printed `DRIFT` for both SuperPaymaster and Registry after
inserting OZ `Ownable2Step._pendingOwner`, then concluded:

```text
negative control ok: the gate rejects an OZ Ownable2Step base
```

Validation gas was remeasured through EntryPoint v0.7:

```text
OP-011 SP validation gas 272723
OP-011 PM verification limit 1150000
OP-011 verification headroom 877277
```

## Daybreak re-review #7 — SP-R7

The slash base deliberately excludes uncounted reservations created with the pre-5.5.1 `Inflight`
shape. Such a record decodes with `counted == false`, is absent from `inflightReserved`, and therefore
cannot be included safely without an explicit migration. This state is unreachable on every release
target: live Sepolia runs `SuperPaymaster-5.4.2`, whose storage layout has no `_inflight` mapping, and
OP is a fresh deployment. The upgrade manifest must assert, before execution, that the observed FROM
version is exactly `SuperPaymaster-5.4.2`; this is a manifest requirement, not an operator assumption.
An upgrade from any other FROM version is outside this release's proven state set and must stop.
The executable manifest collector enforces this requirement at
`script/upgrade/sp_upgrade_exec.py:321-322` before it reads or constructs the remaining upgrade
state.

`SuperPaymasterLens.dryRunValidation` now rejects a computed reservation above `type(uint96).max`
before operator-balance or token previews, matching production admission. The new public reason code
bumps the lens to `SuperPaymasterLens-1.2.2`; SuperPaymaster remains `SuperPaymaster-5.5.1` because its
ABI and storage layout are unchanged.

The 10% aPNTs-price and 20% emergency-price lower limits now round upward, so a non-divisible
reference accepts the exact mathematical lower boundary and rejects one unit below it. `queueSlash`
now gives owner precedence when the owner and BLS aggregator addresses overlap, including during the
global BLS cooldown floor. Finally, the successor deployment template records the enforced five-day
verifier delay and cites `contracts/src/modules/monitoring/BLSAggregator.sol:445` (derived from the
five-day case window at line 436).

### Re-review #7 mutation proof and verification

For SP-R7-L-02, both exact lower-bound expressions were temporarily changed back to truncating
division. The two non-divisible boundary regressions then failed as follows:

```text
[FAIL: next call did not revert as expected] test_SetAPNTSPrice_NonDivisibleLowerBoundaryIsExact() (gas: 37445)
[FAIL: next call did not revert as expected] test_EmergencySetPrice_NonDivisibleLowerBoundaryIsExact() (gas: 121906)
```

For SP-R7-L-03, the `actor != owner()` guard was temporarily removed. The overlap regression then
failed as follows:

```text
[FAIL: SlashCooldown()] test_QueueSlash_OwnerPrecedenceWhenOwnerIsBlsAggregator() (gas: 180166)
```

Both mutations were reverted before the final verification. The final full-tree lines, run with
`-vvvv` once for each final green EVM pass, were:

```text
Ran 167 test suites in 602.41s (2460.49s CPU time): 1901 tests passed, 0 failed, 71 skipped (1972 total tests)
Ran 167 test suites in 498.46s (2496.89s CPU time): 1779 tests passed, 0 failed, 43 skipped (1822 total tests)
```

The first line is Cancun and the second is Prague. Prague used isolated `out/prague` and
`cache/prague` directories. An earlier Cancun discovery run exposed three pre-existing fuzz-helper
expectations that still rounded the aPNTs lower bound downward; those helpers were corrected to the
same ceiling rule, their fixed-seed focused regressions passed, and the quoted Cancun line is the
single final green full-tree confirmation.

Final deployable sizes were:

```text
SuperPaymaster 16265 B headroom 8311
SuperPaymasterAdmin 22156 B headroom 2420
SuperPaymasterLens 5525 B headroom 19051
Registry 23306 B headroom 1270
BLSAggregator 24387 B headroom 189
xPNTsTokenV2 20008 B headroom 4568
xPNTsTokenV2Ext 22543 B headroom 2033
OK: SuperPaymaster core headroom 8311 B >= 1024; all 7 deployables <= EIP-170
```

The storage and ABI gates concluded:

```text
OK: SuperPaymaster core and SuperPaymasterAdmin storage layouts identical (45 entries, last = __gap@44)
OK: core and extension storage layouts identical (57 entries)
OK  SuperPaymaster storage layout = snapshot + 8 allowed appended entries (45 entries)
OK  Registry storage layout = snapshot (unchanged) (32 entries)
abis/ matches the compiled contracts (full shape, not just names)
```

## Re-review #619 B1

Operator withdrawals now use exact escrow plus a bounded execution window. `requestWithdraw(amount)`
immediately moves `amount` from the operator's sponsorship balance into the existing
`PendingWithdrawal.amount` field. The request matures after the 48-hour delay and can execute only
during `[readyAt, readyAt + 24 hours]`. Cancellation returns the escrow to sponsorship at any time;
after the window, anyone may call `expireWithdraw(operator)` to do the same. Only an actual
withdrawal reduces `totalTrackedBalance`.

Escrow is excluded from new sponsorship but remains slashable. Slashing computes its 30% cap over
the operator's unescrowed balance plus withdrawal escrow, consumes the unescrowed balance first,
and then reduces the escrow. `SuperPaymasterLens.dryRunValidation` requires no code change: it
already reads only `aPNTsBalance`, so escrow is excluded automatically in the same way as production
validation.

Accepted residual: during `[readyAt, readyAt + W]`, where `W = 24 hours`, escrowed funds can leave
without further notice. Inside that window the escrowed slice can escape the slash entirely: a
slash that lands after the withdrawal executes finds nothing left of it. Those funds did not
sponsor operations while escrowed, and the request gave at least 48 hours of public notice
(`OperatorWithdrawalRequested` carries `readyAt` and `expiresAt`), so the exposure is limited to
the escrowed slice during at most `W` per request cycle.

Side effect: `xPNTsTokenV2Ext` uses `operators(community).aPNTsBalance` as the backing for the
community-token issuance ceiling. Because escrow leaves `aPNTsBalance` at request time, the backing
(and so the ceiling) drops when a withdrawal is requested, not when it executes. That is the
conservative direction; `isOverIssued()` can turn true up to 48 hours earlier than before.

Deposit cap: a deposit reverts `AmountExceedsUint128` unless the liquid balance, the withdrawal
escrow, the in-flight reservation and the deposit together fit `uint128`. Every later credit back
into `aPNTsBalance` (escrow cancel/expire, postOp refund, stale release) therefore cannot overflow.
Tests: `test_B1_deposit_cap_counts_withdrawal_escrow`,
`test_B1_deposit_cap_counts_inflight_reservation_then_stale_release_and_slash`, and
`test_B1_expireWithdraw_at_exactly_expiry_reverts_and_one_second_later_succeeds`; each is red
against its mutant (escrow ignored, reservation ignored, `<=` relaxed to `<`).

## Reviewed redesign evidence (2026-11-13)

The earlier sizes, source hashes, generated-bundle statements and whole-tree test
counts above are historical and superseded by `.rv-redesign.md`. Current versions
are BLSAggregator-4.14.0, DVTValidator-0.8.0 and Reputation-0.6.0. Genuine crypto
tests, including the M1 replay regression, intentionally skip on Cancun; Prague
evidence must execute the mandatory real-precompile sentinel successfully. CC115
tests using AnchoredOverIssueFraudProofVerifier are **local adapter** evidence,
not evidence of compatibility with the unadapted pinned upstream verifier.
The historical Python executor remains byte-identical to origin/main; rc.8
routing belongs in another PR.

### M1 execution floor and disclosed residuals (2026-11-13)

`BLSAggregator.verifyAndExecute` rejects `proposalId < proposalFloor` with
`InvalidProposalId` only when `msg.sender == DVT_VALIDATOR`. M1 covers slash and
aggregator-routed reputation proposals executed through the current DVT, where
IDs are DVT-allocated. An allocated id with a ready proof becomes stale on that
path when a later rotation raises the floor; reactivating its original DVT does
not restore it. A newly allocated id at or above the fresh floor remains
executable with its own valid proof. Every caller, including the owner, still
receives `InvalidProposalId` for zero or an id at or above `2^128`. The monotonic
floor preserves the exhausted value `2^128` across rotations.

The accepted, disclosed residuals are:

- Owner-direct `verifyAndExecute` accepts caller-chosen ids below the floor.
  This is the documented owner-mediated residual: rotation does not revoke that
  route's unused signed authorizations. Signature, replay and DVT callback checks
  still apply; the floor must not treat an owner-chosen id as a DVT allocation.
- Unused pre-rotation generic proposals remain owner/DVT-executable through
  `executeProposal`; their typed replay keys are separate from the raw-id floor.
- Pre-rotation reputation proofs can still reach Registry through an authorized
  reputation source. That route remains source-gated, enforces per-user epoch
  progression and bounds score changes to ±100. It does not inherit the
  aggregator's execution floor.
- An unused pre-rotation consensus queue proof can still set a reversible
  pre-flag. A BLS-queued freeze has **no time expiry**:
  `SuperPaymasterStorage._isSlashPending` expires only a guardian queue after
  `GUARDIAN_SLASH_FREEZE`. The owner can always cancel the flag with
  `SuperPaymasterAdmin.cancelSlash`. `usedSlashQueueHashes` makes the proof
  one-shot per `(operator, level, epoch)`, even after cancellation. The pre-flag
  moves no funds: execution through the current DVT requires a separate fresh
  slash proof with an id at or above the current floor. Relabelling an old proof
  with a fresh id also fails signature verification. Owner-direct execution with
  caller-chosen ids remains the residual described above. The independent owner
  slash authority is unchanged.

`RotationFloorExecution.t.sol` covers stale current-DVT execution after reactivation,
fresh execution, later rotation invalidation, stale queue versus DVT fund-moving execution,
exact namespace exhaustion, suspended key ownership and the disclosed queue
residual. Signature-dependent tests execute with genuine Prague precompiles and
skip on Cancun. `test_RotationAllocationFloorPreservesAuthorizedRegistryProof`
also checks that the same stale reputation proof fails through the reactivated DVT
before succeeding through the authorized Registry source. The same real-Registry
suite adds `test_PostRotationDvtReputationUpdateExecutes` and
`test_OwnerDirectLowIdStillExecutesAfterRotation`, proving successful reputation
updates with genuine signatures on both authorized routes. Final suite counts,
runtime size and changed files are recorded in `.rv-narrow.md`; ABI/docs
regeneration is left to the calling session.

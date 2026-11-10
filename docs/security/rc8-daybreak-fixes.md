# rc.8 Daybreak fix set — 2026-11-09

Worktree: `/Users/jason/Dev/aastar/sp-wt/rc8`, branch `cc125/rc8-daybreak-fixes`.
Input: `C4-report.md`, `C2-report.md`, `C1-report.md` in
`/Users/jason/Dev/aastar/manifest-live/daybreak-2026-11-09/`.
The initial `git diff 8de39026 -- contracts/src` was empty. No network, chain,
key access, commits, or Git metadata writes were performed.
The pre-existing OpenZeppelin v5.1.0 `package-lock.json` edit was preserved.

## Implementation

### C4-H-01: separate signing cutoff and withdrawal readiness

`BLSAggregator-4.13.0` retains the two-day public notice. For request time `t`:

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

### C4-L-01 deferred, C4-L-02 included

C4-L-02 is included: generic `executeProposal` stores `proposalSignersCommitment` after signature
verification and before calling the arbitrary target (test_GenericCommitmentIsStoredBeforeTargetCall,
test_Prague_GenericProposalRecordsSigners).

C4-L-01 is NOT fixed in rc.8. A first attempt removed the generic-path `markProposalExecuted` callback; the
Daybreak re-review showed that generic and slash proposals still share `executedProposals`, so a fresh generic
id could then pre-consume a slash proposal id that DVTValidator allocates later (a new reachable path). The
callback is restored exactly as before rc.8 and C4-L-01 is deferred to 5.5.1 (disjoint id namespaces).

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

### Version propagation

- BLSAggregator: 4.12.0 → 4.13.0.
- SuperPaymaster: 5.5.0 → 5.5.1.
- xPNTsTokenV2: XPNTs-4.0.0 → XPNTs-4.0.1.
- SuperPaymasterLens: 1.2.0 → 1.2.1; its exact SP-version gate follows 5.5.1.
- xPNTsFactoryV2: 3.0.0-v2 → 3.0.1-v2; its exact template-version gate follows 4.0.1.

The last two changes are required to keep diagnostics and token creation working
with the new versions. Current-version assertions and the experimental
ProfilePaymaster test helper were updated; historical deployment fixtures remain
historical. Downstream DVT/SDK consumers need the new withdrawal timing and ABI
constant/events before release. No downstream notifications were sent.

## BLS round 4

### DVT proposal-id rotation

`DVTValidator-0.7.0` takes `firstProposalId` in its constructor. The 5.5.0
deployment scripts use `1` for a fresh aggregator. For every later
DVT rotation, the selected value must exceed every raw proposal id the retained
aggregator has executed and must leave ample room below `2^128` for the new
deployment's expected lifetime. The constructor rejects zero and values at or
above `2^128`; proposal creation also fails closed if that namespace is exhausted.

Pending proposals belong to the old DVT and are abandoned at rotation. They are
not migrated or executable through the replacement DVT and must be proposed again
there, receiving ids from the replacement's new range.

### Validator-removal quorum floor

`DVTValidator.removeValidator` reaches `BLSAggregator.revokeBLSPublicKey` as the
configured DVT. That route now uses the same committee-survival check as a
voluntary guardian exit, including the maximum of `defaultThreshold` and every
slash threshold. A direct aggregator-owner revocation deliberately remains the
emergency eviction override and bypasses the check.

The DVTValidator owner must be the same Safe-compatible M-of-N owner as the
BLSAggregator. `setDVTValidator` remains an immediate owner call: rotating the
DVT adds no power beyond the owner's existing direct `verifyAndExecute` route,
and every DVT path still requires a BLS quorum of registered keys. Verifier
rotation separately retains its contract-enforced five-day delay. Deployment
scripts transfer both owners together and assert equality.

### Reputation rule disablement

`Reputation-0.5.0` records rule existence and active state separately. A rule
configured with `baseScore == 0` is inactive and contributes no score; it does
not receive the default rule. The default applies only to a first rule id that
the community has never configured. Re-enabling updates the same listed rule
without inserting a duplicate. The added private mapping is an append-only
storage-layout change on this directly deployed, non-upgradeable contract.

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

Engine: `/Users/jason/.foundry/bin/forge` 1.7.1, Solidity 0.8.33, default profile.
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

The final command results are recorded below; round-7 raw logs are in `/tmp/rc8-bls-r7-*.log`.

The first full Cancun run exposed two stale expectations: the central release
version table still named the old SP/Lens versions, and the invariant handler's
independent model retained a standby after promotion. The release readback
constants (including token/factory bootstrap and BLS deployment readback) were
updated. The invariant model now clears a promoted standby and independently
asserts that standby is never current SP. No production behavior was weakened to
satisfy the old model. Subsequent final results are recorded below.

Final BLSAggregator runtime: **24,551 B**, headroom **25 B**. The final release
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

The source files used for those three final artifacts are bound by SHA-256:

| Artifact | Source file SHA-256 |
|---|---|
| BLSAggregator | `011cdd40a146ee0edcae99173598bafc8c144607d5c6449e1b4b6e85f86f26b5` |
| DVTValidator | `6ed802f84b3a49fe8488f3ed20f1d93493d867c0e0f3aa3bc76fdf1a07b936ab` |
| ReputationSystem | `597060791537136711ed0e413884f4ccc6dba4456378ecbbdd9e88fa9d75e714` |

## Release ABIs

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

## Final verification results (verbatim)

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
OK  Registry storage layout = snapshot (unchanged) (32 entries)
```

The forced default build that compiled the production fixes reported
`Compiler run successful with warnings:`; the final cached build confirms the
final tree. ABI verification ended with `abis/ matches the compiled contracts
(full shape, not just names)`.

Skips come from existing EVM-specific precompile/artifact guards and opt-in fork suites; no new test skips were added. Whole-suite setup skips account for the different total test counts across EVMs. The two allowed appended SP storage entries predate this task; no storage entries were introduced here. `git diff --check` passed. ABI bundles and documentation were regenerated from final Cancun artifacts and their checks pass.

The requested contract/deployment fixes, version propagation and all specified local verification are complete. Manifest/executor findings remain explicitly deferred to the dedicated PR. No chain or deployment validation was attempted, as requested.

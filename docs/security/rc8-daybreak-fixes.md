# rc.8 Daybreak fix set — 2026-11-09

Worktree: `/Users/jason/Dev/aastar/sp-wt/rc8`, branch `cc125/rc8-daybreak-fixes`.
Input: `C4-report.md`, `C2-report.md`, `C1-report.md` in
`/Users/jason/Dev/aastar/manifest-live/daybreak-2026-11-09/`.
The initial `git diff 8de39026 -- contracts/src` was empty. No network, chain,
key access, ABI regeneration, commits, or Git metadata writes were performed.
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

The final command results are recorded below; complete raw logs are in `/tmp/rc8-daybreak/`.

The first full Cancun run exposed two stale expectations: the central release
version table still named the old SP/Lens versions, and the invariant handler's
independent model retained a standby after promotion. The release readback
constants (including token/factory bootstrap and BLS deployment readback) were
updated. The invariant model now clears a promoted standby and independently
asserts that standby is never current SP. No production behavior was weakened to
satisfy the old model. Subsequent final results are recorded below.

Final BLSAggregator runtime: **24,223 B**, headroom **353 B**; **122 B smaller**
than rc.7 despite the challenge-period addition. All measurements use Cancun,
optimizer 500 runs, via-IR and Solidity 0.8.33. Prague outputs/cache are isolated
under `out/prague` and `cache/prague`; the size gate reads only default/Cancun
artifacts and verifies source hashes and compiler settings.

| Deployable | Runtime bytes | EIP-170 headroom |
|---|---:|---:|
| BLSAggregator | 24,223 | 353 |
| SuperPaymaster | 13,744 | 10,832 |
| SuperPaymasterAdmin | 17,975 | 6,601 |
| SuperPaymasterLens | 5,413 | 19,163 |
| Registry | 23,306 | 1,270 |
| xPNTsTokenV2 | 20,008 | 4,568 |
| xPNTsTokenV2Ext | 22,543 | 2,033 |

## ABIs for the release owner to regenerate

No file in `abis/` was modified.

- `abis/BLSAggregator.json`: new `GUARDIAN_FRAUD_CHALLENGE()` getter and bytecode.
- `abis/xPNTsTokenV2.json`, `abis/xPNTsTokenV2Ext.json`,
  `abis/xPNTsTokenV2.full.json`: new `StandbyInvalidated(address)` and
  `StandbyProposalCancelled(address)` events; core/extension bytecode changes.
- `abis/SuperPaymaster.json`, `abis/SuperPaymasterAdmin.json`,
  `abis/SuperPaymasterLens.json`, `abis/xPNTsFactoryV2.json`: unchanged ABI
  signatures, changed embedded bytecode/version behavior.
- `abis/SuperPaymaster.full.json`: combined ABI signatures remain unchanged,
  but its note still names 5.5.0 and should be refreshed to 5.5.1.

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

forge test --match-path <17 affected test files> (Cancun)

```text
Ran 22 test suites in 4.18s (4.91s CPU time): 265 tests passed, 0 failed, 31 skipped (296 total tests)
```

forge test (full tree, Cancun)

```text
Ran 165 test suites in 49.45s (240.03s CPU time): 1851 tests passed, 0 failed, 71 skipped (1922 total tests)
```

forge test --evm-version prague --match-path <17 affected test files>

```text
Ran 22 test suites in 3.98s (8.02s CPU time): 211 tests passed, 0 failed, 20 skipped (231 total tests)
```

forge test --evm-version prague (full tree)

```text
Ran 165 test suites in 54.95s (257.84s CPU time): 1731 tests passed, 0 failed, 43 skipped (1774 total tests)
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

The default build that compiled the production fixes reported `Compiler run successful with warnings:`; the final cached build confirms the final tree.

Skips come from existing EVM-specific precompile/artifact guards and opt-in fork suites; no new test skips were added. Whole-suite setup skips account for the different total test counts across EVMs. The two allowed appended SP storage entries predate this task; no storage entries were introduced here. `git diff --check --ignore-submodules` passed. ABI and tracked Python-cache diffs are empty.

The requested fixes, both conditional C4 lows, version propagation and all specified local verification are complete. The only execution adjustment was omitting `nice` after the sandbox refused it. No chain or deployment validation was attempted, as requested.

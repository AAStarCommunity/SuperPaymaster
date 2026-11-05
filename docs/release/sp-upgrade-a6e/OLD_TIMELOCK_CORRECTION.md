# Old timelock correction — 2026-11-05

The retained local A3a plan hashes to
`0bb821d18f60495d9b576763923d456a8e5f64277be40549da24643de5083151`.
The S2 transaction, block and build commit are the supplied DSR provenance;
no RPC or receipt lookup was performed.

Reader inventory completed before editing config.sepolia.json:

| File | Use and impact |
|---|---|
| contracts/script/v3/DeployLive.s.sol | Writer, not reader: serializes its newly deployed timelock. No change. |
| contracts/script/v3/DeployAnvil.s.sol | Writer of local deployment config. No change. |
| contracts/script/v3/DeployV54.s.sol | Writer: replaces the key with its deployed timelock. No change. |
| contracts/script/v3/UpgradeLive.s.sol | Reads optional address, skips deployment when present, supplies it to a new PolicyRegistry. Now selects the A3a timelock. |
| contracts/script/v3/UpgradeViaTimelock.s.sol | Reads fallback for TIMELOCK; validates and uses it for scheduling/execution and governance checks. Now selects A3a unless overridden. |
| contracts/script/checks/Check10_V54.s.sol | Checks code and PolicyRegistry.timelock binding against config. Now checks A3a; stale wiring will fail. |
| contracts/script/checks/CheckDefaultArtifacts.s.sol | Classifies all keys, checks timelock artifact, aPNTs governance and PolicyRegistry wiring. Now checks A3a. **The new timelockControllerLegacy key is unknown and fails classification.** Left unchanged per instruction; running against the updated config requires a separately reviewed classification rule. |
| scripts/d5b-anvil-rehearsal.sh | Writes a synthetic rehearsal config; does not read Sepolia's key. No change. |
| contracts/test/scripts/CheckDefaultArtifacts.t.sol | Builds synthetic config with its own timelock, not the Sepolia file. No change. |
| script/upgrade/old_owner_isolation.py | Reads committed Sepolia config for immutable aliases; timelockController is not an alias. No change. |
| script/upgrade/test_old_owner_isolation.py | Reads committed config to test immutable aliases; does not consume this key. No change. |

Indirect shell callers:

- `script/evidence/check-default-artifacts-sepolia-fork.sh` selects config.sepolia.json for CheckDefaultArtifacts; inherits the unknown-key blocker.
- `script/evidence/d5b-fork-rehearsal.sh` runs UpgradeViaTimelock with ENV=sepolia; its config fallback now selects A3a.
- `script/evidence/a2-full-rehearsal.sh` runs UpgradeViaTimelock with an explicit TIMELOCK; that override still wins.
- `scripts/check-live-scripts-compile.sh` compiles deployment/upgrade scripts without reading this config value; no impact.
- `scripts/d5b-anvil-rehearsal.sh` invokes UpgradeViaTimelock against its generated d5b-rehearsal config; no impact.

Repository source scan found no other direct consumers of this key. Shell wrappers invoking the checks inherit their behavior; gasless tests read other Sepolia config fields. No deployment/check/shell reader scripts or config-reading code were changed. No forge build needed: no Solidity changed and the unknown-key failure is explicit in _classify.

## Changed files

- `deployments/config.sepolia.json`: canonical A3a timelock and legacy key.
- `script/upgrade/deployed_source_candidates.json`: A3a address, creation block, commit and transaction; retained legacy evidence labelled.
- `script/upgrade/old_owner_isolation.py`: legacy constant and authority-row enumeration from the validated isolation inventory.
- `script/upgrade/manifest_exec.py`: block-bound legacy checks at collection and closing, with retained reads.
- `script/upgrade/test_old_owner_isolation.py`: wrong-timelock source-set regression.
- `script/upgrade/test_manifest_exec.py`: named gate controls, all getter/mapping/role negatives, both Safe negatives, block binding and strict offline fakes.
- `script/upgrade/probe_phase_c_gates.py`: new gate controls and the source-set regression.
- `script/evidence/audit605_probes.py`: required function/gate/test bindings.
- `script/upgrade/audit/probe_gate_removal.py`: new function included in mutation scope.
- `script/upgrade/OLD_OWNER_ISOLATION_RESULTS.md` and `script/upgrade/DEPLOYED_SOURCE_PARITY_RESULTS.md`: historical address-binding corrections.
- `script/upgrade/README.md` and `docs/release/sp-upgrade-a6e/MANIFEST-DESIGN.md`: precondition, recorded reads and residual scope.
- This report: reader inventory, compatibility finding and acceptance results.

## Gate controls

| Gate | Named negative test |
|---|---|
| old_timelock_tl_roles | ManifestTests.test_old_timelock_tl_roles |
| old_timelock_authority | ManifestTests.test_old_timelock_authority |
| old_timelock_safe | ManifestTests.test_old_timelock_safe |
| old_timelock_holds_nothing | ManifestTests.test_old_timelock_holds_nothing |
| old_owner_source_targets (existing) | OldOwnerIsolationTests.test_legacy_timelock_source_targets |

Each new negative asserts `record['gate']` at the pinned check and through
`dvt_closing`. The authority negative covers every synthetic getter, mapping and
role row outside the new timelock; all four timelock roles have separate cases.
Safe owner and module membership are separate negative cases. The aggregate
control rejects missing target coverage. Positive controls require every recorded
read to use the selected block; the collector control checks retained pin reads.

## Acceptance results

Offline runs from the repository root. Optional live-fork environment variables
were unset. Only the gate-probe command used `script/upgrade` as its working
directory. Logs are retained under `out/oldtl-checks/` (ignored build output).

| Command | A3A_ENGINE_DIR=$HOME/.foundry/bin (1.7.1) | A3A_ENGINE_DIR unset (1.8.7-nightly, 4e8874b) |
|---|---|---|
| python3 -B script/upgrade/test_manifest_exec.py | Ran 379 tests; OK (skipped=2) | Ran 379 tests; OK (skipped=2) |
| python3 -B script/upgrade/test_old_owner_isolation.py | Ran 57 tests; OK (skipped=2) | Ran 57 tests; OK (skipped=2) |
| python3 -B script/upgrade/test_manifest_phase_c.py | Ran 140 tests; OK | Ran 140 tests; OK |

The two skips are opt-in hydrated Anvil/fork controls, excluded by the offline
constraint. Existing Phase C tests emit unittest deprecation warnings; they pass.

Once on 1.7.1:

- `script/evidence/stale_proposal_probes.py`: `SOURCE_UNCHANGED 1 PROBES_ALL_RED=1`.
- `script/upgrade/audit/test_audit_findings.py`: `Ran 6 tests`; `OK`.
- `script/a3a/test_a3a_exec.py`: `Ran 102 tests`; `OK`.
- `script/upgrade/test_sp_upgrade_exec.py`: `Ran 141 tests`; `OK`.
- `probe_phase_c_gates.py a832cf55`: `PHASE_C_GATE_PROBES PASS 138/138 red; uncovered new gates: []`.

Additional focused checks: five old-timelock tests passed on 1.7.1; the final
closing-fixture check passed on the default engine. `git diff --check` passed.
Initial test runs exposed missing fake replies; those fixtures were corrected.
The table reports the corrected runs, not the initial failures.

`audit605_probes.py` was skipped as requested: it requires a clean tree, and
this worktree contains the requested uncommitted edits. Its REQUIRED bindings
and PHASE_FUNCTIONS registration were updated. No config-validation forge build
was needed. The first broad mutation run reached an unintended offline Forge
rebuild after suppressing old_owner_source_targets: the negative fixture had
not stubbed the path beyond its expected rejection. That run was interrupted,
the synthetic build fixture was added, and the broad probe was restarted and passed all 138 controls. The corrected source-target control also passed on the default engine.
No network/RPC, environment-file reads, real keys, commits, pushes, checkouts,
resets or stashes were used.

# Route-A procedure mutations

## Current status and rerun

**Observed (2026-10-23, Sepolia fork block 11974561, foundry nightly 926eb1d, `--hardfork amsterdam`, committed runner `script/evidence/rams-a-mutations-inplace.sh` with expected-assertion matching, clean tree e704f1f5 — each log's `dirty:` lines show only the patched test file and run outputs):** CONTROL **GREEN, 10/10**; **M1–M13 all KILLED by their expected assertion** (`mutations-run3/summary.tsv`; `mutations-run2/` is the same result from the uncommitted tree, header Commit 5b60c80b, kept as history; every `Mn.log` and `CONTROL.log` starts with the forge version / commit / exact args header). M5 is killed by the SETTLE read-back only — see the A5b note below; settlement does not discriminate SETTLE at MIN=440000. The earlier `mutations-run1-INVALID/` run (temp-worktree runner) is kept as an infrastructure-failure record only.

To reproduce:

```bash
bash script/evidence/rams-a-mutations-generate.sh
FORGE=/absolute/path/to/amsterdam-nightly/forge \
SEPOLIA_FORK_RPC="$ARCHIVE_RPC" FORK_BLOCK=11974561 \
OPERATORS="$COMPLETE_OPERATOR_INVENTORY" \
./script/evidence/rams-a-mutations-inplace.sh \
  docs/design/aoa-balance-mode/data/rams-a/mutations-run2 \
  docs/design/aoa-balance-mode/data/rams-a/mutations-rerun
```

The generator requires unique literal anchors and regenerates all thirteen diffs against the current test. The runner saves the current rehearsal, applies one patch at a time with zero fuzz, and restores the saved bytes on exit (including uncommitted work). Only the rehearsal is patched. It does not broadcast or change production sources. Use a fresh output directory to preserve historical logs.

## Verdict contract

`targets.tsv` has three columns: ID, exact target test name, expected first-failure substring. KILLED requires the **first failure of that exact target** to contain that substring. Any other target failure is WRONG-ASSERTION; PASS is SURVIVED; skipped/missing/compile/RPC failures are INVALID. CONTROL must pass every route test without skips. The runner exits nonzero for any other result. CONTROL and every mutant log contain Forge version, commit, exact command (including `--hardfork amsterdam` and `--no-isolate`), block, inventory and `RPC host: <redacted>`. A configured fork unsets `FOUNDRY_OFFLINE`; RPC-unset runs compile offline and skip fork tests.

| ID | Procedure mutation / source anchor | Required first-failure substring |
|---|---|---|
| M1 | `_upgrade`: empty atomic upgrade calldata | `atomic global pause` |
| M2 | `_pauseAll`: skip inventory index 0 | `operator pause read-back` |
| M3 | A5: successful activation moved to eta−1 | `GasParamsTimelock` |
| M4 | A5: resume and probe 300k before activation | `exact SIG_FAILURE required` |
| M5 | A5: queue SETTLE=160000; retain read-back after settlement | `SETTLE read-back` |
| M6 | `_timelock`: extra executor in constructor | `extra executor` |
| M7 | A6: predecessor-free activation before legacy implementation upgrade | `FailedInnerCall` |
| M8 | `readbackGate`: omit guardian gate | `did not revert as expected` |
| M9 | A2: upgrade without global pause | `exact SIG_FAILURE required` |
| M10 | A4: submit before pausing | `did not revert as expected` |
| M11 | A6: `requiredPredecessor = bytes32(0)` | `TimelockUnexecutedPredecessor` |
| M12 | A3: skip rejection-loop body for mandatory ANNI class | `all operator classes probed` |
| M13 | A6: grant ownerAccount EXECUTOR after role audit | `did not revert as expected` |

## M5 evidentiary limit

M5 is killed **only by the read-back gate**. Settlement does not discriminate SETTLE=420000 versus 160000 at MIN=440000; SETTLE is defense in depth there. The 440k admissible minimum already exceeds the approximately 365k settlement need. There is no claim that every mutant is killed at its named settlement assertion.

`test_A5b_settleBindingAnalysis` queues and executes each real tuple `(440000, SETTLE, 5000, 340000)`, validates the minimum-limit V2 operation, then binary-searches callback success gas with its real reserved context and rolled-back attempts. It also runs real `handleOps` settlement at the minimum admissible limit for BOTH tuples. It logs both thresholds and whether the no-OOG band intersects admissible limits; it explicitly asserts no intersection in this fixture (`RAMS: no admissible no-OOG band at MIN 440k in fixture`). This is a measurement for this token/state/call path, not a universal gas bound for arbitrary token implementations or future states. Increasing the callback budget on this fixed path cannot create a lower-budget OOG band above its measured success threshold. Fork rerun: thresholds 438,786 (SETTLE 420000) and 174,659 (SETTLE 160000); see `README.md`.

## A6 independent predecessor negative

M7 remains a limited legacy ordering control: `FailedInnerCall()` occurs because 5.4.2 lacks the selector. It does not prove predecessor enforcement. A6 now runs the real preparation upgrade/queue batch, then on a snapshot schedules a second upgrade/queue batch and an activation that depends on its batch ID. At activation's own ETA the proxy is already 5.5.0 and its queued params are mature, but the required batch is unexecuted. A diagnostic call asserts the exact `TimelockUnexecutedPredecessor(bytes32)` payload; a subsequent `vm.expectRevert` also checks that exact payload. M11 removes the dependency from both schedule and execution; activation can then succeed and is caught by `RAMS: TimelockUnexecutedPredecessor required`. The snapshot restores the original timeline before the parallel/sequential controls.

The early batch and activation checks use the full `TimelockUnexpectedOperationState(id, Ready bitmap)` payload. The old tautological predecessor-done check is removed. M13 exercises actual execution authorization after the constructor role read-backs, rather than duplicating M6's membership check.

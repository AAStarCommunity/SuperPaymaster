# Route-A procedure mutations

Status: authored and checked locally only. **No fork/control/mutation Forge run has been performed for this table.** The expected diagnostics below are hypotheses to verify, not observed kills. The existing `fork-run2-11974561.log` records 15 passes: nine route tests and six budget tests. The rehearsal runner's `--match-path contracts/test/rams/RamsARouteRehearsal.t.sol` selects the nine route tests; this script uses that same filter for its unmutated control.

Run from any directory with the same nightly and complete archive operator inventory used by the rehearsal:

```bash
FORGE=/absolute/path/to/nightly-926eb1d/forge \
SEPOLIA_FORK_RPC="$ARCHIVE_RPC" FORK_BLOCK=11974561 \
OPERATORS="$COMPLETE_OPERATOR_INVENTORY" \
./script/evidence/rams-a-mutations.sh
```

Every invocation uses `FORGE test --match-path contracts/test/rams/RamsARouteRehearsal.t.sol --no-isolate -vvv --hardfork amsterdam`, with `FOUNDRY_ISOLATE=false` and `FOUNDRY_OFFLINE=true`. Mutants additionally use the exact named `--match-test '^test_NAME$'` below. `SEPOLIA_FORK_RPC`, `FORK_BLOCK`, and `OPERATORS` remain in the environment. Offline compilation does not disable fork RPC reads. The script records the actual Forge version; the caller must supply the intended nightly, block and inventory.

The script creates a detached temporary git worktree, overlays a copy of the current checkout (including untracked rehearsal files and populated dependencies), and starts each mutation from the same saved control file. Only the copied rehearsal is patched. It never patches `contracts/src`, broadcasts, installs dependencies, or changes the original rehearsal/helpers. Output/cache directories are private to the worktree, which is removed on exit.

The durable `mutations-UTC-PID/` directory contains the baseline file, commit, exact per-mutant diffs, anchor-check output, Forge logs, and `summary.tsv`. The printed TSV reports **observed** failing test names and full Forge failure messages, with log paths for traces. The RPC URL is redacted. Exit 0 requires all nine unmutated route tests green, none skipped, and all ten named mutants red with the diagnostic family below. A survivor, wrong failure, skipped test, compilation error, RPC failure, or failed control produces nonzero status. No earlier green log substitutes for this run's control.

All source references below are baseline `contracts/test/rams/RamsARouteRehearsal.t.sol` line numbers. Mutants can shift line numbers; the saved diff gives the mapping.

| ID | Named target test | Procedure change | Expected assertion/revert and baseline location | Observed result |
|---|---|---|---|---|
| M1 | `test_A3_atomicUpgradeWithGlobalPause` | `_upgrade(true)` sends empty upgrade calldata instead of the pause delegatecall; keep its expected `true` read-back. | `RAMS: atomic global pause`, `RamsARouteRehearsal.t.sol:333`. | Not run |
| M2 | `test_A1_oldPausePath_blocksAllOperators` | `_pauseAll` skips the setter for inventory index 0, which A1 explicitly made active. | `RAMS: operator pause read-back`, `RamsARouteRehearsal.t.sol:263`, before the op probes. | Not run |
| M3 | `test_A5_governanceTimeline_EOAowner` | Move the successful activation attempt from `eta` to `eta-1`; leave both existing expected early reverts intact. | Unexpected `GasParamsTimelock()` at the success-path call, `RamsARouteRehearsal.t.sol:669`. This is an uncaught contract revert, before `_assertGas(true)` at line 670. | Not run |
| M4 | `test_A5_governanceTimeline_EOAowner` | Move V2 funding/binding and operator resume before activation; globally resume there and move the existing 300k rejection probe immediately after resume. Gas params are still defaults. | The now-admitted op yields `RAMS: exact SIG_FAILURE required`, `RamsARouteRehearsal.t.sol:317`, from the probe originally at line 682. | Not run |
| M5 | `test_A5_governanceTimeline_EOAowner` | Queue `(440000,160000,5000,340000)` through the real API, read its ETA directly, and defer the unchanged active gas read-back until after settlement. | Amsterdam settlement control at line 680 must fail inside `_run`/`_settleOne`: expected `RAMS: exact legacy postOp failure` at line 564 (unexpected V2 postOp revert reason), or `RAMS: bundle success mismatch` at line 549 / `RAMS: settlement reverted` at line 584 / `RAMS: missing settlement` at line 585 depending on emitted events. **SETTLE read-back alone does not count.** | Not run |
| M6 | `test_A6_governanceTimeline_SafeTimelock` | Construct the timelock with both SAFE and `ownerAccount` as executors; proposer stays SAFE-only. | `RAMS: extra executor`, `RamsARouteRehearsal.t.sol:697`. | Not run |
| M7 | `test_A6_governanceTimeline_SafeTimelock` | Alongside the batch, schedule `executeGasParams()` with predecessor zero; at external ETA execute it before the upgrade/queue batch. | Unexpected revert at inserted `tl.execute` immediately after baseline line 745. Expected `FailedInnerCall()` (empty legacy selector revert wrapped by OZ Address), possibly displayed as `EvmError: Revert`/unrecognized selector. This is a revert at an expected-success call, **not an assertion failure**; the original predecessor assertion at line 799 is never reached. | Not run |
| M8 | `test_A7_readbackGate` | Omit the guardian read-back from the gate procedure; retain guardian storage tampering and its expected revert. | `next call did not revert as expected`: `_tamper`'s `vm.expectRevert(bytes(reason))` at `RamsARouteRehearsal.t.sol:868`, exercised by guardian negative control at line 919; the gate call at line 869 incorrectly returns. | Not run |
| M9 | `test_A2_newOperatorRisk_window` | Use `_upgrade(false)` instead of the atomic global pause. Keep the newly registered operator active and the V2 migration/probes intact. | Migrated new-operator op is admitted: `RAMS: exact SIG_FAILURE required`, `RamsARouteRehearsal.t.sol:317`, from line 478. `_upgrade(false)` truthfully checks the resulting unpaused state, so a helper pause assertion cannot mask admission. | Not run |
| M10 | `test_A4_legacyContexts` | Submit `signedBeforePause` via the existing `handleOps(rejected,...)` before pausing. Move the existing direct rejection probe and pause setter after that submission so the actual submission is reached. | `next call did not revert as expected`: the `AA34 signature error` expectation at `RamsARouteRehearsal.t.sol:604`, on `ep.handleOps` at line 605. The signed op is still valid and should execute/settle. | Not run |

M4 changes the timing of the existing rejection probe to expose the unsafe window; it does not invert an assertion. M5 deliberately bypasses `_queue()`'s fixed SETTLE expectation by performing the queue procedure inline, and moves rather than weakens `_assertGas(true)`. Otherwise the test would fail on a value comparison without demonstrating a settlement failure. No mutation changes an expected assertion value or removes a negative control.

M7's outcome has a specific evidentiary limit: at this point the proxy is still 5.4.2 and has neither the new selector nor a queued proposal. Its red result demonstrates that this ordering cannot complete the rehearsal. It does **not**, on its own, prove that the external predecessor dependency discriminates independently of implementation readiness. The script records the actual revert and rejects an unrelated diagnostic; it does not label the unreachable line-799 assertion as observed.

## Patch anchors

`mutate.py` requires exactly one occurrence for every replacement. Scoped replacements first anchor `function NAME(`, ending at the next function; this avoids mutating identical operations in other tests. Listed strings are literal source text (indentation/newlines are also checked by the script):

| ID | Scope anchors and replacement anchors |
|---|---|
| M1 | Global: `atomicPause ? abi.encodeWithSignature("setGlobalPaused(bool)", true) : bytes("")` |
| M2 | `_pauseAll`: `sp.setOperatorPaused(operators[i], stopped);` |
| M3 | `test_A5_governanceTimeline_EOAowner`: `vm.warp(eta);` |
| M4 | `test_A5_governanceTimeline_EOAowner`: contiguous `_freshPrice();` / `xPNTsTokenV2 token = _v2Ready();` / `_pauseAll(false);`; `_probe(_op(OWNER, 300_000, true), false, 0);`; `vm.warp(eta);` |
| M5 | `test_A5_governanceTimeline_EOAowner`: `uint256 eta = _queue();`; `_assertGas(true);`; `_settleOne(op); // The orchestrator must run under nightly --hardfork amsterdam.` |
| M6 | `_timelock`: `tl = new TimelockController(DELAY, safeOnly, safeOnly, address(0));` |
| M7 | `test_A6_governanceTimeline_SafeTimelock`: `tl.scheduleBatch(targets, values, data, bytes32(0), salt, DELAY);`; `vm.warp(scheduled + DELAY);` |
| M8 | `readbackGate`: `require(sp.guardian() == g.guardian, "RAMS gate: guardian");` |
| M9 | `test_A2_newOperatorRisk_window`: `_upgrade(true);` |
| M10 | `test_A4_legacyContexts`: contiguous `_pauseAll(true);` / `_probe(signedBeforePause, false, 0);`; `ep.handleOps(rejected, payable(address(0xBEEF)));` |

Local validation: `bash -n script/evidence/rams-a-mutations.sh` and the `--check-patches` local-only mode, which applies all ten Python patches to throwaway file copies and checks unique anchors. Neither invokes Forge, creates a worktree, or accesses RPC. Literal anchors were also located with `rg -n -F` in the current rehearsal. These checks establish syntax/patch applicability only; runtime diagnostics remain unverified.

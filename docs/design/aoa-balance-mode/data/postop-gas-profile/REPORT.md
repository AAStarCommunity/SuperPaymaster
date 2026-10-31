# Fresh-deployment postOp gas profile

2026-10-31. Offline measurements; changes left in the working tree.

## Conclusion

The fresh single-operation EntryPoint v0.7 path completes at **440,000 gas in both modes on Amsterdam**. The immediately lower limit, **439,999**, is rejected by validation with `FailedOp(0, "AA34 signature error")`: this is the minimum **admitted** limit under the unchanged deployment tuple, not a measurement of how far the entry guard or validation floor could safely be lowered.

Fresh direct calls complete at **438,828 gas** in both modes. This does not reproduce the earlier snapshot scan's 570k BALANCE / 634k CREDIT completion thresholds. The evidence supports a **snapshot/test-setup effect** in that scan, rather than a requirement for more than 440k in this fresh single-operation path. It does not isolate a bug in `vm.revertTo` from the scan's release/re-admit and transaction-history effects.

**No residual non-guard band on fresh state.** On Amsterdam the fresh direct minimum, 438,828, is also where the entry guard starts admitting. Both `test_direct_minimum_minus_one` (438,827) and `test_direct_stable_boundary_is_guard_on_amsterdam` (431,514, the stable-engine guard boundary) assert that the call fails with exactly `PostOpGasTooLow()`, so both ends of that window are guard rejections, not out-of-gas past the guard. On Cancun and Prague the guard boundary and the direct minimum are both 431,514. In this fresh single-operation setup, a postOp the guard admits completes, on all three engines. The window's interior is not sampled point by point; the claim rests on its two ends and on gasleft being monotonic in the call gas.

This answers the open finding in `../rr5-guard-fail/REPORT.md` as follows: the 440k–632k (CREDIT) / 440k–568k (BALANCE) non-guard band appears only in that test's snapshot/release/re-admit lifecycle and does not appear when each sample is deployed fresh. Which part of that lifecycle causes it (snapshot restore, the release/re-admit sequence, or the transaction history it creates) is **not** isolated here.

There is also a real **peak-above-net** effect. Neither the net frame nor eight sparse checkpoints alone is a sufficient peak estimate. The retained instruction trajectories include the token child frames and the unforwarded gas held by their callers.

## Method and assertions

`contracts/test/v2/SuperPaymasterPostOpGasProfile.t.sol` deploys fresh contracts in `setUp`, with a real transaction boundary before the test. Every gas-search sample runs in a **separate Forge process**. No snapshots are used. Both modes enable the operator's rate-limit timestamp write, start with zero protocol revenue and user debt, and use real token settlement. CREDIT accounts have no tokens; BALANCE accounts are funded. Validation and postOp occur in the same test transaction. The direct path validates normally and then pranks only the EntryPoint caller for postOp; it does not release/re-admit a prior reservation.

The EntryPoint runtime is the repository's canonical v0.7 fixture, with a deployed SimpleAccount and a real target call. Completion requires no `PostOpRevertReason`, a `UserOperationEvent`, retained target execution, consumed operation hash, cleared token reservation, positive protocol revenue, and zero debt for BALANCE / positive debt for CREDIT. Absence of a revert event alone is not accepted as success. The only accepted top-level rejection is the exact AA34 error below MIN_POST.

The runner searches from 418k in 2k steps, brackets the first completion, bisects to one gas, and independently reruns both adjacent endpoints. Tests freeze the completion thresholds, and fourteen normal tests per engine include both adjacent endpoints for each path/mode, the guard classification below the direct minimum, and checkpoint trajectories. Search tests also assert the frozen classification at every sample. The tuple remains `MIN_POST / SETTLE / C_WRAP / C_POSTOP = 440000 / 420000 / 5000 / 340000`.

The test-only `contracts/test/helpers/ProfilePaymaster.sol` is a generated copy of the production implementation with eight `gasleft()` reads into a memory array, followed by one event. It is installed only in the trajectory fixtures. The provenance checker reconstructs this copy from current production source and refuses drift. Threshold tests and instruction traces use the **unmodified production implementation**.

## Minimum limits

| Engine | BALANCE EntryPoint | CREDIT EntryPoint | BALANCE direct | CREDIT direct |
|---|---:|---:|---:|---:|
| Stable Cancun | 440,000 | 440,000 | 431,514 | 431,514 |
| Stable Prague | 440,000 | 440,000 | 431,514 | 431,514 |
| Nightly 4e8874b Amsterdam | 440,000 | 440,000 | 438,828 | 438,828 |

Every value has an independently deployed failing value−1 sample. The EntryPoint boundary includes admission policy; the direct boundary bypasses that policy but retains the production postOp guard and validation-produced context.

## Amsterdam trajectory at a 440,000 postOp limit

Checkpoint readings are implementation-body values, after entry modifiers and before the measurement event and modifier epilogue. They are **instrumented** values, not whole-proxy net gas.

| Checkpoint | BALANCE gasleft | CREDIT gasleft |
|---|---:|---:|
| Body entry | 421,153 | 421,153 |
| After entry guard | 420,876 | 420,876 |
| After timestamp | 311,132 | 311,132 |
| After idempotency marker and operator counter | 90,305 | 90,305 |
| After token settlement returns | 237,508 | 157,476 |
| After in-flight delete | 335,227 | 255,195 |
| After protocol revenue write | 223,928 | 143,896 |
| After sponsorship event | 221,752 | 141,720 |
| Maximum consumption among checkpoints | 330,848 | 330,848 |
| Net between first and last checkpoints | 199,401 | 279,433 |

The checkpoint maximum is a lower bound on the true intra-frame peak: it omits the token's own intermediate low points. The instruction reducer follows every postOp/descendant step, adds gas retained in suspended caller frames, and resumes from the engine's actual gas on return. It does not sum the tracer's clamped nonnegative opcode costs. Compact raw step data, including reservoir values, are retained in `run/*-steps.json`.

Full **unmodified proxy frame**, including descendants, from the retained instruction trajectory:

| Mode | Peak consumed | Net consumed at return | Minimum total regular gas remaining | Peak − net |
|---|---:|---:|---:|---:|
| BALANCE | 390,897 | 211,234 | 49,103 | 179,663 |
| CREDIT | 372,998 | 291,266 | 67,002 | 81,732 |

The minimum occurs at the token clone’s `RETURN`, before its remaining state-gas reservoir is returned to the caller: 195,840 reservoir gas for BALANCE and 97,920 for CREDIT. Both postOp traces begin with reservoir zero.

BALANCE has the higher peak despite its lower net. Storage-clear credits returned later in the call tree make the final net a poor estimate of the maximum regular gas needed during execution. These numbers include forwarding overhead and child execution, unlike the instrumented body-only checkpoint deltas.

## Comparison to previous evidence

The existing `SuperPaymasterRR5GuardFail.t.sol::test_RR5_diag_scan_band` is rerun unchanged. Its snapshot/release/re-admit setup is deliberately preserved as the comparison, not imported into the fresh tests.

| Engine | Existing snapshot scan, BALANCE | Existing snapshot scan, CREDIT | Fresh direct, either mode |
|---|---|---|---:|
| Cancun / Prague | settles from 432k; no non-guard failures | same | 431,514 |
| Amsterdam | non-guard failure 440k–568k; settles from 570k | non-guard failure 440k–632k; settles from 634k | 438,828 |

The previous `nosubsidy-attribution` matrix validates **two operations before the first settlement**. Here the bundle contains one operation. In particular, the first matrix settlement leaves aggregate `lockedOf`/`creditReservedOf` outstanding for the second operation; the single-operation settlement clears that aggregate slot. Amsterdam state-gas credits make that difference material. The prior first-frame net numbers (BALANCE 309,496; CREDIT 389,186, with a separate 389,218 counterexample) must not be silently substituted for this single-operation trajectory. Peak and net are separate measurements, and bundle/state history is part of the fixture.

### Sepolia calibration (`rams-rr-matrix`)

The existing calibration records 10/10 strict matches for nightly **4e8874b** against real Sepolia transaction status, receipt gas, first-step frame gas and first-step reservoir. Its predecessor had 10/10 receipt-only matches but 0/10 strict matches. This supports using the specified corrected engine, but does **not** calibrate every later postOp opcode in this new fixture against Sepolia.

The retained phase-2 matrix used 1,080 mined local `handleOps` transactions, 360 cells across R0, RR30M and RRdelta. It found no guard pass/fail changes in 720 R0↔RR comparisons; guard gas was 421,177–421,178, and 439,999 was rejected before postOp. Its 40 outcome changes were state-demand cells, and the exhaustion fixture used an adversarial token. It also documented EntryPoint reimbursement differences under RR. Those are broader reservoir/state-history experiments, not a proof of a universal 440k postOp bound. The present tests are offline Forge measurements; no new Sepolia transaction or public RPC calibration was performed.

## What is not established

- A universal production upper bound across arbitrary bundle sizes, account/token implementations, reservoir regimes, parameters, prices, storage histories or future engines.
- The peak for a **multi-operation bundle**. The trajectory here is single-op. The earlier 2-op matrix has a larger first-op net (CREDIT 389,186), and its peak has not been measured. The final tuple cannot be set from these single-op numbers alone.
- A safe lower replacement for MIN_POST or SETTLE. The 439,999 result is an admission rejection, not a postOp OOG boundary.
- A uniquely identified snapshot implementation defect. The old and fresh setups differ in lifecycle/history as well as snapshot usage.
- A repaired no-subsidy guarantee. Completion and EntryPoint's accounting are distinct; the previous fixed-seed no-subsidy counterexample remains outside this task.
- A new on-chain calibration or validation of the earlier proposed 470k/450k tuple. No gas parameters, production source, or deployment files were changed.

For the studied fresh single-op path, retaining 440k is supported; sizing a universal production limit requires the broader state/bundle/reservoir envelope, not extrapolation from either the net frame or the snapshot band alone.

## Reproduction and evidence

From the repository root:

```sh
PROFILE_DEPS_ROOT=/Users/jason/Dev/aastar/SuperPaymaster \
  script/evidence/postop-gas-profile-run.sh \
  docs/design/aoa-balance-mode/data/postop-gas-profile/run
```

Omit `PROFILE_DEPS_ROOT` when local dependencies are populated. In this worktree it supplies read-only Chainlink/Solady remappings; Forge's attempted automatic submodule installation prints warnings, but compilation uses those remappings. Build/cache/debug temporary files are kept under `/tmp`, outside the output directory. The output must initially be empty.

For direct test invocation, set `PROFILE_AMSTERDAM=true` on the Amsterdam engine; the runner records and supplies this explicit expectation selector. The other two engines use `false`.

Each engine uses `--offline`; Amsterdam additionally uses `--no-isolate --evm-version prague --hardfork amsterdam`. Commands, scoped profile environment, engine versions, repository HEAD, source hashes, exits, summaries and compact trajectories are retained. The verdict rejects nonzero exits, empty/missing logs, wrong test counts, changed exact thresholds or checkpoint numbers, missing adjacent samples, and changed snapshot bands. Production source hashes are checked before/after. All changes are left uncommitted.

Final run: **292 Forge commands, all exit 0**, comprising **328 passing test executions**, zero failures and zero skips. Cancun: 106; Prague: 106; Amsterdam: 116. Each engine's main suite passes 14/14; the remaining executions are single-sample searches, two snapshot diagnostics per engine, and two Amsterdam instruction captures.

The runner and final verifier both exit **0**. Probe provenance, Solidity formatting and shell syntax checks pass. Separate negative checks confirm that an empty log with exit 0 is rejected, a nonzero command exit is rejected, and a nonempty output directory is rejected with exit 2 without modifying its existing file.

See [verdict](run/verdict.txt), [numbers](run/numbers.json), [per-command exits](run/exits.txt), [verification](run/verification.txt), [input hashes](run/inputs.sha256), and [evidence hashes](run/SHA256SUMS). `contracts/src/` hashes match before and after the run. No commit was made.

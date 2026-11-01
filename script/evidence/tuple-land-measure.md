# Tuple landing: measurement handoff

This step changes no frozen expected value. Run after committing the harness:

```sh
PROFILE_DEPS_ROOT=/Users/jason/Dev/aastar/SuperPaymaster \
  bash script/evidence/tuple-land-measure.sh EMPTY_OUTPUT_DIRECTORY
python3 script/evidence/tuple-land-measure.py --verify EMPTY_OUTPUT_DIRECTORY
```

`--dry-run` prints the twelve commands without writing or executing Forge.
Measurement requires a clean working tree and an empty output directory. Builds
are temporary. Each engine/mode/budget gets a fresh Forge process. The 480000
runs select `TUPLE_480=true` (480000/450000/5000/450000); the 440000 controls
select the original tuple (440000/420000/5000/340000). A 440000 control under the
new tuple would fail validation and would not reproduce the frozen checkpoints.

The recorder bypasses only checkpoint equality assertions. The existing
trajectory count, operation completion, postOp failure, consumed hash, revenue,
reservation release and debt assertions remain active. The verifier requires
one passing trajectory test and precisely eight indexed checkpoints per log.
Controls must equal the arrays read with `git show <head.txt>:<test source>`.
Verification needs the recorded commit in the local object database, but does
not use current working-tree expectations or execute Forge.

## Sources for all 14 frozen tests

Paths below are relative to `docs/design/aoa-balance-mode/data/tuple-480/`
unless stated otherwise. These are instructions for the later assertion update;
no assertions are updated here. A = Amsterdam, C = Cancun, P = Prague.

| # | Test | Values for the accepted tuple | Source |
|---|---|---|---|
| 1 | GasMatrix `test_matrix_balance_success` | MIN=480000, SETTLE=450000, WRAP=5000, POSTOP=450000 | `REPORT.md`, Recommendation (accepted configuration, not a gas measurement) |
| 2 | GasMatrix `test_matrix_balance_revert` | Same four constants | Same |
| 3 | GasMatrix `test_matrix_credit_success` | Same four constants | Same |
| 4 | GasMatrix `test_matrix_credit_revert` | Same four constants | Same |
| 5 | GasMatrix `test_matrix_combined` | Same four constants | Same |
| 6 | ProfileBalance `test_direct_minimum` | A=469305; C/P=461990 | `measurements.json`, `boundaries`, settle=450000, credit=false, legacy=false, nonfresh=false; `REPORT.md` R4 |
| 7 | ProfileCredit `test_direct_minimum` | A=469305; C/P=461990 | Same boundary rows with credit=true |
| 8 | ProfileBalance `test_entrypoint_minimum` | Submitted minimum=480000; completion=true | Accepted MIN in `REPORT.md`; successful balance bundle `run/multi-2-0-0.log`; new balance trajectory logs also assert single-op completion at 480000 on all three engines |
| 9 | ProfileCredit `test_entrypoint_minimum` | Submitted minimum=480000; completion=true | Same accepted MIN; credit bundle `run/multi-2-1-0.log`; new credit trajectory logs also assert single-op completion on all engines |
| 10 | ProfileBalance `test_search_sample` | Default budget / real-EP threshold=480000; direct threshold A=469305, C/P=461990 | Accepted MIN plus boundary rows in #6; completion corroboration in #8 |
| 11 | ProfileCredit `test_search_sample` | Default budget / real-EP threshold=480000; direct threshold A=469305, C/P=461990 | Accepted MIN plus boundary rows in #7; completion corroboration in #9 |
| 12 | ProfileBalanceTrajectory `test_trajectory` | Budget=480000; eight checkpoints per engine, not yet measured | NEW output `checkpoints.json`: `[engine]["balance"]["480000"]`, independently re-parsed from `<engine>-balance-480000.log` |
| 13 | ProfileCreditTrajectory `test_trajectory` | Budget=480000; eight checkpoints per engine, not yet measured | NEW output `checkpoints.json`: `[engine]["credit"]["480000"]`, independently re-parsed from `<engine>-credit-480000.log` |
| 14 | MultiOp `test_bundle` | Default budget and validation floor=480000; default completed/settled/hits=2 | Accepted MIN; `run/multi-2-0-0.log` (default N=2, balance, shared operator); default count remains unchanged |

The six control arrays come from the frozen source at the new run's `head.txt`:
Amsterdam credit/balance use their respective arrays; Cancun and Prague share
the stable credit/balance arrays. The control values are not replacements for
the new-tuple arrays. Existing multi-op opcode trajectories are not substitutes
for the instrumented ProfilePaymaster checkpoints.

No other measured scalar is missing for these fourteen tests. The matrix's
four tuple fields and EntryPoint's configured validation floor are configuration
values. The direct thresholds are already measured at adjacent integer budgets,
with completion at the boundary. Existing minus-one tests must later move with
the corresponding thresholds, though they are not among these fourteen failing
tests. This step deliberately leaves all those assertions unchanged.

# Accepted gas tuple assertion landing

Changes are uncommitted. Production sources and archived evidence are unchanged.

Evidence paths below are relative to `docs/design/aoa-balance-mode/data/`.
A = Amsterdam; C/P = stable Cancun/Prague. Old tuple = (440000,420000,5000,340000);
accepted tuple = (480000,450000,5000,450000).

| Test | Old frozen value | New frozen value | Evidence file + field |
| --- | --- | --- | --- |
| GasMatrix `test_matrix_balance_revert` | Old tuple | Accepted tuple | `tuple-480/REPORT.md`, Recommendation; `script/evidence/tuple-land-measure.md`, rows 1–5 |
| GasMatrix `test_matrix_balance_success` | Old tuple | Accepted tuple | `tuple-480/REPORT.md`, Recommendation; `script/evidence/tuple-land-measure.md`, rows 1–5 |
| GasMatrix `test_matrix_combined` | Old tuple | Accepted tuple | `tuple-480/REPORT.md`, Recommendation; `script/evidence/tuple-land-measure.md`, rows 1–5 |
| GasMatrix `test_matrix_credit_revert` | Old tuple | Accepted tuple | `tuple-480/REPORT.md`, Recommendation; `script/evidence/tuple-land-measure.md`, rows 1–5 |
| GasMatrix `test_matrix_credit_success` | Old tuple | Accepted tuple | `tuple-480/REPORT.md`, Recommendation; `script/evidence/tuple-land-measure.md`, rows 1–5 |
| PostOpProfileBalanceTest `test_direct_minimum` | A 438828; C/P 431514 | A 469305; C/P 461990 | `tuple-480/measurements.json`, `boundaries[engine, settle=450000, credit=false, legacy=false, nonfresh=false].boundary` |
| PostOpProfileBalanceTest `test_entrypoint_minimum` | 440000 | 480000 | `tuple-480/REPORT.md`, Recommendation; `script/evidence/tuple-land-measure.md`, rows 8–9 |
| PostOpProfileBalanceTest `test_search_sample` | Default/EP 440000; direct A 438828, C/P 431514 | Default/EP 480000; direct A 469305, C/P 461990 | `script/evidence/tuple-land-measure.md`, rows 10–11; boundary fields above |
| PostOpProfileCreditTest `test_direct_minimum` | A 438828; C/P 431514 | A 469305; C/P 461990 | `tuple-480/measurements.json`, `boundaries[engine, settle=450000, credit=true, legacy=false, nonfresh=false].boundary` |
| PostOpProfileCreditTest `test_entrypoint_minimum` | 440000 | 480000 | `tuple-480/REPORT.md`, Recommendation; `script/evidence/tuple-land-measure.md`, rows 8–9 |
| PostOpProfileCreditTest `test_search_sample` | Default/EP 440000; direct A 438828, C/P 431514 | Default/EP 480000; direct A 469305, C/P 461990 | `script/evidence/tuple-land-measure.md`, rows 10–11; boundary fields above |
| PostOpProfileBalanceTrajectoryTest `test_trajectory` | Budget 440000; amsterdam: [421153, 420876, 311132, 90305, 237508, 335227, 223928, 221752]; cancun: [428353, 428076, 406352, 361565, 317428, 317227, 293948, 291772] (Prague = Cancun) | Budget 480000; amsterdam: [460528, 460251, 350507, 129680, 276883, 374602, 263303, 261127]; cancun: [467728, 467451, 445727, 400940, 356803, 356602, 333323, 331147] (Prague = Cancun) | `tuple-land/run/checkpoints.json`, `[engine]["balance"]["440000"/"480000"]` |
| PostOpProfileCreditTrajectoryTest `test_trajectory` | Budget 440000; amsterdam: [421153, 420876, 311132, 90305, 157476, 255195, 143896, 141720]; cancun: [428353, 428076, 406352, 361565, 311016, 310815, 287536, 285360] (Prague = Cancun) | Budget 480000; amsterdam: [460528, 460251, 350507, 129680, 196851, 294570, 183271, 181095]; cancun: [467728, 467451, 445727, 400940, 350391, 350190, 326911, 324735] (Prague = Cancun) | `tuple-land/run/checkpoints.json`, `[engine]["credit"]["440000"/"480000"]` |
| PostOpMultiOpTest `test_bundle` | Default/floor 440000; completed/settled/hits = 2 | Default/floor 480000; completed/settled/hits = 2 | `script/evidence/tuple-land-measure.md`, row 14; `tuple-480/run/multi-2-0-0.log` |

Adjacent negative controls follow the same measured thresholds: EntryPoint 479999
rejects; direct A 469304 and C/P 461989 reject. Amsterdam's stable-boundary guard
control moves from 431514 to 461990.

The multi-op JSON is copied from `tuple-480/run/numbers.json` (24 cases, 80 operations).
Mapping: `amsterdam-N-MODE-same/distinct` maps to `multi-N-PATTERN-0/1`, where
balance/credit/mixed-bc/mixed-cb map to 0/1/2/3. Every initial, minimum_remaining,
peak, net and terminal field comes directly from that case. Maximum peak remains
391239. No value is extrapolated from the old budget.

## Remaining old-number audit

- `SelectedGasFixtures`: the default is the accepted deployment tuple from `DeploymentGasFixtures`.
  TUPLE_CANDIDATE=true still selects 470000/450000/5000/450000, and TUPLE_480=true takes precedence.
  There is no historical-tuple selector. Archived runs (tuple-validation, tuple-480, tuple-land) are
  bound to their recorded revisions and are reproduced by checking those revisions out.
- Profile trajectory: only the 480000 arrays remain. The 440000 control arrays are read by
  `tuple-land-measure.py --verify` from the test source at its recorded revision `3670d57a`.
- `SuperPaymasterV55Fuzz.t.sol`: `_r(440_000)` is a random execution-gas range,
  not a deployment parameter; unchanged.
- `SuperPaymasterV3_Pricing.t.sol`: 114400001 is a price rounding assertion; unchanged.
- `RamsARouteRehearsal.t.sol`: deployment queue, readback, signed operations and
  tuple hash now use the accepted tuple; alternate SETTLE=160000 is preserved.
- `RamsABudget.t.sol`: sponsored allowance changes to 480000. Its arithmetic
  expectations become 2590000 required gas, 0.00259 ETH, and 310.8 tokens, derived
  by its existing prefund/reservation formulas (not measured execution costs).

## Verification

Stable Cancun: 162 suites, 1831 passed, 0 failed, 65 skipped (1896 total).
Stable Prague: 162 suites, 1711 passed, 0 failed, 39 skipped (1750 total).
Amsterdam: 162 suites, 1696 passed, 7 failed, 39 skipped (1742 total).
All 14 updated tests pass. Historical 440000 Amsterdam trajectories: 2 passed,
0 failed, 0 skipped, with TUPLE_480=false, TUPLE_CANDIDATE=false and
TRAJECTORY_BUDGET=440000. Python executor: 141 passed, 0 failed (Homebrew Python;
system Python 3.9 lacks required standard-library tomllib).

Archived verification: tuple-land (12 trajectories, six old controls), tuple480,
and tuple-validation pass. `rr5-lifecycle-run.py` and its run are absent from HEAD;
only the distinct `rr5-guard-fail-run.sh` archive exists. Lifecycle verification
cannot be claimed.

### Amsterdam failures and baseline proof

Registered RR-5 failures: `test_RR5_exactSelector_adjacentBoundary` in both
balance/credit contracts, plus `test_RR5_snapshot_not_live_bound` (three total).

| Alternate-floor test | Current accepted tuple | Parent old tuple | Cached mainline old tuple |
| --- | --- | --- | --- |
| SuperPaymasterV55PostOpBoundTest.test_rule_under_all_floor_params | FAIL | FAIL | FAIL |
| SuperPaymasterV55GasParamsTest.test_settle_floor_keeps_no_oog_band | FAIL | FAIL | FAIL |
| SuperPaymasterV55FuzzTest.testFuzz_G2_floor_params | FAIL | FAIL | FAIL |
| SuperPaymasterV55FuzzTest.test_G2_coverage_replay_floor_params | FAIL | FAIL | FAIL |

Parent: `3670d57ae63dcc4a63ff83a05bbf8b34ea41758a` (`HEAD^`).
Cached mainline: `45e996af` (`origin/main`). Local `main` at `3b0d4821` predates
these tests, so it is not the mainline baseline. No refs were fetched or changed.
Both baselines were extracted with `git archive` into independent temporary
folders; original test/production sources and old deployment tuple were retained.
Each baseline run: **3 suites, 0 passed, 4 failed, 0 skipped (4 total)**.

Both used the pinned nightly with `PROFILE_AMSTERDAM=true` and:

```sh
forge test --no-isolate --evm-version prague --hardfork amsterdam \
  --match-path 'contracts/test/v2/SuperPaymasterV55*.t.sol' \
  --match-test 'test_rule_under_all_floor_params|test_settle_floor_keeps_no_oog_band|testFuzz_G2_floor_params|test_G2_coverage_replay_floor_params' \
  --fuzz-seed 0x747beb88c8834abdd140cd1c6fba159cd533dca858baccb3a8bccd984f6539c3
```

Local run logs: [Cancun](/tmp/tland-cancun.log), [Prague](/tmp/tland-prague.log),
[Amsterdam](/tmp/tland-amsterdam.log), [parent](/tmp/tland-parent.log),
[cached mainline](/tmp/tland-origin-main.log), [historical trajectories](/tmp/tland-historical.log),
[Python](/tmp/tland-python.log).

`git diff --check` passes. No production source, archived data, release evidence,
or `script/b-layer` file was modified; no changes were committed.

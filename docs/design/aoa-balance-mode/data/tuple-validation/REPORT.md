# Tuple validation

2026-10-31. Worktree-only parameter experiment; production contracts and the original
`DeploymentGasFixtures.sol` are unchanged. Results below concern the canonical EntryPoint
v0.7 runtime and Amsterdam nightly `4e8874b`, with stable Cancun/Prague controls.

**Decision:** the candidate repairs the demonstrated reimbursement shortfall and adds
no non-frozen test regressions. The observed 15%-margin tuple is
**470000/450000/5000/450000**. It does **not** resolve the three Amsterdam RR-5 failures,
so an unconditional all-properties-safe replacement tuple is not established.

## Shortfall accounting

**Yes: the retained current-tuple counterexample loses 5,785 gas, or
10,788,338,725,450 wei at 1,864,881,370 wei/gas.** CREDIT settlement succeeds after
user execution reverts. The fresh state includes the user's rate-limit timestamp,
SP idempotency marker, first operator transaction counter, and first protocol revenue.
Revert is the observed execution path, not the cause of the storage cost: the prior
matrix measures the same postOp cost for success and revert with equivalent state.

The source formula (`SuperPaymaster.sol`, postOp) for a current 384-byte context is:

```
B = C_POSTOP + C_WRAP + ceil((callGasLimit + postOpGasLimit) / 10)
aGas = ceil((P + B * gasPrice) * price * 1e18 / (10**decimals * aPriceUSD))
charge = min(a0, ceil(aGas * (10000 + feeBps) / 10000))
netChargeWei = floor(floor(charge * 10000 / (10000 + feeBps))
                     * 10**decimals * aPriceUSD / (price * 1e18))
```

The gas tuple, prices and fee come from the validation snapshot. The reservation cap
`a0` can constrain charges; it does not bind this counterexample. A legacy 352-byte
context instead uses `postOpGasLimit + LEGACY_C_WRAP_GAS`, a different formula.

EntryPoint v0.7 `_postExecution` adds its measured postOp/wrapper cost to the cost
passed to SP, then applies `floor(max(0, callGasLimit + postOpGasLimit -
executionGasUsed) / 10)`. Here `executionGasUsed` includes execution, postOp and
EntryPoint overhead since `preOpGas`; it is not merely gas consumed by the user call.
The penalty has no 40,000-gas waiver in this v0.7 source. Final cost is gas times the
operation's effective gas price. Transaction-end refund accounting is not substituted
for the UserOperationEvent cost.

| Exact retained counterexample item | Gas or value |
|---|---:|
| callGasLimit | 285,665 |
| postOpGasLimit (above MIN 440,000) | 465,691 |
| combined execution allowance | 751,356 |
| preOpGas from innerHandleOp | 548,219 |
| P / gasPrice | 559,825 |
| user execution + pre-postOp overhead: 559,825 − 548,219 | 11,606 |
| whole SP proxy postOp frame | 389,218 |
| EntryPoint postOp wrapper | 1,834 |
| actual gas before penalty | 950,877 |
| executionGasUsed: 950,877 − 548,219 | 402,658 |
| unused execution/postOp gas | 348,698 |
| EntryPoint penalty: floor(348,698 / 10) | 34,869 |
| final actualGasUsed | 985,746 |
| F − P, gas equivalent | 425,921 |
| C_POSTOP + C_WRAP | 345,000 |
| SP budget term: ceil(751,356 / 10) | 75,136 |
| charge coverage beyond P | 420,136 |
| shortfall: 425,921 − 420,136 | **5,785** |

Price = 200,000,000,000 with eight decimals; aPriceUSD = 19,256,000,000,000,000;
protocol fee = 1,000 bps. Exact `aGas` is 189,812,111,780,906,730,370;
charge/debt is 208,793,322,958,997,403,407. Converting that charge back with both
floors gives 1,827,511,012,226,570 wei, versus EntryPoint's
1,838,299,350,952,020 wei. No rounding discrepancy explains away the loss.

Inputs are independently decoded and checked by
`contracts/test/tuple_validation_evidence_test.py` from the retained
[nosubsidy frame](../nosubsidy-attribution/counterexample-frame-amsterdam.log) and
[G-7 EntryPoint trace](../rams-g7/mechanism-g2-trace.log). The 1,834 wrapper value
is the exact residual of EntryPoint's gas identity using the retained frame and
preOpGas, not a claim that every operation has this wrapper cost.

## Selection and evidence method

`SelectedGasFixtures.sol` selects the candidate only when `TUPLE_CANDIDATE=true`.
Its default values remain 440000/420000/5000/340000, and the original
`DeploymentGasFixtures.sol` is byte-for-byte unchanged. Consumers use runtime-selected
limits for operation budgets, sweeps and charge expectations. Explicit all-floor tests
still queue their own tuple. The original gas matrix, gas-profile checkpoints and
multi-op 440000 assertions are preserved; their failures with a different tuple are
reported below, not suppressed or rewritten.

The runner uses a fresh fuzz-failure directory per invocation and records a fixed
`0x5eed` fuzz seed, engine versions, command arguments, selectors, exit codes, source
hashes, and per-test outcomes. It rejects a nonempty evidence directory. Full-suite
commands have no test filter. Amsterdam uses `--no-isolate --evm-version prague
--hardfork amsterdam`; stable Cancun uses the default target, and stable Prague uses
`--evm-version prague`. The existing stable per-test isolation annotations remain.

Build outputs are disposable. Cancun runs in a `/tmp` mirror with identical checked
contract/test sources, because deployment-script tests require a literal `out/` directory.
This preserves their artifact and metadata checks without editing deployment scripts or
creating a root-level artifact path in this worktree. Other engines use private build
paths under `contracts/test/`. Three test artifact readers now honor `FOUNDRY_OUT`,
defaulting to `out`. Missing-submodule installation warnings are not hidden; explicit
read-only dependency remappings resolve the local dependencies.

The 24-case Amsterdam multi-op matrix covers N=2/3/5, BALANCE/CREDIT/two alternating
orders, and same/distinct accounts: 80 operations. Whole-proxy trajectories are reduced
from the engine debug arena, including descendant gas retained by ancestors and signed
Amsterdam state-gas effects. EntryPoint's unused-gas penalty is separately extracted
at the canonical runtime's DIV instruction (PC 7838), retaining numerator and denominator.
The charge is not compared with transaction-end gas after refunds.

The evidence verifier requires the complete 46-command inventory, exact selectors,
completed test counts, exit/status consistency, all 24 trajectories and 80 frames,
trajectory arithmetic, the 15% peak/net bounds, penalty arithmetic, and source/file hashes.
A resealed missing-command control must fail. The original current-tuple G2 failure is
also a live negative control for the reimbursement gate.

## Results

Full suites use stable Forge 1.7.1 (`4072e487`) and Amsterdam 1.8.7-nightly
(`4e8874b`). Counts include the existing runtime-dependent skips; no new skip was added.

| Engine / tuple | Passed | Failed | Skipped | Exit |
|---|---:|---:|---:|---:|
| Amsterdam / current | 1693 | 9 | 39 | 1 |
| Amsterdam / candidate | 1681 | 21 | 39 | 1 |
| Stable Cancun / current | 1830 | 0 | 65 | 0 |
| Stable Cancun / candidate | 1816 | 14 | 65 | 1 |
| Stable Prague / current | 1710 | 0 | 39 | 0 |
| Stable Prague / candidate | 1696 | 14 | 39 | 1 |

The Amsterdam baseline has the six G-7 failures **plus three RR-5 failures**, which
were added to this repository after the G-7 report. They are not nine new G-7 failures.

| Original G-7 failure | Current Amsterdam | Candidate Amsterdam | Reason |
|---|---|---|---|
| `testFuzz_G2_I8_I9_I10_conservation` | FAIL | **PASS, 1000 runs** | Larger charge buffer covers measured final EntryPoint costs |
| `test_G2_coverage_replay_fixed_seeds` | FAIL | **PASS, 1000 seeds** | Zero subsidized settled operations; original assertion retained |
| `testFuzz_G2_floor_params` | FAIL | FAIL | Explicit alternate floor tuple; not the candidate |
| `test_G2_coverage_replay_floor_params` | FAIL | FAIL | Explicit alternate floor tuple; settlement failure retained |
| `test_settle_floor_keeps_no_oog_band` | FAIL | FAIL | Explicit SETTLE floor still admits a non-guard failure |
| `test_rule_under_all_floor_params` | FAIL | FAIL | Explicit C_POSTOP 175000 remains below measured 15% need 335316 |

Both reimbursement tests pass on both stable engines with both tuples. The candidate
fixed-seed Amsterdam replay settles 4,189 operations and reports `SUBSIDY: 0 0 0`.
The separate accounting command reproduces the exact old 5,785-gas counterexample.
Changing the minimum changes generated reservations/admission and subsequent campaign
paths: the candidate replay is the same seed campaign, not a claim that its operation
hashes or every branch remain identical to the old run.

The **only new failures** on all three engines are these fourteen frozen expectations:

- Five `SuperPaymasterPostOpGasMatrixTest.test_matrix_*` tests assert the original
  440000/420000/5000/340000 tuple and reject 470000 immediately.
- In each of `PostOpProfileBalanceTest` and `PostOpProfileCreditTest`,
  `test_direct_minimum`, `test_entrypoint_minimum`, and `test_search_sample` still
  require the original direct boundary / 440000 allowance: six failures.
- Both profile `test_trajectory` tests still submit 440000: two failures before
  any frozen checkpoint can be evaluated.
- `PostOpMultiOpTest.test_bundle` defaults to 440000 and rejects the new validation
  floor: one failure. Separate candidate matrix commands explicitly submit 470000.

No previously passing non-frozen test changes to failure. Skips are unchanged within
each engine. The full keyed comparison is in `run/statuses.json`; failure reasons
and every test outcome are retained in the six `run/full-*.log` files.

## Guard results and the unresolved RR-5 scope

Fresh direct-call samples in both modes reject **469304** with the exact
`PostOpGasTooLow()` selector and complete at **469305**. Samples at 450001 reject
with that selector; 470000 completes. Real EntryPoint samples complete at 470000
and reject 469999 with exact `FailedOp(0, "AA34 signature error")`.

Thus the measured fresh fixture has no non-guard failure at its admission boundary.
The call-gas boundary is **19305 above SETTLE=450000**, reflecting proxy forwarding
and work before the implementation guard. It is only **695 below MIN_POST=470000**.
Do not replace this boundary with `MIN_POST - peak`: those are different questions
and different measurement boundaries.

**Not every admitted postOp completes across the retained test setups.** Amsterdam
RR-5 still fails the adjacent-boundary test in both modes and the CREDIT
`test_RR5_snapshot_not_live_bound` test at its fixed 600000 call allowance. The
snapshot/release/re-admit diagnostic reports these candidate bands (2k sampling):

| Mode | Last guard rejection | Non-guard failures | First completion |
|---|---:|---:|---:|
| BALANCE | 468000 | 470000–568000 | 570000 |
| CREDIT | 468000 | 470000–632000 | 634000 |

The current-tuple bands begin at 440000 and end at the same 568000 / 632000.
The candidate narrows their lower end; it does not eliminate them. The RR-5
real-EntryPoint negative control and stale-recovery tests pass in both modes.
All RR-5 tests pass on stable Cancun and Prague with the candidate; their direct
snapshot guard boundary is 461990, a different fixture from the fresh boundary above.

These results agree with the earlier fresh-versus-snapshot reports. They do not isolate
whether the remaining difference is snapshot reservoir restoration, release/re-admit
history, or another aspect of that lifecycle. It would be incorrect to report these
three failures as fixed, or to promote the fresh measurements into a universal guard
proof.


## Candidate peak, net and reimbursement margins

All 24 candidate matrix cases and all 80 operations complete at 470000. There are no
PostOpRevertReason events. The maximum **peak remains 391239**, with **78761 gas**
remaining at the lowest point (16.76% of the initial allowance). It occurs in the
first operation of same-user all-BALANCE N=2/3/5 and BALANCE-first alternating N=3/5.
Maximum **net remains 389186**, in first-use same-user CREDIT paths. Raising the
allowance does not change these observed frame costs.

The retained `worst-net-0.log` and `worst-net-1.log` compare N=5, same-user, all-CREDIT
bundles. For their first operation, fee = 1 gwei and P = 990573000000000 wei:

| First operation accounting, gas-equivalent | Current (440000 post limit) | Candidate (470000 post limit) |
|---|---:|---:|
| callGasLimit | 300000 | 300000 |
| preOpGas | 875285 | 875285 |
| P / fee | 990573 | 990573 |
| whole SP proxy net | 389186 | 389186 |
| EntryPoint wrapper | 1837 | 1837 |
| pre-penalty actual gas | 1381596 | 1381596 |
| executionGasUsed | 506311 | 506311 |
| unused execution/postOp gas | 233689 | 263689 |
| EntryPoint penalty | 23368 | **26368** |
| final actualGasUsed | 1404964 | 1407964 |
| SP budget term | 74000 | 77000 |
| C_POSTOP + C_WRAP + budget term | 419000 | 532000 |
| net charge, gas-equivalent | 1409573 | 1522573 |
| reimbursement margin | **4609** | **114609** |

Candidate net charge = 1522573000000000 wei; final cost = 1407964000000000 wei;
margin = **114609000000000 wei**. The token's fee-inclusive CREDIT charge is
167483030000000000000 aPNTs units; removing the 1000-bps fee and applying the
snapshot price yields exactly that net charge, with no rounding residual.

`penalties.json` retains the candidate first operation's actual DIV inputs:
2636890 / 100 = 26368, floor. Together with the pinned EntryPoint formula and the
unchanged pre-penalty cost, this establishes the old penalty of 23368. The higher
allowance adds **3000 penalty gas**, and also **3000 budget-allowance gas** to SP's
charge. The remaining **110000** increase in the reimbursement margin comes from
C_POSTOP. The current multi-op sample was already reimbursed despite its frame
exceeding 340000; it is not the 5785-gas reverting G2 counterexample.

For the retained original reverting operation, **holding execution/frame/wrapper gas
fixed** and increasing its post limit from 465691 to 495691 gives penalty 37869,
buffer 533136 and a **104215-gas** margin. This is an algebraic counterfactual,
not a newly measured replay of that exact operation hash. The measured candidate
claims are the passing G2 campaign and the independent worst-net matrix above.

## Recommendation and smallest tuple under the frozen rule

**Raise C_POSTOP to 450000 for the measured EntryPoint paths.** The smallest rounded
tuple supported by the frozen 15% rule and these measurements is:

```
queueGasParams(470000, 450000, 5000, 450000)
               MIN     SETTLE  WRAP  C_POSTOP
```

| Constraint / margin | Value |
|---|---:|
| Larger retained whole-proxy net sample | 389218 |
| ceil(1.15 × 389218), then round up to 5000 | 447601 → 450000 |
| C_POSTOP above that net sample | 60782, **15.616%** |
| ceil(1.15 × measured peak 391239), then round up to 5000 | 449925 → 450000 |
| Rounded peak allowance above measured peak | 58761, **15.019%** |
| MIN_POST above measured outer-proxy peak | 78761 |
| MIN_POST − SETTLE | 20000 |
| MIN_POST above measured fresh direct guard boundary | 695 |
| C_WRAP above worst-net sample's measured EP wrapper | 3163 |
| Worst-net sample reimbursement margin, after EP penalty | 114609 |

The peak-versus-SETTLE comparison is the conservative sizing rule, **not** a claim
that the outer-proxy peak is measured at the implementation guard. The separately
measured 469305 boundary is what establishes the small 695-gas admission reserve.

A 445000 rounded bound fails both the 447601 net requirement and the 449925 peak
requirement. 450000 is therefore the smallest 5000-step bound under this policy;
MIN=SETTLE+20000 gives 470000. C_WRAP stays at its existing administrative minimum.
For this single original counterexample, an algebraic C_POSTOP increase of only 5785
would close its deficit; that would not satisfy the frozen whole-frame margin rule.

`SuperPaymasterAdmin._checkGasParams` requires SETTLE in [155000,1000000],
MIN ≥ SETTLE+20000 and MIN ≤ 2000000, C_POSTOP in [175000,MIN], and C_WRAP in
[5000,50000]. The candidate satisfies every constraint and is actually queued and
executed by the tests, rather than merely substituted into an off-chain equation.

**This is a scoped parameter recommendation, not an all-properties sign-off.** It
repairs the demonstrated reimbursement gate, completes the fresh single/multi-op
measurements, and introduces no new non-frozen full-suite failures. A larger tuple
is not needed for those measured gates.

If “passes” includes every retained Amsterdam guard assertion, the candidate is
insufficient and **no smallest all-properties-passing tuple is established here**.
Simply raising SETTLE past the observed ~634k snapshot completion region would make
the unchanged fixed-600k snapshot test reject at the guard. Explicit all-floor tests
queue a different tuple, and the frozen 440000 tests intentionally cannot accept this
higher minimum. Consequently, presenting a larger tuple as making this unchanged
suite wholly green would be false. The snapshot lifecycle needs reconciliation
before an unconditional deployment recommendation; this report does not replace
that unresolved behavior with a guessed larger bound.

## What is not established

- Universal reimbursement or completion for all states, operation values, account/token
  implementations, oracle/fee configurations, context versions, or future engines.
- Elimination or root-cause attribution of the three Amsterdam RR-5 failures, or
  safety of every tuple permitted by the administrative bounds.
- A production-safe intrinsic lower limit, or a proof that the 695-gas fresh admission
  reserve survives other proxy/entry/context paths.
- Bundles larger than five or an exhaustive state-gas reservoir study. The G2 fuzz and
  fixed seeds broaden coverage but do not prove a maximum.
- Reimbursement of deliberately injected postOp settlement failures; the original
  conservation/rollback tests retain their separate treatment of those failures.
- Production deployment, bundler estimation, a live-network loss estimate, or a change
  to production defaults. Nothing was committed or deployed.

## Reproduce and verify

From the repository root, with the stated local Foundry engines installed:

```sh
PROFILE_DEPS_ROOT=/Users/jason/Dev/aastar/SuperPaymaster \
  bash script/evidence/tuple-validation-run.sh EMPTY_OUT_DIR
python3 script/evidence/tuple-validation-run.py --verify EMPTY_OUT_DIR
python3 contracts/test/tuple_validation_evidence_test.py EMPTY_OUT_DIR
```

The optional `TUPLE_BUILD_ROOT` reuses generated compiler artifacts under
`contracts/test/`; `TUPLE_CANCUN_ROOT` reuses a source-checked disposable `/tmp` mirror.
Neither option selects a tuple. The runner explicitly selects each tuple and ignores
ambient G2/PROFILE/MULTI/TUPLE/FOUNDRY experiment overrides when launching Forge.

The retained run has **41 Forge exits of 0 and 5 exits of 1**. The five nonzero exits
are the two Amsterdam full suites, the candidate Cancun and Prague full suites,
and the original-tuple accounting negative control. They are explained above, not
converted to passing test results. All 24 candidate matrix commands, 12 fresh
boundary/admission commands, and two worst-net trace commands exit 0.

| Evidence/check | Exit |
|---|---:|
| Full runner and embedded fail-closed verifier | 0 |
| Standalone verifier | 0 |
| Python accounting/evidence tests: 3 tests, including three tamper subcases | 0 |
| Resealed missing-command negative control | 1, required rejection |
| Runner pointed at the nonempty retained directory | 1, required rejection |
| Git whitespace and unchanged production/default-fixture checks | 0 |

Files: [runner](../../../../../script/evidence/tuple-validation-run.py),
[wrapper](../../../../../script/evidence/tuple-validation-run.sh),
[selected helper](../../../../../contracts/test/helpers/SelectedGasFixtures.sol),
[fresh boundary tests](../../../../../contracts/test/v2/SuperPaymasterTupleValidation.t.sol),
[accounting/verifier tests](../../../../../contracts/test/tuple_validation_evidence_test.py),
[outcome changes](outcome-changes.tsv), [run inventory](run/commands.jsonl),
[measurements](run/numbers.json), [penalty operands](run/penalties.json),
[verdict](run/verdict.txt), [hashes](run/SHA256SUMS), and [validation](validation.log).
All source edits and retained evidence are in `contracts/test/`, `script/evidence/`,
and `docs/`; `contracts/src/` and the committed deployment fixture remain unchanged.

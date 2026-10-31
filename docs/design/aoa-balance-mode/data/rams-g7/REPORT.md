# CC-127 / G-7 — Amsterdam fixture repair and retained mechanism results

Local offline experiment, 2026-10-30. **Not an all-green Amsterdam result.** No contract source, Foundry configuration, or deployment script was changed. No commit, push, network access, or live-chain transaction. Engine and exact flags: [commands.md](commands.md).

## Full-suite results

Counts are pass / fail / skip, from complete raw runs (not merged targeted reruns).

| Runtime | Before | After | Evidence |
|---|---:|---:|---|
| Amsterdam | 1615 / 54 / 39 | 1663 / 6 / 39 | [amsterdam-before.log](amsterdam-before.log), [amsterdam.log](amsterdam.log) |
| Prague | 1669 / 0 / 39 | 1669 / 0 / 39 | [prague-before.log](prague-before.log), [prague.log](prague.log) |
| Cancun | 1789 / 0 / 65 | 1789 / 0 / 65 | [cancun-before.log](cancun-before.log), [cancun.log](cancun.log) |

Re-run from the committed HEAD `3b6c7b57` (clean tree), as the repo's gate commands (CLAUDE.md) prescribe:

| Runtime | Engine / flags | Result | Evidence |
|---|---|---:|---|
| Amsterdam | nightly `4e8874b`, flags as above | 1663 / 6 / 39 (same 6 tests) | [amsterdam-rerun-head.log](amsterdam-rerun-head.log) |
| Prague gate | stable forge 1.7.1, `forge test --offline --evm-version prague` | 1677 / 0 / 39 | [gate-prague-forge171.log](gate-prague-forge171.log) |
| Cancun gate | stable forge 1.7.1, `forge test --offline` | 1797 / 0 / 65 | [gate-cancun-forge171.log](gate-cancun-forge171.log) |

The gate runs report 8 more tests than the nightly `--no-isolate` runs in the table above (1716 vs 1708 and 1862 vs 1854 in total); both have zero failures. The difference comes from the different engine and isolation mode, not from these edits.

The Amsterdam baseline is the supplied exact-tree log; Cancun and Prague baselines were run before edits. Common flags include `--offline --no-isolate --fuzz-seed 0x5eed -vv`; Amsterdam also uses `--evm-version prague --hardfork amsterdam`. Inline per-test isolation/fuzz settings still apply. Different total test counts across compile targets existed before these edits and are not new skips.

## Classification scope

**48 F rows are repaired. Two M rows fail with the queued deployment tuple. Four M† rows deliberately test the older *all-hard-bound-floors* tuple.** M† is a scope qualification: their universal “every allowed configuration works” claim is false on Amsterdam, but they are **not evidence that 440k/420k/5k/340k fails that same property**. Calling these four ordinary stale fixtures and replacing their tuple would erase their original intent. They remain failing, with their original descriptive names and assertions. Thus the requested binary classification cannot honestly treat every residual failure as a failure under the queued tuple; the distinction is explicit below.

F = fixture/parameter repair, verified passing in the final Amsterdam run. M = retained mechanism result under the queued tuple. M† = retained mechanism result for the explicitly different all-floor scope. Root classes: V (verification allowance), S (postOp allocation/floor), N (entry guard/no-OOG scan), P (probe instrumentation), W (measured postOp bound). The initial failure can mask later failures; the two deployment G2 rows document that progression rather than declaring a fixture-only result.

## Shared fixtures and preserved intent

`contracts/test/helpers/DeploymentGasFixtures.sol` is the single definition of the queued tuple **440000 / 420000 / 5000 / 340000**. Its `configure` activates it using owner queue → 48 h + 1 s → execute, before price-sensitive setup. It does not write source-contract storage directly.

- Paymaster verification = **1,150,000**, derived from R-AMS-F2 §1.1's measured fresh-SP SP_RENEW need 998,865, plus 15%, rounded up to 5,000. This also covers the supplied 820,305 first balance-op need. It is a test budget, not a new deployment default.
- Sweep upper endpoint = **506,000**, the configured 440k floor plus 15%; fixed low endpoints and guard/success coverage assertions remain. The bundler sweep upper endpoint derives from all declared operation budgets plus 15%. Seven above-floor cases remain in the nine-case postOp sweep.
- G2's successful execution minimum = **140,000**: successful fresh `hit` through the account measured 114,957 charged gas, adjusted for two 63/64 forwards, plus 15%, rounded up to 5,000. The former EX_OK minimum 100k can OOG at the target's fresh slot; the diagnostic trace shows a failing target frame of 95,278 versus successful target frames of 110,419. EX_REVERT and EX_OOG budgets and all I8/I9/I10/no-subsidy assertions are unchanged.
- Historical 5.4.2 / 5.5.0 bytecode upgrade tests keep their historical implementation/formula. They receive larger operation budgets, not a fictitious GasParams API on old bytecode. The 5.5.0 legacy oracle now substitutes the operation's actual postOp allocation in its existing `postOpGas + 30000` formula (current source legacy branch confirms this formula). The rc1/rc2 test keeps its deliberately distinct VAL/MID tuples and only raises verification allowance.
- D5b's starting tuple is now the deployment tuple. Its *mid-bundle adversarial change* is adjusted to remain distinguishable (NEW_MIN = floor + 400k, NEW_SETTLE = floor + 160k, NEW_CPOSTOP = deployed C_POSTOP + 300k; see §Review round 2 for NEW_SETTLE); the original “buffer differs by >200k” precondition and snapshot bounds are unchanged. This is not an increase in the deployed contract bound.
- Exact-charge oracles substitute the shared parameters; no discriminating bound is loosened. The logging subtraction in the all-floor postOp rule now follows its assertion, so a negative margin reports the bound failure rather than panicking before it.

Every test in the changed test files (92 tests, a conservative superset of paths affected) has named discriminating assertions in [assertion-inventory.md](assertion-inventory.md).

## The 54 original failures

Failure messages below are from the supplied baseline, including fuzz counterexamples. Locations refer to the final test sources. The final status is checked by test name against the full Amsterdam log.

| # | Test | File:line | Baseline failure message | Root cause class / progression | Type | After |
|---|---|---|---|---|---|---|
| 1 | `test_baseline_normalPostOp` | `contracts/test/security/PoC_C04_ForcedPostOpOOG.t.sol:178` | baseline handleOps must not revert | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 2 | `test_fix_minGasFloorIsSufficient` | `contracts/test/security/PoC_C04_ForcedPostOpOOG.t.sol:251` | op at the MIN floor must pass validation and execute | S: old postOp allocation/settlement floor | F | PASS |
| 3 | `test_fix_minGasFloorIsSufficient_creditPath` | `contracts/test/security/PoC_C04_ForcedPostOpOOG.t.sol:268` | postOp must NOT fail at MIN_POST_OP_GAS on the CREDIT path | S: old postOp allocation/settlement floor | F | PASS |
| 4 | `test_fix_verdict` | `contracts/test/security/PoC_C04_ForcedPostOpOOG.t.sol:228` | baseline handleOps must not revert | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 5 | `test_SP_gasless_balance_mode_op_conservation` | `contracts/test/tokens/APNTsCappedSPIntegration.t.sol:216` | FailedOpWithRevert(0, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 6 | `test_SP_withdrawProtocolRevenue_after_ops` | `contracts/test/tokens/APNTsCappedSPIntegration.t.sol:243` | FailedOpWithRevert(0, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 7 | `test_d5b_forward_mid_bundle_upgrade_with_extension_calls` | `contracts/test/v2/SuperPaymasterD5bUpgradeRace.t.sol:275` | FailedOpWithRevert(2, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 8 | `test_d5b_rollback_mid_bundle_with_extension_calls` | `contracts/test/v2/SuperPaymasterD5bUpgradeRace.t.sol:324` | FailedOpWithRevert(2, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 9 | `test_feeSnapshot_feeLoweredMidBundle_chargesValidationFee` | `contracts/test/v2/SuperPaymasterFeeSnapshot.t.sol:222` | FailedOpWithRevert(1, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 10 | `test_feeSnapshot_feeRaisedMidBundle_chargesValidationFee` | `contracts/test/v2/SuperPaymasterFeeSnapshot.t.sol:208` | FailedOpWithRevert(1, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 11 | `test_feeSnapshot_forward_prevReleaseContext_usesLiveFee` | `contracts/test/v2/SuperPaymasterFeeSnapshot.t.sol:239` | FailedOpWithRevert(1, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 12 | `test_feeSnapshot_rollback_prevReleaseSettlesNewContext` | `contracts/test/v2/SuperPaymasterFeeSnapshot.t.sol:260` | FailedOpWithRevert(1, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 13 | `test_control_rc1_stays_chargesLiveFee` | `contracts/test/v2/SuperPaymasterRc1Rc2MidBundle.t.sol:466` | FailedOpWithRevert(2, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 14 | `test_control_rc2_stays_chargesSnapshotFee` | `contracts/test/v2/SuperPaymasterRc1Rc2MidBundle.t.sol:450` | FailedOpWithRevert(2, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 15 | `test_rc1_to_rc2_forward_mid_bundle` | `contracts/test/v2/SuperPaymasterRc1Rc2MidBundle.t.sol:399` | FailedOpWithRevert(2, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 16 | `test_rc2_to_rc1_rollback_mid_bundle` | `contracts/test/v2/SuperPaymasterRc1Rc2MidBundle.t.sol:423` | FailedOpWithRevert(2, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 17 | `test_control_v542_stays_settlesNormally` | `contracts/test/v2/SuperPaymasterV542ToRc2MidBundle.t.sol:295` | control: no postOp revert: 2 != 0 | S: old postOp allocation/settlement floor | F | PASS |
| 18 | `test_B1_no_oog_band_above_entry_guard` | `contracts/test/v2/SuperPaymasterV55.t.sol:416` | no OOG band: a postOp that passed the entry check must complete: 0x != 0x8890295d | N: old SETTLE guard and sweep range | F | PASS |
| 19 | `test_G_min_post_op_gas_covers_measured_postOp` | `contracts/test/v2/SuperPaymasterV55.t.sol:185` | MIN_POST_OP_GAS must cover postOp x 64/63 + margin: 235580 > 200000 | W: old 200k minimum vs measured postOp | F | PASS |
| 20 | `test_I8_settle_failure_rolls_back_user_execution_e2e` | `contracts/test/v2/SuperPaymasterV55.t.sol:485` | assertion failed | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 21 | `test_TR1409_settles_at_MIN_POST_OP_GAS_worst_path` | `contracts/test/v2/SuperPaymasterV55.t.sol:164` | op at the floor must validate and execute | S: old postOp allocation/settlement floor | F | PASS |
| 22 | `test_balance_mode_end_to_end` | `contracts/test/v2/SuperPaymasterV55.t.sol:135` | handleOps | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 23 | `test_R13_revocation_user_disable_and_emergency_reject_via_entrypoint` | `contracts/test/v2/SuperPaymasterV55Adversarial.t.sol:1087` | control: re-enabled | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 24 | `test_R13_sp_replacement_pending_cannot_lock_old_sp_fails_closed` | `contracts/test/v2/SuperPaymasterV55Adversarial.t.sol:1065` | during the 48 h window the current SP keeps working | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 25 | `test_R13_stolen_owner_cannot_take_user_funds` | `contracts/test/v2/SuperPaymasterV55Adversarial.t.sol:1004` | control: an op committing to the new rate is sponsored | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 26 | `test_RouteA_maxCost_above_auto_cap_rejected_not_truncated` | `contracts/test/v2/SuperPaymasterV55Adversarial.t.sol:810` | control: a0 within the cap | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 27 | `test_RouteA_self_drain_blocked_by_escrow_user_still_pays` | `contracts/test/v2/SuperPaymasterV55Adversarial.t.sol:744` | assertion failed | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 28 | `test_TR1401_sybil_each_account_pays_own_lock_unbacked_zero_flat_in_N` | `contracts/test/v2/SuperPaymasterV55Adversarial.t.sol:337` | T-R14-01: bundle of funded Sybils executes | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 29 | `test_TR1402_same_account_multi_nonce_keys_kth_rejected_when_free_balance_below_x0` | `contracts/test/v2/SuperPaymasterV55Adversarial.t.sol:387` | T-R14-02: 4th op rejected at validation (balance - lockedOf < x0): 0x65c8fd4d0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000d41413333207265766572746564000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 != 0x220266b600000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000001441413334207369676e6174757265206572726f72000000000000000000000000 | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 30 | `test_TR1403_stale_blacklist_admitted_ops_settle_new_op_rejected` | `contracts/test/v2/SuperPaymasterV55Adversarial.t.sol:430` | assertion failed | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 31 | `test_TR1404_user_execution_revert_still_pays_and_clears_lock` | `contracts/test/v2/SuperPaymasterV55Adversarial.t.sol:466` | assertion failed | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 32 | `test_TR1405_postOp_revert_undoes_execution_operator_loss_le_a0_attacker_gain_zero` | `contracts/test/v2/SuperPaymasterV55Adversarial.t.sol:500` | bundle succeeds (postOpReverted path) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 33 | `test_TR1406_credit_off_debts_never_increase_on_any_path` | `contracts/test/v2/SuperPaymasterV55Adversarial.t.sol:546` | funded op sponsored in balance mode | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 34 | `test_TR1407_bundler_gas_sweep_never_keeps_unpaid_execution` | `contracts/test/v2/SuperPaymasterV55Adversarial.t.sol:622` | sweep reaches the sufficient region: 0 <= 0 | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 35 | `test_TR1407_direct_postOp_gas_sweep_returns_only_when_settled` | `contracts/test/v2/SuperPaymasterV55Adversarial.t.sol:660` | success region reached: 0 <= 0 | N: old SETTLE guard and sweep range | F | PASS |
| 36 | `test_TR1407_postOpGasLimit_sweep_via_entrypoint` | `contracts/test/v2/SuperPaymasterV55Adversarial.t.sol:590` | at/above the floor: executed and settled | S: old postOp allocation/settlement floor | F | PASS |
| 37 | `test_migration_legacy3x_token_operator_gets_sigFail_AA34_not_AA33` | `contracts/test/v2/SuperPaymasterV55Adversarial.t.sol:880` | control: v2 token path sponsors | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 38 | `testFuzz_G2_I8_I9_I10_conservation` | `contracts/test/v2/SuperPaymasterV55Fuzz.t.sol:449` | I8/B-1: op settled iff its settlement was not made to fail: false != true; counterexample: calldata=0x067567e50000000000000000000000000000000585f7cd5d3627c4d9674e9dbdb2c22a23 args=[1879485820647092361487882485522095024675 [1.879e39]] | Initial stale verification/settlement budgets; then EX_OK call OOG; now deployment no-subsidy failure | M | FAIL |
| 39 | `testFuzz_G2_floor_params` | `contracts/test/v2/SuperPaymasterV55Fuzz.t.sol:409` | I8/B-1: op settled iff its settlement was not made to fail: false != true; counterexample: calldata=0x0350e2360000000000000000000000000000000000000000000000000000000000000dcd args=[3533] | Old all-floor tuple: universal guard/settlement/buffer claim | M† | FAIL |
| 40 | `testFuzz_G2_noOOGBand_direct_postOp` | `contracts/test/v2/SuperPaymasterV55Fuzz.t.sol:527` | no-OOG band: a postOp that passed the SETTLE_GAS_BOUND entry check must complete: 0x != 0x8890295d; counterexample: calldata=0xceba05ed0000000000000000000000000000000000000000000000000000000000002ecc0000000000000000000000000000000000000000000000000000000000000001 args=[11980 [1.198e4], true] | N: old SETTLE guard and sweep range | F | PASS |
| 41 | `test_G2_coverage_replay_fixed_seeds` | `contracts/test/v2/SuperPaymasterV55Fuzz.t.sol:464` | I8/B-1: op settled iff its settlement was not made to fail: false != true | Initial stale verification/settlement budgets; then EX_OK call OOG; now deployment no-subsidy failure | M | FAIL |
| 42 | `test_G2_coverage_replay_floor_params` | `contracts/test/v2/SuperPaymasterV55Fuzz.t.sol:418` | I8/B-1: op settled iff its settlement was not made to fail: false != true | Old all-floor tuple: universal guard/settlement/buffer claim | M† | FAIL |
| 43 | `test_G_sp_charge_covers_final_cost_large_limits` | `contracts/test/v2/SuperPaymasterV55Gas.t.sol:293` | FailedOpWithRevert(0, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 44 | `test_G_sp_charge_covers_final_cost_user_call_reverts` | `contracts/test/v2/SuperPaymasterV55Gas.t.sol:297` | FailedOpWithRevert(0, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 45 | `test_G_sp_charge_covers_final_cost_worst_postOp_at_floor` | `contracts/test/v2/SuperPaymasterV55Gas.t.sol:289` | FailedOpWithRevert(0, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 46 | `test_G_wrap_bound_canonical_entrypoint_bundle_positions` | `contracts/test/v2/SuperPaymasterV55Gas.t.sol:171` | C_WRAP bounds the overhead at every bundle position: 184136 > 5000 | P: probe fresh recording slots OOG; invalid measurement | F | PASS |
| 47 | `test_G_wrap_bound_canonical_entrypoint_single_ops` | `contracts/test/v2/SuperPaymasterV55Gas.t.sol:146` | postOp really ran in every scenario: 3 != 4 | P: probe fresh recording slots OOG; invalid measurement | F | PASS |
| 48 | `test_settle_floor_keeps_no_oog_band` | `contracts/test/v2/SuperPaymasterV55GasParams.t.sol:280` | SETTLE floor: no OOG band above the entry guard: 0x != 0x8890295d | Old all-floor tuple: universal guard/settlement/buffer claim | M† | FAIL |
| 49 | `test_open_executor_param_change_mid_bundle_does_not_harm_admitted_ops` | `contracts/test/v2/SuperPaymasterV55ParamRace.t.sol:156` | FailedOpWithRevert(1, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 50 | `test_each_path_within_C_POSTOP` | `contracts/test/v2/SuperPaymasterV55PostOpBound.t.sol:383` | rule per path: BALANCE first-time user, cold lastTimestamp: 1750000000 < 2179790500 | W: old C_POSTOP below measured need | F | PASS |
| 51 | `test_rule_C_POSTOP_ge_W_postop_times_1_plus_m` | `contracts/test/v2/SuperPaymasterV55PostOpBound.t.sol:340` | probe postOp ran in every scenario: 2 != 3 | P + W: probe instrumentation and old C_POSTOP | F | PASS |
| 52 | `test_rule_under_all_floor_params` | `contracts/test/v2/SuperPaymasterV55PostOpBound.t.sol:347` | probe postOp ran in every scenario: 2 != 3 | Old all-floor tuple: universal guard/settlement/buffer claim | M† | FAIL |
| 53 | `test_mid_bundle_rollback_to_5_5_0_settles_contexts_of_the_new_impl` | `contracts/test/v2/SuperPaymasterV55UpgradeRace.t.sol:248` | FailedOpWithRevert(1, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |
| 54 | `test_mid_bundle_upgrade_from_5_5_0_settles_contexts_of_the_old_impl` | `contracts/test/v2/SuperPaymasterV55UpgradeRace.t.sol:238` | FailedOpWithRevert(1, "AA33 reverted", 0x) | V + S: stale 700k verification and/or postOp budget | F | PASS |

## Retained mechanisms and diagnostic limits

### Deployment tuple: G2 conservation and fixed-seed replay

The repaired campaign passes beyond the original I8/B-1 settlement failure and the later EX_OK OOG fixture issue. It now fails the original **net-of-fee charge >= EntryPoint actualGasCost** gate. The assertion, oracle, fee conversion, and deployment C_POSTOP/C_WRAP are not raised or bypassed.

- `test_settle_floor_keeps_no_oog_band()`: SETTLE floor: no OOG band above the entry guard: 0x != 0x8890295d
- `testFuzz_G2_I8_I9_I10_conservation(uint256)`: DSR no-subsidy: net-of-fee charge (ETH @ validation snapshot) >= op's actualGasCost: 3198959360372700 < 3212962866402288; counterexample: calldata=0x067567e50000000000000000000000000000000000000000000000000000000000003086 args=[12422 [1.242e4]]
- `testFuzz_G2_floor_params(uint256)`: I8/B-1: op settled iff its settlement was not made to fail: false != true; counterexample: calldata=0x0350e2360000000000000000000000000000000000000000000000000000000000000dcd args=[3533]
- `test_G2_coverage_replay_fixed_seeds()`: DSR no-subsidy: net-of-fee charge (ETH @ validation snapshot) >= op's actualGasCost: 1827511012226570 < 1838299350952020
- `test_G2_coverage_replay_floor_params()`: I8/B-1: op settled iff its settlement was not made to fail: false != true
- `test_rule_under_all_floor_params()`: rule: C_POSTOP >= W_postop x (1 + m): 175000 < 335316

The unmutated [fixed-seed trace excerpt](mechanism-g2-trace.log) (full raw trace: `mechanism-g2-trace.log.gz`, kept outside git, sha256 in `external-traces.sha256`) narrows the deployment finding further. For op `0xb53300949c74cb28a674e9ee9ab6370dca7a2b48a4000765ae21d419a79eebd8`, the user execution intentionally reverts, CREDIT settlement completes, I8/B-1 and the SP/token charge-equality checks pass, and only the no-subsidy gate fails. The trace reports **389,218 gas for the proxy postOp frame (388,818 in the implementation)**, exceeding **C_POSTOP=340,000** while remaining below MIN=440,000. This path is not covered by the isolated per-path 291,579 maximum quoted below. EntryPoint's passed cost P is 1,044,007,212,960,250 wei; final cost F is 1,838,299,350,952,020 wei; fee is 1,864,881,370 wei/gas. F−P is exactly 425,921 gas, while the net charge beyond P covers 420,136 gas. The shortfall is **10,788,338,725,450 wei = 5,785 gas** in this test. No opcode-level attribution of the larger SP frame is established here; the test’s result and frame-bound violation are retained rather than “fixed” with a larger C_POSTOP.

The final full fuzz run replays Forge's cached counterexample 12422 (`runs: 0` in the final log); it is an executed counterexample, not a claim that 1,000 fresh fuzz campaigns passed. Fixed-seed replay independently reproduces the deployment finding.

The failures above are executable counterexamples to the tests' properties, not proof of a particular opcode-level root cause or a quantified live-network loss. The no-subsidy discrepancy must be investigated as a mechanism/oracle issue; this task does not establish which production change would repair it. It is not relabeled F merely because the initial failure was fixture-related. No parameter above the queued tuple was chosen to make G2 green.

### All-floor scope (M†)

The retained tuple is MIN 175k / SETTLE 155k / C_WRAP 5k / C_POSTOP 175k. The all-floor G2 fuzz and replay still fail settlement; the explicit all-floor guard scan still finds an OOG band. The postOp rule now reports **175000 < 335316** rather than a probe-count failure/logging underflow. On the deployed tuple the same normal postOp rule and per-path test pass; the measured worst frame is 291,579 and the 15% requirement is 335,316, below 340,000. This does not make every permitted tuple safe. The four original all-floor assertions are intentionally preserved.

### C_WRAP: 184136 is an invalid measurement, not wrapper overhead

[mutation-old-budgets-probe.log](mutation-old-budgets-probe.log) restores the cold recording slots and 200k probe allocation. It reproduces **184136 > 5000** exactly. The trace shows `PostOpProbePaymaster.postOp` OOG, `PostOpReverted`, and `lastPassedGas() == 0` after rollback. The test computes **383836 + 300 - 0 - 200000 = 184136** with an invalid P. The beneficiary transfer happens after the UserOperationEvent, outside that measured per-op window; this is not evidence of a new-beneficiary wrapper charge.

The recording slots now start nonzero before measurement; the counter retains a zero-based public count. The original burn-to-floor procedure, 5k bound, 2x-headroom assertion, limit-independence check, and penalty control remain. Bundle positions additionally require every probe postOp to complete before calculating the bound. Final measured wrapper upper bounds are in `amsterdam.log` (about 1,868 at each position). This supports a probe fresh-storage artifact, consistent with EIP-8037 and the earlier calibrated study; no new opcode-level state-gas breakdown is claimed here.

### Measured postOp minimum

`test_G_min_post_op_gas_covers_measured_postOp` reads the configured minimum for its original `used * 64 / 63 + 20000` assertion. It passes with 440k. The deliberate old-parameter mutation reproduces **235580 > 200000** exactly. The final measured direct-frame value is logged, and is distinct from the EntryPoint-mediated minimum. The final worst-path bound suite also searches minimum completing call gas; do not substitute raw charged gas for the gas allowance required by the guard and forwarding.

## Mutation evidence

All mutants are test-only and restored before final suite runs. The temporary runner is preserved as [G7Mutations.t.sol.txt](G7Mutations.t.sol.txt), not loaded by Forge. Seven runner mutations hit their intended assertions; three budget/probe runs add two distinct tests plus a second mutation of the balance test: **nine distinct changed tests with ten successful assertion-killing controls**, covering all five original classes.

| Target test | Mutation | Observed discriminating failure | Evidence |
|---|---|---|---|
| `test_balance_mode_end_to_end` | mocked settleLocked returns zero without settlement | `user paid in xPNTs: 0 <= 0` | mutations.log |
| `test_B1_no_oog_band_above_entry_guard` | SETTLE restored to 160k | named no-OOG assertion, empty revert vs PostOpGasTooLow | mutations.log |
| `test_TR1409_settles_at_MIN_POST_OP_GAS_worst_path` | settleLocked forced to revert | `postOp must NOT fail at MIN_POST_OP_GAS` | mutations.log |
| `test_fix_minGasFloorIsSufficient` | balance settlement no-op | `worst path must be exercised ...: 0 <= 0` | mutations.log |
| `test_fix_minGasFloorIsSufficient_creditPath` | credit settlement no-op | `credit path must be exercised ...: 0 <= 0` | mutations.log |
| `test_each_path_within_C_POSTOP` | C_POSTOP restored to 175k, MIN/SETTLE remain deployed | `1750000000 < 2179790500` per-path bound | mutations.log |
| `test_G_min_post_op_gas_covers_measured_postOp` | old 200k/160k/5k/175k tuple | `235580 > 200000` | mutations.log |
| `test_balance_mode_end_to_end` | PM verification restored to 700k | `handleOps` assertion (trace: AA33 / OOG) | mutation-old-budgets-probe.log |
| `test_G_wrap_bound_canonical_entrypoint_bundle_positions` | original cold probe slots and 200k allocation | original `184136 > 5000` bound | mutation-old-budgets-probe.log |
| `test_G_wrap_bound_canonical_entrypoint_single_ops` | original cold probe slots and 200k allocation | `postOp really ran ...: 3 != 4` | mutation-old-budgets-probe.log |

The two G2 mutation attempts are **not counted**: the first omitted isolation and hit StillLive; the isolated retry hit the same no-subsidy finding as the unmutated final suite, so it does not prove an independently killed assertion. Both logs are retained instead of presenting them as successful mutation coverage. G2's original assertions demonstrably remain live in the final failing suite, but that is not substituted for a clean mutation control.

## Cross-runtime status comparison

- Cancun: **0 test status changes** (comparison key = file + contract + test signature; named invariant results also compared).
- Prague: **0 test status changes** (comparison key = file + contract + test signature; named invariant results also compared).

Intermediate runs exposed fixture-oracle mistakes (the legacy postOp allocation in its expected formula, a typed-constant uint32 overflow, and insufficient separation of D5b's two tuples). Those were repaired before the final runs; they are not unexplained final status changes. No new skips or expected-failure suppression was introduced.

## Verification limits

These are offline Forge results for the requested engine and the suite's existing isolation choices. They do not prove behavior under all state-gas reservoir regimes, all seeds, different account factories, or live bundler estimation. The baseline Amsterdam run was supplied, not regenerated. The four all-floor findings concern a different tuple by construction. The remaining deployment no-subsidy failures prevent declaring G-7 fully green or the queued configuration universally sufficient.

## Review round 2 (PR #563 review M-1, S-1..S-4)

All runs below are at `a941ddd9` (clean tree), produced by `script/evidence/rams-g7-rerun.sh`. Logs are in
[`r2/`](r2/), with hashes in `r2/SHA256SUMS`. The test sources these runs used are in `r2/test-sources.sha256`.
The top-level `test-sources.sha256` records round 1, so the D5b and Fuzz lines in it no longer match HEAD by design.

- **M-1 (fixed).** The original D5b `NEW_SETTLE = 300_000` was below the victims' postOp limit (`MIN_POST` = 440k),
  so a guard that read the *live* settle bound passed, just as one reading the snapshot did. D5b had lost its
  discrimination. The fix sets `NEW_SETTLE = MIN_POST + 160_000` (600k) and adds the precondition
  `assertGt(NEW_SETTLE, MIN_POST)`.
  - Mutation `SuperPaymaster.sol` `snapSettle = uint32(snap >> 32)` → `_gasParams.settleGasBound`:
    `test_d5b_forward_mid_bundle_upgrade_with_extension_calls` fails `forward: no victim postOp fails: 2 != 0` on
    both forge 1.7.1 Cancun and Amsterdam (`r2/mutation-m1-d5b-*.log`).
  - The rollback test stays green under this mutation, as expected: after the rollback the victims settle on the
    previous-release fixture bytecode, which the mutation does not touch.
- **S-1 (kept, with evidence).** The `test_G_min_post_op_gas_covers_measured_postOp` bound reads the configured floor
  (440k). Restoring 200k is green on Cancun but red on Amsterdam: `amsterdam-before.log`,
  `235580 > 200000` (measured 212,212 × 64/63 + 20k). The relaxation is therefore required on Amsterdam.
- **S-2 (comment added).** The EX_OK call-gas floor is the Amsterdam-measured success need; below it the call is
  not a success path.
- **S-3 (fixed).** The absolute engine path in `commands.md` is now `~/…`.
- **S-4 (added).** `test_G2_noOOGBand_fixed_points_above_settle` adds samples at SETTLE + {1, 2k, 10k, 40k} for
  both modes. Each sample starts from a fresh snapshot, and the top sample must settle.
  - Positive control: with the top sample changed to SETTLE + 1, the test fails
    `SETTLE + 40k settles: the success band is sampled`.
  - While adding it, I found that the credit branch read `balanceOf` *after* `vm.prank`, so the prank was
    consumed by the static call. It only worked because the user started empty. The branch now reads the balance
    before the prank.

| run (`r2/`) | result |
|---|---|
| `cancun-forge171.log` (forge 1.7.1) | 1798 passed, 0 failed, 65 skipped |
| `prague-forge171.log` (forge 1.7.1, `--evm-version prague`) | 1678 passed, 0 failed, 39 skipped |
| `amsterdam.log` (nightly 4e8874b) | 1664 passed, 6 failed, 39 skipped — the **same 6** tests as `amsterdam.log` above (set diff empty) |
| `mutation-m1-d5b-cancun.log` / `-amsterdam.log` | 1 passed, 1 failed (the forward test), source restored, tree clean |

Each count is one above round 1 because of the new S-4 test.

The 6 remaining failures are unchanged:
- 2 are the no-subsidy mechanism result. DSR ruled (CC-127 1c0b8150) that frame-level attribution must come first,
  and that is now being done separately.
- 4 are the floor-parameter (M†) rows.

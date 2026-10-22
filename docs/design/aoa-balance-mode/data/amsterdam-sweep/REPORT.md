# Amsterdam (EIP-7732 / EIP-8037 / EIP-8038) test sweep — CC-125

Evidence for spec `03-final-spec.md` §10.8b **R-AMS**. Read-only analysis: nothing under
`contracts/src`, `contracts/script`, `foundry.toml` or `.github` was changed; no RPC, no keys, no
transactions. All numbers come from forge's in-process revm.

- Commit under test: `79c0c6ffe197da9ee288fab881272b3af168dcc1` (`origin/main` on 2026-10-22).
- Date: 2026-10-22. Sepolia activated Amsterdam on 2026-10-06 13:53 UTC.

## 0. Headline

**Under Amsterdam execution, all four GOV-5 defaults except C_WRAP are too small, and the
default `paymasterVerificationGasLimit` used throughout the tests (700k) is too small too.
All the values needed are still inside the GOV-5 hard bounds**, so the fix is the
`queueGasParams` → `executeGasParams` path (≥ 96 h after GOV-1), not a UUPS upgrade. One caveat:
these numbers come from revm's EIP-8037 constants. They must be re-measured on a real Amsterdam
chain before they are used (see §7).

| parameter | default | GOV-5 hard bounds | needed (Prague) | needed (Amsterdam, revm) | default OK under Amsterdam? | fix path |
|---|---|---|---|---|---|---|
| `SETTLE_GAS_BOUND` | 160,000 | [155k, 1M] | ≤ 155,000 (no-OOG band holds at the floor) | **≥ 380,000** (no-OOG band: CREDIT holds from 370k, BALANCE from 380k; 10k sweep steps) | **NO** | GOV-5 queue (in bounds) |
| `MIN_POST_OP_GAS` | 200,000 | [SETTLE + 20k, 2M] | ≥ 167,387 (smallest completing limit, T-R14-09) | **≥ 400,000** (= SETTLE + 20k; smallest completing limit 379,783–399,000) | **NO** | GOV-5 queue (in bounds) |
| `C_POSTOP_GAS` | 175,000 | [175k, MIN] | ≥ 170,130 (= W_postop 147,939 × 1.15) | **≥ 335,316** (= W_postop 291,579 × 1.15) | **NO** (−40% vs W_postop) | GOV-5 queue (in bounds, once MIN ≥ 335,316) |
| `C_WRAP_GAS` | 5,000 | [5k, 50k] | ≥ 1,770 | **≥ 1,870** (clean probe, see §3.3) | yes (2.67×) | none |
| `paymasterVerificationGasLimit` (SDK / test ops, not a contract parameter) | 700,000 in most test ops | — | ≥ 188,773 (EntryPoint flow) | **≥ 804,813** (EntryPoint flow; direct call 646k–710k) | **NO**: 18 tests fail with AA33 | SDK |

**Deployment**: every CREATE costs about **7.4× more** (24 direct CREATEs: 54.4M → 402.5M gas).
**9 contracts need more than 2^24 = 16,777,216 gas to create** (SuperPaymaster impl 51.9M,
BLSAggregator 38.6M, xPNTsFactory 36.7M, Registry 36.2M, xPNTsTokenV2Ext 34.0M, xPNTsTokenV2 30.9M,
MySBT 19.5M; plus SuperPaymasterAdmin 30.1M inside the SP constructor, and the reference EntryPoint 19.6M).
The SP impl alone is 51.9M, close to a 60M block. With revm's EIP-7825 check enabled, a single
Registry CREATE failed (§5.2). Whether Sepolia's tx-gas cap counts state gas is **not verified**.

**Tool version is not a factor**: forge 1.7.1 and 1.8.6 give identical results on cancun (0 of
1,840 result lines differ, and the G-layer values are byte-identical). **Prague vs Amsterdam:
54 tests flip from PASS to FAIL**, all in the SP 5.5 G-layer / postOp / EntryPoint-integration
suites. No test in any other area changes.

## 1. Tools and settings

| item | value |
|---|---|
| forge (sweep) | `forge Version: 1.8.6`, commit `6bad0a66de7c83f7b33695044138f0f5fa4c5990`, built 2026-10-21T17:56:11Z; binary sha256 `cfabb782…26c3` |
| forge (baseline) | `forge Version: 1.7.1`, commit `4072e48705af9d93e3c0f6e29e93b5e9a40caed8`, built 2026-05-08T07:50:55Z; binary sha256 `4f77da08…355c` |
| install | `foundry.paradigm.xyz` (foundryup) is blocked by this environment's egress proxy (403), so the official release tarballs were used: `github.com/foundry-rs/foundry/releases/download/v1.8.6/foundry_v1.8.6_linux_amd64.tar.gz` (likewise v1.7.1) |
| solc | 0.8.33+commit.64118f21 (`solc-static-linux` from the ethereum/solidity GitHub release, placed in `~/.svm/0.8.33/`; binaries.soliditylang.org is blocked), sha256 `1274e5c4…5468`; all runs `--offline` |
| isolation | forge 1.8.6 defaults to `isolate = true` (`forge config`), which clears transient storage between calls and breaks the suite with `NotLive()`. All 1.8.6 runs use **`--no-isolate`** plus `FOUNDRY_ISOLATE=false`, on the CLI and environment only (foundry.toml untouched). 1.7.1 defaults to no isolation; `FOUNDRY_ISOLATE=false` was set as well. |
| `--gas-report` | **forces isolation in 1.8.6 even with `--no-isolate`**: 41 Prague / 82 Amsterdam tests fail with `NotLive()` in that mode. The gas-report logs are kept (`gasreport_v2_*_FORCED_ISOLATION.log.gz`) but are **not used** for the numbers. Per-function gas comes from `-vvvv` call traces instead (§4). |
| fuzz seed | `--fuzz-seed 0x5eed` on every run; runs and depth come from foundry.toml (fuzz 256, invariant 256×500) |
| separate artifact dirs | `FOUNDRY_OUT` / `FOUNDRY_CACHE_PATH` per configuration (`out/` for 1.8.6-cancun; `/tmp/sweep/out_prague` for prague and amsterdam; `/tmp/sweep/out_171` for 1.7.1), so no run reuses another run's build |

### 1.1 How Amsterdam execution was achieved

solc 0.8.33 accepts EVM versions only up to `osaka` (`solc --help`: "…cancun, prague or osaka"),
so **no amsterdam compile target exists**. forge 1.8.6 separates the two settings:

- `--evm-version <v>` is the **compile** target, and also the default runtime spec;
- `--hardfork <HARDFORK>` ("The runtime EVM hardfork to use") is the **runtime** revm spec. It
  accepts `amsterdam`; an unknown value is rejected (`--hardfork foo` → "unknown ethereum hardfork 'foo'").

Run (c) = **`--evm-version prague --hardfork amsterdam`**: the same Prague-compiled bytecode as
run (b), executed under revm's Amsterdam spec. (b) → (c) therefore isolates the hard fork. The
deployment measurement (§5) runs the **shipped profile.default cancun init code** under both runtime specs.

Calibration probes confirm the runtime switch is real (`probe_calibration.log`, same bytecode each time):

| probe | cancun / prague runtime | amsterdam runtime |
|---|---|---|
| CALL that does one zero→non-zero SSTORE | 22,575 | **110,595** |
| CREATE of 7,000 B runtime | 1,433,897 | **10,908,811** (7.6×; Sepolia reported ~9.3M for a ~7 KB CREATE, so revm's figure looks the same or more conservative; the exact Sepolia byte count is unknown) |
| cold BALANCE / cold EXTCODESIZE | 2,626 / 2,626 | 3,026 / 3,126 (EIP-8038) |
| warm SSTORE non-zero→non-zero (call) | 1,108 | 1,208 |
| cold SLOAD inside a call | 3,218 | 3,218 (unchanged in this revm) |
| EIP-2537 G1ADD (0x0b) | prague: 128-byte output; cancun: no precompile | 128-byte output |
| `call{gas: 50k}` → one new-slot SSTORE | ok | **fails** (state gas counts against the frame's gas limit) |
| `call{gas: 150k}` → two new-slot SSTOREs | ok | **fails**; succeeds at 300k (223,361 consumed) |

The last two rows matter: in this revm, EIP-8037 state gas is **charged inside the frame's gas
limit**. So the postOp, validation and verification limits must cover it directly.

### 1.2 Exact commands

```bash
export PATH=/tmp/fd/v1.8.6:$PATH FOUNDRY_ISOLATE=false
# (a) 1.8.6 cancun (repo default)
forge test --offline --no-isolate --fuzz-seed 0x5eed -vv                                        > a_186_cancun.log
# (b) 1.8.6 prague
FOUNDRY_OUT=/tmp/sweep/out_prague FOUNDRY_CACHE_PATH=/tmp/sweep/cache_prague \
forge test --offline --no-isolate --fuzz-seed 0x5eed -vv --evm-version prague                    > b_186_prague.log
# (c) 1.8.6 amsterdam execution (prague bytecode)
FOUNDRY_OUT=/tmp/sweep/out_prague FOUNDRY_CACHE_PATH=/tmp/sweep/cache_prague \
forge test --offline --no-isolate --fuzz-seed 0x5eed -vv --evm-version prague --hardfork amsterdam > c_186_amsterdam.log
# (d) 1.7.1 cancun baseline
FOUNDRY_OUT=/tmp/sweep/out_171 FOUNDRY_CACHE_PATH=/tmp/sweep/cache_171 \
/tmp/fd/v1.7.1/forge test --offline --fuzz-seed 0x5eed -vv                                      > d_171_cancun.log
# per-function traces (§4): same as (b)/(c) plus  -vvvv --match-path 'contracts/test/v2/*'
# scratch G-layer re-measurement (§3): scratch/AmsScratch.t.sol.txt copied to
#   contracts/test/zz_scratch_ams/AmsScratch.t.sol (temporary, deleted, never committed), then
#   forge test --offline --no-isolate --evm-version prague [--hardfork amsterdam] --match-path contracts/test/zz_scratch_ams/AmsScratch.t.sol -vv
#   settle sweep: FOUNDRY_GAS_LIMIT=9223372036854775807 ... --match-test test_ams_settle_sweep
# deployment gas (§5): separate scratch project /tmp/deploygas (scratch/deploygas.foundry.toml.txt,
#   scratch/DeployGas.t.sol.txt); init code taken from out/ by scratch/resolve.py (profile.default
#   cancun artifacts selected by metadata: runs 500 / Registry 200, viaIR, evmVersion cancun), then
#   forge test --no-isolate --evm-version prague [--hardfork amsterdam] -vv
```
`scratch/run.sh` is the exact driver for (a)–(d). `scratch/parse.py`, `diff.py` and `traces.py`
produce the tables. `timeline.txt` holds the timestamps. Its `exit=` field is **not reliable**
(it captures `date`'s status), so use each log's summary line instead.

### 1.3 Suite totals

| run | result line |
|---|---|
| (d) 1.7.1 cancun | 149 suites: 1791 passed, 0 failed, 49 skipped (1840) |
| (a) 1.8.6 cancun | 149 suites: 1783 passed, 0 failed, 49 skipped (1832)¹ |
| (b) 1.8.6 prague | 149 suites: 1663 passed, 0 failed, 23 skipped (1686) |
| (c) 1.8.6 amsterdam | 149 suites: 1609 passed, **54 failed**, 23 skipped (1686) |

¹ 1.8.6 groups invariant functions under one entry, so the summary count differs from 1.7.1. Per
test function, both versions have the same 1,840 result lines. Cancun → Prague changes are the
documented precompile split (BLS suites run against etched stubs on Cancun and skip themselves
on Prague; the real-precompile `paper7` / CC48 / CC115 suites skip on Cancun and run on Prague).
All 231 of these changes are PASS↔SKIP; there is no FAIL in either run. See the third table in `result_diffs.md`.

## 2. Result differences

### 2.1 1.7.1-cancun vs 1.8.6-cancun

**0 differences** over 1,840 result lines. The G-layer logs are identical too (W_postop 147,939;
T-R14-09 measured postOp 142,092; wrap 1,756/1,758/1,770). The tool upgrade does not move any
result or measured value. (The 142,092 on this HEAD differs from the 140,770 recorded in
EVIDENCE-INDEX U-05 for an older commit. The value is the same under both forge versions.)

### 2.2 1.8.6-prague (b) vs 1.8.6-amsterdam (c): 54 tests PASS → FAIL

Causes, by class:
- **AA33 (18 tests)**: the test ops set `paymasterVerificationGasLimit = 700,000`. SP validation
  in the EntryPoint flow needs about 805k under Amsterdam (§4), so EntryPoint reverts validation.
  This is a gas-limit consequence, not a logic change.
- **OOG / no-OOG band (3 tests)**: a postOp that passes the 160k `SETTLE_GAS_BOUND` entry guard
  then runs out of gas (empty revert data instead of `PostOpGasTooLow` `0x8890295d`). **This breaks
  the B-1 / I8 "no OOG band" guarantee at the default parameters.**
- **assertion / revert (33 tests)**: these all follow from the same postOp gas shortfall (op
  rejected or postOp reverted at `MIN_POST_OP_GAS` = 200k, conservation and sweep tests not
  reaching the success region, G-rule assertions), plus the probe artefact explained in §3.3.

| # | suite | test | 1.8.6 prague | 1.8.6 amsterdam | class | failure reason (1.8.6 amsterdam) |
|---|---|---|---|---|---|---|
| 1 | `PoC_C04_ForcedPostOpOOG.t.sol:PoC_C04_ForcedPostOpOOG_Test` | `test_baseline_normalPostOp` | PASS | FAIL | revert/other | baseline handleOps must not revert |
| 2 | `PoC_C04_ForcedPostOpOOG.t.sol:PoC_C04_ForcedPostOpOOG_Test` | `test_fix_minGasFloorIsSufficient` | PASS | FAIL | revert/other | op at the MIN floor must pass validation and execute |
| 3 | `PoC_C04_ForcedPostOpOOG.t.sol:PoC_C04_ForcedPostOpOOG_Test` | `test_fix_minGasFloorIsSufficient_creditPath` | PASS | FAIL | revert/other | postOp must NOT fail at MIN_POST_OP_GAS on the CREDIT path |
| 4 | `PoC_C04_ForcedPostOpOOG.t.sol:PoC_C04_ForcedPostOpOOG_Test` | `test_fix_verdict` | PASS | FAIL | revert/other | baseline handleOps must not revert |
| 5 | `APNTsCappedSPIntegration.t.sol:APNTsCappedSPIntegrationTest` | `test_SP_gasless_balance_mode_op_conservation` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(0, "AA33 reverted", 0x) |
| 6 | `APNTsCappedSPIntegration.t.sol:APNTsCappedSPIntegrationTest` | `test_SP_withdrawProtocolRevenue_after_ops` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(0, "AA33 reverted", 0x) |
| 7 | `SuperPaymasterD5bUpgradeRace.t.sol:SuperPaymasterD5bUpgradeRaceTest` | `test_d5b_forward_mid_bundle_upgrade_with_extension_calls` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 8 | `SuperPaymasterD5bUpgradeRace.t.sol:SuperPaymasterD5bUpgradeRaceTest` | `test_d5b_rollback_mid_bundle_with_extension_calls` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 9 | `SuperPaymasterFeeSnapshot.t.sol:SuperPaymasterFeeSnapshotTest` | `test_feeSnapshot_feeLoweredMidBundle_chargesValidationFee` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 10 | `SuperPaymasterFeeSnapshot.t.sol:SuperPaymasterFeeSnapshotTest` | `test_feeSnapshot_feeRaisedMidBundle_chargesValidationFee` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 11 | `SuperPaymasterFeeSnapshot.t.sol:SuperPaymasterFeeSnapshotTest` | `test_feeSnapshot_forward_prevReleaseContext_usesLiveFee` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 12 | `SuperPaymasterFeeSnapshot.t.sol:SuperPaymasterFeeSnapshotTest` | `test_feeSnapshot_rollback_prevReleaseSettlesNewContext` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 13 | `SuperPaymasterRc1Rc2MidBundle.t.sol:SuperPaymasterRc1Rc2MidBundleTest` | `test_control_rc1_stays_chargesLiveFee` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 14 | `SuperPaymasterRc1Rc2MidBundle.t.sol:SuperPaymasterRc1Rc2MidBundleTest` | `test_control_rc2_stays_chargesSnapshotFee` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 15 | `SuperPaymasterRc1Rc2MidBundle.t.sol:SuperPaymasterRc1Rc2MidBundleTest` | `test_rc1_to_rc2_forward_mid_bundle` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 16 | `SuperPaymasterRc1Rc2MidBundle.t.sol:SuperPaymasterRc1Rc2MidBundleTest` | `test_rc2_to_rc1_rollback_mid_bundle` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 17 | `SuperPaymasterV542ToRc2MidBundle.t.sol:SuperPaymasterV542ToRc2MidBundleTest` | `test_control_v542_stays_settlesNormally` | PASS | FAIL | assertion | control: no postOp revert: 2 != 0 |
| 18 | `SuperPaymasterV55.t.sol:SuperPaymasterV55Test` | `test_B1_no_oog_band_above_entry_guard` | PASS | FAIL | OOG | no OOG band: a postOp that passed the entry check must complete: 0x != 0x8890295d |
| 19 | `SuperPaymasterV55.t.sol:SuperPaymasterV55Test` | `test_G_min_post_op_gas_covers_measured_postOp` | PASS | FAIL | assertion | MIN_POST_OP_GAS must cover postOp x 64/63 + margin: 235580 > 200000 |
| 20 | `SuperPaymasterV55.t.sol:SuperPaymasterV55Test` | `test_I8_settle_failure_rolls_back_user_execution_e2e` | PASS | FAIL | assertion | assertion failed |
| 21 | `SuperPaymasterV55.t.sol:SuperPaymasterV55Test` | `test_TR1409_settles_at_MIN_POST_OP_GAS_worst_path` | PASS | FAIL | revert/other | op at the floor must validate and execute |
| 22 | `SuperPaymasterV55.t.sol:SuperPaymasterV55Test` | `test_balance_mode_end_to_end` | PASS | FAIL | revert/other | handleOps |
| 23 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_R13_revocation_user_disable_and_emergency_reject_via_entrypoint` | PASS | FAIL | revert/other | control: re-enabled |
| 24 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_R13_sp_replacement_pending_cannot_lock_old_sp_fails_closed` | PASS | FAIL | revert/other | during the 48 h window the current SP keeps working |
| 25 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_R13_stolen_owner_cannot_take_user_funds` | PASS | FAIL | revert/other | control: an op committing to the new rate is sponsored |
| 26 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_RouteA_maxCost_above_auto_cap_rejected_not_truncated` | PASS | FAIL | revert/other | control: a0 within the cap |
| 27 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_RouteA_self_drain_blocked_by_escrow_user_still_pays` | PASS | FAIL | assertion | assertion failed |
| 28 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1401_sybil_each_account_pays_own_lock_unbacked_zero_flat_in_N` | PASS | FAIL | revert/other | T-R14-01: bundle of funded Sybils executes |
| 29 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1402_same_account_multi_nonce_keys_kth_rejected_when_free_balance_below_x0` | PASS | FAIL | assertion | T-R14-02: 4th op rejected at validation (balance - lockedOf < x0): 0x65c8fd4d00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060000000000000000 |
| 30 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1403_stale_blacklist_admitted_ops_settle_new_op_rejected` | PASS | FAIL | assertion | assertion failed |
| 31 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1404_user_execution_revert_still_pays_and_clears_lock` | PASS | FAIL | assertion | assertion failed |
| 32 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1405_postOp_revert_undoes_execution_operator_loss_le_a0_attacker_gain_zero` | PASS | FAIL | revert/other | bundle succeeds (postOpReverted path) |
| 33 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1406_credit_off_debts_never_increase_on_any_path` | PASS | FAIL | revert/other | funded op sponsored in balance mode |
| 34 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1407_bundler_gas_sweep_never_keeps_unpaid_execution` | PASS | FAIL | assertion | sweep reaches the sufficient region: 0 <= 0 |
| 35 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1407_direct_postOp_gas_sweep_returns_only_when_settled` | PASS | FAIL | assertion | success region reached: 0 <= 0 |
| 36 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1407_postOpGasLimit_sweep_via_entrypoint` | PASS | FAIL | revert/other | at/above the floor: executed and settled |
| 37 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_migration_legacy3x_token_operator_gets_sigFail_AA34_not_AA33` | PASS | FAIL | revert/other | control: v2 token path sponsors |
| 38 | `SuperPaymasterV55Fuzz.t.sol:SuperPaymasterV55FuzzTest` | `testFuzz_G2_I8_I9_I10_conservation` | PASS | FAIL | assertion | I8/B-1: op settled iff its settlement was not made to fail: false != true; counterexample: calldata=0x067567e50000000000000000000000000000000585f7cd5d3627c4d9674e9dbdb2c22a23 args=[187948582064709236148788248552209502467 |
| 39 | `SuperPaymasterV55Fuzz.t.sol:SuperPaymasterV55FuzzTest` | `testFuzz_G2_floor_params` | PASS | FAIL | assertion | I8/B-1: op settled iff its settlement was not made to fail: false != true; counterexample: calldata=0x0350e2360000000000000000000000000000000000000000000000000000000000000dcd args=[3533] |
| 40 | `SuperPaymasterV55Fuzz.t.sol:SuperPaymasterV55FuzzTest` | `testFuzz_G2_noOOGBand_direct_postOp` | PASS | FAIL | OOG | no-OOG band: a postOp that passed the SETTLE_GAS_BOUND entry check must complete: 0x != 0x8890295d; counterexample: calldata=0xceba05ed0000000000000000000000000000000000000000000000000000000000002ecc000000000000000000000 |
| 41 | `SuperPaymasterV55Fuzz.t.sol:SuperPaymasterV55FuzzTest` | `test_G2_coverage_replay_fixed_seeds` | PASS | FAIL | assertion | I8/B-1: op settled iff its settlement was not made to fail: false != true |
| 42 | `SuperPaymasterV55Fuzz.t.sol:SuperPaymasterV55FuzzTest` | `test_G2_coverage_replay_floor_params` | PASS | FAIL | assertion | I8/B-1: op settled iff its settlement was not made to fail: false != true |
| 43 | `SuperPaymasterV55Gas.t.sol:SuperPaymasterV55GasTest` | `test_G_sp_charge_covers_final_cost_large_limits` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(0, "AA33 reverted", 0x) |
| 44 | `SuperPaymasterV55Gas.t.sol:SuperPaymasterV55GasTest` | `test_G_sp_charge_covers_final_cost_user_call_reverts` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(0, "AA33 reverted", 0x) |
| 45 | `SuperPaymasterV55Gas.t.sol:SuperPaymasterV55GasTest` | `test_G_sp_charge_covers_final_cost_worst_postOp_at_floor` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(0, "AA33 reverted", 0x) |
| 46 | `SuperPaymasterV55Gas.t.sol:SuperPaymasterV55GasTest` | `test_G_wrap_bound_canonical_entrypoint_bundle_positions` | PASS | FAIL | assertion | C_WRAP bounds the overhead at every bundle position: 184136 > 5000 |
| 47 | `SuperPaymasterV55Gas.t.sol:SuperPaymasterV55GasTest` | `test_G_wrap_bound_canonical_entrypoint_single_ops` | PASS | FAIL | assertion | postOp really ran in every scenario: 3 != 4 |
| 48 | `SuperPaymasterV55GasParams.t.sol:SuperPaymasterV55GasParamsTest` | `test_settle_floor_keeps_no_oog_band` | PASS | FAIL | OOG | SETTLE floor: no OOG band above the entry guard: 0x != 0x8890295d |
| 49 | `SuperPaymasterV55ParamRace.t.sol:SuperPaymasterV55ParamRaceTest` | `test_open_executor_param_change_mid_bundle_does_not_harm_admitted_ops` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 50 | `SuperPaymasterV55PostOpBound.t.sol:SuperPaymasterV55PostOpBoundTest` | `test_each_path_within_C_POSTOP` | PASS | FAIL | assertion | rule per path: BALANCE first-time user, cold lastTimestamp: 1750000000 < 2179790500 |
| 51 | `SuperPaymasterV55PostOpBound.t.sol:SuperPaymasterV55PostOpBoundTest` | `test_rule_C_POSTOP_ge_W_postop_times_1_plus_m` | PASS | FAIL | assertion | probe postOp ran in every scenario: 2 != 3 |
| 52 | `SuperPaymasterV55PostOpBound.t.sol:SuperPaymasterV55PostOpBoundTest` | `test_rule_under_all_floor_params` | PASS | FAIL | assertion | probe postOp ran in every scenario: 2 != 3 |
| 53 | `SuperPaymasterV55UpgradeRace.t.sol:SuperPaymasterV55UpgradeRaceTest` | `test_mid_bundle_rollback_to_5_5_0_settles_contexts_of_the_new_impl` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 54 | `SuperPaymasterV55UpgradeRace.t.sol:SuperPaymasterV55UpgradeRaceTest` | `test_mid_bundle_upgrade_from_5_5_0_settles_contexts_of_the_old_impl` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |

## 3. G layer: measured gas, Prague vs Amsterdam

Sources: `b_186_prague.log` / `c_186_amsterdam.log` (in-repo tests), `scratch_g_layer.log` and
`scratch_settle_sweep.log` (scratch re-measurement, source in `scratch/AmsScratch.t.sol.txt`).
Bounds are from `SuperPaymasterStorage.sol:187-203`: defaults MIN 200,000 / SETTLE 160,000 /
C_WRAP 5,000 / C_POSTOP 175,000; SETTLE ∈ [155k, 1M], MIN ∈ [SETTLE+20k, 2M], C_POSTOP ∈ [175k, MIN],
C_WRAP ∈ [5k, 50k].

### 3.1 W_postop per path (`SuperPaymasterV55PostOpBound`, 1M budget; `minLimit` = smallest completing gas limit, binary search)

| path | Prague consumed / minLimit | Amsterdam consumed / minLimit | ratio (consumed) |
|---|---|---|---|
| BALANCE first-time user, cold lastTimestamp | 133,927 / 167,387 | 189,547 / 375,484 | 1.42× |
| CREDIT first-time user, cold lastTimestamp, first debt | **147,939** / 167,387 | **291,579** / **379,783** | 1.97× |
| BALANCE during token emergency (E-2) | 133,927 / 167,387 | 189,547 / 375,484 | 1.42× |
| CREDIT during token emergency (E-2) | 147,939 / 167,387 | 291,579 / 379,783 | 1.97× |
| BALANCE old locker after SP rotation (L-3) | 133,927 / 167,387 | 189,547 / 375,484 | 1.42× |
| CREDIT old locker after SP rotation (L-3) | 147,939 / 167,387 | 291,579 / 379,783 | 1.97× |
| BALANCE no rate-limit write (control) | 113,534 / 167,387 | 81,134 / 265,350 | 0.71× |
| BALANCE charge clamped at a0 (control) | 132,574 / 167,387 | 188,194 / 374,064 | 1.42× |
| **W_postop (max)** | **147,939** | **291,579** | **1.97×** |

Under Amsterdam, `minLimit` is far above `consumed`. A frame needs enough gas *available* to pay
the state gas of its fresh SSTOREs. Some of that state gas is refunded within the frame (net
`consumed` can even drop: see the control row and §4), but the limit must still cover the peak.

### 3.2 Rules and margins

| rule / test | quantity | Prague | Amsterdam | default | margin Prague → Amsterdam |
|---|---|---|---|---|---|
| C_POSTOP ≥ W_postop × 1.15 (`test_rule_C_POSTOP_ge_W_postop_times_1_plus_m`) | W × 1.15 | 170,130 | **335,316** | C_POSTOP 175,000 | +18.3% over W → **−40.0%** (C_POSTOP < W itself) |
| T-R14-09: MIN ≥ smallest completing postOp limit (`test_rule_*`, max minLimit) | max minLimit | 167,387 | **379,783** | MIN 200,000 | +19.5% → **−47.3%** |
| T-R14-09 (direct): MIN ≥ postOp × 64/63 + 20k (`test_G_min_post_op_gas_covers_measured_postOp`) | measured postOp → requirement | 142,092 → 164,347 | 212,212 → **235,580** | MIN 200,000 | +21.7% → **−15.1%** |
| T-R14-09 e2e (`test_TR1409_settles_at_MIN_POST_OP_GAS_worst_path`) | op at MIN executes and settles | PASS | **FAIL** ("op at the floor must validate and execute": AA33 at the test's 700k verification limit) | — | — |
| no-OOG band above the entry guard (`test_B1_no_oog_band_above_entry_guard`, `test_settle_floor_keeps_no_oog_band`, `testFuzz_G2_noOOGBand_direct_postOp`) | holds at SETTLE = 160k / 155k | yes | **no** | SETTLE 160,000 | broken |
| no-OOG band SETTLE sweep (scratch, MIN = SETTLE + 20k, C_POSTOP 175k, C_WRAP 5k; postOp gas 100k..650k in 1k steps) | smallest SETTLE with no OOG band | ≤ 155,000 (in-repo tests) | **CREDIT 370,000; BALANCE 380,000** (fails at 155k, 160k, 340k, 360k; BALANCE also fails at 370k) | SETTLE 160,000 | **needs ≥ 380k** |
| same sweep: first settling postOp call gas | — | — | CREDIT 380,000 / BALANCE 399,000 at SETTLE ≤ 380k | — | → MIN ≥ 400k |

The sweep values for SETTLE = 380k–450k are in `scratch_settle_sweep.log`. The Prague run of the
same sweep was killed by the OOM killer (exit 137; no output). Prague's in-repo no-OOG tests
pass at the defaults and at the floor, so no Prague sweep was needed.

### 3.3 C_WRAP (EntryPoint wrap overhead around postOp)

| measurement | Prague | Amsterdam |
|---|---|---|
| in-repo `test_G_wrap_bound_canonical_entrypoint_single_ops` (succeeded/200k, /1M, reverted/200k) | 1,758 / 1,756 / 1,770 | 184,136 / 1,874 / 1,870, and the test FAILS: "postOp really ran 3 != 4" |
| in-repo `…bundle_positions` (pos 0..3) | 1,758 / 1,770 / 1,770 / 1,770 | 184,136 / 74,127 / 74,136 / 74,147 (FAIL) |
| **scratch, probe slots pre-set to non-zero** (single 200k / 1M) | 1,770 / 1,756 | **1,870 / 1,856** (probe ran 2/2) |
| **scratch, probe pre-set, bundle positions 0..3** | 1,770 ×4 | **1,870 ×4** (probe ran 4/4) |

The in-repo Amsterdam figures (184k, 74k) are **artefacts of the probe paymaster, not EntryPoint
overhead**. `PostOpProbePaymaster.postOp` writes `lastPassedGas` and `calls` (zero→non-zero).
Under EIP-8037 those two new slots alone exceed the 200k postOp limit, so the probe's postOp
reverts and the `F − P − limit` formula no longer applies. With those slots pre-set, the real
wrap is **1,870 (+100 vs Prague, EIP-8038 cold access)**. C_WRAP 5,000 keeps 2.67×. The ≥ 2×
headroom assertion still holds. The probe helper needs a fix before the G layer can be re-run on
an Amsterdam chain: pre-initialize its slots, or log through events.

### 3.4 Implication for the GOV-5 tuple (revm Amsterdam constants)

The minimal tuple that satisfies every G rule measured here is **SETTLE ≥ 380,000, MIN ≥ 400,000,
C_POSTOP ≥ 335,316 (≤ MIN), C_WRAP = 5,000**. Every value is inside the hard bounds (SETTLE ≤ 1M,
MIN ≤ 2M, C_POSTOP ≤ MIN, C_WRAP ≤ 50k), so **no UUPS upgrade is needed for the parameters
themselves**. The 15% DSR margin was not added on top of SETTLE / MIN, and the full suite was
**not** re-run with the new tuple (see §7). The hard *lower* bounds (155k / 175k / 5k) do not
constrain anything here.

## 4. Per-function gas (SuperPaymaster, xPNTsTokenV2), Prague vs Amsterdam

`--gas-report` cannot be used without isolation in forge 1.8.6 (§1). The table below comes from
the `-vvvv` call traces of `contracts/test/v2/*`. It reads the gas of every **implementation
frame** (`SuperPaymaster::…` / `xPNTsTokenV2::…` delegatecall), **only in the 213 tests that pass
under both forks**, and only where a test's call sequence is identical under both, so samples are
paired. The values are frame gas, excluding tx intrinsic and refunds applied at tx end.

| function (implementation frame) | samples | Prague min / median / max | Amsterdam min / median / max | ratio of medians | paired ratio min..max |
|---|---|---|---|---|---|
| `SuperPaymaster::postOp` | 23 | 1,479 / 105,823 / 156,172 | 1,479 / 70,274 / 691,692 | 0.66x | 0.63x..4.72x |
| `SuperPaymaster::validatePaymasterUserOp` | 6 | 184,628 / 188,773 / 188,773 | 800,668 / 804,813 / 804,813 | 4.26x | 4.26x..4.34x |
| `xPNTsTokenV2::settleCredit` | 5 | 47,650 / 47,650 / 47,650 | 27,850 / 27,850 / 27,850 | 0.58x | 0.58x..0.58x |
| `xPNTsTokenV2::settleLocked` | 28 | 5,973 / 33,580 / 41,180 | 5,973 / 23,680 / 45,680 | 0.71x | 0.69x..1.11x |
| `xPNTsTokenV2::tryLockForGas` | 61 | 2,372 / 76,002 / 162,281 | 2,372 / 340,062 / 690,401 | 4.47x | 1.00x..4.80x |
| `xPNTsTokenV2::tryReserveCredit` | 15 | 2,187 / 13,507 / 111,578 | 2,187 / 13,507 / 358,333 | 1.00x | 1.00x..3.82x |


Reading:
- **validatePaymasterUserOp ×4.26** (188,773 → 804,813 in the EntryPoint flow). The scratch
  direct calls (first-time user, `scratch_settle_sweep.log`) measure 646k (CREDIT) to 710k
  (BALANCE). Both exceed the 700k `paymasterVerificationGasLimit` that the test ops use. **SDK /
  bundler `paymasterVerificationGasLimit` must rise to at least ~850k (with margin) for SP 5.5
  under Amsterdam.** The ERC-7562 / bundler acceptance of such a limit (B layer) was not tested.
- **tryLockForGas ×4.47** (median 76,002 → 340,062; max 162,281 → 690,401). The lock record is
  a zero→non-zero write. This is the bulk of the validation growth.
- **tryReserveCredit**: median unchanged (most samples are early rejections), max 111,578 → 358,333.
- **postOp / settleLocked / settleCredit go *down* (0.58×–0.71× median)** while their peak need
  goes up (minLimit 167k → 380k, §3.1). These functions clear the lock / reservation records
  (non-zero→zero). In this revm, the state gas of a cleared slot appears to be credited inside the
  frame. That is an observation from the numbers; the revm source was not checked. Consequence: a
  postOp's *net* frame gas (and hence EntryPoint's actualGasCost) can be lower than under Prague,
  but its *gas limit* must be about 2.3× higher.

## 5. Deployment gas

### 5.1 CREATE gas per contract

Contract list: everything `contracts/script/v3/DeployLive.s.sol` (including `V54Bootstrap`,
`V55Bootstrap` and `SuperPaymaster`'s constructor-created extension) and `DeployAPNTsCapped.s.sol`
create, plus OZ TimelockController. Method: `scratch/DeployGas.t.sol.txt`, a separate scratch
project that runs the **shipped profile.default cancun init code** (selected from `out/` by
artifact metadata, `scratch/resolve.py`) in DeployLive's order, with the same kinds of constructor
arguments (deployer = the test contract; a mock Chainlink feed; a real EntryPoint v0.7 instance;
`AOAProtocolRegistry.bootstrapApprove(KIND_TIER_SOURCE, tierSource.codehash)` before
`xPNTsFactoryV2`, as `V55Bootstrap` does). The figure is the gas the CREATE opcode consumed in the
calling frame: 32k base, init-code word cost, constructor execution and code deposit. **It excludes
the 21k tx intrinsic and calldata.** Log: `deploy_gas.log`.

| # | contract (as created by the scripts) | runtime B | initcode+args B | Prague CREATE gas | Amsterdam CREATE gas | ratio | > 2^24 (EIP-7825 cap) under Amsterdam |
|---|---|---|---|---|---|---|---|
| 1 | EntryPoint v0.7 (reference only; canonical, not deployed by us) | 12143 | 12596 | 2,579,259 | 19,551,229 | 7.58x | **YES** |
| 2 | Registry | 23306 | 23670 | 4,771,578 | 36,200,392 | 7.59x | **YES** |
| 3 | ERC1967Proxy (Registry, incl. initialize) | 100 | 863 | 1,338,622 | 6,472,746 | 4.84x | no |
| 4 | xPNTsFactory | 6802 | 25246 | 4,996,345 | 36,659,827 | 7.34x | **YES** |
| 5 | GTokenAuthorization | 6113 | 8332 | 1,326,851 | 9,885,953 | 7.45x | no |
| 6 | GTokenStaking | 9061 | 9616 | 1,915,468 | 14,395,862 | 7.52x | no |
| 7 | MySBT | 12111 | 13460 | 2,616,500 | 19,505,744 | 7.45x | **YES** |
| 8 | SuperPaymaster impl (incl. `new SuperPaymasterAdmin` in ctor) | 13744 | 34647 | 6,903,960 | 51,852,966 | 7.51x | **YES** |
| 9 | ERC1967Proxy (SuperPaymaster, incl. initialize) | 100 | 895 | 219,163 | 1,131,727 | 5.16x | no |
| 10 | SuperPaymasterAdmin standalone (breakdown only; already inside the row above) | 19214 | 20109 | 3,998,682 | 30,062,288 | 7.52x | **YES** |
| 11 | GlobalTierSource | 542 | 769 | 140,884 | 1,025,446 | 7.28x | no |
| 12 | AOAProtocolRegistry | 2746 | 2987 | 605,889 | 4,510,205 | 7.44x | no |
| 13 | xPNTsTokenV2Ext | 22005 | 24175 | 4,469,850 | 33,992,248 | 7.60x | **YES** |
| 14 | xPNTsTokenV2 | 20008 | 22236 | 4,069,915 | 30,935,931 | 7.60x | **YES** |
| 15 | xPNTsFactoryV2 | 8537 | 10884 | 2,246,532 | 15,701,584 | 6.99x | no |
| 16 | SuperPaymasterLens | 5413 | 5439 | 1,116,095 | 8,480,005 | 7.60x | no |
| 17 | ReputationSystem | 7044 | 7790 | 1,555,737 | 11,528,983 | 7.41x | no |
| 18 | DVTValidator | 6326 | 6611 | 1,345,031 | 10,099,339 | 7.51x | no |
| 19 | BLSAggregator | 24345 | 25072 | 5,131,894 | 38,558,810 | 7.51x | **YES** |
| 20 | MicroPaymentChannel | 6117 | 6611 | 1,303,831 | 9,780,133 | 7.50x | no |
| 21 | PaymasterFactory | 6158 | 6280 | 1,311,106 | 9,841,944 | 7.51x | no |
| 22 | Paymaster | 10492 | 10974 | 2,202,763 | 16,586,651 | 7.53x | no |
| 23 | X402Facilitator | 4332 | 4713 | 945,835 | 7,047,751 | 7.45x | no |
| 24 | TimelockController | 5458 | 7019 | 1,248,219 | 9,111,985 | 7.30x | no |
| 25 | PolicyRegistry | 6349 | 6883 | 1,351,549 | 10,136,553 | 7.50x | no |
| 26 | APNTsCapped | 5346 | 8003 | 1,246,796 | 9,049,604 | 7.26x | no |
| 27 | EIP-1167 clone of xPNTsTokenV2 (raw, 45 B runtime) | 45 | 55 | 41,828 | 265,290 | 6.34x | no |
| 28 | EIP-1167 clone of xPNTsToken (3.x aPNTs) (raw, 45 B runtime) | 45 | 55 | 42,097 | 265,559 | 6.31x | no |
| 29 | EIP-1167 clone of Paymaster (raw, 45 B runtime) | 45 | 55 | 41,828 | 265,290 | 6.34x | no |
| | **sum of the 24 CREATEs DeployLive + DeployAPNTsCapped perform directly (excludes the reference/breakdown rows and the raw clone rows; factory clone+initialize calls not measured)** | | | **54,380,413** | **402,492,389** | **7.40x** | |


### 5.2 Block and tx limits

- With `--enable-tx-gas-limit` (revm's EIP-7825 check) and `--isolate`, the Amsterdam-runtime
  CREATE of `Registry` (37.8M) **fails** inside the test; without the check it succeeds
  (`tx_gas_cap_probe.log`, `scratch/Cap.t.sol.txt`). Under cancun it succeeds either way (5.3M).
  This **suggests** that revm applies the 2^24 cap to state gas as well. If Sepolia does the same,
  the 9 contracts marked YES above **cannot be deployed as they are** (they would need splitting).
  If it does not, they fit (largest: SP impl 51.9M against a ~60M block). **Not verified against
  a real Amsterdam node.**
- Cost: about 402.5M gas for a full fresh DeployLive + APNTsCapped, versus 54.4M, plus the
  factory clone + initialize calls (not measured, see §7). A raw EIP-1167 clone alone goes from
  41.8k to 265.3k.

## 6. Answers to the R-AMS checklist

| R-AMS item (§10.8b) | result |
|---|---|
| Re-run G layer: T-R14-09 | **fails** at MIN 200k; needs ≥ 379,783 (≥ 400k with SETTLE + 20k) |
| Re-run G layer: no-OOG scan | **fails** at SETTLE 160k (and 155k); holds from SETTLE ≥ 380k |
| Re-run G layer: C_WRAP | OK: 1,870 ≤ 5,000 once the probe artefact is removed |
| C_POSTOP rule | **fails**: W_postop 291,579 > 175k; needs ≥ 335,316 |
| Values beyond hard bounds? | **No**: all needed values fit GOV-5 bounds, so queue/execute (≥ 96 h), no UUPS |
| `paymasterVerificationGasLimit` (SDK) | **must rise** from 700k to ≥ ~805k measured |
| B layer | **not run** (needs real bundlers on an Amsterdam chain; §7) |

## 7. What could NOT be measured, and why

1. **A real Amsterdam chain.** The task's hard rules forbid public-chain RPC and transactions.
   All numbers are revm 1.8.6's Amsterdam implementation. EIP-8037's cost-per-state-byte is a
   parameter (Sepolia's ~9.3M for ~7 KB versus revm's 10.9M for 7,000 B); the exact values must be
   confirmed on Sepolia before any parameter is queued.
2. **B layer** (Rundler / Alto ERC-7562 compliance, bundler gas estimation, acceptance of an
   ~850k paymaster verification limit): needs bundler binaries and an Amsterdam node. Not available here.
3. **Amsterdam compile target**: solc 0.8.33 has none (max `osaka`). Bytecode was compiled for
   prague (tests) or cancun (deployment) and executed under the Amsterdam runtime.
4. **`forge test --gas-report` without isolation**: forge 1.8.6 forces isolation for gas reports.
   §4 uses traces instead. The forced-isolation reports are kept but not used.
5. **Full-suite re-run with the proposed tuple** (SETTLE 380k / MIN 400k / C_POSTOP ≥ 335,316):
   doing it needs the test constants changed (`MIN_POST_OP_GAS`, `C_WRAP`, op verification limits
   are hard-coded in the tests). Out of scope for a read-only sweep. Only the SETTLE sweep ran
   with MIN = SETTLE + 20k.
6. **Prague SETTLE sweep**: killed by the OOM killer (exit 137). Not needed, since the in-repo
   Prague no-OOG tests pass.
7. **Factory clone + initialize gas** (`xPNTsFactory.deployxPNTsToken`, `xPNTsFactoryV2.deployxPNTsToken`,
   `PaymasterFactory.deployPaymaster`): the factories require a registered community or the
   orchestrated role setup (the 3.x factory reverts `CallerNotCommunity()` in the harness). Only
   the raw 45-byte clone CREATE was measured. The initialize SSTOREs (all zero→non-zero) will add
   a large Amsterdam surcharge.
8. **Exact tx-level deployment gas** (intrinsic, calldata floor, EIP-7825 behaviour on Sepolia): see §5.2.
9. **Per-function samples from tests that fail under Amsterdam** are excluded from §4 by
   construction. The worst-path numbers come from §3 instead.
10. **Prague `-vvvv` trace log** (1.8 GB) was not kept. Regenerate it with the command in §1.2.
    The Amsterdam trace log is kept as `traces_v2_amsterdam.log.gz`.

## 8. Files

| file | content |
|---|---|
| `a_186_cancun.log`, `b_186_prague.log`, `c_186_amsterdam.log`, `d_171_cancun.log` | full `-vv` suite logs (a)–(d) |
| `result_diffs.md` | the three per-test difference tables (prague→amsterdam, 1.7.1→1.8.6, cancun→prague) |
| `function_gas_table.md`, `traces_v2_amsterdam.log.gz` | §4 table; Amsterdam `-vvvv` traces of `contracts/test/v2/*` |
| `scratch_g_layer.log`, `scratch_settle_sweep.log` | §3 scratch re-measurements |
| `deploy_gas.log`, `tx_gas_cap_probe.log` | §5 |
| `probe_calibration.log` | §1.1 runtime-spec probes |
| `gasreport_v2_*_FORCED_ISOLATION.log.gz` | `--gas-report` output (forced isolation, not used for numbers) |
| `timeline.txt` | run timestamps |
| `scratch/` | every scratch source and script used: test files as `.txt` so nothing is compiled from `docs/`, plus `run.sh`, `parse.py`, `diff.py`, `traces.py`, `resolve.py` |

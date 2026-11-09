# Paired measurement gate

`paired_stats.py` validates and analyses the frozen AOA/RepCredit paired designs. It uses only the Python standard library and emits machine-readable JSON (schema `paired-stats-v2`). The AOA analysis follows the preregistration in the AOA paper, `submission_BRA/main.tex`, `\subsection{RQ3: Preregistered Gas-Cost Measurement ...}` (label `sec:gas`).

```bash
python3 scripts/gate/paired_stats.py --design aoa --csv AOA_FROZEN.csv --out AOA_STATS.json
python3 scripts/gate/paired_stats.py --design repcredit --csv REPCREDIT_FROZEN.csv --out REPCREDIT_STATS.json
cd scripts/gate && python3 test_paired_stats.py
```

Exit codes: `0` = `gate: PASS` (target number of complete blocks, confirmatory); `3` = `gate: INCOMPLETE` (JSON still written, `confirmatory: false`); `2` = FAIL (malformed or protocol-violating input, no JSON).

## Fixed constants

The values are fixed by the 2026-10-10 protocol and the RQ3 amendment and have no CLI override: AOA requires 50 complete three-arm matched blocks with at most 60 formal attempts per arm; RepCredit requires 30 complete two-arm cycles with at most 36 formal attempts per arm/cycle. More complete blocks than the target is an error (no outcome-dependent extension). Bootstrap seed `20261010`, 10,000 resamples. Holm family alpha 0.05 over the two AOA primary comparisons. Smaller values passed directly to the internal `analyse()` function are used only to keep fixture tests fast; they are not a supported route for producing paper results.

The only CLI parameter is `--block-length` for the moving-block bootstrap (default and preregistered value `3`). The preregistered length-3 interval is always emitted as `moving_block_bootstrap`; a non-default value adds a separate `moving_block_bootstrap_exploratory` entry (`preregistered_block_length: false`) and never replaces or suppresses the preregistered one.

## Input

Required columns: `REQUIRED_COLUMNS` in the script, plus, for the AOA design, `block_slot` (the block's 0-based position in the pre-generated 60-slot schedule; identical for all rows of a block, unique per block, required on every formal row) and `prior_formal_slots` (one value for the whole file: the number of schedule slots consumed by earlier windows, `0` for the first window). The cap applies across windows: `prior_formal_slots` + this window's formal attempts (per arm) and formal blocks must not exceed 60, and every `block_slot` must lie in `[prior_formal_slots, 60)`. The gate cannot verify the declared prior count; the cross-window attempt manifest must, and `schedule.prior_formal_slots_declared` records that it was declared.

Each formal `(pair_id, arm)` may have at most one attempt: a failed slot is not retried in place; a retry takes a new `pair_id` and slot, and the old block stays incomplete.

A row enters analysis only when `success=true`, `warmup=false`, `injected=false`, `invalid_reason` is empty, and `exclusion_reason` is empty (or `incomplete_block`, see below). Every other row must state the exact mechanically derived exclusion reason, such as `unsuccessful_attempt`, `injected+unsuccessful_attempt`, or `invalid:rpc_mismatch`; otherwise the gate fails. Allowed invalidity codes are limited to `rpc_mismatch`, `chain_reorg`, and `collector_corruption`.

One invocation accepts exactly one `experiment_id`, `window_id`, protocol version, git commit, and runtime-codehash set. Hard failures: duplicate UserOperation hashes, duplicate attempt indices within an arm, unexpected arms, conflicting or shared `block_slot` values, attempt-cap overflow, more than one included row per arm in a block, non-integer or negative values in `txGasUsed` or any optional raw metric column (derived spreads may be negative), a `precheck_refused=true` row that is not an AOA SP attempt, is successful, or carries any receipt/event/trace/validation-context value (`BROADCAST_ONLY_COLUMNS`; a refused attempt is never broadcast), and reconciliation failures (penalty, w_buf, ĉ, c = min(a0, ĉ); below). Reconciliation runs on **every row** whose inputs are present, including rows of incomplete blocks and failed rows, independent of whether the row enters a table.

Optional columns (integers unless noted; empty means "not available for this row"): `sender` (text), `precheck_refused` (bool), `feeBps` (snapshotted or live protocol fee in basis points, as used in `postOp`), `actualGasUsed`, `actualGasCostWei` (C_event), `preVerificationGas`, `l1FeeWei`, `callGasLimit`, `paymasterPostOpGasLimit`, `gasBeforePenalty` (G, trace), `preOpGas` (G_preOp, trace), `cPreWei` (C_pre, `postOp` argument), `bufWei` (w_buf), `gBufGas` (g_buf), `actualUserOpFeePerGas` (p_op), `aPNTsPerWeiNum` / `aPNTsPerWeiDen` (P as an exact rational, aPNTs per wei), `chargeAPNTs` (c), `chargeHatAPNTs` (ĉ, pre-cap), `a0APNTs` (a0), `refundPostopCost` (TPM r), `actualTokenNeeded` (TPM charge), `tokenChargeWei` (TPM charge converted to wei by the collector with the contract's integer scaling at the postOp-updated cached price before markup).

## Incomplete blocks (B1)

A block is analysed only when every arm has an included row. Blocks among the formal `pair_id`s that miss an arm are listed in `incomplete_blocks` with `reason: incomplete_block`, `missing_arms`, per-arm `reason_codes` (`<arm>:<exclusion reasons>` or `<arm>:no_row`), and their successful rows with costs under `successful_rows_not_analysed`; they are counted in `incomplete_block_count` / `block_exclusion_counts` and do not enter any statistic. A successful row may carry `exclusion_reason=incomplete_block`; the gate checks that its block is in fact incomplete. If fewer than the target number of complete blocks exist, the result is `INCOMPLETE`; the statistics over the complete blocks are still emitted but are not confirmatory.

## Output

Per primary comparison (`SP-VerifyingPaymaster`, `SP-TokenPaymaster`; RepCredit `credit-balance`), over complete blocks in `block_slot` order:

- `mean_difference`, `median_difference`, `min_difference`, `max_difference`, `n`;
- `bootstrap_mean_95ci`: marginal (unadjusted, i.i.d.) percentile bootstrap of the mean; endpoints are the `ceil(0.025B)`-th and `ceil(0.975B)`-th order statistics of the B resampled means;
- `signs`: `positive` / `negative` / `zero` / `n_nonzero`;
- `exact_two_sided_sign_p`: exact two-sided binomial sign test with zero differences dropped (with 50 non-zero differences, p ≤ 0.025 iff at least 34 share a sign);
- AOA only: `holm_adjusted_sign_p` (Holm step-down over the two comparisons) and `holm_reject_family_alpha` (adjusted p ≤ 0.05; equivalently the smaller raw p is tested at 0.025 and the larger at 0.05);
- `moving_block_bootstrap`: sensitivity interval for the mean from a moving-block bootstrap (overlapping blocks of length L, ceil(n/L) blocks per resample, truncated to n, same seed and resample count) over the retained blocks in `block_slot` order; `contiguous_schedule` is false when slots are missing, and `schedule.missing_slots` lists them. With L = 1 the result equals the marginal bootstrap.

`secondary_metrics`: per arm, descriptive summaries (n, mean, median, sample SD, min, max, nearest-rank P95, unadjusted marginal bootstrap 95% CI of the mean; no tests) over complete blocks for `txGasUsed`, `actualGasUsed`, `residual_actualGasUsed_minus_txGasUsed`, `preVerificationGas`, `unusedGasPenalty` (recomputed as ⌊10·max(0, L_call + L_postOp − (G − G_preOp))/100⌋ and checked against `actualGasUsed − G` when `actualGasUsed` is present), `l1FeeWei`, `C_event_actualGasCostWei`, `bufferRatio_wbuf_over_Cpre` (SP; `bufWei` is cross-checked against (g_buf + ⌈0.1(L_call + L_postOp)⌉)·p_op when those columns exist), `s0_wei` (SP: ⌈(C_pre + w_buf)P⌉/P − C_event; TPM: C_pre + r·p_op − C_event), `sc_wei` (SP: c/P − C_event, with c = min(a0, ĉ) checked; TPM: `tokenChargeWei` − C_event), `charge_token_units`, and `cap_binding_counts` (SP: ĉ > a0 and ĉ = a0). ĉ is reconstructed as ⌈⌈(C_pre + w_buf)P⌉·(10000 + feeBps)/10000⌉ (SuperPaymaster.sol `aGas` and `charge`, both `Rounding.Ceil`); a declared `chargeHatAPNTs` must equal the reconstruction. Without `feeBps` (or other inputs) the declared ĉ is used and `c_hat_verification` says `unverified`. Each entry has `status`: `ok`, `partial` (some blocks lack values; listed), `empty`, `absent` (input columns missing; named in `missing_columns`), or `not_applicable` (e.g. VPM spreads).

`schedule` (retained slots in order; `missing_slots` from `prior_formal_slots` to the last attempted slot; `missing_slots_without_any_formal_row`; `unexecuted_slots_after_window`). `arm_counts` (formal attempts, included, analysed, successful-in-incomplete-block, failed attempts with receipt gas sum, failed-attempt `actualGasCostWei` with known/missing row counts and `ok`/`partial`/`empty`/`absent` status — unknown cost is never reported as 0, precheck refusals when the column exists), `exclusion_counts`, `exclusion_counts_by_arm`, and `per_account` (per arm and `sender`: n, mean/median/min/max `txGasUsed`; `absent` without a `sender` column).

## Scope

This is a **paired-statistics CSV gate only**. It does not prove that a receipt, event, transaction hash, runtime codehash, RPC response, or other Passport value is authentic or complete. Those properties require the separately specified two-RPC receipt/event reconciliation, deployment-bytecode check, state snapshots, and evidence-manifest verification before this script is run. Trace-derived inputs (C_pre, G, G_preOp) and the P rational are taken as given from the collector.

The sign-test p-values are secondary diagnostics for the balance of signs; they do not by themselves support a claim about the mean. Both bootstrap procedures and the sign test treat blocks as exchangeable; the moving-block interval is a sensitivity check and does not establish independence.

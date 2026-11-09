#!/usr/bin/env python3
"""Validate a frozen paired-measurement CSV and compute paired gas statistics.

This gate implements the pre-registered AOA/RepCredit designs in
AOA_RepCredit_Separated_Measurement_Protocol_2026-10-10.md as amended by the
AOA v8 RQ3 subsection (main.tex, \\subsection{RQ3: Preregistered Gas-Cost
Measurement}).  Gate schema: paired-stats-v2.

Fail-closed rules (GateError, exit 2): one invocation may contain only one
experiment/window/pin; every non-analysis row needs its mechanically derived
exclusion reason; duplicate IDs, unknown arms, conflicting block slots and
non-numeric metric values are errors.

Block-level rule (B1): a matched block is analysed only when every arm has
exactly one included (successful, formal, non-injected, valid) row.  Blocks
that miss an arm are *reported* -- counted, listed with per-arm reason codes,
and their successful rows listed with costs -- but excluded from inference.
If fewer complete blocks than the design target exist, the result is
`gate: INCOMPLETE` (exit 3): structured accounting, no confirmatory claim.

Required CSV columns are REQUIRED_COLUMNS plus DESIGN_REQUIRED_COLUMNS for the
design.  `pair_id` is the AOA matched block or RepCredit paired cycle;
`block_slot` is the block's position in the pre-generated schedule (same for
every row of a block, unique per block).  Optional metric columns are listed in
OPTIONAL_INT_COLUMNS; a metric whose inputs are absent is reported as
`status: absent` with the missing columns named.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import random
import statistics
import sys
from collections import Counter, defaultdict
from fractions import Fraction
from pathlib import Path


SCHEMA = "paired-stats-v2"

DESIGNS = {
    "aoa": {
        "paper_id": "AOA",
        "arms": ("SP", "VerifyingPaymaster", "TokenPaymaster"),
        "reference": "SP",
        "expected_pairs": 50,
        "attempt_cap": 60,
        "holm": True,
    },
    "repcredit": {
        "paper_id": "RepCredit",
        "arms": ("balance", "credit"),
        "reference": "credit",
        "expected_pairs": 30,
        "attempt_cap": 36,
        "holm": False,
    },
}

REQUIRED_COLUMNS = {
    "paper_id", "experiment_id", "window_id", "protocol_version",
    "git_commit", "runtime_codehashes", "arm", "pair_id", "attempt_index",
    "userOpHash", "txGasUsed", "success", "warmup", "injected",
    "invalid_reason", "exclusion_reason",
}

# AOA: the moving-block bootstrap runs over retained blocks in schedule order,
# so the schedule position is mandatory; the attempt cap applies across all
# windows, so the number of schedule slots consumed by earlier windows
# (`prior_formal_slots`, constant within the file, 0 for the first window) is
# mandatory as well.  The gate cannot verify that declared value; the
# cross-window attempt manifest must.
DESIGN_REQUIRED_COLUMNS = {"aoa": {"block_slot", "prior_formal_slots"}, "repcredit": set()}

# Optional integer columns (gas units, wei, token base units, rational parts).
# All raw values are non-negative; derived spreads may be negative.
OPTIONAL_INT_COLUMNS = (
    "block_slot", "prior_formal_slots",
    "actualGasUsed", "actualGasCostWei", "preVerificationGas", "l1FeeWei",
    "callGasLimit", "paymasterPostOpGasLimit", "gasBeforePenalty", "preOpGas",
    "cPreWei", "bufWei", "gBufGas", "actualUserOpFeePerGas",
    "aPNTsPerWeiNum", "aPNTsPerWeiDen", "feeBps", "chargeAPNTs", "chargeHatAPNTs", "a0APNTs",
    "refundPostopCost", "actualTokenNeeded", "tokenChargeWei",
)
# Receipt / event / trace / validation-context fields that a precheck-refused
# (never broadcast) attempt must leave empty.  UserOperation fields
# (gas limits, preVerificationGas) and state reads (price, fee) may be filled.
BROADCAST_ONLY_COLUMNS = ("txGasUsed", "actualGasUsed", "actualGasCostWei", "l1FeeWei",
                          "gasBeforePenalty", "preOpGas", "cPreWei", "bufWei", "gBufGas",
                          "actualUserOpFeePerGas", "chargeAPNTs", "chargeHatAPNTs", "a0APNTs",
                          "refundPostopCost", "actualTokenNeeded", "tokenChargeWei")
PRECHECK_ARM = "SP"          # the sampler runs sp_attempt_precheck before SP attempts only
BPS_DENOMINATOR = 10_000     # SuperPaymasterStorage.sol
OPTIONAL_BOOL_COLUMNS = ("precheck_refused",)
OPTIONAL_TEXT_COLUMNS = ("sender",)

TRUE = {"true", "1"}
FALSE = {"false", "0"}
ALLOWED_INVALID_REASONS = {"rpc_mismatch", "chain_reorg", "collector_corruption"}
INCOMPLETE_BLOCK = "incomplete_block"
BOOTSTRAP_SEED = 20261010
BOOTSTRAP_RESAMPLES = 10_000
MOVING_BLOCK_LENGTH = 3
FAMILY_ALPHA = 0.05          # Holm over the two AOA primary comparisons
PENALTY_PERCENT = 10         # EntryPoint v0.7 _postExecution


class GateError(ValueError):
    """Input violates a pre-registered gate."""


# ---------------------------------------------------------------- parsing --

def parse_bool(value: str, field: str, row_number: int) -> bool:
    value = value.strip().lower()
    if value in TRUE:
        return True
    if value in FALSE:
        return False
    raise GateError(f"row {row_number}: {field} must be true/false or 1/0")


def parse_int(value: str, field: str, row_number: int) -> int:
    try:
        return int(value)
    except ValueError as exc:
        raise GateError(f"row {row_number}: {field}={value!r} is not an integer") from exc


def expected_exclusion(row: dict[str, object]) -> str:
    reasons = []
    if row["warmup"]:
        reasons.append("warmup")
    if row["injected"]:
        reasons.append("injected")
    if row["invalid_reason"]:
        reasons.append(f"invalid:{row['invalid_reason']}")
    if not row["success"]:
        reasons.append("unsuccessful_attempt")
    return "+".join(reasons)


def load_rows(path: Path) -> tuple[list[dict[str, object]], str, set[str]]:
    raw = path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise GateError("CSV has no header")
        fieldnames = reader.fieldnames
        blank_headers = [index + 1 for index, name in enumerate(fieldnames) if not name or not name.strip()]
        if blank_headers:
            raise GateError(f"blank CSV header names at columns: {blank_headers}")
        whitespace_headers = [name for name in fieldnames if name != name.strip()]
        if whitespace_headers:
            raise GateError(f"CSV header names may not have surrounding whitespace: {whitespace_headers}")
        duplicate_headers = sorted(name for name, count in Counter(fieldnames).items() if count > 1)
        if duplicate_headers:
            raise GateError(f"duplicate CSV header names: {duplicate_headers}")
        missing = sorted(REQUIRED_COLUMNS - set(fieldnames))
        if missing:
            raise GateError("missing required columns: " + ", ".join(missing))
        columns = set(fieldnames)
        int_columns = [name for name in OPTIONAL_INT_COLUMNS if name in columns]
        bool_columns = [name for name in OPTIONAL_BOOL_COLUMNS if name in columns]
        rows: list[dict[str, object]] = []
        for row_number, raw_row in enumerate(reader, start=2):
            if None in raw_row:
                extras = raw_row[None]
                count = len(extras) if isinstance(extras, list) else 1
                raise GateError(f"row {row_number}: {count} extra unnamed CSV field(s)")
            non_text = sorted(key for key, value in raw_row.items() if value is not None and not isinstance(value, str))
            if non_text:
                raise GateError(f"row {row_number}: non-text CSV values in columns: {non_text}")
            row: dict[str, object] = {str(key): (value or "").strip() for key, value in raw_row.items()}
            row["_row"] = row_number
            for field in ("paper_id", "experiment_id", "window_id", "protocol_version",
                          "git_commit", "runtime_codehashes", "arm", "pair_id"):
                if not row[field]:
                    raise GateError(f"row {row_number}: {field} is required")
            row["attempt_index"] = parse_int(str(row["attempt_index"]), "attempt_index", row_number)
            if row["attempt_index"] < 0:
                raise GateError(f"row {row_number}: attempt_index must be non-negative")
            for field in ("success", "warmup", "injected"):
                row[field] = parse_bool(str(row[field]), field, row_number)
            for field in bool_columns:
                row[field] = parse_bool(str(row[field]), field, row_number) if row[field] else None
            for field in int_columns:
                row[field] = parse_int(str(row[field]), field, row_number) if row[field] else None
                if row[field] is not None and row[field] < 0:
                    raise GateError(f"row {row_number}: {field} must be non-negative")
            if row["invalid_reason"] and row["invalid_reason"] not in ALLOWED_INVALID_REASONS:
                allowed = ", ".join(sorted(ALLOWED_INVALID_REASONS))
                raise GateError(f"row {row_number}: invalid_reason must be one of {allowed}")
            expected = expected_exclusion(row)
            declared = row["exclusion_reason"]
            # A successful formal row may carry the block-level reason
            # `incomplete_block`; the gate verifies it after block composition.
            row["declared_incomplete_block"] = expected == "" and declared == INCOMPLETE_BLOCK
            if declared != expected and not row["declared_incomplete_block"]:
                raise GateError(
                    f"row {row_number}: exclusion_reason={declared!r}; "
                    f"expected {expected!r} (no silent exclusion or inclusion allowed)"
                )
            included = expected == ""
            row["included"] = included
            if included:
                if not row["userOpHash"]:
                    raise GateError(f"row {row_number}: included row requires userOpHash")
                row["txGasUsed"] = parse_int(str(row["txGasUsed"]), "txGasUsed", row_number)
                if row["txGasUsed"] <= 0:
                    raise GateError(f"row {row_number}: txGasUsed must be positive")
            elif row["txGasUsed"]:
                row["txGasUsed"] = parse_int(str(row["txGasUsed"]), "txGasUsed", row_number)
                if row["txGasUsed"] < 0:
                    raise GateError(f"row {row_number}: txGasUsed must be non-negative")
            else:
                row["txGasUsed"] = None
            if row.get("precheck_refused"):
                if row["success"]:
                    raise GateError(f"row {row_number}: precheck_refused attempt cannot be successful")
                filled = [name for name in BROADCAST_ONLY_COLUMNS if row.get(name) not in (None, "")]
                if filled:
                    raise GateError(f"row {row_number}: precheck_refused attempt was not broadcast "
                                    f"but has values in {filled}")
            rows.append(row)
    if not rows:
        raise GateError("CSV contains no data rows")
    return rows, digest, columns


def one_value(rows: list[dict[str, object]], field: str) -> str:
    values = {str(row[field]) for row in rows}
    if len(values) != 1:
        raise GateError(f"mixed {field} values are forbidden: {sorted(values)}")
    return next(iter(values))


# ------------------------------------------------------------- statistics --

def percentile_bounds(sorted_means: list[float], resamples: int) -> dict[str, float]:
    lo_index = max(0, math.ceil(0.025 * resamples) - 1)
    hi_index = min(resamples - 1, math.ceil(0.975 * resamples) - 1)
    return {"low": sorted_means[lo_index], "high": sorted_means[hi_index]}


def bootstrap_ci(values: list[int], seed: int, resamples: int) -> dict[str, float]:
    """Marginal (i.i.d.) percentile bootstrap of the mean."""
    if resamples < 100:
        raise GateError("bootstrap resamples must be >= 100")
    rng = random.Random(seed)
    n = len(values)
    means = []
    for _ in range(resamples):
        means.append(sum(values[rng.randrange(n)] for _ in range(n)) / n)
    means.sort()
    return percentile_bounds(means, resamples)


def moving_block_bootstrap_ci(values: list[int], block_length: int, seed: int,
                              resamples: int) -> dict[str, float]:
    """Moving-block percentile bootstrap of the mean (Kuensch 1989).

    Overlapping blocks of `block_length` consecutive values (n - L + 1 start
    positions) are drawn uniformly with replacement, ceil(n / L) per resample,
    concatenated in draw order and truncated to n.  With L = 1 the draw stream
    is identical to bootstrap_ci, so both give the same interval.
    """
    if resamples < 100:
        raise GateError("bootstrap resamples must be >= 100")
    n = len(values)
    if block_length < 1 or block_length > n:
        raise GateError(f"block length {block_length} must be in [1, n={n}]")
    starts = n - block_length + 1
    blocks_needed = math.ceil(n / block_length)
    rng = random.Random(seed)
    means = []
    for _ in range(resamples):
        total, taken = 0, 0
        for _ in range(blocks_needed):
            start = rng.randrange(starts)
            for offset in range(block_length):
                if taken == n:
                    break
                total += values[start + offset]
                taken += 1
        means.append(total / n)
    means.sort()
    return percentile_bounds(means, resamples)


def float_bootstrap_ci(values: list[float], seed: int, resamples: int) -> dict[str, float]:
    """Marginal percentile bootstrap for descriptive secondary metrics."""
    rng = random.Random(seed)
    n = len(values)
    means = sorted(math.fsum(rng.choices(values, k=n)) / n for _ in range(resamples))
    return percentile_bounds(means, resamples)


def exact_sign_test(values: list[int]) -> float:
    """Exact two-sided binomial sign test; zero differences are dropped."""
    nonzero = [value for value in values if value != 0]
    n = len(nonzero)
    if n == 0:
        return 1.0
    positives = sum(value > 0 for value in nonzero)
    tail = min(positives, n - positives)
    probability = sum(math.comb(n, k) for k in range(tail + 1)) / (2 ** n)
    return min(1.0, 2.0 * probability)


def holm_adjust(p_values: dict[str, float]) -> dict[str, float]:
    """Holm step-down adjusted p-values (monotone, capped at 1)."""
    ordered = sorted(p_values.items(), key=lambda item: (item[1], item[0]))
    adjusted: dict[str, float] = {}
    running = 0.0
    total = len(ordered)
    for rank, (label, p_value) in enumerate(ordered):
        running = max(running, min(1.0, (total - rank) * p_value))
        adjusted[label] = running
    return adjusted


def sign_counts(values: list[int]) -> dict[str, int]:
    return {
        "positive": sum(value > 0 for value in values),
        "negative": sum(value < 0 for value in values),
        "zero": sum(value == 0 for value in values),
        "n_nonzero": sum(value != 0 for value in values),
    }


def to_json_number(value: Fraction | int | float) -> int | float:
    if isinstance(value, Fraction):
        return value.numerator if value.denominator == 1 else float(value)
    return value


def describe(values: list[Fraction | int], seed: int, resamples: int) -> dict[str, object]:
    """Descriptive summary: unadjusted bootstrap interval, no test."""
    exact = sorted(Fraction(value) for value in values)
    n = len(exact)
    mean = sum(exact, Fraction(0)) / n
    p95 = exact[math.ceil(0.95 * n) - 1]       # nearest rank (48th of 50)
    floats = [float(value) for value in exact]
    return {
        "n": n,
        "mean": to_json_number(mean),
        "median": to_json_number(statistics.median(exact)),
        "sd": float(statistics.stdev(exact)) if n >= 2 else None,
        "min": to_json_number(exact[0]),
        "max": to_json_number(exact[-1]),
        "p95_nearest_rank": to_json_number(p95),
        "bootstrap_mean_95ci_unadjusted": float_bootstrap_ci(floats, seed, resamples),
    }


# -------------------------------------------------------- secondary metrics --

def ceil_fraction(value: Fraction) -> int:
    return -((-value.numerator) // value.denominator)


def rate(row: dict[str, object]) -> Fraction:
    num, den = row["aPNTsPerWeiNum"], row["aPNTsPerWeiDen"]
    if num <= 0 or den <= 0:
        raise GateError(f"row {row['_row']}: aPNTsPerWeiNum/Den must be positive")
    return Fraction(num, den)


def unused_gas_penalty(row: dict[str, object]) -> int:
    """floor(10 * max(0, L_call + L_postOp - (G - G_preOp)) / 100), EntryPoint v0.7."""
    unused = row["callGasLimit"] + row["paymasterPostOpGasLimit"] - (row["gasBeforePenalty"] - row["preOpGas"])
    penalty = (max(0, unused) * PENALTY_PERCENT) // 100
    if row.get("actualGasUsed") is not None and row["actualGasUsed"] - row["gasBeforePenalty"] != penalty:
        raise GateError(
            f"row {row['_row']}: actualGasUsed - gasBeforePenalty = "
            f"{row['actualGasUsed'] - row['gasBeforePenalty']} but recomputed penalty is {penalty}"
        )
    return penalty


def sp_buffer_wei(row: dict[str, object]) -> int:
    """bufWei, cross-checked against (g_buf + ceil(0.1 (L_call + L_postOp))) p_op when inputs exist."""
    buf = row["bufWei"]
    if all(row.get(name) is not None for name in
           ("gBufGas", "callGasLimit", "paymasterPostOpGasLimit", "actualUserOpFeePerGas")):
        limits = row["callGasLimit"] + row["paymasterPostOpGasLimit"]
        expected = (row["gBufGas"] + ceil_fraction(Fraction(limits, 10))) * row["actualUserOpFeePerGas"]
        if expected != buf:
            raise GateError(f"row {row['_row']}: bufWei={buf} but recomputed w_buf={expected}")
    return buf


def sp_buffer_ratio(row: dict[str, object]) -> Fraction:
    if row["cPreWei"] <= 0:
        raise GateError(f"row {row['_row']}: cPreWei must be positive")
    return Fraction(sp_buffer_wei(row), row["cPreWei"])


def sp_pre_fee_apnts(row: dict[str, object]) -> int:
    """ceil((C_pre + w_buf) P): SuperPaymaster.sol aGas (mulDiv, Rounding.Ceil)."""
    return ceil_fraction((row["cPreWei"] + sp_buffer_wei(row)) * rate(row))


def sp_s0(row: dict[str, object]) -> Fraction:
    return Fraction(sp_pre_fee_apnts(row)) / rate(row) - row["actualGasCostWei"]


CHAT_INPUTS = ("cPreWei", "bufWei", "aPNTsPerWeiNum", "aPNTsPerWeiDen", "feeBps")


def sp_chat(row: dict[str, object]) -> tuple[int | None, bool]:
    """Pre-cap charge c_hat = ceil(ceil((C_pre + w_buf) P) (1 + f)), f = feeBps / 10000.

    Returns (c_hat, reconstructed).  When the reconstruction inputs are present
    the value is recomputed and any declared chargeHatAPNTs must match it;
    otherwise the declared value is returned unverified.
    """
    declared = row.get("chargeHatAPNTs")
    if all(row.get(name) is not None for name in CHAT_INPUTS):
        chat = ceil_fraction(Fraction(sp_pre_fee_apnts(row) * (BPS_DENOMINATOR + row["feeBps"]),
                                      BPS_DENOMINATOR))
        if declared is not None and declared != chat:
            raise GateError(f"row {row['_row']}: chargeHatAPNTs={declared} but reconstructed c_hat={chat}")
        return chat, True
    return declared, False


def sp_check_charge(row: dict[str, object]) -> None:
    chat, _ = sp_chat(row)
    if chat is not None and row.get("a0APNTs") is not None and row.get("chargeAPNTs") is not None:
        if row["chargeAPNTs"] != min(row["a0APNTs"], chat):
            raise GateError(f"row {row['_row']}: chargeAPNTs != min(a0APNTs, c_hat)")


def sp_sc(row: dict[str, object]) -> Fraction:
    sp_check_charge(row)
    return Fraction(row["chargeAPNTs"]) / rate(row) - row["actualGasCostWei"]


PENALTY_INPUTS = ("callGasLimit", "paymasterPostOpGasLimit", "gasBeforePenalty", "preOpGas")


def reconcile_row(row: dict[str, object]) -> None:
    """Row-level consistency checks, run on every row whose inputs are present,
    independent of whether the row enters any statistic or table."""
    if all(row.get(name) is not None for name in PENALTY_INPUTS):
        unused_gas_penalty(row)
    if row["arm"] == "SP":
        if row.get("bufWei") is not None:
            sp_buffer_wei(row)
        sp_check_charge(row)          # reconstructs c_hat (and checks the declared one) when possible
        sp_chat(row)


ALL = None  # metric applies to every arm

# name -> list of (arms or ALL, required columns, function(row) -> number)
SECONDARY_METRICS: dict[str, list[tuple[object, tuple[str, ...], object]]] = {
    "txGasUsed": [(ALL, ("txGasUsed",), lambda r: r["txGasUsed"])],
    "actualGasUsed": [(ALL, ("actualGasUsed",), lambda r: r["actualGasUsed"])],
    "residual_actualGasUsed_minus_txGasUsed": [
        (ALL, ("actualGasUsed", "txGasUsed"), lambda r: r["actualGasUsed"] - r["txGasUsed"])],
    "preVerificationGas": [(ALL, ("preVerificationGas",), lambda r: r["preVerificationGas"])],
    "unusedGasPenalty": [
        (ALL, ("callGasLimit", "paymasterPostOpGasLimit", "gasBeforePenalty", "preOpGas"), unused_gas_penalty)],
    "l1FeeWei": [(ALL, ("l1FeeWei",), lambda r: r["l1FeeWei"])],
    "C_event_actualGasCostWei": [(ALL, ("actualGasCostWei",), lambda r: r["actualGasCostWei"])],
    "bufferRatio_wbuf_over_Cpre": [(("SP",), ("bufWei", "cPreWei"), sp_buffer_ratio)],
    "s0_wei": [
        (("SP",), ("cPreWei", "bufWei", "aPNTsPerWeiNum", "aPNTsPerWeiDen", "actualGasCostWei"), sp_s0),
        (("TokenPaymaster",), ("cPreWei", "refundPostopCost", "actualUserOpFeePerGas", "actualGasCostWei"),
         lambda r: r["cPreWei"] + r["refundPostopCost"] * r["actualUserOpFeePerGas"] - r["actualGasCostWei"]),
    ],
    "sc_wei": [
        (("SP",), ("chargeAPNTs", "aPNTsPerWeiNum", "aPNTsPerWeiDen", "actualGasCostWei"), sp_sc),
        (("TokenPaymaster",), ("tokenChargeWei", "actualGasCostWei"),
         lambda r: r["tokenChargeWei"] - r["actualGasCostWei"]),
    ],
    "charge_token_units": [
        (("SP",), ("chargeAPNTs",), lambda r: r["chargeAPNTs"]),
        (("TokenPaymaster",), ("actualTokenNeeded",), lambda r: r["actualTokenNeeded"]),
    ],
}


def secondary_tables(complete: dict[str, dict[str, dict[str, object]]], arms: tuple[str, ...],
                     columns: set[str], seed: int, resamples: int) -> dict[str, object]:
    tables: dict[str, object] = {}
    for metric, specs in SECONDARY_METRICS.items():
        per_arm: dict[str, object] = {}
        for arm in arms:
            spec = next((s for s in specs if s[0] is ALL or arm in s[0]), None)
            if spec is None:
                per_arm[arm] = {"status": "not_applicable"}
                continue
            _, needed, function = spec
            absent = [name for name in needed if name not in columns]
            if absent:
                per_arm[arm] = {"status": "absent", "missing_columns": absent}
                continue
            values, empty_blocks = [], []
            for pair_id in sorted(complete):
                row = complete[pair_id][arm]
                if any(row.get(name) is None for name in needed):
                    empty_blocks.append(pair_id)
                    continue
                values.append(function(row))
            if not values:
                per_arm[arm] = {"status": "empty", "rows_missing_values": empty_blocks}
                continue
            entry = {"status": "ok" if not empty_blocks else "partial", **describe(values, seed, resamples)}
            if empty_blocks:
                entry["rows_missing_values"] = empty_blocks
            per_arm[arm] = entry
        tables[metric] = per_arm

    # Cap-binding counts (SP only): c_hat > a0 and c_hat = a0.
    cap: dict[str, object] = {}
    for arm in arms:
        if arm != "SP":
            cap[arm] = {"status": "not_applicable"}
            continue
        if "a0APNTs" not in columns or ("chargeHatAPNTs" not in columns
                                        and any(name not in columns for name in CHAT_INPUTS)):
            needed = ["a0APNTs", *CHAT_INPUTS]
            cap[arm] = {"status": "absent",
                        "missing_columns": [name for name in needed if name not in columns]}
            continue
        rows = [complete[p][arm] for p in sorted(complete)]
        usable, reconstructed = [], 0
        for r in rows:
            chat, rebuilt = sp_chat(r)
            if chat is None or r["a0APNTs"] is None:
                continue
            sp_check_charge(r)
            usable.append((chat, r["a0APNTs"]))
            reconstructed += rebuilt
        if not usable:
            cap[arm] = {"status": "empty", "n": 0}
            continue
        if reconstructed == len(usable):
            verification = "reconstructed"
        elif reconstructed == 0:
            verification = "unverified (declared chargeHatAPNTs; feeBps or other inputs absent)"
        else:
            verification = "mixed"
        cap[arm] = {
            "status": "ok" if len(usable) == len(rows) else "partial",
            "n": len(usable),
            "c_hat_verification": verification,
            "c_hat_reconstructed_rows": reconstructed,
            "cap_binding_chat_gt_a0": sum(chat > a0 for chat, a0 in usable),
            "cap_equal_chat_eq_a0": sum(chat == a0 for chat, a0 in usable),
        }
    tables["cap_binding_counts"] = cap
    return tables


# ---------------------------------------------------------------- analysis --

def mbb_entry(differences: list[int], block_length: int, retained_slots: list[int] | None,
              missing_slots: list[int] | None, seed: int, resamples: int) -> dict[str, object]:
    entry: dict[str, object] = {
        "block_length": block_length,
        "preregistered_block_length": block_length == MOVING_BLOCK_LENGTH,
    }
    if retained_slots is None:
        return {**entry, "status": "not_computed", "reason": "block_slot column absent (no schedule order)"}
    if len(differences) < block_length:
        return {**entry, "status": "not_computed",
                "reason": f"n={len(differences)} < block length {block_length}"}
    return {
        **entry,
        "status": "ok",
        "order": "retained blocks by block_slot",
        "contiguous_schedule": not missing_slots,
        "mean_95ci": moving_block_bootstrap_ci(differences, block_length, seed, resamples),
    }


def block_reason(rows_for_arm: list[dict[str, object]], arm: str) -> str:
    if not rows_for_arm:
        return f"{arm}:no_row"
    reasons = sorted({str(row["exclusion_reason"]) or "included" for row in rows_for_arm})
    return f"{arm}:" + "|".join(reasons)


def analyse(path: Path, design_name: str, expected_pairs: int | None,
            attempt_cap: int | None, seed: int, resamples: int,
            block_length: int = MOVING_BLOCK_LENGTH) -> dict[str, object]:
    design = DESIGNS[design_name]
    expected_pairs = expected_pairs if expected_pairs is not None else int(design["expected_pairs"])
    attempt_cap = attempt_cap if attempt_cap is not None else int(design["attempt_cap"])
    if expected_pairs <= 0 or attempt_cap < expected_pairs:
        raise GateError("attempt cap must be >= a positive expected-pairs value")
    if block_length < 1:
        raise GateError("moving-block length must be >= 1")

    rows, digest, columns = load_rows(path)
    missing_design = sorted(DESIGN_REQUIRED_COLUMNS[design_name] - columns)
    if missing_design:
        raise GateError(f"design {design_name} requires columns: {', '.join(missing_design)}")
    paper_id = one_value(rows, "paper_id")
    if paper_id != design["paper_id"]:
        raise GateError(f"design {design_name} requires paper_id={design['paper_id']}, got {paper_id}")
    identity = {
        field: one_value(rows, field)
        for field in ("experiment_id", "window_id", "protocol_version", "git_commit", "runtime_codehashes")
    }

    arms = tuple(design["arms"])
    unexpected = sorted({str(row["arm"]) for row in rows} - set(arms))
    if unexpected:
        raise GateError(f"unexpected arms for {design_name}: {unexpected}")
    for row in rows:
        if row.get("precheck_refused") and (design_name != "aoa" or row["arm"] != PRECHECK_ARM):
            raise GateError(f"row {row['_row']}: precheck_refused applies only to {PRECHECK_ARM} attempts "
                            "in the AOA design")
        reconcile_row(row)

    hashes = [str(row["userOpHash"]) for row in rows if row["userOpHash"]]
    duplicate_hashes = sorted(value for value, count in Counter(hashes).items() if count > 1)
    if duplicate_hashes:
        raise GateError(f"duplicate userOpHash values: {duplicate_hashes[:5]}")

    # Attempts consumed by earlier windows count toward the cap (cross-window).
    prior_slots = 0
    if "prior_formal_slots" in columns:
        declared_prior = {row["prior_formal_slots"] for row in rows}
        if len(declared_prior) != 1 or None in declared_prior:
            raise GateError("prior_formal_slots must be one non-empty value for the whole file")
        prior_slots = int(next(iter(declared_prior)))

    for arm in arms:
        indices = [int(row["attempt_index"]) for row in rows if row["arm"] == arm]
        duplicates = sorted(value for value, count in Counter(indices).items() if count > 1)
        if duplicates:
            raise GateError(f"arm {arm}: duplicate attempt_index values: {duplicates}")
        formal_attempts = [row for row in rows if row["arm"] == arm and not row["warmup"] and not row["injected"]]
        if prior_slots + len(formal_attempts) > attempt_cap:
            raise GateError(f"arm {arm}: {prior_slots} prior + {len(formal_attempts)} formal attempts "
                            f"exceeds cap {attempt_cap}")

    formal_rows = [row for row in rows if not row["warmup"] and not row["injected"]]
    formal_pair_ids = {str(row["pair_id"]) for row in formal_rows}
    if prior_slots + len(formal_pair_ids) > attempt_cap:
        raise GateError(f"{prior_slots} prior + {len(formal_pair_ids)} formal pair/cycle IDs "
                        f"exceeds cap {attempt_cap}")

    # One formal attempt per (block, arm): a failed slot is not retried in place;
    # a retry takes a new pair_id / slot and the old block stays incomplete.
    per_slot_arm = Counter((str(row["pair_id"]), str(row["arm"])) for row in formal_rows)
    repeated = sorted(key for key, count in per_slot_arm.items() if count > 1)
    if repeated:
        raise GateError(f"several formal attempts for the same (pair_id, arm): {repeated[:5]}")

    # Schedule slots: one slot per block, one block per slot, inside the frozen
    # schedule and after the slots consumed by earlier windows.
    slot_of: dict[str, int] = {}
    if "block_slot" in columns:
        for row in formal_rows:
            slot = row["block_slot"]
            if slot is None:
                raise GateError(f"row {row['_row']}: formal row requires block_slot")
            if not prior_slots <= slot < attempt_cap:
                raise GateError(f"row {row['_row']}: block_slot={slot} outside "
                                f"[{prior_slots}, {attempt_cap}) (0-based schedule after prior windows)")
            pair_id = str(row["pair_id"])
            if slot_of.setdefault(pair_id, slot) != slot:
                raise GateError(f"pair {pair_id}: conflicting block_slot values")
        slot_counts = Counter(slot_of.values())
        clashes = sorted(slot for slot, count in slot_counts.items() if count > 1)
        if clashes:
            raise GateError(f"block_slot values shared by several pair_ids: {clashes}")

    included_by_pair: dict[str, dict[str, dict[str, object]]] = defaultdict(dict)
    rows_by_pair_arm: dict[tuple[str, str], list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        pair_id, arm = str(row["pair_id"]), str(row["arm"])
        rows_by_pair_arm[(pair_id, arm)].append(row)
        if not row["included"]:
            continue
        if arm in included_by_pair[pair_id]:
            raise GateError(f"pair {pair_id}: multiple included rows for arm {arm}")
        included_by_pair[pair_id][arm] = row

    complete = {
        pair_id: arm_rows for pair_id, arm_rows in included_by_pair.items()
        if set(arm_rows) == set(arms)
    }
    for pair_id in complete:
        for arm, row in complete[pair_id].items():
            if row["declared_incomplete_block"]:
                raise GateError(f"row {row['_row']}: declared incomplete_block but block {pair_id} is complete")
    if len(complete) > expected_pairs:
        raise GateError(
            f"{len(complete)} complete blocks exceed the stopping target {expected_pairs} "
            "(no outcome-dependent extension)"
        )

    incomplete_blocks = []
    for pair_id in sorted(formal_pair_ids - set(complete)):
        present = included_by_pair.get(pair_id, {})
        reasons = [block_reason(rows_by_pair_arm.get((pair_id, arm), []), arm)
                   for arm in arms if arm not in present]
        incomplete_blocks.append({
            "pair_id": pair_id,
            "block_slot": slot_of.get(pair_id),
            "reason": INCOMPLETE_BLOCK,
            "missing_arms": [arm for arm in arms if arm not in present],
            "reason_codes": reasons,
            "successful_rows_not_analysed": [
                {"arm": arm, "userOpHash": row["userOpHash"], "txGasUsed": row["txGasUsed"],
                 "actualGasCostWei": row.get("actualGasCostWei")}
                for arm, row in sorted(present.items())
            ],
        })

    status = "PASS" if len(complete) == expected_pairs else "INCOMPLETE"
    pair_ids = sorted(complete, key=lambda p: (slot_of.get(p, -1), p))
    reference = str(design["reference"])

    retained_slots = [slot_of[p] for p in pair_ids] if slot_of else None
    missing_slots = None
    schedule: dict[str, object] = {"prior_formal_slots": prior_slots,
                                   "prior_formal_slots_declared": "prior_formal_slots" in columns}
    if slot_of:
        # Executed span of this window: from the first slot after earlier windows
        # to the last attempted slot.  Slots in the span without a complete block
        # are "missing" (failed, incomplete, or never recorded); slots after the
        # span are unexecuted.
        last = max(slot_of.values())
        retained_set = set(retained_slots)
        missing_slots = [slot for slot in range(prior_slots, last + 1) if slot not in retained_set]
        schedule.update(
            retained_slots_in_order=retained_slots,
            missing_slots=missing_slots,
            missing_slots_without_any_formal_row=[slot for slot in missing_slots
                                                  if slot not in set(slot_of.values())],
            unexecuted_slots_after_window=attempt_cap - (last + 1),
        )
    else:
        schedule.update(retained_slots_in_order=None, missing_slots=None)

    comparisons: dict[str, dict[str, object]] = {}
    for other in arms:
        if other == reference or not pair_ids:
            continue
        label = f"{reference}-{other}"
        differences = [
            int(complete[pair_id][reference]["txGasUsed"])
            - int(complete[pair_id][other]["txGasUsed"])
            for pair_id in pair_ids
        ]
        entry: dict[str, object] = {
            "definition": f"txGasUsed({reference}) - txGasUsed({other})",
            "n": len(differences),
            "mean_difference": statistics.mean(differences),
            "median_difference": statistics.median(differences),
            "min_difference": min(differences),
            "max_difference": max(differences),
            "bootstrap_mean_95ci": bootstrap_ci(differences, seed, resamples),
            "bootstrap_interval_type": "marginal (unadjusted) percentile, i.i.d. blocks",
            "signs": sign_counts(differences),
            "exact_two_sided_sign_p": exact_sign_test(differences),
        }
        # The preregistered length is always reported; another --block-length is
        # an additional, exploratory result and never replaces it.
        entry["moving_block_bootstrap"] = mbb_entry(differences, MOVING_BLOCK_LENGTH, retained_slots,
                                                    missing_slots, seed, resamples)
        if block_length != MOVING_BLOCK_LENGTH:
            entry["moving_block_bootstrap_exploratory"] = mbb_entry(
                differences, block_length, retained_slots, missing_slots, seed, resamples)
        comparisons[label] = entry

    if design["holm"] and comparisons:
        raw = {label: float(value["exact_two_sided_sign_p"]) for label, value in comparisons.items()}
        adjusted = holm_adjust(raw)
        for label in comparisons:
            comparisons[label]["holm_adjusted_sign_p"] = adjusted[label]
            comparisons[label]["holm_reject_family_alpha"] = adjusted[label] <= FAMILY_ALPHA

    exclusion_counts = Counter(
        str(row["exclusion_reason"]) for row in rows
        if not row["included"]
    )
    exclusion_by_arm = {
        arm: dict(sorted(Counter(str(r["exclusion_reason"]) for r in rows
                                 if r["arm"] == arm and not r["included"]).items()))
        for arm in arms
    }
    arm_counts = {}
    for arm in arms:
        arm_rows = [row for row in rows if row["arm"] == arm]
        failed = [row for row in arm_rows if not row["warmup"] and not row["injected"] and not row["success"]]
        entry = {
            "rows": len(arm_rows),
            "formal_attempts": sum(not row["warmup"] and not row["injected"] for row in arm_rows),
            "included_successes": sum(bool(row["included"]) for row in arm_rows),
            "analysed_in_complete_blocks": len(complete),
            "successful_in_incomplete_blocks": sum(
                any(s["arm"] == arm for s in block["successful_rows_not_analysed"])
                for block in incomplete_blocks),
            "excluded_rows": sum(not row["included"] for row in arm_rows),
            "failed_formal_attempts": len(failed),
            "failed_txGasUsed_sum": sum(r["txGasUsed"] for r in failed if r["txGasUsed"] is not None),
            "failed_with_receipt": sum(r["txGasUsed"] is not None for r in failed),
        }
        if "actualGasCostWei" in columns:
            known = [r["actualGasCostWei"] for r in failed if r["actualGasCostWei"] is not None]
            entry["failed_actualGasCostWei"] = {
                "status": "ok" if len(known) == len(failed) else ("empty" if not known else "partial"),
                "known_rows": len(known),
                "missing_rows": len(failed) - len(known),
                "sum_over_known_rows": sum(known) if known else None,
            }
        else:
            entry["failed_actualGasCostWei"] = {"status": "absent", "missing_columns": ["actualGasCostWei"]}
        if "precheck_refused" in columns:
            entry["precheck_refusals"] = sum(bool(r["precheck_refused"]) for r in arm_rows
                                             if not r["warmup"] and not r["injected"])
        arm_counts[arm] = entry

    per_account: dict[str, object]
    if "sender" in columns:
        per_account = {}
        for arm in arms:
            by_sender: dict[str, list[int]] = defaultdict(list)
            for pair_id in pair_ids:
                row = complete[pair_id][arm]
                by_sender[str(row["sender"]) or "<empty>"].append(int(row["txGasUsed"]))
            per_account[arm] = {
                sender: {"n": len(v), "mean_txGasUsed": statistics.mean(v),
                         "median_txGasUsed": statistics.median(v), "min": min(v), "max": max(v)}
                for sender, v in sorted(by_sender.items())
            }
    else:
        per_account = {"status": "absent", "missing_columns": ["sender"]}

    return {
        "schema": SCHEMA,
        "gate": status,
        "confirmatory": status == "PASS",
        "design": design_name,
        "source_csv": str(path),
        "source_sha256": digest,
        **identity,
        "expected_complete_pairs": expected_pairs,
        "attempt_cap": attempt_cap,
        "complete_pairs": len(complete),
        "formal_pair_ids": len(formal_pair_ids),
        "incomplete_block_count": len(incomplete_blocks),
        "incomplete_blocks": incomplete_blocks,
        "schedule": schedule,
        "bootstrap": {"resamples": resamples, "seed": seed, "statistic": "paired mean difference",
                      "moving_block_length": MOVING_BLOCK_LENGTH,
                      "exploratory_moving_block_length": None if block_length == MOVING_BLOCK_LENGTH
                      else block_length},
        "sign_test": {"type": "exact two-sided binomial, zeros dropped",
                      "family_alpha": FAMILY_ALPHA if design["holm"] else None,
                      "multiplicity": "Holm over primary comparisons" if design["holm"] else "none"},
        "arm_counts": arm_counts,
        "exclusion_counts": dict(sorted(exclusion_counts.items())),
        "exclusion_counts_by_arm": exclusion_by_arm,
        "block_exclusion_counts": {INCOMPLETE_BLOCK: len(incomplete_blocks)},
        "comparisons": comparisons,
        "secondary_metrics": secondary_tables(complete, arms, columns, seed, resamples),
        "per_account": per_account,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--design", choices=sorted(DESIGNS), required=True)
    parser.add_argument("--csv", type=Path, required=True)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--block-length", type=int, default=MOVING_BLOCK_LENGTH,
                        help="moving-block bootstrap length (preregistered: 3)")
    args = parser.parse_args(argv)
    try:
        result = analyse(args.csv, args.design, None, None,
                         BOOTSTRAP_SEED, BOOTSTRAP_RESAMPLES, args.block_length)
    except (GateError, OSError) as exc:
        print(f"paired-stats gate FAIL: {exc}", file=sys.stderr)
        return 2
    output = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.write_text(output, encoding="utf-8")
    sys.stdout.write(output)
    if result["gate"] != "PASS":
        print(f"paired-stats gate {result['gate']}: {result['complete_pairs']} of "
              f"{result['expected_complete_pairs']} complete blocks", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

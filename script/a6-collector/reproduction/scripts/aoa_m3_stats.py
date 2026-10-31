#!/usr/bin/env python3
"""AOA M3.5 Statistical, N-2 Penalty Interval Identification & B-9 Reservation Accounting Pipeline.

Runs offline structural validation (`aoa_m3_check.check`) first and fails closed
on any error. Extracts per-attempt gas, N-2 unused execution gas penalty bounds
(separating exact trace-derived values from interval-identified bounds), and B-9
validation reservation (`tryLockForGas`) vs. `postOp` settlement (`settleLocked`)
accounting from the archived files. Computes per-arm summary statistics (with
Sample SD and percentile bootstrap `[ci95Low, ci95High]` endpoints strictly
separated), pre-registered paired sign tests with Holm-Bonferroni adjustment,
Cliff's delta effect sizes, and emits both JSON and LaTeX.
"""
from __future__ import annotations

import argparse
from decimal import Decimal
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import random
import re
import sys
from typing import Any

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from aoa_m3_check import check as structural_check  # noqa: E402

BOOTSTRAP_SEED = 20261030
BOOTSTRAP_RESAMPLES = 10000
PENALTY_PERCENT = 10
WEI_PER_TOKEN = 10**18

TOPIC_LOCK_CREATED = "0x03da0f36cf019c40dd1b53d90ab4c01e862440c7ea050399b5fd643fc32fb766"
TOPIC_LOCK_SETTLED = "0x0db2e760de332f46e05e4200a1577fc713d3601c848f570fbbe50a4d281ecec1"
TOPIC_TX_SPONSORED = "0xcde7e91a718e2439d8ff2a679ad52713e82a37b72622fb530c8c41039fdd5bf0"

RE_ADDR20 = re.compile(r"^0x[0-9a-fA-F]{40}$")
RE_HASH32 = re.compile(r"^0x[0-9a-fA-F]{64}$")
RE_PADDED_ADDR = re.compile(r"^0x0{24}[0-9a-fA-F]{40}$")
RE_TWO_WORDS = re.compile(r"^0x[0-9a-fA-F]{128}$")

ARMS = ("SP", "VerifyingPaymaster", "TokenPaymaster")
ARM_SHORT = {
    "SP": "SP",
    "VerifyingPaymaster": "VPM",
    "TokenPaymaster": "TPM",
}
PRIMARY_COMPARISONS = (
    "SP_minus_VerifyingPaymaster",
    "SP_minus_TokenPaymaster",
)
ALL_COMPARISONS = (
    ("SP_minus_VerifyingPaymaster", "SP", "VerifyingPaymaster"),
    ("SP_minus_TokenPaymaster", "SP", "TokenPaymaster"),
    ("TokenPaymaster_minus_VerifyingPaymaster", "TokenPaymaster", "VerifyingPaymaster"),
)

# Point-identified per-arm metrics (never conflating interval bounds with point observations)
POINT_METRICS = (
    "actualGasUsed",
    "txGasUsed",
    "billingResidual",
    "txMinusActualGas",
    "actualGasCostWei",
    "effectiveGasPriceWei",
    "userOpGasPriceWei",
    "callGasLimit",
    "paymasterPostOpGasLimit",
    "preVerificationGas",
    "executionGasLimit",
)
# Interval-bound metrics summarized per arm
BOUND_METRICS = (
    "penaltyLower",
    "penaltyUpper",
    "gasExPenaltyLower",
    "gasExPenaltyUpper",
    "spPenaltyBuffer",
)
CORE_METRICS = POINT_METRICS + BOUND_METRICS

B9_METRICS = (
    "xLockedWei",
    "xBurnedWei",
    "releasedReservationWei",
    "xLockedTokens",
    "xBurnedTokens",
    "releasedReservationTokens",
    "reservationExcessRatioPct",
    "releasedShareOfLockedPct",
    "lockUtilizationPct",
    "settlementRoundingDeltaWei",
    "aReservedWei",
    "aChargedWei",
    "aGasWei",
    "aReleasedToOperatorBudgetWei",
    "aRefundedToOperatorWei",
    "postStateLockedOfWei",
    "postStateDebtsWei",
)


def _require_nonneg_int(val: Any, name: str) -> int:
    """Strictly require a Python `int` (rejecting `bool`, `float`, `str`) >= 0."""
    if type(val) is not int or val < 0:
        raise ValueError(f"{name} must be a non-negative int, got {val!r} ({type(val).__name__})")
    return val


def _require_pos_int(val: Any, name: str) -> int:
    """Strictly require a Python `int` (rejecting `bool`, `float`, `str`) > 0."""
    if type(val) is not int or val <= 0:
        raise ValueError(f"{name} must be a positive int, got {val!r} ({type(val).__name__})")
    return val


def _to_fraction(val: int | float | Fraction | Decimal) -> Fraction:
    if type(val) is bool or not isinstance(val, (int, float, Fraction, Decimal)):
        raise ValueError(f"sample value must be numeric (not bool), got {val!r}")
    if isinstance(val, Fraction):
        return val
    if isinstance(val, int):
        return Fraction(val)
    if isinstance(val, Decimal):
        return Fraction(val)
    if not math.isfinite(val):
        raise ValueError(f"sample value must be finite, got {val!r}")
    return Fraction(val)


def _frac_to_decimal_str(val: Fraction, max_decimals: int = 12) -> str:
    """Format an exact `Fraction` as a decimal string without float64 precision loss."""
    if val.denominator == 1:
        return str(val.numerator)
    sign = "-" if val < 0 else ""
    abs_val = abs(val)
    int_part, rem = divmod(abs_val.numerator, abs_val.denominator)
    digits = []
    for _ in range(max_decimals):
        if rem == 0:
            break
        rem *= 10
        d, rem = divmod(rem, abs_val.denominator)
        digits.append(str(d))
    # Round last digit if remainder >= half denominator
    if rem * 2 >= abs_val.denominator and digits:
        carry = 1
        for i in range(len(digits) - 1, -1, -1):
            nd = int(digits[i]) + carry
            if nd == 10:
                digits[i] = "0"
                carry = 1
            else:
                digits[i] = str(nd)
                carry = 0
                break
        if carry:
            int_part += 1
    frac_str = "".join(digits).rstrip("0")
    if not frac_str:
        return f"{sign}{int_part}"
    return f"{sign}{int_part}.{frac_str}"


def quantile_linear_frac(sorted_vals: list[Fraction], p: Fraction) -> Fraction:
    """Exact Type-7 linear interpolation quantile over sorted `Fraction` values."""
    n = len(sorted_vals)
    if n == 0:
        raise ValueError("quantile on empty sample")
    if n == 1 or p <= 0:
        return sorted_vals[0]
    if p >= 1:
        return sorted_vals[-1]
    idx = p * (n - 1)
    lo = int(math.floor(idx))
    hi = int(math.ceil(idx))
    frac = idx - lo
    return sorted_vals[lo] * (1 - frac) + sorted_vals[hi] * frac


def quantile_linear(sorted_vals: list[int | float], p: float) -> float:
    """Type-7 linear interpolation quantile matching NumPy/R default."""
    if not (0.0 <= p <= 1.0) and not math.isnan(p):
        pass
    fracs = [_to_fraction(x) for x in sorted_vals]
    p_frac = Fraction(0) if p <= 0.0 else (Fraction(1) if p >= 1.0 else Fraction(str(p)))
    return float(quantile_linear_frac(fracs, p_frac))


def compute_skewness(
    values: list[int | float | Fraction],
    mean_frac: Fraction | None = None,
) -> float | None:
    """Adjusted Fisher-Pearson sample skewness G1 using exact centered moments.

    Returns `None` when sample size `n < 3` or when the sample is constant (`sd == 0`),
    avoiding reporting an arbitrary `0.0` when `0 / 0` is undefined.
    """
    n = len(values)
    if n < 3:
        return None
    fracs = [_to_fraction(x) for x in values]
    if min(fracs) == max(fracs):
        return None
    mu = mean_frac if mean_frac is not None else sum(fracs) / n
    diffs = [float(x - mu) for x in fracs]
    m2 = sum(d * d for d in diffs) / n
    if m2 <= 0.0:
        return None
    m3 = sum(d * d * d for d in diffs) / n
    g1 = m3 / (m2 ** 1.5)
    return float(math.sqrt(n * (n - 1)) / (n - 2) * g1)


def _bootstrap_mean_ci_exact(
    fracs: list[Fraction],
    seed: int = BOOTSTRAP_SEED,
    resamples: int = BOOTSTRAP_RESAMPLES,
) -> dict[str, Any]:
    """Compute deterministic percentile bootstrap 95% CI on exact offsets relative to `base = fracs[0]`.

    Never adds `float(base)` inside the resample loop, preserving exact offset quantiles and CI width
    even for `10**20 + i` wei quantities (`> 2^53`).
    """
    _require_nonneg_int(seed, "seed")
    _require_pos_int(resamples, "resamples")
    n = len(fracs)
    if n == 0:
        raise ValueError("bootstrap on empty sample")
    base = fracs[0]
    if min(fracs) == max(fracs):
        return {
            "baseFrac": base,
            "lowOffsetFrac": Fraction(0),
            "highOffsetFrac": Fraction(0),
            "ciLowFrac": base,
            "ciHighFrac": base,
            "ciWidthFrac": Fraction(0),
            "ciHalfWidthFrac": Fraction(0),
        }

    deltas = [x - base for x in fracs]
    rng = random.Random(seed)
    randrange = rng.randrange

    # Fast exact path when all offsets are integers (e.g. gas or wei counts)
    if all(d.denominator == 1 for d in deltas):
        deltas_int = [d.numerator for d in deltas]
        boot_sums = [0] * resamples
        for b in range(resamples):
            total_i = 0
            for _ in range(n):
                total_i += deltas_int[randrange(n)]
            boot_sums[b] = total_i
        boot_sums.sort()
        boot_delta_means = [Fraction(s, n) for s in boot_sums]
    else:
        boot_delta_means = [Fraction(0)] * resamples
        for b in range(resamples):
            total_f = Fraction(0)
            for _ in range(n):
                total_f += deltas[randrange(n)]
            boot_delta_means[b] = total_f / n
        boot_delta_means.sort()

    low_offset = quantile_linear_frac(boot_delta_means, Fraction(25, 1000))
    high_offset = quantile_linear_frac(boot_delta_means, Fraction(975, 1000))
    width_frac = high_offset - low_offset
    half_width_frac = width_frac / 2
    ci_low_frac = base + low_offset
    ci_high_frac = base + high_offset

    return {
        "baseFrac": base,
        "lowOffsetFrac": low_offset,
        "highOffsetFrac": high_offset,
        "ciLowFrac": ci_low_frac,
        "ciHighFrac": ci_high_frac,
        "ciWidthFrac": width_frac,
        "ciHalfWidthFrac": half_width_frac,
    }


def bootstrap_mean_ci(
    values: list[int | float],
    seed: int = BOOTSTRAP_SEED,
    resamples: int = BOOTSTRAP_RESAMPLES,
) -> tuple[float, float, float]:
    """Deterministic percentile bootstrap 95% CI `(ci95Low, ci95High, ci95HalfWidth)`."""
    if not values:
        raise ValueError("bootstrap on empty sample")
    fracs = [_to_fraction(x) for x in values]
    exact = _bootstrap_mean_ci_exact(fracs, seed=seed, resamples=resamples)
    return (
        float(exact["ciLowFrac"]),
        float(exact["ciHighFrac"]),
        float(exact["ciHalfWidthFrac"]),
    )


def summarize_sample(
    values: list[int | float],
    seed: int = BOOTSTRAP_SEED,
    resamples: int = BOOTSTRAP_RESAMPLES,
) -> dict[str, Any]:
    """Compute summary statistics with exact `Fraction` moments and `[ci95Low, ci95High]` endpoints."""
    _require_nonneg_int(seed, "seed")
    _require_pos_int(resamples, "resamples")
    n = len(values)
    if n == 0:
        raise ValueError("cannot summarize empty sample")
    fracs = [_to_fraction(x) for x in values]
    sfracs = sorted(fracs)
    base = sfracs[0]

    if sfracs[0] == sfracs[-1]:
        cval = float(base)
        cstr = _frac_to_decimal_str(base)
        return {
            "n": n,
            "mean": cval,
            "meanExact": cstr,
            "sd": 0.0,
            "median": cval,
            "q25": cval,
            "q75": cval,
            "iqr": 0.0,
            "min": cval,
            "max": cval,
            "range": 0.0,
            "p95": cval,
            "skewness": None,
            "baseExact": cstr,
            "ci95LowOffset": 0.0,
            "ci95HighOffset": 0.0,
            "ci95Low": cval,
            "ci95High": cval,
            "ci95LowExact": cstr,
            "ci95HighExact": cstr,
            "ci95Width": 0.0,
            "ci95WidthExact": "0",
            "ci95HalfWidth": 0.0,
            "bootstrapSeed": seed,
            "bootstrapResamples": resamples,
        }

    mean_frac = sum(fracs) / n
    mean = float(mean_frac)
    if n > 1:
        var_frac = sum((x - mean_frac) ** 2 for x in fracs) / (n - 1)
        sd = math.sqrt(max(0.0, float(var_frac)))
    else:
        sd = 0.0

    sdeltas = [x - base for x in sfracs]
    q25_d = quantile_linear_frac(sdeltas, Fraction(25, 100))
    med_d = quantile_linear_frac(sdeltas, Fraction(50, 100))
    q75_d = quantile_linear_frac(sdeltas, Fraction(75, 100))
    p95_d = quantile_linear_frac(sdeltas, Fraction(95, 100))

    q25_frac = base + q25_d
    med_frac = base + med_d
    q75_frac = base + q75_d
    iqr_frac = q75_d - q25_d
    p95_frac = base + p95_d
    range_frac = sfracs[-1] - sfracs[0]

    skew = compute_skewness(fracs, mean_frac=mean_frac)
    ci_exact = _bootstrap_mean_ci_exact(fracs, seed=seed, resamples=resamples)

    return {
        "n": n,
        "mean": mean,
        "meanExact": _frac_to_decimal_str(mean_frac),
        "sd": sd,
        "median": float(med_frac),
        "q25": float(q25_frac),
        "q75": float(q75_frac),
        "iqr": float(iqr_frac),
        "min": float(sfracs[0]),
        "max": float(sfracs[-1]),
        "range": float(range_frac),
        "p95": float(p95_frac),
        "skewness": skew,
        "baseExact": _frac_to_decimal_str(ci_exact["baseFrac"]),
        "ci95LowOffset": float(ci_exact["lowOffsetFrac"]),
        "ci95HighOffset": float(ci_exact["highOffsetFrac"]),
        "ci95Low": float(ci_exact["ciLowFrac"]),
        "ci95High": float(ci_exact["ciHighFrac"]),
        "ci95LowExact": _frac_to_decimal_str(ci_exact["ciLowFrac"]),
        "ci95HighExact": _frac_to_decimal_str(ci_exact["ciHighFrac"]),
        "ci95Width": float(ci_exact["ciWidthFrac"]),
        "ci95WidthExact": _frac_to_decimal_str(ci_exact["ciWidthFrac"]),
        "ci95HalfWidth": float(ci_exact["ciHalfWidthFrac"]),
        "bootstrapSeed": seed,
        "bootstrapResamples": resamples,
    }


def paired_sign_test(x: list[int | float], y: list[int | float]) -> dict[str, Any]:
    """Exact two-sided paired binomial sign test on `(x_i - y_i)` with explicit tie accounting."""
    if len(x) != len(y) or len(x) == 0:
        raise ValueError("paired_sign_test requires non-empty equal-length lists")
    n_pos = 0
    n_neg = 0
    n_tie = 0
    for xi, yi in zip(x, y):
        fx = _to_fraction(xi)
        fy = _to_fraction(yi)
        if fx > fy:
            n_pos += 1
        elif fx < fy:
            n_neg += 1
        else:
            n_tie += 1
    n_eff = n_pos + n_neg
    if n_eff == 0:
        p_val = 1.0
    else:
        k = min(n_pos, n_neg)
        tail = sum(math.comb(n_eff, j) for j in range(k + 1))
        p_frac = min(Fraction(1, 1), Fraction(2 * tail, 1 << n_eff))
        p_val = float(p_frac)
    return {
        "nPairs": len(x),
        "nPos": n_pos,
        "nNeg": n_neg,
        "nTie": n_tie,
        "nEff": n_eff,
        "pValueTwoSided": p_val,
    }


def holm_bonferroni(p_values: dict[str, float]) -> dict[str, float]:
    """Step-down Holm-Bonferroni multiple-testing adjustment over a named hypothesis family."""
    if not p_values:
        return {}
    for k, v in p_values.items():
        if type(v) is bool or not isinstance(v, (int, float)) or math.isnan(v) or v < 0.0 or v > 1.0:
            raise ValueError(f"invalid p-value for {k!r}: {v!r}")
    m = len(p_values)
    ordered = sorted(p_values.items(), key=lambda kv: (float(kv[1]), kv[0]))
    adjusted_by_key: dict[str, float] = {}
    running_max = 0.0
    for idx, (k, raw_p) in enumerate(ordered):
        step_p = (m - idx) * float(raw_p)
        running_max = max(running_max, step_p)
        adjusted_by_key[k] = min(1.0, running_max)
    return {k: adjusted_by_key[k] for k in p_values}


def cliffs_delta(x: list[int | float], y: list[int | float]) -> dict[str, Any]:
    """Compute Cliff's delta effect size and Romano et al. magnitude label."""
    nx, ny = len(x), len(y)
    if nx == 0 or ny == 0:
        raise ValueError("cliffs_delta requires non-empty lists")
    fx = [_to_fraction(xi) for xi in x]
    fy = [_to_fraction(yj) for yj in y]
    greater = 0
    less = 0
    for xi in fx:
        for yj in fy:
            if xi > yj:
                greater += 1
            elif xi < yj:
                less += 1
    delta = (greater - less) / float(nx * ny)
    abs_d = abs(delta)
    if abs_d < 0.147:
        magnitude = "negligible"
    elif abs_d < 0.33:
        magnitude = "small"
    elif abs_d < 0.474:
        magnitude = "medium"
    else:
        magnitude = "large"
    return {
        "delta": delta,
        "greaterPairs": greater,
        "lessPairs": less,
        "equalPairs": nx * ny - greater - less,
        "totalPairs": nx * ny,
        "magnitude": magnitude,
    }


def compute_interval_difference(
    low_a: int,
    high_a: int,
    low_b: int,
    high_b: int,
) -> tuple[int, int]:
    """Compute the true identified interval `[L_A - U_B, U_A - L_B]` for `A - B`."""
    la = _require_nonneg_int(low_a, "low_a")
    ua = _require_nonneg_int(high_a, "high_a")
    lb = _require_nonneg_int(low_b, "low_b")
    ub = _require_nonneg_int(high_b, "high_b")
    if la > ua:
        raise ValueError(f"invalid interval A: [{la}, {ua}]")
    if lb > ub:
        raise ValueError(f"invalid interval B: [{lb}, {ub}]")
    return (la - ub, ua - lb)


def compute_n2_penalty(
    actual_gas_used: int,
    call_gas_limit: int,
    post_op_gas_limit: int,
    pre_verification_gas: int = 0,
    execution_gas_used: int | None = None,
) -> dict[str, Any]:
    """Compute or bound EntryPoint.sol:718-730 10% unused execution gas penalty.

    Enforces strict integer types (`int`, rejecting `bool`) and arithmetic feasibility:
      1. Since `actualGasUsed = preVerificationGas + validationGas + executionGasUsed + penalty(executionGasUsed)`
         with `validationGas >= 0`, `executionGasUsed >= 0`, and `executionGasUsed + penalty(executionGasUsed) >= floor(L_exec / 10)`,
         any valid UserOperation must satisfy:
           `actualGasUsed >= preVerificationGas + (callGasLimit + paymasterPostOpGasLimit) // 10`.
      2. When `execution_gas_used` is provided (exact mode), it must also satisfy:
           `actualGasUsed - preVerificationGas - executionGasUsed - penaltyExact >= 0`.
      3. When `execution_gas_used` is `None` (archive-only interval mode), `penaltyExact` and
         `actualGasExPenaltyExact` are set to `None` rather than conflating the upper bound with
         a point observation.
    """
    act = _require_nonneg_int(actual_gas_used, "actual_gas_used")
    call_lim = _require_nonneg_int(call_gas_limit, "call_gas_limit")
    post_lim = _require_nonneg_int(post_op_gas_limit, "post_op_gas_limit")
    pvg = _require_nonneg_int(pre_verification_gas, "pre_verification_gas")

    exec_limit = call_lim + post_lim
    penalty_statutory_cap = (exec_limit * PENALTY_PERCENT) // 100
    sp_buffer = (exec_limit * PENALTY_PERCENT + 99) // 100

    min_feasible_actual = pvg + penalty_statutory_cap
    if act < min_feasible_actual:
        raise ValueError(
            f"infeasible gas accounting: actualGasUsed ({act}) < preVerificationGas ({pvg}) + "
            f"floor(executionGasLimit/10) ({penalty_statutory_cap}) = {min_feasible_actual}"
        )

    s_budget = act - pvg
    # Left-hand side f(g) = g + ((max(0, exec_limit - g) * 10) // 100) is strictly non-decreasing in g.
    lo, hi = 0, exec_limit
    while lo < hi:
        mid = (lo + hi + 1) // 2
        f_mid = mid + (((exec_limit - mid) * PENALTY_PERCENT) // 100)
        if f_mid <= s_budget:
            lo = mid
        else:
            hi = mid - 1
    max_possible_exec_gas = lo
    if s_budget >= exec_limit:
        penalty_lower_from_pvg = 0
    else:
        penalty_lower_from_pvg = ((exec_limit - max_possible_exec_gas) * PENALTY_PERCENT) // 100

    if execution_gas_used is not None:
        exec_used = _require_nonneg_int(execution_gas_used, "execution_gas_used")
        unused_gas = max(0, exec_limit - exec_used)
        exact_penalty = (unused_gas * PENALTY_PERCENT) // 100
        inferred_validation_and_overhead = act - pvg - exec_used - exact_penalty
        if inferred_validation_and_overhead < 0:
            raise ValueError(
                f"infeasible exact gas trace: actualGasUsed ({act}) - preVerificationGas ({pvg}) - "
                f"executionGasUsed ({exec_used}) - penaltyExact ({exact_penalty}) = "
                f"{inferred_validation_and_overhead} < 0"
            )
        gas_ex_penalty = act - exact_penalty
        return {
            "callGasLimit": call_lim,
            "paymasterPostOpGasLimit": post_lim,
            "preVerificationGas": pvg,
            "executionGasLimit": exec_limit,
            "executionGasUsed": exec_used,
            "unusedExecutionGas": unused_gas,
            "penaltyExact": exact_penalty,
            "penaltyLower": exact_penalty,
            "penaltyUpper": exact_penalty,
            "unusedGasPenaltyLowerBound": penalty_lower_from_pvg,
            "unusedGasPenaltyUpperBound": penalty_statutory_cap,
            "spPenaltyBuffer": sp_buffer,
            "actualGasExPenaltyExact": gas_ex_penalty,
            "gasExPenaltyLower": gas_ex_penalty,
            "gasExPenaltyUpper": gas_ex_penalty,
            "actualGasExPenaltyLower": gas_ex_penalty,
            "actualGasExPenaltyUpper": gas_ex_penalty,
            "penaltyDerivation": "exact_from_execution_gas_used",
        }

    return {
        "callGasLimit": call_lim,
        "paymasterPostOpGasLimit": post_lim,
        "preVerificationGas": pvg,
        "executionGasLimit": exec_limit,
        "executionGasUsed": None,
        "unusedExecutionGas": None,
        "penaltyExact": None,
        "penaltyLower": penalty_lower_from_pvg,
        "penaltyUpper": penalty_statutory_cap,
        "unusedGasPenaltyLowerBound": penalty_lower_from_pvg,
        "unusedGasPenaltyUpperBound": penalty_statutory_cap,
        "spPenaltyBuffer": sp_buffer,
        "actualGasExPenaltyExact": None,
        "gasExPenaltyLower": act - penalty_statutory_cap,
        "gasExPenaltyUpper": act - penalty_lower_from_pvg,
        "actualGasExPenaltyLower": act - penalty_statutory_cap,
        "actualGasExPenaltyUpper": act - penalty_lower_from_pvg,
        "penaltyDerivation": "interval_bound_no_execution_trace",
    }


def _hex_word(data: str, index: int) -> int:
    raw = data[2:] if data.startswith(("0x", "0X")) else data
    start = 64 * index
    end = start + 64
    if len(raw) < end:
        raise ValueError(f"log data too short for word {index}: len={len(raw)}")
    return int(raw[start:end], 16)


def _unpad_topic_address(topic: str, label: str) -> str:
    if not RE_PADDED_ADDR.fullmatch(topic):
        raise ValueError(f"non-canonical address topic for {label}: {topic!r}")
    addr = "0x" + topic[-40:].lower()
    if int(addr, 16) == 0:
        raise ValueError(f"zero address in topic for {label}: {topic!r}")
    return addr


def _require_contract_address(addr: Any, label: str) -> str:
    if not isinstance(addr, str) or not RE_ADDR20.fullmatch(addr):
        raise ValueError(f"missing or invalid contract address for {label}: {addr!r}")
    addr_lc = addr.lower()
    if int(addr_lc, 16) == 0:
        raise ValueError(f"zero contract address for {label}: {addr!r}")
    return addr_lc


def _parse_nonneg_decimal_int(val: Any, label: str) -> int:
    if isinstance(val, str) and val.isdecimal():
        return int(val)
    raise ValueError(f"{label} must be a non-negative decimal string, got {val!r}")


def compute_b9_settlement(
    user_op_hash: str,
    receipt_logs: list[dict[str, Any]],
    state_obj: dict[str, Any],
    expected_token_address: str | None = None,
    expected_sp_address: str | None = None,
    expected_user_address: str | None = None,
    expected_operator_address: str | None = None,
) -> dict[str, Any]:
    """Decode and strictly verify B-9 (`tryLockForGas` vs `settleLocked`) reservation & settlement metrics."""
    if not isinstance(user_op_hash, str) or not RE_HASH32.fullmatch(user_op_hash):
        raise ValueError(f"invalid user_op_hash: {user_op_hash!r}")
    op_hash_lc = user_op_hash.lower()

    lock_created_hits = []
    lock_settled_hits = []
    tx_sponsored_hits = []

    for log in receipt_logs:
        if not isinstance(log, dict):
            raise ValueError("receipt log entry must be a dict")
        topics = [str(t).lower() for t in log.get("topics", [])]
        if not topics:
            continue
        t0 = topics[0]
        if t0 == TOPIC_LOCK_CREATED:
            if len(topics) >= 3 and topics[2] == op_hash_lc:
                lock_created_hits.append(log)
        elif t0 == TOPIC_LOCK_SETTLED:
            if len(topics) >= 3 and topics[2] == op_hash_lc:
                lock_settled_hits.append(log)
        elif t0 == TOPIC_TX_SPONSORED:
            tx_sponsored_hits.append(log)

    if len(lock_created_hits) != 1:
        raise ValueError(f"SP attempt {user_op_hash}: expected 1 LockedForGas log, found {len(lock_created_hits)}")
    if len(lock_settled_hits) != 1:
        raise ValueError(f"SP attempt {user_op_hash}: expected 1 SettledLocked log, found {len(lock_settled_hits)}")
    if len(tx_sponsored_hits) != 1:
        raise ValueError(
            f"SP attempt {user_op_hash}: expected 1 TransactionSponsored log, found {len(tx_sponsored_hits)}"
        )

    lc_log = lock_created_hits[0]
    ls_log = lock_settled_hits[0]
    ts_log = tx_sponsored_hits[0]

    lc_addr = _require_contract_address(lc_log.get("address"), "LockedForGas.address")
    ls_addr = _require_contract_address(ls_log.get("address"), "SettledLocked.address")
    ts_addr = _require_contract_address(ts_log.get("address"), "TransactionSponsored.address")

    if lc_addr != ls_addr:
        raise ValueError(
            f"SP attempt {user_op_hash}: LockedForGas emitter ({lc_addr}) != SettledLocked emitter ({ls_addr})"
        )
    if expected_token_address is not None:
        exp_tok = _require_contract_address(expected_token_address, "expected_token_address")
        if lc_addr != exp_tok:
            raise ValueError(
                f"SP attempt {user_op_hash}: token log emitter ({lc_addr}) != expected xPNTs ({exp_tok})"
            )

    lc_topics = [str(t).lower() for t in lc_log.get("topics", [])]
    ls_topics = [str(t).lower() for t in ls_log.get("topics", [])]
    ts_topics = [str(t).lower() for t in ts_log.get("topics", [])]

    if len(lc_topics) != 4:
        raise ValueError(f"SP attempt {user_op_hash}: LockedForGas requires 4 topics, got {len(lc_topics)}")
    if len(ls_topics) != 3:
        raise ValueError(f"SP attempt {user_op_hash}: SettledLocked requires 3 topics, got {len(ls_topics)}")
    if len(ts_topics) != 3:
        raise ValueError(f"SP attempt {user_op_hash}: TransactionSponsored requires 3 topics, got {len(ts_topics)}")

    lc_user = _unpad_topic_address(lc_topics[1], "LockedForGas.user")
    lc_locker = _unpad_topic_address(lc_topics[3], "LockedForGas.locker")
    ls_user = _unpad_topic_address(ls_topics[1], "SettledLocked.user")
    ts_operator = _unpad_topic_address(ts_topics[1], "TransactionSponsored.operator")
    ts_user = _unpad_topic_address(ts_topics[2], "TransactionSponsored.user")

    if lc_user != ls_user or lc_user != ts_user:
        raise ValueError(
            f"SP attempt {user_op_hash}: user topic mismatch across logs ({lc_user}, {ls_user}, {ts_user})"
        )
    if lc_locker != ts_addr:
        raise ValueError(
            f"SP attempt {user_op_hash}: LockedForGas.locker ({lc_locker}) != TransactionSponsored emitter ({ts_addr})"
        )
    if expected_sp_address is not None:
        exp_sp = _require_contract_address(expected_sp_address, "expected_sp_address")
        if ts_addr != exp_sp:
            raise ValueError(
                f"SP attempt {user_op_hash}: TransactionSponsored emitter ({ts_addr}) != expected SP ({exp_sp})"
            )
    if expected_user_address is not None:
        exp_usr = _require_contract_address(expected_user_address, "expected_user_address")
        if lc_user != exp_usr:
            raise ValueError(f"SP attempt {user_op_hash}: log user ({lc_user}) != expected sender ({exp_usr})")
    if expected_operator_address is not None:
        exp_op = _require_contract_address(expected_operator_address, "expected_operator_address")
        if ts_operator != exp_op:
            raise ValueError(
                f"SP attempt {user_op_hash}: TransactionSponsored.operator ({ts_operator}) != expected ({exp_op})"
            )

    lc_data = str(lc_log.get("data", ""))
    ls_data = str(ls_log.get("data", ""))
    ts_data = str(ts_log.get("data", ""))
    for d_str, d_lbl in ((lc_data, "LockedForGas"), (ls_data, "SettledLocked"), (ts_data, "TransactionSponsored")):
        if not RE_TWO_WORDS.fullmatch(d_str):
            raise ValueError(f"SP attempt {user_op_hash}: {d_lbl} data must be 2 32-byte words, got {d_str!r}")

    x_locked = _hex_word(lc_data, 0)
    a_reserved = _hex_word(lc_data, 1)
    x_burned = _hex_word(ls_data, 0)
    a_charged = _hex_word(ls_data, 1)
    a_gas = _hex_word(ts_data, 0)
    debt_apnts = _hex_word(ts_data, 1)

    if a_reserved <= 0 or x_locked <= 0:
        raise ValueError(
            f"SP attempt {user_op_hash}: aReserved ({a_reserved}) and xLocked ({x_locked}) must be positive"
        )
    if a_charged < 0 or a_charged > a_reserved:
        raise ValueError(
            f"SP attempt {user_op_hash}: aCharged ({a_charged}) outside valid [0, aReserved ({a_reserved})]"
        )
    if x_burned <= 0 or x_burned > x_locked:
        raise ValueError(
            f"SP attempt {user_op_hash}: xBurned ({x_burned}) outside valid (0, xLocked ({x_locked})]"
        )
    if a_charged != debt_apnts:
        raise ValueError(
            f"SP attempt {user_op_hash}: SettledLocked.aCharged ({a_charged}) != "
            f"TransactionSponsored.debtAPNTs ({debt_apnts})"
        )
    if a_gas <= 0 or a_gas > a_charged:
        raise ValueError(
            f"SP attempt {user_op_hash}: aGas ({a_gas}) outside valid (0, aCharged ({a_charged})]"
        )

    # Verify xPNTsTokenV2.sol:259-261 proportional ceiling burn formula:
    # xBurned = min(xLocked, ceil(aCharged * xLocked / aReserved))
    expected_x_burned = min(x_locked, (a_charged * x_locked + a_reserved - 1) // a_reserved)
    if x_burned != expected_x_burned:
        raise ValueError(
            f"SP attempt {user_op_hash}: xBurned ({x_burned}) violates ceiling burn formula "
            f"min(xLocked, ceil(aCharged * xLocked / aReserved)) = {expected_x_burned}"
        )
    floor_x_burned = (a_charged * x_locked) // a_reserved
    settlement_rounding_delta_wei = x_burned - floor_x_burned
    if settlement_rounding_delta_wei not in (0, 1):
        raise ValueError(
            f"SP attempt {user_op_hash}: settlementRoundingDeltaWei ({settlement_rounding_delta_wei}) not in {{0, 1}}"
        )

    # Cross-check against stateFile readbacks
    readbacks = state_obj.get("readbacks", {})
    before_a = readbacks.get("before", {}).get("A")
    after_a = readbacks.get("after", {}).get("A")
    if not isinstance(before_a, dict) or not isinstance(after_a, dict):
        raise ValueError(f"SP attempt {user_op_hash}: missing readbacks.before.A or readbacks.after.A in stateFile")

    d_user_xpnts = _parse_nonneg_decimal_int(before_a.get("userXPNTs"), "before.A.userXPNTs") - _parse_nonneg_decimal_int(
        after_a.get("userXPNTs"), "after.A.userXPNTs"
    )
    d_total_spent = _parse_nonneg_decimal_int(after_a.get("totalSpent"), "after.A.totalSpent") - _parse_nonneg_decimal_int(
        before_a.get("totalSpent"), "before.A.totalSpent"
    )
    d_op_bal = _parse_nonneg_decimal_int(
        before_a.get("operatorBalance"), "before.A.operatorBalance"
    ) - _parse_nonneg_decimal_int(after_a.get("operatorBalance"), "after.A.operatorBalance")
    d_rev = _parse_nonneg_decimal_int(
        after_a.get("protocolRevenue"), "after.A.protocolRevenue"
    ) - _parse_nonneg_decimal_int(before_a.get("protocolRevenue"), "before.A.protocolRevenue")

    if d_user_xpnts != x_burned:
        raise ValueError(f"SP attempt {user_op_hash}: state userXPNTs delta ({d_user_xpnts}) != xBurned ({x_burned})")
    if d_total_spent != a_reserved:
        raise ValueError(
            f"SP attempt {user_op_hash}: state totalSpent delta ({d_total_spent}) != aReserved ({a_reserved})"
        )
    if d_op_bal != a_charged or d_rev != a_charged:
        raise ValueError(
            f"SP attempt {user_op_hash}: state operator/revenue delta ({d_op_bal}/{d_rev}) != aCharged ({a_charged})"
        )

    # Directly verify zero post-state residual lock and debt (never inferred solely from balance deltas)
    if "lockedOf" not in after_a or "debts" not in after_a:
        raise ValueError(
            f"SP attempt {user_op_hash}: stateFile readbacks.after.A must explicitly record 'lockedOf' and 'debts'"
        )
    post_locked_of = _parse_nonneg_decimal_int(after_a.get("lockedOf"), "after.A.lockedOf")
    post_debts = _parse_nonneg_decimal_int(after_a.get("debts"), "after.A.debts")
    if post_locked_of != 0 or post_debts != 0:
        raise ValueError(
            f"SP attempt {user_op_hash}: non-zero post-state residual lock/debt: "
            f"lockedOf={post_locked_of}, debts={post_debts}"
        )
    for zero_field in ("lockXLocked", "creditReservedOf", "inflightA0"):
        if zero_field in after_a:
            zval = _parse_nonneg_decimal_int(after_a.get(zero_field), f"after.A.{zero_field}")
            if zval != 0:
                raise ValueError(f"SP attempt {user_op_hash}: non-zero post-state {zero_field}={zval}")
    if "inflightOperator" in after_a:
        inflight_op = str(after_a["inflightOperator"])
        if not RE_ADDR20.fullmatch(inflight_op) or int(inflight_op, 16) != 0:
            raise ValueError(f"SP attempt {user_op_hash}: non-zero post-state inflightOperator={inflight_op!r}")

    released_wei = x_locked - x_burned
    released_budget_wei = a_reserved - a_charged
    excess_ratio_pct = float(Fraction(released_wei * 100, x_burned))
    released_share_pct = float(Fraction(released_wei * 100, x_locked))
    lock_util_pct = float(Fraction(x_burned * 100, x_locked))

    return {
        "xLockedWei": x_locked,
        "xBurnedWei": x_burned,
        "releasedReservationWei": released_wei,
        "xLockedTokens": float(Fraction(x_locked, WEI_PER_TOKEN)),
        "xBurnedTokens": float(Fraction(x_burned, WEI_PER_TOKEN)),
        "releasedReservationTokens": float(Fraction(released_wei, WEI_PER_TOKEN)),
        "reservationExcessRatioPct": excess_ratio_pct,
        "releasedShareOfLockedPct": released_share_pct,
        "lockUtilizationPct": lock_util_pct,
        "settlementRoundingDeltaWei": settlement_rounding_delta_wei,
        "aReservedWei": a_reserved,
        "aChargedWei": a_charged,
        "aGasWei": a_gas,
        "aReleasedToOperatorBudgetWei": released_budget_wei,
        "aRefundedToOperatorWei": released_budget_wei,
        "postStateLockedOfWei": post_locked_of,
        "postStateDebtsWei": post_debts,
    }


# Backward-compatible function alias
compute_b9_overcharge = compute_b9_settlement


def _pair_sort_key(pair_id: str) -> tuple[str, int]:
    if "/" in pair_id:
        prefix, tail = pair_id.rsplit("/", 1)
        if tail.isdigit():
            return (prefix, int(tail))
    return (pair_id, 0)


def source_code_hashes() -> dict[str, str]:
    """Hash every local implementation file required by the publication entrypoint."""
    return {
        name: hashlib.sha256((HERE / name).read_bytes()).hexdigest()
        for name in ("aoa_m3_stats.py", "aoa_m3_check.py", "gate/stats_from_csv.py")
    }


def analyze_package(
    package: dict[str, Any],
    root: Path,
    expected: int = 50,
    seed: int = BOOTSTRAP_SEED,
    resamples: int = BOOTSTRAP_RESAMPLES,
) -> dict[str, Any]:
    """Validate an `aoa-m3-receive-v1` package and compute full M3.5 statistics."""
    _require_pos_int(expected, "expected")
    _require_nonneg_int(seed, "seed")
    _require_pos_int(resamples, "resamples")

    check_res = structural_check(package, root, expected)
    if check_res.get("status") != "OFFLINE_STRUCTURE_PASS" or check_res.get("errors"):
        raise ValueError(f"aoa_m3_check failed: {check_res.get('errors')}")

    run_type = package.get("runType", "unknown")
    if run_type not in ("rehearsal", "formal-candidate"):
        raise ValueError(f"invalid runType: {run_type!r} (expected 'rehearsal' or 'formal-candidate')")

    passport_cache: dict[str, dict[str, Any]] = {}

    def load_json(rel_path: str) -> dict[str, Any]:
        return json.loads((root / rel_path).read_text(encoding="utf-8"))

    arm_records: dict[str, list[dict[str, Any]]] = {arm: [] for arm in ARMS}
    pair_map: dict[str, dict[str, dict[str, Any]]] = {}
    b9_records: list[dict[str, Any]] = []

    for row in package.get("attempts", []):
        if row.get("included") is not True:
            continue
        arm = row["paymasterKind"]
        pair_id = row["pairId"]
        p_file = row["passportFile"]
        if p_file not in passport_cache:
            passport_cache[p_file] = load_json(p_file)
        passport = passport_cache[p_file]
        receipt = load_json(row["receiptFile"])
        uoe = load_json(row["uoeFile"])
        state = load_json(row["stateFile"])

        # Cross-verify summary fields against archived raw files (fail closed on mismatch)
        uoe_gas = _parse_nonneg_decimal_int(uoe.get("actualGasUsed"), f"{row['attemptId']}: uoe.actualGasUsed")
        uoe_cost = _parse_nonneg_decimal_int(uoe.get("actualGasCost"), f"{row['attemptId']}: uoe.actualGasCost")
        tx_obj = receipt.get("tx", {})
        tx_gas = _parse_nonneg_decimal_int(tx_obj.get("gasUsed"), f"{row['attemptId']}: receipt.tx.gasUsed")
        tx_price = _parse_nonneg_decimal_int(
            tx_obj.get("effectiveGasPrice"), f"{row['attemptId']}: receipt.tx.effectiveGasPrice"
        )
        if (
            uoe_gas != int(row["actualGasUsed"])
            or uoe_cost != int(row["actualGasCostWei"])
            or tx_gas != int(row["txGasUsed"])
            or tx_price != int(row["effectiveGasPriceWei"])
        ):
            raise ValueError(f"attempt {row['attemptId']}: summary fields disagree with raw uoe/receipt files")

        if uoe_gas <= 0 or uoe_cost % uoe_gas != 0:
            raise ValueError(
                f"attempt {row['attemptId']}: actualGasCost ({uoe_cost}) not divisible by actualGasUsed ({uoe_gas})"
            )
        userop_gas_price = uoe_cost // uoe_gas

        inv = passport.get("start", {}).get("invariant", {})
        inv_gas = inv.get("gas", {})
        inv_pm_gas = inv.get("pmGas", {})
        # Gas limits come from the hashed passport, never an unbound row override.
        def passport_gas(section: dict[str, Any], field: str, row_section: Any) -> int:
            value = _parse_nonneg_decimal_int(section.get(field), f"{row['attemptId']}: passport.{field}")
            if row_section is not None:
                if not isinstance(row_section, dict):
                    raise ValueError(f"{row['attemptId']}: gas override must be an object")
                if field in row_section:
                    supplied = _parse_nonneg_decimal_int(row_section[field], f"{row['attemptId']}: row.{field}")
                    if supplied != value:
                        raise ValueError(f"{row['attemptId']}: row {field} disagrees with archived passport")
            return value

        call_gas_limit = passport_gas(inv_gas, "callGasLimit", row.get("gas"))
        pre_ver_gas = passport_gas(inv_gas, "preVerificationGas", row.get("gas"))
        pm_gas = inv_pm_gas.get(ARM_SHORT[arm], {})
        post_op_gas_limit = passport_gas(pm_gas, "post", row.get("paymasterGas"))
        passport_gas(pm_gas, "ver", row.get("paymasterGas"))

        # No pinned trace parser exists yet. A producer's flag and archived filename
        # cannot establish the EntryPoint measurement boundary or reconstruct gas.
        exec_gas_used_val: int | None = None
        if row.get("executionGasUsed") is not None:
            raise ValueError(
                f"attempt {row['attemptId']}: executionGasUsed is unsupported until a pinned "
                "trace reconstruction adapter verifies the EntryPoint measurement boundary"
            )

        n2 = compute_n2_penalty(
            actual_gas_used=uoe_gas,
            call_gas_limit=call_gas_limit,
            post_op_gas_limit=post_op_gas_limit,
            pre_verification_gas=pre_ver_gas,
            execution_gas_used=exec_gas_used_val,
        )

        # billingResidual = actualGasUsed - txGasUsed (matching main.tex:510 positive convention)
        rec: dict[str, Any] = {
            "attemptId": row["attemptId"],
            "pairId": pair_id,
            "paymasterKind": arm,
            "chainId": int(row["chainId"]),
            "txHash": row["txHash"],
            "userOpHash": row["userOpHash"],
            "actualGasUsed": uoe_gas,
            "txGasUsed": tx_gas,
            "billingResidual": uoe_gas - tx_gas,
            "txMinusActualGas": tx_gas - uoe_gas,
            "actualGasCostWei": uoe_cost,
            "effectiveGasPriceWei": tx_price,
            "userOpGasPriceWei": userop_gas_price,
            **n2,
        }

        if arm == "SP":
            exp_token = inv.get("xPNTs", {}).get("address") or inv.get("superPaymaster", {}).get("operator", {}).get(
                "xPNTsToken"
            )
            exp_sp = uoe.get("paymaster") or inv.get("xPNTs", {}).get("superPaymaster")
            exp_user = uoe.get("sender") or inv.get("sender")
            exp_op = inv.get("superPaymaster", {}).get("operator", {}).get("address")
            for label, address in (("token", exp_token), ("paymaster", exp_sp),
                                   ("sender", exp_user), ("operator", exp_op)):
                _require_contract_address(address, f"{row['attemptId']}: expected {label}")
            b9 = compute_b9_settlement(
                user_op_hash=row["userOpHash"],
                receipt_logs=receipt.get("logs", []),
                state_obj=state,
                expected_token_address=exp_token,
                expected_sp_address=exp_sp,
                expected_user_address=exp_user,
                expected_operator_address=exp_op,
            )
            rec["b9"] = b9
            b9_records.append(
                {
                    "attemptId": row["attemptId"],
                    "pairId": pair_id,
                    "txHash": row["txHash"],
                    "userOpHash": row["userOpHash"],
                    **b9,
                }
            )

        arm_records[arm].append(rec)
        pair_map.setdefault(pair_id, {})[arm] = rec

    sorted_pairs = sorted(pair_map.keys(), key=_pair_sort_key)
    for arm in ARMS:
        arm_records[arm].sort(key=lambda r: _pair_sort_key(r["pairId"]))
    b9_records.sort(key=lambda r: _pair_sort_key(r["pairId"]))

    # Per-arm summary statistics
    arms_summary: dict[str, dict[str, Any]] = {}
    for arm in ARMS:
        recs = arm_records[arm]
        arms_summary[arm] = {}
        for metric in CORE_METRICS:
            vals = [r[metric] for r in recs]
            arms_summary[arm][metric] = summarize_sample(vals, seed=seed, resamples=resamples)
        for exact_field in ("penaltyExact", "actualGasExPenaltyExact"):
            exact_vals = [r[exact_field] for r in recs]
            if all(v is not None for v in exact_vals):
                arms_summary[arm][exact_field] = summarize_sample(exact_vals, seed=seed, resamples=resamples)
            else:
                arms_summary[arm][exact_field] = None

    # B-9 Settlement & Released Reservation summary for SP
    b9_summary: dict[str, Any] = {}
    for metric in B9_METRICS:
        vals = [r[metric] for r in b9_records]
        b9_summary[metric] = summarize_sample(vals, seed=seed, resamples=resamples)

    # Paired triplet differences, exact sign tests, Holm-Bonferroni adjustment, Cliff's delta,
    # and true interval propagation [L_A - U_B, U_A - L_B] for interval-identified quantities.
    paired_summary: dict[str, dict[str, Any]] = {}
    for comp_name, arm_a, arm_b in ALL_COMPARISONS:
        paired_summary[comp_name] = {
            "armA": arm_a,
            "armB": arm_b,
            "isPrimaryPreRegistered": comp_name in PRIMARY_COMPARISONS,
            "matchedPairs": len(sorted_pairs),
            "metrics": {},
            "intervalDifferences": {},
        }
        for metric in POINT_METRICS:
            vals_a = [pair_map[p][arm_a][metric] for p in sorted_pairs]
            vals_b = [pair_map[p][arm_b][metric] for p in sorted_pairs]
            diffs = [a - b for a, b in zip(vals_a, vals_b)]
            paired_summary[comp_name]["metrics"][metric] = {
                "pairedDifference": summarize_sample(diffs, seed=seed, resamples=resamples),
                "signTest": paired_sign_test(vals_a, vals_b),
                "cliffsDelta": cliffs_delta(vals_a, vals_b),
            }

        # True interval propagation: [L_A - U_B, U_A - L_B]
        gas_ex_diff_bounds = [
            compute_interval_difference(
                pair_map[p][arm_a]["gasExPenaltyLower"],
                pair_map[p][arm_a]["gasExPenaltyUpper"],
                pair_map[p][arm_b]["gasExPenaltyLower"],
                pair_map[p][arm_b]["gasExPenaltyUpper"],
            )
            for p in sorted_pairs
        ]
        pen_diff_bounds = [
            compute_interval_difference(
                pair_map[p][arm_a]["penaltyLower"],
                pair_map[p][arm_a]["penaltyUpper"],
                pair_map[p][arm_b]["penaltyLower"],
                pair_map[p][arm_b]["penaltyUpper"],
            )
            for p in sorted_pairs
        ]
        paired_summary[comp_name]["intervalDifferences"] = {
            "actualGasExPenalty": {
                "formula": "[gasExPenaltyLower_A - gasExPenaltyUpper_B, gasExPenaltyUpper_A - gasExPenaltyLower_B]",
                "diffLower": summarize_sample([b[0] for b in gas_ex_diff_bounds], seed=seed, resamples=resamples),
                "diffUpper": summarize_sample([b[1] for b in gas_ex_diff_bounds], seed=seed, resamples=resamples),
            },
            "penalty": {
                "formula": "[penaltyLower_A - penaltyUpper_B, penaltyUpper_A - penaltyLower_B]",
                "diffLower": summarize_sample([b[0] for b in pen_diff_bounds], seed=seed, resamples=resamples),
                "diffUpper": summarize_sample([b[1] for b in pen_diff_bounds], seed=seed, resamples=resamples),
            },
        }

    # Apply Holm-Bonferroni adjustment across primary family (m=2) and all-pairs family (m=3)
    for metric in POINT_METRICS:
        raw_primary = {
            c: paired_summary[c]["metrics"][metric]["signTest"]["pValueTwoSided"] for c in PRIMARY_COMPARISONS
        }
        adj_primary = holm_bonferroni(raw_primary)
        raw_all3 = {
            c: paired_summary[c]["metrics"][metric]["signTest"]["pValueTwoSided"] for c, _, _ in ALL_COMPARISONS
        }
        adj_all3 = holm_bonferroni(raw_all3)
        for comp_name, _, _ in ALL_COMPARISONS:
            st_obj = paired_summary[comp_name]["metrics"][metric]["signTest"]
            st_obj["pValueHolmPrimary"] = adj_primary.get(comp_name)
            st_obj["pValueHolmAllPairs"] = adj_all3[comp_name]

    source_meta = package.get("source", {})
    chain_ids = sorted({r["chainId"] for arm in ARMS for r in arm_records[arm]})
    b9_block = {
        "arm": "SP",
        "mode": "BALANCE",
        "formula": "xBurned = min(xLocked, ceil(aCharged * xLocked / aReserved))",
        "metrics": b9_summary,
    }
    return {
        "schema": "aoa-m3-stats-v2",
        "scriptPath": "scripts/aoa_m3_stats.py",
        "sourceCodeSha256": source_code_hashes(),
        "runType": run_type,
        "isRehearsal": run_type == "rehearsal",
        "isFormalCandidate": run_type == "formal-candidate",
        "chainIds": chain_ids,
        "source": source_meta,
        "inputFilesSha256": dict(package.get("files", {})),
        "structuralCheck": check_res,
        "statisticalConfig": {
            "ddof": 1,
            "pythonVersion": sys.version.split()[0],
            "bootstrapRng": "Python random.Random.randrange; independent reseeding per metric",
            "bootstrapSeed": seed,
            "bootstrapResamples": resamples,
            "ciLevel": 0.95,
            "quantileMethod": "linear_type7_exact_fraction",
            "signTestTieHandling": "exclude_ties_report_nTie_and_nEff",
            "multipleTestingAdjustment": "holm_bonferroni_step_down",
            "primaryComparisonFamily": list(PRIMARY_COMPARISONS),
            "billingResidualDefinition": "actualGasUsed - txGasUsed",
            "r2_4_guard": (
                "Sample SD (ddof=1) and percentile bootstrap 95% CI [ci95Low, ci95High] "
                "are reported in separate fields and columns."
            ),
        },
        "arms": arms_summary,
        "pairedComparisons": paired_summary,
        "b9Settlement": b9_block,
        "b9Overcharge": b9_block,
        "arm_records": arm_records,
        "b9_records": b9_records,
    }


def compare_stat_results(
    computed: dict[str, Any],
    external: dict[str, Any],
    rel_tol: float = 0.0,
    abs_tol: float = 0.0,
) -> dict[str, Any]:
    """Compare complete same-engine reproduction reports, excluding root comparison metadata.

    Source hashes are part of identity: this is not cross-implementation validation.
    Default comparison is exact. Optional tolerance applies only to ordinary floats;
    integer accounting is exact and p-values never receive absolute tolerance.
    """
    if not all(math.isfinite(t) and t >= 0 for t in (rel_tol, abs_tol)):
        raise ValueError("comparison tolerances must be finite and non-negative")
    mismatches: list[str] = []
    checked = 0

    def _cmp(path: str, a: Any, b: Any) -> None:
        nonlocal checked
        if isinstance(a, dict):
            if not isinstance(b, dict):
                mismatches.append(f"{path}: expected dict, got {type(b).__name__}")
                return
            ignored = {"statResultsComparison"} if path == "root" else set()
            for missing in sorted(set(a) - set(b) - ignored):
                mismatches.append(f"{path}.{missing}: missing in external report")
            for extra in sorted(set(b) - set(a) - ignored):
                mismatches.append(f"{path}.{extra}: absent from computed report")
            for key in sorted((set(a) & set(b)) - ignored):
                _cmp(f"{path}.{key}", a[key], b[key])
        elif isinstance(a, list):
            if not isinstance(b, list) or len(a) != len(b):
                mismatches.append(f"{path}: list length/type mismatch")
                return
            for i, (ai, bi) in enumerate(zip(a, b)):
                _cmp(f"{path}[{i}]", ai, bi)
        else:
            checked += 1
            if type(a) is float and type(b) is float:
                # Never allow a small positive p-value to compare equal to zero.
                field_abs_tol = 0.0 if path.rsplit(".", 1)[-1].startswith("pValue") else abs_tol
                matches = math.isfinite(a) and math.isfinite(b) and math.isclose(
                    a, b, rel_tol=rel_tol, abs_tol=field_abs_tol
                )
            else:
                matches = type(a) is type(b) and a == b
            if not matches:
                mismatches.append(f"{path}: computed={a!r} != external={b!r}")

    _cmp("root", computed, external)
    return {
        "match": len(mismatches) == 0,
        "checkedFields": checked,
        "relTol": rel_tol,
        "absTol": abs_tol,
        "comparisonScope": "complete_same_engine_report_except_root_statResultsComparison",
        "mismatches": mismatches,
    }


def _fmt_num(val: float | None, decimals: int = 2) -> str:
    if val is None:
        return "N/A"
    if abs(val - round(val)) < 1e-9 and decimals == 0:
        return f"{int(round(val)):,}"
    return f"{val:,.{decimals}f}"


def _fmt_ci(st: dict[str, Any], decimals: int = 2) -> str:
    low = Decimal(st["ci95LowExact"])
    high = Decimal(st["ci95HighExact"])
    return f"[{low:,.{decimals}f}, {high:,.{decimals}f}]"


def _fmt_pval(p: float | None) -> str:
    if p is None:
        return "N/A"
    if p < 1e-4:
        return f"{p:.2e}"
    return f"{p:.4f}"


def render_latex(report: dict[str, Any]) -> str:
    """Render ready-to-include LaTeX tables for Tables 5-7 and B-9 Reservation & Settlement Summary."""
    run_type = report["runType"]
    source = report.get("source", {})
    run_id = source.get("runId", "unknown")
    chain_str = ", ".join(str(c) for c in report.get("chainIds", []))
    head_str = str(source.get("collectorHead", "unknown"))[:12]
    n_groups = report["structuralCheck"]["matched_groups"]
    resamples = int(report["statisticalConfig"]["bootstrapResamples"])
    resamples_tex = f"{resamples:,}".replace(",", "{,}")
    seed = int(report["statisticalConfig"]["bootstrapSeed"])

    if run_type == "rehearsal":
        banner = (
            f"REHEARSAL ONLY (Local Anvil chainId={chain_str}, runId={run_id}, "
            f"collectorHead={head_str}) --- NOT PUBLIC-CHAIN EVIDENCE (D12-CHAIN-01)"
        )
    else:
        banner = (
            f"FORMAL CANDIDATE (chainId={chain_str}, runId={run_id}, "
            f"collectorHead={head_str})"
        )

    arms = report["arms"]
    paired = report["pairedComparisons"]
    b9 = report["b9Settlement"]["metrics"]

    lines = [
        "% =============================================================================",
        f"% Auto-generated by {report.get('publicationEntrypoint', 'scripts/aoa_m3_stats.py')} (schema: {report['schema']})",
        f"% Run status : {banner}",
        f"% Triplets   : n = {n_groups} matched (SP, VerifyingPaymaster, TokenPaymaster)",
        f"% Bootstrap  : B = {resamples}, seed = {seed}",
        "% R2-4 Guard : Sample SD (ddof=1) and 95% Bootstrap CI [Low, High] are strictly separated.",
        "% =============================================================================",
        "",
        "% --- Table 5: Controlled 3-Arm Gas Distribution Summary ---",
        "\\begin{table}[htbp]\\centering",
        f"\\caption{{Controlled three-arm gas summary ($n={n_groups}$ matched triplets; \\texttt{{runType={run_type}}}, \\texttt{{chainId={chain_str}}}). Sample SD ($\\text{{ddof}}=1$) and percentile bootstrap 95\\% CI $[\\text{{Low}}, \\text{{High}}]$ ($B={resamples_tex}$) are reported separately.}}",
        "\\label{tab:m3-gas-summary}",
        "\\resizebox{\\textwidth}{!}{%",
        "\\begin{tabular}{llrrrrlrrrrr}",
        "\\toprule",
        "\\textbf{Metric} & \\textbf{Arm} & \\textbf{$n$} & \\textbf{Mean} & \\textbf{SD} & \\textbf{95\\% CI $[\\text{Low}, \\text{High}]$} & \\textbf{Median} & \\textbf{IQR} & \\textbf{Min} & \\textbf{Max} & \\textbf{P95} & \\textbf{Skewness} \\\\",
        "\\midrule",
    ]

    for metric_key, metric_label in (
        ("actualGasUsed", "Billed (\\texttt{actualGasUsed})"),
        ("txGasUsed", "Receipt (\\texttt{txGasUsed})"),
    ):
        for idx, arm in enumerate(ARMS):
            st = arms[arm][metric_key]
            m_col = metric_label if idx == 0 else ""
            skew_str = "N/A" if st["skewness"] is None else f"{st['skewness']:+.4f}"
            lines.append(
                f"{m_col} & {arm} & {st['n']} & {_fmt_num(st['mean'], 2)} & {_fmt_num(st['sd'], 2)} & "
                f"{_fmt_ci(st, 2)} & {_fmt_num(st['median'], 1)} & {_fmt_num(st['iqr'], 1)} & "
                f"{_fmt_num(st['min'], 0)} & {_fmt_num(st['max'], 0)} & {_fmt_num(st['p95'], 1)} & {skew_str} \\\\"
            )
        lines.append("\\midrule")
    if lines[-1] == "\\midrule":
        lines[-1] = "\\bottomrule"

    lines.extend([
        "\\end{tabular}%",
        "}",
        "\\end{table}",
        "",
        "% --- Table 6: Billing Residual & N-2 10% Unused Execution Gas Penalty Interval Bounds ---",
        "\\begin{table}[htbp]\\centering",
        f"\\caption{{Accounting-layer decomposition and EntryPoint v0.7 10\\% unused execution gas penalty bounds (\\texttt{{EntryPoint.sol:718-730}}; $n={n_groups}$, \\texttt{{runType={run_type}}}). Without call-frame execution traces, penalty and \\texttt{{actualGasExPenalty}} are interval-identified.}}",
        "\\label{tab:m3-n2-decomposition}",
        "\\resizebox{\\textwidth}{!}{%",
        "\\begin{tabular}{lrrrrrr}",
        "\\toprule",
        "\\textbf{Arm} & \\textbf{Mean \\texttt{actualGasUsed}} & \\textbf{Mean \\texttt{txGasUsed}} & \\textbf{Mean Residual (\\texttt{actual - tx})} & \\textbf{$L_{\\text{exec}}$ (\\texttt{call + postOp})} & \\textbf{N-2 Penalty $[\\text{LB}, \\text{UB}]$} & \\textbf{\\texttt{actualGasExPenalty} $[\\text{Lower}, \\text{Upper}]$} \\\\",
        "\\midrule",
    ])

    for arm in ARMS:
        st_act = arms[arm]["actualGasUsed"]
        st_tx = arms[arm]["txGasUsed"]
        st_res = arms[arm]["billingResidual"]
        st_lex = arms[arm]["executionGasLimit"]
        st_plb = arms[arm]["penaltyLower"]
        st_pub = arms[arm]["penaltyUpper"]
        st_glb = arms[arm]["gasExPenaltyLower"]
        st_gub = arms[arm]["gasExPenaltyUpper"]
        lines.append(
            f"{arm} & {_fmt_num(st_act['mean'], 2)} & {_fmt_num(st_tx['mean'], 2)} & {_fmt_num(st_res['mean'], 2)} & "
            f"{_fmt_num(st_lex['mean'], 0)} & [{_fmt_num(st_plb['mean'], 0)}, {_fmt_num(st_pub['mean'], 0)}] & "
            f"[{_fmt_num(st_glb['mean'], 2)}, {_fmt_num(st_gub['mean'], 2)}] \\\\"
        )

    lines.extend([
        "\\bottomrule",
        "\\end{tabular}%",
        "}",
        "\\end{table}",
        "",
        "% --- Table 7: Paired Triplet Differences, Sign Tests, Holm Adjustment & Cliff's Delta ---",
        "\\begin{table}[htbp]\\centering",
        f"\\caption{{Paired within-triplet gas differences, two-sided exact paired sign tests with Holm--Bonferroni adjustment ($B={resamples_tex}$ bootstrap resamples), Cliff's $\\delta$, and identified \\texttt{{actualGasExPenalty}} difference intervals $[L_A - U_B, U_A - L_B]$ ($n={n_groups}$ pairs; \\texttt{{runType={run_type}}}).}}",
        "\\label{tab:m3-paired-comparisons}",
        "\\resizebox{\\textwidth}{!}{%",
        "\\begin{tabular}{llrrlrrrrrl}",
        "\\toprule",
        "\\textbf{Comparison} & \\textbf{Metric} & \\textbf{Mean $\\Delta$} & \\textbf{SD $\\Delta$} & \\textbf{95\\% CI $[\\text{Low}, \\text{High}]$} & \\textbf{Median $\\Delta$} & \\textbf{IQR $\\Delta$} & \\textbf{Sign $p$} & \\textbf{Holm $p$} & \\textbf{Cliff's $\\delta$} & \\textbf{Magnitude / Bound} \\\\",
        "\\midrule",
    ])

    for comp_key, comp_label in (
        ("SP_minus_VerifyingPaymaster", "SP $-$ VPM"),
        ("SP_minus_TokenPaymaster", "SP $-$ TPM"),
        ("TokenPaymaster_minus_VerifyingPaymaster", "TPM $-$ VPM"),
    ):
        for m_key, m_label in (
            ("actualGasUsed", "\\texttt{actualGasUsed}"),
            ("txGasUsed", "\\texttt{txGasUsed}"),
        ):
            entry = paired[comp_key]["metrics"][m_key]
            pd_st = entry["pairedDifference"]
            st_test = entry["signTest"]
            cd = entry["cliffsDelta"]
            holm_p = (
                st_test["pValueHolmPrimary"]
                if st_test["pValueHolmPrimary"] is not None
                else st_test["pValueHolmAllPairs"]
            )
            lines.append(
                f"{comp_label} & {m_label} & {_fmt_num(pd_st['mean'], 2)} & {_fmt_num(pd_st['sd'], 2)} & "
                f"{_fmt_ci(pd_st, 2)} & {_fmt_num(pd_st['median'], 1)} & {_fmt_num(pd_st['iqr'], 1)} & "
                f"{_fmt_pval(st_test['pValueTwoSided'])} & {_fmt_pval(holm_p)} & "
                f"{cd['delta']:+.4f} & {cd['magnitude']} \\\\"
            )
        idiff = paired[comp_key]["intervalDifferences"]["actualGasExPenalty"]
        dl = idiff["diffLower"]["mean"]
        du = idiff["diffUpper"]["mean"]
        lines.append(
            f"{comp_label} & \\texttt{{actualGasExPenalty}} $[L_A-U_B, U_A-L_B]$ & "
            f"\\multicolumn{{3}}{{c}}{{[{_fmt_num(dl, 0)}, {_fmt_num(du, 0)}]}} & "
            f"-- & -- & -- & -- & -- & interval bound \\\\"
        )
        lines.append("\\midrule")
    if lines[-1] == "\\midrule":
        lines[-1] = "\\bottomrule"

    lines.extend([
        "\\end{tabular}%",
        "}",
        "\\end{table}",
        "",
        "% --- B-9: SP Validation Reservation (tryLockForGas) vs PostOp Settlement (settleLocked) Summary ---",
        "\\begin{table}[htbp]\\centering",
        f"\\caption{{B-9 SuperPaymaster validation reservation (\\texttt{{tryLockForGas}}) versus \\texttt{{postOp}} settlement (\\texttt{{settleLocked}}) accounting ($n={n_groups}$ SP attempts; \\texttt{{runType={run_type}}}, $B={resamples_tex}$).}}",
        "\\label{tab:m3-b9-settlement}",
        "\\resizebox{\\textwidth}{!}{%",
        "\\begin{tabular}{lrrlrrrr}",
        "\\toprule",
        "\\textbf{Quantity} & \\textbf{Mean} & \\textbf{SD} & \\textbf{95\\% CI $[\\text{Low}, \\text{High}]$} & \\textbf{Median} & \\textbf{IQR} & \\textbf{Min} & \\textbf{Max} \\\\",
        "\\midrule",
    ])

    b9_rows = (
        ("xLockedTokens", "Validation Reservation $x_{\\text{locked}}$ (xPNTs)", 4),
        ("xBurnedTokens", "Settled Burn $x_{\\text{burned}}$ (xPNTs)", 4),
        ("releasedReservationTokens", "Released Reservation $x_{\\text{locked}} - x_{\\text{burned}}$ (xPNTs)", 4),
        ("reservationExcessRatioPct", "Reservation Excess Ratio $(x_{\\text{locked}} - x_{\\text{burned}})/x_{\\text{burned}}$ (\\%)", 4),
        ("releasedShareOfLockedPct", "Released Share of Lock $(x_{\\text{locked}} - x_{\\text{burned}})/x_{\\text{locked}}$ (\\%)", 4),
        ("lockUtilizationPct", "Lock Utilization $x_{\\text{burned}}/x_{\\text{locked}}$ (\\%)", 4),
        ("settlementRoundingDeltaWei", "Ceiling Rounding Delta $x_{\\text{burned}} - \\lfloor c x_0 / a_0 \\rfloor$ (wei)", 0),
    )
    for key, label, dec in b9_rows:
        st = b9[key]
        lines.append(
            f"{label} & {_fmt_num(st['mean'], dec)} & {_fmt_num(st['sd'], 6)} & {_fmt_ci(st, dec)} & "
            f"{_fmt_num(st['median'], dec)} & {_fmt_num(st['iqr'], 6)} & {_fmt_num(st['min'], dec)} & {_fmt_num(st['max'], dec)} \\\\"
        )

    lines.extend([
        "\\bottomrule",
        "\\end{tabular}%",
        "}",
        "\\end{table}",
        "",
    ])
    return "\n".join(lines)


def main(argv: list[str] | None = None, *, publication_entrypoint: str | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path, help="Path to receive.json package")
    parser.add_argument("--expected", type=int, default=50, help="Expected number of matched triplets (default: 50)")
    parser.add_argument("--seed", type=int, default=BOOTSTRAP_SEED, help=f"Bootstrap RNG seed (default: {BOOTSTRAP_SEED})")
    parser.add_argument(
        "--resamples",
        type=int,
        default=BOOTSTRAP_RESAMPLES,
        help=f"Bootstrap resamples B (default: {BOOTSTRAP_RESAMPLES})",
    )
    parser.add_argument("--json-out", type=Path, default=None, help="Write machine-readable JSON report to path")
    parser.add_argument("--latex-out", type=Path, default=None, help="Write LaTeX tables snippet to path")
    parser.add_argument(
        "--compare-stat-results",
        type=Path,
        default=None,
        help="Compare computed summary against an external stat_results.json and fail closed on mismatch",
    )
    args = parser.parse_args(argv)

    try:
        if args.expected <= 0:
            raise ValueError("expected must be positive")
        if args.resamples <= 0:
            raise ValueError("resamples must be positive")
        if args.seed < 0:
            raise ValueError("seed must be non-negative")
        raw_bytes = args.package.read_bytes()
        pkg_sha256 = hashlib.sha256(raw_bytes).hexdigest()
        pkg_data = json.loads(raw_bytes.decode("utf-8"))
        report = analyze_package(
            pkg_data,
            args.package.parent,
            expected=args.expected,
            seed=args.seed,
            resamples=args.resamples,
        )
        report["packageSha256"] = pkg_sha256
        if publication_entrypoint is not None:
            report["publicationEntrypoint"] = publication_entrypoint

        if args.compare_stat_results is not None:
            ext_data = json.loads(args.compare_stat_results.read_text(encoding="utf-8"))
            comp_res = compare_stat_results(report, ext_data)
            report["statResultsComparison"] = comp_res
            if not comp_res["match"]:
                raise ValueError(f"stat_results comparison failed: {comp_res['mismatches']}")

        if args.json_out is not None:
            args.json_out.parent.mkdir(parents=True, exist_ok=True)
            args.json_out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        if args.latex_out is not None:
            args.latex_out.parent.mkdir(parents=True, exist_ok=True)
            args.latex_out.write_text(render_latex(report), encoding="utf-8")
        if args.json_out is None:
            print(json.dumps(report, indent=2, ensure_ascii=False))
        return 0
    except Exception as exc:  # fail closed on any error
        err_payload = {"status": "FAIL", "errors": [str(exc)]}
        print(json.dumps(err_payload, indent=2, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Unit tests for scripts/aoa_m3_stats.py (M3.5 Statistical, N-2 & B-9 Pipeline)."""
from __future__ import annotations

import copy
from decimal import Decimal
import hashlib
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from aoa_m3_check import CONTROLS
from gate.stats_from_csv import main as publication_main
from aoa_m3_stats import (
    _fmt_ci,
    BOOTSTRAP_RESAMPLES,
    BOOTSTRAP_SEED,
    TOPIC_LOCK_CREATED,
    TOPIC_LOCK_SETTLED,
    TOPIC_TX_SPONSORED,
    analyze_package,
    bootstrap_mean_ci,
    cliffs_delta,
    compare_stat_results,
    compute_b9_overcharge,
    compute_b9_settlement,
    compute_interval_difference,
    compute_n2_penalty,
    compute_skewness,
    holm_bonferroni,
    main as cli_main,
    paired_sign_test,
    quantile_linear,
    render_latex,
    summarize_sample,
)


def _word_hex(val: int) -> str:
    return format(val, "064x")


TOKEN_ADDR = "0xdc17c27ae8be831af07cc38c02930007060020f4"
SP_ADDR = "0x68b1d87f95878fe05b998f19b66f4baba5de1aed"
USER_ADDR = "0x43a71246698e5be1d9fb04183589eda602ea06f1"
OP_ADDR = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
USER_TOPIC = "0x" + "0" * 24 + USER_ADDR[2:]
SP_TOPIC = "0x" + "0" * 24 + SP_ADDR[2:]
OP_TOPIC = "0x" + "0" * 24 + OP_ADDR[2:]


class TestAoaM3Stats(unittest.TestCase):
    def test_complete_result_comparison_rejects_semantic_tampering(self) -> None:
        report = {
            "arm_records": {"SP": [{"actualGasUsed": 10**20 + 1}]},
            "b9_records": [{"xBurnedWei": 10**20 + 1}],
            "source": {"runId": "original"},
            "structuralCheck": {"matched_groups": 50},
            "packageSha256": "original",
            "signTest": {"pValueHolmPrimary": 3.55e-15},
        }
        self.assertTrue(compare_stat_results(report, copy.deepcopy(report))["match"])
        for field in report:
            mutated = copy.deepcopy(report)
            mutated[field] = {"forged": True}
            self.assertFalse(compare_stat_results(report, mutated)["match"], field)
            missing = copy.deepcopy(report)
            del missing[field]
            self.assertFalse(compare_stat_results(report, missing)["match"], field)
        zero_p = copy.deepcopy(report)
        zero_p["signTest"]["pValueHolmPrimary"] = 0.0
        self.assertFalse(compare_stat_results(report, zero_p, abs_tol=1e-8)["match"])
        one_wei = copy.deepcopy(report)
        one_wei["b9_records"][0]["xBurnedWei"] += 1
        self.assertFalse(compare_stat_results(report, one_wei)["match"])
        with_metadata = copy.deepcopy(report)
        with_metadata["statResultsComparison"] = {"match": True}
        self.assertTrue(compare_stat_results(report, with_metadata)["match"])

    def test_n2_bounds_match_exhaustive_feasible_execution(self) -> None:
        for limit in range(41):
            for budget in range(limit // 10, limit + 10):
                penalties = [max(0, limit - gas) // 10
                             for gas in range(budget + 1)
                             if gas + max(0, limit - gas) // 10 <= budget]
                result = compute_n2_penalty(budget + 17, limit, 0, 17)
                self.assertEqual(result["penaltyLower"], min(penalties))
                self.assertEqual(result["penaltyUpper"], max(penalties))

    def test_latex_ci_preserves_large_integer_offsets(self) -> None:
        result = summarize_sample([10**20 + i for i in range(50)], resamples=200)
        rendered = _fmt_ci(result, 2)
        self.assertIn(format(Decimal(result["ci95LowExact"]), ",.2f"), rendered)
        self.assertNotEqual(result["ci95LowExact"], result["ci95HighExact"])

    def test_summarize_sample_and_r2_4_separation(self) -> None:
        sample = [10.0, 20.0, 30.0, 40.0, 50.0]
        res = summarize_sample(sample, seed=BOOTSTRAP_SEED, resamples=BOOTSTRAP_RESAMPLES)
        self.assertEqual(res["n"], 5)
        self.assertAlmostEqual(res["mean"], 30.0, places=9)
        self.assertAlmostEqual(res["sd"], math.sqrt(250.0), places=9)
        self.assertAlmostEqual(res["median"], 30.0, places=9)
        self.assertAlmostEqual(res["q25"], 20.0, places=9)
        self.assertAlmostEqual(res["q75"], 40.0, places=9)
        self.assertAlmostEqual(res["iqr"], 20.0, places=9)
        self.assertAlmostEqual(res["min"], 10.0, places=9)
        self.assertAlmostEqual(res["max"], 50.0, places=9)
        self.assertAlmostEqual(res["range"], 40.0, places=9)
        self.assertAlmostEqual(res["p95"], 48.0, places=9)
        self.assertAlmostEqual(res["skewness"], 0.0, places=9)
        self.assertNotAlmostEqual(res["sd"], res["ci95HalfWidth"], places=2)
        self.assertGreater(res["ci95Width"], 0.0)
        self.assertAlmostEqual(res["ci95Width"], res["ci95High"] - res["ci95Low"], places=9)
        low2, high2, half2 = bootstrap_mean_ci(sample, seed=BOOTSTRAP_SEED, resamples=BOOTSTRAP_RESAMPLES)
        self.assertEqual(res["ci95Low"], low2)
        self.assertEqual(res["ci95High"], high2)
        self.assertEqual(res["ci95HalfWidth"], half2)

    def test_constant_sample_zero_sd_and_none_skewness(self) -> None:
        for val in (387702, 775404002713914, 107666900376834150000):
            sample = [val] * 50
            res = summarize_sample(sample)
            self.assertEqual(res["n"], 50)
            self.assertEqual(res["mean"], float(val))
            self.assertEqual(res["meanExact"], str(val))
            self.assertEqual(res["sd"], 0.0)
            self.assertEqual(res["iqr"], 0.0)
            self.assertEqual(res["range"], 0.0)
            self.assertIsNone(res["skewness"])
            self.assertEqual(res["ci95LowExact"], str(val))
            self.assertEqual(res["ci95HighExact"], str(val))
            self.assertEqual(res["ci95Width"], 0.0)
            self.assertEqual(res["ci95HalfWidth"], 0.0)

    def test_codex_counterexample_skewed_asymmetric_ci(self) -> None:
        # Codex Astra P1-05.1 counterexample: [0]*9 + [100] has mean=10, percentile CI=[0, 30] (not 10 +/- 15)
        sample = [0] * 9 + [100]
        res = summarize_sample(sample, seed=BOOTSTRAP_SEED, resamples=BOOTSTRAP_RESAMPLES)
        self.assertAlmostEqual(res["mean"], 10.0, places=9)
        self.assertAlmostEqual(res["ci95Low"], 0.0, places=9)
        self.assertAlmostEqual(res["ci95High"], 30.0, places=9)
        # Endpoint distance to mean is asymmetric: mean - low = 10 != high - mean = 20
        self.assertNotAlmostEqual(res["mean"] - res["ci95Low"], res["ci95High"] - res["mean"], places=2)

    def test_codex_counterexample_large_int_tiny_variance_ci(self) -> None:
        # Codex Astra P1-05.2 counterexample: 10**20 + i for i=0..49
        sample = [10**20 + i for i in range(50)]
        res = summarize_sample(sample, seed=BOOTSTRAP_SEED, resamples=2000)
        self.assertAlmostEqual(res["sd"], math.sqrt(50 * 51 / 12.0), places=9)
        self.assertEqual(res["range"], 49.0)
        self.assertGreater(res["ci95Width"], 7.0)
        self.assertGreater(res["ci95HalfWidth"], 3.5)
        low_dec = Decimal(res["ci95LowExact"])
        high_dec = Decimal(res["ci95HighExact"])
        self.assertGreater(high_dec - low_dec, Decimal("7.0"))
        self.assertAlmostEqual(float(high_dec - low_dec), res["ci95Width"], places=9)
        # Invalid resamples <= 0 must raise ValueError
        with self.assertRaises(ValueError):
            summarize_sample(sample, resamples=0)

    def test_skewness_asymmetric(self) -> None:
        sample = [1.0, 2.0, 2.0, 3.0, 10.0]
        res = summarize_sample(sample, resamples=500)
        self.assertIsNotNone(res["skewness"])
        self.assertGreater(res["skewness"], 1.5)
        self.assertAlmostEqual(res["skewness"], compute_skewness(sample), places=12)
        self.assertIsNone(compute_skewness([1.0, 2.0]))

    def test_quantile_linear(self) -> None:
        vals = [10.0, 20.0, 30.0, 40.0]
        self.assertAlmostEqual(quantile_linear(vals, 0.0), 10.0)
        self.assertAlmostEqual(quantile_linear(vals, 0.25), 17.5)
        self.assertAlmostEqual(quantile_linear(vals, 0.50), 25.0)
        self.assertAlmostEqual(quantile_linear(vals, 0.75), 32.5)
        self.assertAlmostEqual(quantile_linear(vals, 1.0), 40.0)

    def test_cliffs_delta(self) -> None:
        cd_pos = cliffs_delta([100, 101, 102], [10, 11, 12])
        self.assertAlmostEqual(cd_pos["delta"], 1.0)
        self.assertEqual(cd_pos["magnitude"], "large")

        cd_neg = cliffs_delta([10, 11, 12], [100, 101, 102])
        self.assertAlmostEqual(cd_neg["delta"], -1.0)
        self.assertEqual(cd_neg["magnitude"], "large")

        cd_zero = cliffs_delta([5, 5, 5], [5, 5, 5])
        self.assertAlmostEqual(cd_zero["delta"], 0.0)
        self.assertEqual(cd_zero["magnitude"], "negligible")

        cd_half = cliffs_delta([2, 4], [1, 3])
        self.assertAlmostEqual(cd_half["delta"], 0.5)
        self.assertEqual(cd_half["magnitude"], "large")

    def test_paired_sign_test_and_holm_bonferroni(self) -> None:
        # 10 positive diffs, 0 negative, 2 ties -> nEff = 10, p = 2 * (1 / 1024) = 1 / 512
        x = [10] * 10 + [5, 5]
        y = [1] * 10 + [5, 5]
        st = paired_sign_test(x, y)
        self.assertEqual(st["nPairs"], 12)
        self.assertEqual(st["nPos"], 10)
        self.assertEqual(st["nNeg"], 0)
        self.assertEqual(st["nTie"], 2)
        self.assertEqual(st["nEff"], 10)
        self.assertAlmostEqual(st["pValueTwoSided"], 2.0 / 1024.0, places=12)

        # All ties -> nEff = 0, p = 1.0
        st_ties = paired_sign_test([7, 7, 7], [7, 7, 7])
        self.assertEqual(st_ties["nEff"], 0)
        self.assertEqual(st_ties["pValueTwoSided"], 1.0)

        # Holm-Bonferroni step-down on 3 hypotheses: p = {h1: 0.01, h2: 0.04, h3: 0.03}
        # Ordered: h1 (0.01 * 3 = 0.03), h3 (max(0.03, 0.03 * 2 = 0.06) = 0.06), h2 (max(0.06, 0.04 * 1) = 0.06)
        adj = holm_bonferroni({"h1": 0.01, "h2": 0.04, "h3": 0.03})
        self.assertAlmostEqual(adj["h1"], 0.03, places=12)
        self.assertAlmostEqual(adj["h3"], 0.06, places=12)
        self.assertAlmostEqual(adj["h2"], 0.06, places=12)

    def test_n2_penalty_exact_and_interval_bounds_and_codex_counterexamples(self) -> None:
        # 1. Exact calculation when execution_gas_used is provided
        exact = compute_n2_penalty(
            actual_gas_used=387702,
            call_gas_limit=100000,
            post_op_gas_limit=200000,
            pre_verification_gas=60000,
            execution_gas_used=120000,
        )
        self.assertEqual(exact["executionGasLimit"], 300000)
        self.assertEqual(exact["unusedExecutionGas"], 180000)
        self.assertEqual(exact["penaltyExact"], 18000)
        self.assertEqual(exact["actualGasExPenaltyExact"], 387702 - 18000)
        self.assertEqual(exact["penaltyDerivation"], "exact_from_execution_gas_used")

        # 2. Archive-only interval bound for VPM (actualGasUsed=120575, callGas=100000, postOpGas=50000, preVer=60000)
        bounded_vpm = compute_n2_penalty(
            actual_gas_used=120575,
            call_gas_limit=100000,
            post_op_gas_limit=50000,
            pre_verification_gas=60000,
        )
        self.assertIsNone(bounded_vpm["penaltyExact"])
        self.assertIsNone(bounded_vpm["actualGasExPenaltyExact"])
        self.assertNotIn("unusedGasPenalty", bounded_vpm)
        self.assertEqual(bounded_vpm["penaltyLower"], 9936)
        self.assertEqual(bounded_vpm["penaltyUpper"], 15000)
        self.assertEqual(bounded_vpm["gasExPenaltyLower"], 120575 - 15000)
        self.assertEqual(bounded_vpm["gasExPenaltyUpper"], 120575 - 9936)

        # 3. True paired interval difference [L_A - U_B, U_A - L_B] (Codex Astra P1-03)
        bounded_sp = compute_n2_penalty(
            actual_gas_used=387702,
            call_gas_limit=100000,
            post_op_gas_limit=200000,
            pre_verification_gas=60000,
        )
        diff_lo, diff_hi = compute_interval_difference(
            bounded_sp["gasExPenaltyLower"],
            bounded_sp["gasExPenaltyUpper"],
            bounded_vpm["gasExPenaltyLower"],
            bounded_vpm["gasExPenaltyUpper"],
        )
        # SP: [357702, 387702], VPM: [105575, 110639] -> [357702 - 110639, 387702 - 105575] = [247063, 282127]
        self.assertEqual((diff_lo, diff_hi), (247063, 282127))
        self.assertNotEqual(diff_lo, bounded_sp["gasExPenaltyLower"] - bounded_vpm["gasExPenaltyLower"])

        # 4. Codex Astra P0-02 counterexample: actualGasUsed=1, PVG=60000, call=100000, postOp=200000 -> rejected!
        with self.assertRaises(ValueError):
            compute_n2_penalty(
                actual_gas_used=1,
                call_gas_limit=100000,
                post_op_gas_limit=200000,
                pre_verification_gas=60000,
            )

        # 5. Infeasible exact executionGasUsed where actual - PVG - exec - penalty < 0 -> rejected!
        with self.assertRaises(ValueError):
            compute_n2_penalty(
                actual_gas_used=100000,
                call_gas_limit=100000,
                post_op_gas_limit=200000,
                pre_verification_gas=60000,
                execution_gas_used=50000,
            )

        # 6. Boolean inputs rejected (since isinstance(True, int) is True in Python)
        with self.assertRaises(ValueError):
            compute_n2_penalty(
                actual_gas_used=True,  # type: ignore[arg-type]
                call_gas_limit=100000,
                post_op_gas_limit=200000,
                pre_verification_gas=60000,
            )

    def test_b9_settlement_and_codex_counterexamples(self) -> None:
        op_hash = "0x" + "ab" * 32
        x_locked = 2544 * 10**18
        a_reserved = 2544 * 10**18
        x_burned = 107666900376834150000
        a_charged = 107666900376834150000
        a_gas = 97879000342576500000

        logs = [
            {
                "address": TOKEN_ADDR,
                "topics": [TOPIC_LOCK_CREATED, USER_TOPIC, op_hash, SP_TOPIC],
                "data": "0x" + _word_hex(x_locked) + _word_hex(a_reserved),
            },
            {
                "address": TOKEN_ADDR,
                "topics": [TOPIC_LOCK_SETTLED, USER_TOPIC, op_hash],
                "data": "0x" + _word_hex(x_burned) + _word_hex(a_charged),
            },
            {
                "address": SP_ADDR,
                "topics": [TOPIC_TX_SPONSORED, OP_TOPIC, USER_TOPIC],
                "data": "0x" + _word_hex(a_gas) + _word_hex(a_charged),
            },
        ]
        state = {
            "readbacks": {
                "before": {
                    "A": {
                        "userXPNTs": str(5000 * 10**18),
                        "totalSpent": "0",
                        "operatorBalance": str(10000 * 10**18),
                        "protocolRevenue": "0",
                        "lockedOf": "0",
                        "debts": "0",
                    }
                },
                "after": {
                    "A": {
                        "userXPNTs": str(5000 * 10**18 - x_burned),
                        "totalSpent": str(a_reserved),
                        "operatorBalance": str(10000 * 10**18 - a_charged),
                        "protocolRevenue": str(a_charged),
                        "lockedOf": "0",
                        "debts": "0",
                    }
                },
            }
        }
        b9 = compute_b9_settlement(
            op_hash,
            logs,
            state,
            expected_token_address=TOKEN_ADDR,
            expected_sp_address=SP_ADDR,
            expected_user_address=USER_ADDR,
            expected_operator_address=OP_ADDR,
        )
        self.assertEqual(b9["xLockedWei"], x_locked)
        self.assertEqual(b9["xBurnedWei"], x_burned)
        self.assertEqual(b9["releasedReservationWei"], x_locked - x_burned)
        self.assertEqual(b9["settlementRoundingDeltaWei"], 0)
        expected_pct = ((x_locked - x_burned) / float(x_burned)) * 100.0
        self.assertAlmostEqual(b9["reservationExcessRatioPct"], expected_pct, places=9)
        self.assertAlmostEqual(b9["releasedShareOfLockedPct"] + b9["lockUtilizationPct"], 100.0, places=9)

        # Non-1:1 exchange rate where ceil(aCharged * xLocked / aReserved) rounds up by 1 wei
        logs_ceil = copy.deepcopy(logs)
        state_ceil = copy.deepcopy(state)
        # Let aReserved = 300, xLocked = 200, aCharged = 100, aGas = 90 -> floor = 66, ceil = 67
        logs_ceil[0]["data"] = "0x" + _word_hex(200) + _word_hex(300)
        logs_ceil[1]["data"] = "0x" + _word_hex(67) + _word_hex(100)
        logs_ceil[2]["data"] = "0x" + _word_hex(90) + _word_hex(100)
        state_ceil["readbacks"]["after"]["A"]["userXPNTs"] = str(5000 * 10**18 - 67)
        state_ceil["readbacks"]["after"]["A"]["totalSpent"] = "300"
        state_ceil["readbacks"]["after"]["A"]["operatorBalance"] = str(10000 * 10**18 - 100)
        state_ceil["readbacks"]["after"]["A"]["protocolRevenue"] = "100"
        b9_ceil = compute_b9_overcharge(op_hash, logs_ceil, state_ceil)
        self.assertEqual(b9_ceil["settlementRoundingDeltaWei"], 1)

        # Floor burn (66 instead of 67) must be rejected by ceiling burn formula check
        logs_bad_burn = copy.deepcopy(logs_ceil)
        logs_bad_burn[1]["data"] = "0x" + _word_hex(66) + _word_hex(100)
        state_bad_burn = copy.deepcopy(state_ceil)
        state_bad_burn["readbacks"]["after"]["A"]["userXPNTs"] = str(5000 * 10**18 - 66)
        with self.assertRaises(ValueError):
            compute_b9_settlement(op_hash, logs_bad_burn, state_bad_burn)

        # Codex Astra P0-02 counterexample: aReserved=100, aCharged=200, xLocked=100, xBurned=50 -> rejected!
        logs_over = copy.deepcopy(logs)
        logs_over[0]["data"] = "0x" + _word_hex(100) + _word_hex(100)
        logs_over[1]["data"] = "0x" + _word_hex(50) + _word_hex(200)
        logs_over[2]["data"] = "0x" + _word_hex(180) + _word_hex(200)
        state_over = copy.deepcopy(state)
        state_over["readbacks"]["after"]["A"]["userXPNTs"] = str(5000 * 10**18 - 50)
        state_over["readbacks"]["after"]["A"]["totalSpent"] = "100"
        state_over["readbacks"]["after"]["A"]["operatorBalance"] = str(10000 * 10**18 - 200)
        state_over["readbacks"]["after"]["A"]["protocolRevenue"] = "200"
        with self.assertRaises(ValueError):
            compute_b9_settlement(op_hash, logs_over, state_over)

        # Codex Astra P0-02 counterexample: TransactionSponsored with only topic0 -> rejected!
        logs_topic0_only = copy.deepcopy(logs)
        logs_topic0_only[2]["topics"] = [TOPIC_TX_SPONSORED]
        with self.assertRaises(ValueError):
            compute_b9_settlement(op_hash, logs_topic0_only, state)

        # Missing or wrong emitter address -> rejected!
        logs_wrong_emitter = copy.deepcopy(logs)
        logs_wrong_emitter[0]["address"] = SP_ADDR
        with self.assertRaises(ValueError):
            compute_b9_settlement(op_hash, logs_wrong_emitter, state)

        # Non-zero post-state residual lock or debt -> rejected!
        state_residual_lock = copy.deepcopy(state)
        state_residual_lock["readbacks"]["after"]["A"]["lockedOf"] = "1"
        with self.assertRaises(ValueError):
            compute_b9_settlement(op_hash, logs, state_residual_lock)

        # Missing post-state lockedOf/debts -> rejected!
        state_no_lock_field = copy.deepcopy(state)
        del state_no_lock_field["readbacks"]["after"]["A"]["lockedOf"]
        with self.assertRaises(ValueError):
            compute_b9_settlement(op_hash, logs, state_no_lock_field)

    def test_end_to_end_package_compare_and_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            files: dict[str, str] = {}

            def write_archived(rel: str, obj: dict) -> str:
                body = (json.dumps(obj, indent=1) + "\n").encode("utf-8")
                path = root / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(body)
                files[rel] = hashlib.sha256(body).hexdigest()
                return rel

            passport = {
                "start": {
                    "invariant": {
                        "sender": USER_ADDR,
                        "xPNTs": {"address": TOKEN_ADDR, "superPaymaster": SP_ADDR},
                        "superPaymaster": {
                            "operator": {"address": OP_ADDR, "xPNTsToken": TOKEN_ADDR},
                        },
                        "gas": {"callGasLimit": "100000", "preVerificationGas": "60000"},
                        "pmGas": {
                            "SP": {"ver": "400000", "post": "200000"},
                            "VPM": {"ver": "100000", "post": "50000"},
                            "TPM": {"ver": "150000", "post": "120000"},
                        },
                    }
                }
            }
            p_file = write_archived("raw/passport.json", passport)

            attempts = []
            gas_table = {
                "SP": (387702, 285571, {"ver": "400000", "post": "200000"}),
                "VerifyingPaymaster": (120575, 92896, {"ver": "100000", "post": "50000"}),
                "TokenPaymaster": (160130, 125766, {"ver": "150000", "post": "120000"}),
            }
            idx = 0
            for pair_idx in range(2):
                for arm in ("SP", "VerifyingPaymaster", "TokenPaymaster"):
                    idx += 1
                    uoe_gas, tx_gas, pm_gas = gas_table[arm]
                    tx_gas_adj = tx_gas - pair_idx * 12
                    cost_wei = uoe_gas * 2000000000
                    op_hash = "0x" + format(idx, "064x")
                    tx_hash = "0x" + format(idx + 100, "064x")
                    blk_hash = "0x" + format(idx + 200, "064x")
                    code_hash = "0x" + format(idx + 300, "064x")

                    logs = []
                    state_obj: dict = {"readbacks": {"before": {"A": {}}, "after": {"A": {}}}}
                    if arm == "SP":
                        x_locked = 2544 * 10**18
                        x_burned = 100 * 10**18
                        a_gas = 90 * 10**18
                        logs = [
                            {
                                "address": TOKEN_ADDR,
                                "topics": [TOPIC_LOCK_CREATED, USER_TOPIC, op_hash, SP_TOPIC],
                                "data": "0x" + _word_hex(x_locked) + _word_hex(x_locked),
                            },
                            {
                                "address": TOKEN_ADDR,
                                "topics": [TOPIC_LOCK_SETTLED, USER_TOPIC, op_hash],
                                "data": "0x" + _word_hex(x_burned) + _word_hex(x_burned),
                            },
                            {
                                "address": SP_ADDR,
                                "topics": [TOPIC_TX_SPONSORED, OP_TOPIC, USER_TOPIC],
                                "data": "0x" + _word_hex(a_gas) + _word_hex(x_burned),
                            },
                        ]
                        state_obj = {
                            "readbacks": {
                                "before": {
                                    "A": {
                                        "userXPNTs": str(5000 * 10**18),
                                        "totalSpent": "0",
                                        "operatorBalance": str(5000 * 10**18),
                                        "protocolRevenue": "0",
                                        "lockedOf": "0",
                                        "debts": "0",
                                    }
                                },
                                "after": {
                                    "A": {
                                        "userXPNTs": str(5000 * 10**18 - x_burned),
                                        "totalSpent": str(x_locked),
                                        "operatorBalance": str(5000 * 10**18 - x_burned),
                                        "protocolRevenue": str(x_burned),
                                        "lockedOf": "0",
                                        "debts": "0",
                                    }
                                },
                            }
                        }

                    r_file = write_archived(
                        f"raw/{arm}-{idx}.receipt.json",
                        {"tx": {"gasUsed": str(tx_gas_adj), "effectiveGasPrice": "1000000000"}, "logs": logs},
                    )
                    u_file = write_archived(
                        f"raw/{arm}-{idx}.uoe.json",
                        {
                            "actualGasUsed": str(uoe_gas),
                            "actualGasCost": str(cost_wei),
                            "sender": USER_ADDR,
                            "paymaster": SP_ADDR if arm == "SP" else "0x" + "55" * 20,
                        },
                    )
                    s_file = write_archived(f"raw/{arm}-{idx}.state.json", state_obj)

                    row = {
                        "attemptId": f"run/{arm}/{idx}",
                        "pairId": f"run/{pair_idx}",
                        "included": True,
                        "paymasterKind": arm,
                        "chainId": 31337,
                        "txHash": tx_hash,
                        "userOpHash": op_hash,
                        "blockHash": blk_hash,
                        "runtimeCodeHash": code_hash,
                        "receiptStatus": 1,
                        "userOpSuccess": True,
                        "settlementVerified": True,
                        "actualGasUsed": str(uoe_gas),
                        "actualGasCostWei": str(cost_wei),
                        "txGasUsed": str(tx_gas_adj),
                        "effectiveGasPriceWei": "1000000000",
                        "receiptFile": r_file,
                        "uoeFile": u_file,
                        "passportFile": p_file,
                        "stateFile": s_file,
                        "paymasterGas": pm_gas,
                        "injectedScenario": None,
                    }
                    row.update(dict.fromkeys(CONTROLS, "ctrl-1"))
                    attempts.append(row)

            pkg = {
                "schema": "aoa-m3-receive-v1",
                "runType": "rehearsal",
                "source": {"runId": "unit-test", "collectorHead": "deadbeef1234"},
                "files": files,
                "attempts": attempts,
            }
            pkg_path = root / "receive.json"
            pkg_path.write_text(json.dumps(pkg, indent=2) + "\n", encoding="utf-8")

            report = analyze_package(pkg, root, expected=2, seed=20261030, resamples=200)
            self.assertEqual(report["runType"], "rehearsal")
            self.assertTrue(report["isRehearsal"])
            self.assertIn("arm_records", report)
            self.assertIn("b9_records", report)
            self.assertEqual(len(report["b9_records"]), 2)
            # billingResidual = actualGasUsed - txGasUsed > 0
            self.assertGreater(report["arms"]["SP"]["billingResidual"]["mean"], 0.0)
            self.assertAlmostEqual(
                report["b9Settlement"]["metrics"]["reservationExcessRatioPct"]["mean"],
                2444.0,
                places=6,
            )
            latex = render_latex(report)
            self.assertIn("REHEARSAL ONLY", latex)
            self.assertIn("B=200", latex)
            self.assertNotIn("B=10{,}000", latex)
            self.assertIn("\\label{tab:m3-b9-settlement}", latex)

            # The authoritative A3.2 entrypoint must exercise the full package pipeline.
            gate_json, gate_tex = root / "gate.json", root / "gate.tex"
            gate_args = ["--m3-package", str(pkg_path), "--expected", "2", "--resamples", "200",
                         "--json-out", str(gate_json), "--latex-out", str(gate_tex)]
            self.assertEqual(publication_main(gate_args), 0)
            gate_report = json.loads(gate_json.read_text())
            self.assertEqual(gate_report["publicationEntrypoint"], "scripts/gate/stats_from_csv.py")
            self.assertEqual(gate_report["arms"], report["arms"])
            self.assertIn("scripts/gate/stats_from_csv.py", gate_tex.read_text())
            self.assertEqual(publication_main(gate_args + ["--compare-stat-results", str(gate_json)]), 0)

            # Compare against identical report -> match=True
            cmp_ok = compare_stat_results(report, copy.deepcopy(report))
            self.assertTrue(cmp_ok["match"])
            for partial in ({}, {"runType": "rehearsal"}):
                self.assertFalse(compare_stat_results(report, partial)["match"])
            missing_endpoint = copy.deepcopy(report)
            del missing_endpoint["arms"]["SP"]["actualGasUsed"]["ci95LowExact"]
            self.assertFalse(compare_stat_results(report, missing_endpoint)["match"])

            # Compare against tampered external stat_results.json -> match=False & CLI exits 1
            tampered_ext = copy.deepcopy(report)
            tampered_ext["arms"]["SP"]["actualGasUsed"]["mean"] = 999999.0
            cmp_bad = compare_stat_results(report, tampered_ext)
            self.assertFalse(cmp_bad["match"])

            ext_path = root / "ext_stats.json"
            ext_path.write_text(json.dumps(tampered_ext), encoding="utf-8")
            self.assertEqual(
                cli_main([str(pkg_path), "--expected", "2", "--resamples", "200", "--compare-stat-results", str(ext_path)]),
                1,
            )

            # Unbound row overrides must not change the archived penalty inputs.
            for field, value in (("gas", {"callGasLimit": "0", "preVerificationGas": "0"}),
                                 ("paymasterGas", {"post": "1", "ver": "400000"}),
                                 ("paymasterGas", {"post": "200000", "ver": "1"})):
                altered_gas = copy.deepcopy(pkg)
                altered_gas["attempts"][0][field] = value
                with self.assertRaisesRegex(ValueError, "disagrees with archived passport"):
                    analyze_package(altered_gas, root, expected=2, seed=20261030, resamples=200)

            # Unverified executionGasUsed on an attempt row must fail closed
            pkg_unverified_trace = copy.deepcopy(pkg)
            pkg_unverified_trace["attempts"][0]["executionGasUsed"] = 120000
            with self.assertRaises(ValueError):
                analyze_package(pkg_unverified_trace, root, expected=2, seed=20261030, resamples=200)
            # A producer flag plus an existing hashed file still proves no trace reconstruction.
            pkg_unverified_trace["attempts"][0]["executionTraceVerified"] = True
            pkg_unverified_trace["attempts"][0]["traceFile"] = p_file
            with self.assertRaises(ValueError):
                analyze_package(pkg_unverified_trace, root, expected=2, seed=20261030, resamples=200)


if __name__ == "__main__":
    unittest.main()

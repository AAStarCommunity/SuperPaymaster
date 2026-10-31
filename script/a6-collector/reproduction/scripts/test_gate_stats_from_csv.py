#!/usr/bin/env python3
"""Behavior checks for the authoritative A3.2 CSV and M3 statistics entrypoint."""
from contextlib import redirect_stdout, redirect_stderr
from decimal import Decimal
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from gate import stats_from_csv as gate
import aoa_m3_stats as stats


class TestGateStats(unittest.TestCase):
    def test_large_integer_csv_and_asymmetric_ci(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            big = root / "large.csv"
            big.write_text("gas\n" + "\n".join(str(10**20 + i) for i in range(50)) + "\n")
            skewed = root / "skewed.csv"
            skewed.write_text("gas\n" + "0\n" * 9 + "100\n")
            output, md = root / "stats.json", root / "stats.md"
            with redirect_stdout(io.StringIO()):
                rc = gate.main(["--col", "gas", f"large={big}", f"skewed={skewed}",
                                "--json-out", str(output), "--out", str(md)])
            self.assertEqual(rc, 0)
            report = json.loads(output.read_text())
            large = report["summaries"]["large"]
            self.assertEqual(large["meanExact"], "100000000000000000024.5")
            self.assertGreater(Decimal(large["ci95HighExact"]), Decimal(large["ci95LowExact"]))
            self.assertEqual(report["summaries"]["skewed"]["ci95LowExact"], "0")
            self.assertEqual(report["summaries"]["skewed"]["ci95HighExact"], "30")
            self.assertIn("[0, 30]", md.read_text())
            self.assertNotIn("±", md.read_text())
            self.assertEqual(large, stats.summarize_sample(gate.load(big, "gas"), seed=42))

    def test_cliff_direction_and_endpoint_helper(self):
        self.assertEqual(gate.cliff([100, 101], [1, 2]), 1.0)
        self.assertEqual(gate.cliff([1, 2], [100, 101]), -1.0)
        self.assertEqual(gate.boot_ci([0] * 9 + [100]), (Decimal(0), Decimal(30)))
        self.assertIsNone(gate.skew([5, 5, 5]))

    def test_bad_csv_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bad.csv"
            for body in ("wrong\n1\n", "gas\nNaN\n", "gas\n"):
                path.write_text(body)
                with redirect_stderr(io.StringIO()):
                    self.assertEqual(gate.main(["--col", "gas", f"bad={path}"]), 1)


if __name__ == "__main__":
    unittest.main()

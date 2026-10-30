#!/usr/bin/env python3
"""Synthetic U-6 controls: each failure differs from accepted input by one stake field.

Changing both passport copies avoids triggering the pre-existing drift check.
These are offline validator controls, not chain evidence.
"""
import copy
import importlib.util
import json
import tempfile
import sys
from pathlib import Path

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("credit", Path(__file__).with_name("credit-schema-downgrade.py"))
credit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(credit)


def main():
    rows = [json.loads(l) for l in credit.SRC.read_text().splitlines() if l.strip()]
    for r in rows:
        credit.patch(r)
        r["schema"] = "a6-gauge/2"
    rows[0]["protocolConformant"] = True
    for r in (rows[0], rows[-1]):
        r["passport"]["invariant"]["credit"] = dict(credit.CREDIT_OFF)
        for stake in r["passport"]["invariant"]["stakes"].values():
            stake.update(staked=True, stake="1000000000000000000", unstakeDelaySec="86400")
    checks = []
    with tempfile.TemporaryDirectory() as d:
        code, report = credit.validate(rows, d, "positive")
        assert code == 0 and report["accepted"] and report["errors"] == [], report
        checks.append({"variant": "all arms at threshold", "exit": code})
        for arm in ("SP", "VPM", "TPM"):
            for field, value, error in (
                ("staked", False, "paymaster not staked"),
                ("stake", "999999999999999999", "paymaster stake below 1000000000000000000 wei"),
                ("unstakeDelaySec", "86399", "paymaster unstakeDelaySec below 86400"),
            ):
                variant = copy.deepcopy(rows)
                for r in (variant[0], variant[-1]):
                    r["passport"]["invariant"]["stakes"][arm][field] = value
                code, report = credit.validate(variant, d, f"{arm}-{field}")
                assert code == 1 and report["errors"] == [f"arm {arm}: {error}"], report
                checks.append({"variant": f"{arm}-{field}", "exit": code, "errors": report["errors"]})
                # Restore just this field: all other checks still accept the same material.
                for r in (variant[0], variant[-1]):
                    r["passport"]["invariant"]["stakes"][arm][field] = rows[0]["passport"]["invariant"]["stakes"][arm][field]
                restored, report = credit.validate(variant, d, "restored")
                assert restored == 0 and report["errors"] == [], report
    print(json.dumps({"checks": checks, "restored_controls": 9, "ok": True}, indent=2))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Regenerate script/evidence/a4-test-results.json from a real run on the current checkout.

Every field is recomputed; nothing is carried over except the reviewed mapping discrepancies and notes.
Run from the repository root after `python3 -B script/evidence/test_a4_mutations.py`:

    A3A_ENGINE_DIR=$HOME/.foundry/bin A4_FOUNDRY_BIN=$HOME/.foundry/bin python3 -B script/evidence/a4_test_results.py

The record names the commit whose code was tested (`testedHead`) and whether the tracked tree was clean.
It cannot name the commit that adds the record itself; that commit must change only this JSON file.
"""
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path.cwd()
SUITES = [
    "script/upgrade/test_manifest_exec.py",
    "script/upgrade/test_release_evidence.py",
    "script/evidence/test_a4_credit_logscan.py",
    "script/evidence/test_a4_state_check.py",
    "script/evidence/test_a4_a6_controls.py",
    "script/evidence/test_a4_anvil_control.py",
]
# Single mutants that independent receipt checks block; each has a killed *_double counterpart.
EXPECTED_SURVIVORS = {"logscan.missing_chunk_log", "logscan.log_hash", "logscan.outside_filter"}


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()


def main():
    if os.environ.get("A4_SKIP_ANVIL"):
        sys.exit("A4_SKIP_ANVIL is set: the anvil control must run for this record")
    for directory in ("script/evidence", "script/upgrade", "script/a3a"):
        sys.path.insert(0, str(ROOT / directory))
    head = git("rev-parse", "HEAD")
    dirty = [line for line in git("status", "--porcelain").splitlines()
             if not line.endswith("script/evidence/a4-test-results.json")]
    rows = []
    for path in SUITES:
        suite = unittest.defaultTestLoader.loadTestsFromName(Path(path).stem)
        result = unittest.TextTestRunner(verbosity=1).run(suite)
        failed, errors, skipped = map(len, (result.failures, result.errors, result.skipped))
        rows.append(dict(suite=path, run=result.testsRun, passed=result.testsRun - failed - errors - skipped,
                         failed=failed, errors=errors, skipped=skipped))
    evidence = ROOT / "script/evidence"
    mutations = json.loads((evidence / "a4-guard-mutations.json").read_text())
    survivors = sorted(row["name"] for row in mutations["mutations"] if not row.get("killed"))
    doubles = {row["name"]: bool(row.get("killed")) for row in mutations["mutations"] if row["name"].endswith("_double")}
    target = evidence / "a4-test-results.json"
    previous = json.loads(target.read_text()) if target.exists() else {}
    blockers = []
    if dirty:
        blockers.append("tracked tree not clean: " + ", ".join(dirty))
    blockers += [f"{r['suite']}: {r['failed']} failed, {r['errors']} errors, {r['skipped']} skipped"
                 for r in rows if r["failed"] or r["errors"] or r["skipped"] or r["run"] == 0]
    if set(survivors) != EXPECTED_SURVIVORS:
        blockers.append("unexpected mutation survivors: " + ", ".join(survivors))
    for name in EXPECTED_SURVIVORS:
        if not doubles.get(name + "_double"):
            blockers.append(f"double mutant {name}_double missing or not killed")
    report = dict(
        scope="checker-logic-offline",
        testedHead=head,
        trackedTreeClean=not dirty,
        result="PASS" if not blockers else "BLOCKED",
        blockers=blockers,
        suites=rows,
        mutations=dict(report="a4-guard-mutations.json", total=mutations["total"], killed=mutations["killed"],
                       survivors=survivors, doubleMutants=doubles,
                       errors=sum(row.get("errors", 0) for row in mutations["mutations"])),
        mappingDiscrepancies=previous.get("mappingDiscrepancies", []),
        notes=previous.get("notes", []),
    )
    target.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: report[k] for k in ("testedHead", "trackedTreeClean", "result", "blockers")}, indent=2))
    sys.exit(0 if not blockers else 1)


if __name__ == "__main__":
    main()

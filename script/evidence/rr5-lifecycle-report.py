#!/usr/bin/env python3
"""Summarise an rr5-lifecycle-run.py output directory as a Markdown table (stdout).

Usage: python3 script/evidence/rr5-lifecycle-report.py <run-dir> > SUMMARY.md
Reads only manifest.json (already checked by `rr5-lifecycle-run.py --verify`). Exits non-zero if any
expected engine/mode/variant row is missing or has an unexpected shape.
"""
import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('run', Path(__file__).with_name('rr5-lifecycle-run.py'))
run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run)

out = Path(sys.argv[1])
manifest = json.loads((out/'manifest.json').read_text())
expected = [f'{e}/{m}/{v}' for e in run.ENGINES for m in run.MODES for v in run.VARIANTS]
assert sorted(manifest) == sorted(expected), 'manifest rows differ from the declared inventory'


def band(row):
    return '—' if row['non_guard_scan'] is None else f"{row['non_guard_scan'][0]:,}–{row['non_guard_scan'][1]:,}"


print('| Engine | Mode | Variant | Guard rejects ≤ | Non-guard failure band (scan) | Completes from |')
print('| --- | --- | --- | --- | --- | --- |')
banded = {}
for key in expected:
    e, m, v = key.split('/')
    row = manifest[key]
    if v in run.SPLIT:
        assert row.get('split') is True and row['failure_selectors'] == [run.NOT_LIVE], key
        print(f"| {e} | {m} | {v} | scan {row['last_guard_scan']:,} | {band(row)} | never: NotLive `{run.NOT_LIVE}` |")
        continue
    assert row['guard_lo'] and row['guard_hi'] and row['complete_lo'], key
    print(f"| {e} | {m} | {v} | {row['last_guard']:,} | {band(row)} | {row['first_complete']:,} |")
    if row['non_guard_scan'] is not None:
        banded.setdefault(e, []).append(f'{m}/{v}')
print()
for e in run.ENGINES:
    rows = banded.get(e, [])
    print(f"- {e}: {len(rows)} non-split rows with a non-guard band" + (': ' + ', '.join(rows) if rows else ''))

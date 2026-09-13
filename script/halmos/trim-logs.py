#!/usr/bin/env python3
"""D5c-1 — trim Halmos/forge evidence logs to their informative part (same rule as
script/evidence/run-logged.sh): keep the provenance header (leading '#' lines) and everything from
the first Halmos 'Running N tests' line (or forge 'Ran N test') onward; replace the omitted block
(forge compiler warnings/lints and Halmos 'Skipped ... duplicate contract names' parse warnings,
several thousand lines per run) by one line saying how many lines were dropped. build.log files of
mutation runs are reduced to their last 5 lines. Idempotent.

usage: python3 script/halmos/trim-logs.py docs/design/aoa-balance-mode/data/halmos
"""
import os
import re
import sys

MARK = re.compile(r"^(Running \d+ tests for |Ran \d+ tests? for )")

root = sys.argv[1]
n_files = 0
for d, _, files in os.walk(root):
    for fn in files:
        p = os.path.join(d, fn)
        if not fn.endswith(".log"):
            continue
        lines = open(p, errors="replace").read().splitlines(True)
        if any(l.startswith("# (trimmed:") for l in lines[:20]):
            continue
        if fn == "build.log":
            keep = [f"# (trimmed: {max(0, len(lines) - 5)} lines of forge build output omitted; last 5 kept)\n"] + lines[-5:]
        else:
            head = []
            i = 0
            while i < len(lines) and lines[i].startswith("#"):
                head.append(lines[i]); i += 1
            j = next((k for k in range(i, len(lines)) if MARK.match(lines[k])), None)
            if j is None:
                continue  # no result section (e.g. an aborted run) — keep verbatim
            keep = head + [f"# (trimmed: {j - i} lines of compiler / Halmos parse warnings omitted)\n"] + lines[j:]
        open(p, "w").writelines(keep)
        n_files += 1
print(f"trimmed {n_files} logs under {root}")

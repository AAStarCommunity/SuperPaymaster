#!/usr/bin/env python3
"""R2-F4: compare every R2A|key|value row of the artifact-bytes re-run with the R-AMS-2a Amsterdam log of
the same test. Rows are compared as (key -> list of values in print order).
Usage: python3 -I cmp_g.py <old logs dir> <new logs dir> <out.md> [old label] [new label]"""
import re, sys, os
from collections import OrderedDict

old_dir, new_dir, out = sys.argv[1:4]
lab_old = sys.argv[4] if len(sys.argv) > 4 else "R-AMS-2a (recompiled by forge nightly, prague)"
lab_new = sys.argv[5] if len(sys.argv) > 5 else "rc.4 artifact bytes"
row = re.compile(r"R2A\|([^|]+)\|(-?\d+)")

def rows(p):
    d = OrderedDict()
    if not os.path.exists(p):
        return None
    for line in open(p, encoding="utf-8", errors="replace"):
        m = row.search(line)
        if m:
            d.setdefault(m.group(1), []).append(m.group(2))
    return d

lines = ["| test | rows (old / new) | identical | differing | only old | only new |", "|---|---|---|---|---|---|"]
diffs = []
total_same = total_diff = 0
for f in sorted(os.listdir(new_dir)):
    if not f.endswith("_amsterdam.log"):
        continue
    o, n = rows(os.path.join(old_dir, f)), rows(os.path.join(new_dir, f))
    if o is None:
        lines.append(f"| {f} | — / {sum(len(v) for v in n.values())} | (no R-AMS-2a log: new test) | | | |")
        continue
    same = [k for k in n if k in o and o[k] == n[k]]
    dif = [k for k in n if k in o and o[k] != n[k]]
    only_o = [k for k in o if k not in n]
    only_n = [k for k in n if k not in o]
    total_same += len(same); total_diff += len(dif) + len(only_o) + len(only_n)
    lines.append(f"| {f} | {sum(len(v) for v in o.values())} / {sum(len(v) for v in n.values())} | {len(same)} | {len(dif)} | {len(only_o)} | {len(only_n)} |")
    for k in dif:
        diffs.append(f"| {f} | `{k}` | {', '.join(o[k])} | {', '.join(n[k])} |")
    for k in only_o:
        diffs.append(f"| {f} | `{k}` | {', '.join(o[k])} | (absent) |")
    for k in only_n:
        diffs.append(f"| {f} | `{k}` | (absent) | {', '.join(n[k])} |")

res = "\n".join(lines) + f"\n\nkeys identical: {total_same}; keys differing or missing: {total_diff}\n"
if diffs:
    res += f"\n| test | key | {lab_old} | {lab_new} |\n|---|---|---|---|\n" + "\n".join(diffs) + "\n"
open(out, "w").write(res)
print(res)

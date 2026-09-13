#!/usr/bin/env python3
"""D5c-1 — rebuild <check>.summary.{json,txt} of a partition directory from its logs (used when a
batch was stopped before the driver wrote its summary). Result per partition, from the log:
PASS / FAIL / TIMEOUT (Halmos result line), TIMEOUT-WALL (the driver's `# WALL-CAP` marker), else
ABORTED (the process was stopped; the log's wall time is the bound). Retry logs (*.retry.log)
supersede the first attempt, which is kept in `first_attempt`.

usage: python3 script/halmos/summarize-dir.py <dir> <Contract> <check> <core|ext> [note]
"""
import json
import os
import re
import sys

d, contract, check, abi = sys.argv[1:5]
note = sys.argv[5] if len(sys.argv) > 5 else ""
ABI = {"core": "xPNTsTokenV2", "ext": "xPNTsTokenV2Ext"}[abi]
pat = re.compile(r"\[(PASS|FAIL|TIMEOUT|ERROR)\]\S*\s*" + re.escape(check) + r"\([^)]*\) \(paths: (\d+), time: ([0-9.]+)s")


def parse(path):
    t = open(path, errors="replace").read()
    r = {"log": os.path.basename(path)}
    w = re.search(r"# exit_code: (-?\d+)\s+wall_seconds: (\d+)", t)
    if w:
        r["exit"], r["wall_s"] = int(w.group(1)), int(w.group(2))
    m = pat.search(t)
    if m:
        r.update(result=m.group(1), paths=int(m.group(2)), time_s=float(m.group(3)))
    elif "# WALL-CAP:" in t:
        r["result"] = "TIMEOUT-WALL"
    else:
        r["result"] = "ABORTED"
    r["counterexample"] = "Counterexample" in t
    return r


res = {}
for fn in sorted(os.listdir(d)):
    if not (fn.startswith(check + ".") and fn.endswith(".log")):
        continue
    label = fn[len(check) + 1:-4]
    retry = label.endswith(".retry")
    label = label[:-6] if retry else label
    r = parse(os.path.join(d, fn))
    r["part"] = label
    if retry and label in res:
        r["first_attempt"] = {k: res[label].get(k) for k in ("result", "paths", "time_s", "log")}
    if retry or label not in res:
        res[label] = r
results = list(res.values())
nb = sum(r["result"] in ("TIMEOUT", "TIMEOUT-WALL") for r in results)
nf = sum(r["result"] == "FAIL" for r in results)
na = sum(r["result"] not in ("PASS", "FAIL", "TIMEOUT", "TIMEOUT-WALL") for r in results)
# never PASS when any part is not PASS; BOUNDED parts are named, never folded into PASS
verdict = "PASS" if nb == nf == na == 0 else f"NOT-ALL-PASS ({nb} BOUNDED, {nf} FAIL, {na} ABORTED/ERROR)"
s = {"contract": contract, "check": check, "abi": ABI, "parts": len(results), "verdict": verdict,
     "rebuilt_from_logs": True, "note": note, "results": results}
json.dump(s, open(os.path.join(d, f"{check}.summary.json"), "w"), indent=1)
with open(os.path.join(d, f"{check}.summary.txt"), "w") as f:
    f.write(f"{contract}.{check} over {ABI}: {verdict} ({len(results)} parts; summary rebuilt from logs) {note}\n")
    for r in results:
        f.write(f"  {r['part']:<40} {r['result']:<15} paths={r.get('paths', '-')} time={r.get('time_s', '-')}s "
                f"wall={r.get('wall_s', '-')}s exit={r.get('exit', '-')}\n")
print(open(os.path.join(d, f"{check}.summary.txt")).read())

#!/usr/bin/env python3
"""D5c-1 — run one Halmos check split into disjoint calldata partitions, in parallel.

usage (repo root):
  python3 script/halmos/run-partitioned.py <Contract> <check_function> <core|ext> <out_dir>
                                           --profile P [--jobs N] [--only LABEL|NAME,...]

The check reads D5C1_PART from the environment (XPNTsV2HalmosBase._partition):
  part 1               = empty calldata + createCalldata's 1028-byte symbolic-selector input;
  part <selector int>  = exactly that non-view function of the ABI (core = xPNTsTokenV2,
                         ext = xPNTsTokenV2Ext; the list is read from the forge artifact's ABI).
The parts are disjoint and their union is exactly the unpartitioned run. Every part writes its own
log (`<out_dir>/<check>.<label>.log`, the full halmos output) framed by
  header   `# meta: {runner, contract, check, abi, label, part, argv, profile, wall_cap_s}` (the
           values the part is launched with — verify-d5c1.py binds the log to its item through it)
           and `# binding: {...}` (source / harness the run starts from);
  trailer  `# exit_code: N  wall_seconds: M` and `# binding: {...}` (after halmos' own build, incl.
           the harness contract's creation-bytecode hash).
The Halmos arguments come ONLY from d5c1_binding.PROFILES (`--profile`); there is no free-form
argument pass-through and no retry (exactly one log per partition). Each part has a hard wall cap
(d5c1_binding.WALL_CAP_S): exceeded -> the process group is killed, `# WALL-CAP:` is written.
The driver also writes `<check>.summary.{json,txt}` (informative; the verdict is verify-d5c1.py's).

Precondition: the harness artifacts must already carry an AST (run script/halmos/run-d5c1.sh once,
or any halmos run); each part still runs halmos' own `forge build`, which is then a cache no-op.
"""
import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import d5c1_binding as B  # noqa: E402

ABI_OF = {"core": "xPNTsTokenV2", "ext": "xPNTsTokenV2Ext"}


def run_part(contract, check, abi, part, label, out_dir, profile):
    log = os.path.join(out_dir, f"{check}.{label}.log")
    fam = B.family_of(contract)
    argv = B.halmos_argv(contract, profile, function=check)
    env = dict(os.environ, D5C1_PART=str(part), PYTHONUNBUFFERED="1",
               PATH=os.path.expanduser("~/.foundry/bin") + ":" + os.path.expanduser("~/.local/bin") + ":" + os.environ["PATH"])
    t0 = time.time()
    with open(log, "w") as f:
        f.write("# D5c1 partitioned run\n")
        f.write(B.meta_line(runner="run-partitioned", contract=contract, check=check, abi=abi, label=label,
                            part=part, argv=argv, profile=profile, wall_cap_s=B.WALL_CAP_S) + "\n")
        f.write(f"# command: D5C1_PART={part} halmos {' '.join(argv)}\n")
        f.write(f"# tree_note: {os.environ.get('D5C1_TREE', '-')}\n")
        # binding BEFORE the run; the trailer below is written after halmos' own build and
        # verify requires the two to agree on src/lib/harness (no drift during the run)
        f.write(B.line(fam) + "\n")
        f.flush()
        # own process group: on the wall cap we kill exactly this halmos and its solver children
        pr = subprocess.Popen(["halmos"] + argv, stdout=f, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        walled = False
        try:
            rc = pr.wait(timeout=B.WALL_CAP_S)
        except subprocess.TimeoutExpired:
            walled = True
            os.killpg(pr.pid, signal.SIGKILL)
            rc = pr.wait()
        if walled:
            f.write(f"\n# WALL-CAP: killed after {B.WALL_CAP_S} s (per-partition cap); no result line = bounded/open\n")
        f.write(f"\n# exit_code: {rc}  wall_seconds: {int(time.time() - t0)}\n")
        f.write(B.line(fam, contract=contract) + "\n")
    text = open(log, errors="replace").read()
    m = re.search(r"\[(PASS|FAIL|TIMEOUT|ERROR)\]\S*\s*" + re.escape(check) + r"\([^)]*\) \(paths: (\d+), time: ([0-9.]+)s", text)
    res = {"part": label, "D5C1_PART": part, "exit": rc, "wall_s": int(time.time() - t0), "log": os.path.basename(log)}
    if m:
        res.update(result=m.group(1), paths=int(m.group(2)), time_s=float(m.group(3)))
    elif "# WALL-CAP:" in text:
        res.update(result="TIMEOUT-WALL", wall_cap_s=B.WALL_CAP_S)
    else:
        res.update(result="NO-RESULT-LINE")
    res["counterexample"] = "Counterexample" in text
    print(json.dumps(res), flush=True)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("contract")
    ap.add_argument("check")
    ap.add_argument("abi", choices=["core", "ext"])
    ap.add_argument("out_dir")
    ap.add_argument("--profile", required=True, choices=sorted(B.PROFILES))
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    os.makedirs(a.out_dir, exist_ok=True)
    parts = B.partition_specs(ABI_OF[a.abi])
    if a.only:
        keep = set(a.only.split(","))
        parts = [p for p in parts if p[1] in keep or p[1].split("-")[0] in keep]
        if not parts:
            sys.exit(f"--only {a.only}: no such partition")
    # the directory holds exactly one run's evidence: no partition log of an earlier run survives
    for fn in os.listdir(a.out_dir):
        if fn.startswith(a.check + ".") and (fn.endswith(".log") or ".summary." in fn):
            os.remove(os.path.join(a.out_dir, fn))
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = []
        for i, (part, label) in enumerate(parts):
            futs.append(ex.submit(run_part, a.contract, a.check, a.abi, part, label, a.out_dir, a.profile))
            time.sleep(3 if i < a.jobs else 0)  # stagger the initial forge-build no-ops
        results = [f.result() for f in futs]
    nb = sum(r["result"] in ("TIMEOUT", "TIMEOUT-WALL") for r in results)
    nf = sum(r["result"] == "FAIL" for r in results)
    na = sum(r["result"] not in ("PASS", "FAIL", "TIMEOUT", "TIMEOUT-WALL") for r in results)
    # never PASS when any part is not PASS; BOUNDED parts are named, never folded into PASS
    verdict = "PASS" if nb == nf == na == 0 else f"NOT-ALL-PASS ({nb} BOUNDED, {nf} FAIL, {na} ABORTED/ERROR)"
    summary = {"contract": a.contract, "check": a.check, "abi": ABI_OF[a.abi], "parts": len(results),
               "verdict": verdict, "wall_s": int(time.time() - t0), "profile": a.profile, "results": results}
    with open(os.path.join(a.out_dir, f"{a.check}.summary.json"), "w") as f:
        json.dump(summary, f, indent=1)
    with open(os.path.join(a.out_dir, f"{a.check}.summary.txt"), "w") as f:
        f.write(f"{a.contract}.{a.check} over {ABI_OF[a.abi]}: {verdict} ({len(results)} parts, wall {summary['wall_s']} s)\n")
        for r in results:
            f.write(f"  {r['part']:<40} {r['result']:<15} paths={r.get('paths', '-')} time={r.get('time_s', '-')}s exit={r['exit']}\n")
    print(verdict)
    sys.exit(0 if verdict == "PASS" else 1)


if __name__ == "__main__":
    main()

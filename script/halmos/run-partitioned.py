#!/usr/bin/env python3
"""D5c-1 — run one Halmos check split into disjoint calldata partitions, in parallel.

usage (repo root):
  python3 script/halmos/run-partitioned.py <Contract> <check_function> <core|ext> <out_dir>
                                           [--jobs N] [--only SEL,...] [-- extra halmos args...]

The check reads D5C1_PART from the environment (XPNTsV2HalmosBase._partition):
  part 1               = empty calldata + createCalldata's 1028-byte symbolic-selector input;
  part <selector int>  = exactly that non-view function of the ABI (core = xPNTsTokenV2,
                         ext = xPNTsTokenV2Ext; the list is read from the forge artifact's ABI).
The parts are disjoint and their union is exactly the unpartitioned run. Every part writes its own
log (`<out_dir>/<check>.<part>.log`, the full halmos output) and the driver writes
`<out_dir>/<check>.summary.json` + `.summary.txt` (per part: result line, paths, time, exit code).
The overall verdict is PASS only if EVERY part printed `[PASS] <check>`.

Precondition: the harness artifacts must already carry an AST (run script/halmos/run-d5c1.sh once,
or any halmos run); each part still runs halmos' own `forge build`, which is then a cache no-op.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import shutil
import signal
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import d5c1_binding  # noqa: E402

ABI_OF = {"core": "xPNTsTokenV2", "ext": "xPNTsTokenV2Ext"}


WALL_CAP_S = 3600  # set from --part-wall-cap-s in main()


def run_part(contract, check, part, label, out_dir, extra, suffix=""):
    log = os.path.join(out_dir, f"{check}.{label}{suffix}.log")
    env = dict(os.environ, D5C1_PART=str(part), PYTHONUNBUFFERED="1",
               PATH=os.path.expanduser("~/.foundry/bin") + ":" + os.path.expanduser("~/.local/bin") + ":" + os.environ["PATH"])
    cmd = ["halmos", "--contract", contract, "--function", check, "--panic-error-codes", "*"] + extra
    t0 = time.time()
    with open(log, "w") as f:
        f.write(f"# D5c1 partitioned run\n# part: {label} (D5C1_PART={part})\n# command: D5C1_PART={part} {' '.join(cmd)}\n")
        try:
            head = subprocess.check_output(["git", "rev-parse", "HEAD"], stderr=subprocess.DEVNULL).decode().strip()
        except Exception:
            head = os.environ.get("D5C1_TREE", "<no git: see D5C1_TREE / mutation diff>")
        f.write(f"# git_head: {head}\n# tree_note: {os.environ.get('D5C1_TREE', '-')}\n")
        # binding BEFORE the run (source / harness it starts from); the trailer below is written
        # after halmos' own build — verify requires the two to agree on src/lib/harness
        f.write(d5c1_binding.line(d5c1_binding.family_of(contract)) + "\n")
        f.flush()
        # own process group: on the wall cap we kill exactly this halmos and its solver children
        pr = subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        walled = False
        try:
            rc = pr.wait(timeout=WALL_CAP_S)
        except subprocess.TimeoutExpired:
            walled = True
            os.killpg(pr.pid, signal.SIGKILL)
            rc = pr.wait()
        if walled:
            f.write(f"\n# WALL-CAP: killed after {WALL_CAP_S} s (per-partition cap); no result line = bounded/open\n")
        f.write(f"\n# exit_code: {rc}  wall_seconds: {int(time.time() - t0)}\n")
        # evidence binding, computed AFTER the run (its build is what the bytecode hash reflects)
        f.write(d5c1_binding.line(d5c1_binding.family_of(contract)) + "\n")
    text = open(log).read()
    m = re.search(r"\[(PASS|FAIL|TIMEOUT|ERROR)\]\s*\x1b?\[?0?m?\s*" + re.escape(check) + r"\([^)]*\) \(paths: (\d+), time: ([0-9.]+)s", text)
    res = {"part": label, "D5C1_PART": part, "exit": rc, "wall_s": int(time.time() - t0), "log": os.path.basename(log)}
    if m:
        res.update(result=m.group(1), paths=int(m.group(2)), time_s=float(m.group(3)))
    elif "# WALL-CAP:" in text:
        res.update(result="TIMEOUT-WALL", wall_cap_s=WALL_CAP_S)
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
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--only", default="")
    ap.add_argument("--retry-timeout-ms", type=int, default=0,
                    help="parts whose result is TIMEOUT are re-run once with --solver-timeout-assertion <ms> "
                         "(0 = no retry, the default); the retry REPLACES the partition log (exactly one log "
                         "per partition) and the first attempt is moved to <out_dir>/attempts/")
    ap.add_argument("--part-wall-cap-s", type=int, default=3600,
                    help="hard wall-clock cap per partition; exceeded -> TIMEOUT-WALL (no retry)")
    argv = sys.argv[1:]
    extra = []
    if "--" in argv:
        k = argv.index("--")
        argv, extra = argv[:k], argv[k + 1:]
    a = ap.parse_args(argv)
    global WALL_CAP_S
    WALL_CAP_S = a.part_wall_cap_s
    os.makedirs(a.out_dir, exist_ok=True)
    parts = d5c1_binding.partition_specs(ABI_OF[a.abi])
    if a.only:
        keep = set(a.only.split(","))
        parts = [p for p in parts if p[1] in keep or p[1].split("-")[0] in keep]
    else:
        # a full run replaces the whole directory's evidence: no partition log of an earlier run survives
        for fn in os.listdir(a.out_dir):
            if fn.startswith(a.check + ".") and (fn.endswith(".log") or ".summary." in fn):
                os.remove(os.path.join(a.out_dir, fn))
        shutil.rmtree(os.path.join(a.out_dir, "attempts"), ignore_errors=True)
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = []
        for i, (part, label) in enumerate(parts):
            futs.append(ex.submit(run_part, a.contract, a.check, part, label, a.out_dir, extra))
            time.sleep(3 if i < a.jobs else 0)  # stagger the initial forge-build no-ops
        results = [f.result() for f in futs]
    if a.retry_timeout_ms:
        idx = [i for i, r in enumerate(results) if r["result"] == "TIMEOUT"]
        os.makedirs(os.path.join(a.out_dir, "attempts"), exist_ok=True)
        for i in idx:
            os.replace(os.path.join(a.out_dir, results[i]["log"]), os.path.join(a.out_dir, "attempts", results[i]["log"]))
            results[i]["log"] = "attempts/" + results[i]["log"]
        with ThreadPoolExecutor(max_workers=a.jobs) as ex:
            futs = {i: ex.submit(run_part, a.contract, a.check, results[i]["D5C1_PART"], results[i]["part"],
                                 a.out_dir, extra + ["--solver-timeout-assertion", str(a.retry_timeout_ms)])
                    for i in idx}
            for i, fu in futs.items():
                r = fu.result()
                r["first_attempt"] = {k: results[i].get(k) for k in ("result", "paths", "time_s", "log")}
                r["retry_solver_timeout_assertion_ms"] = a.retry_timeout_ms
                results[i] = r
    # merge with an earlier summary of the same check (a re-run of some partitions via --only)
    sj = os.path.join(a.out_dir, f"{a.check}.summary.json")
    if a.only and os.path.exists(sj):
        old = {r["part"]: r for r in json.load(open(sj))["results"]}
        for r in results:
            if r["part"] in old:
                r["previous_attempt"] = {k: old[r["part"]].get(k) for k in ("result", "paths", "time_s", "log")}
            old[r["part"]] = r
        results = list(old.values())
    nb = sum(r["result"] in ("TIMEOUT", "TIMEOUT-WALL") for r in results)
    nf = sum(r["result"] == "FAIL" for r in results)
    na = sum(r["result"] not in ("PASS", "FAIL", "TIMEOUT", "TIMEOUT-WALL") for r in results)
    # never PASS when any part is not PASS; BOUNDED parts are named, never folded into PASS
    verdict = "PASS" if nb == nf == na == 0 else f"NOT-ALL-PASS ({nb} BOUNDED, {nf} FAIL, {na} ABORTED/ERROR)"
    summary = {"contract": a.contract, "check": a.check, "abi": ABI_OF[a.abi], "parts": len(results),
               "verdict": verdict, "wall_s": int(time.time() - t0), "extra_args": extra, "results": results}
    with open(os.path.join(a.out_dir, f"{a.check}.summary.json"), "w") as f:
        json.dump(summary, f, indent=1)
    with open(os.path.join(a.out_dir, f"{a.check}.summary.txt"), "w") as f:
        f.write(f"{a.contract}.{a.check} over {ABI_OF[a.abi]}: {verdict} ({len(results)} parts, wall {summary['wall_s']} s)\n")
        for r in results:
            note = f"  (first attempt {r['first_attempt']['result']}; retried with --solver-timeout-assertion {r['retry_solver_timeout_assertion_ms']})" if "first_attempt" in r else ""
            f.write(f"  {r['part']:<40} {r['result']:<15} paths={r.get('paths', '-')} time={r.get('time_s', '-')}s exit={r['exit']}{note}\n")
    print(verdict)
    sys.exit(0 if verdict == "PASS" else 1)


if __name__ == "__main__":
    main()

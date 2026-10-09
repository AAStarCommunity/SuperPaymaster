#!/usr/bin/env python3
"""Wall-capped, self-judging reproduction of the D5c-2 I9 reachability witness.

Default target: SuperPaymasterI9HalmosTest.check_witness_I9_freshBalanceSettlementReachable
(EVIDENCE-INDEX H-06; archived run: data/halmos-i9/all-checks-final.log, 478 paths, 2881.59 s).

Why this exists
  * The archived H-06 command has only a PER-QUERY solver timeout
    (`--solver-timeout-assertion`), no total wall-clock bound, so a slow run can go on for
    hours with no verdict. This runner adds an independent TOTAL wall cap that works on macOS
    (no coreutils `timeout` needed): halmos runs in its own process group and the whole group
    (halmos + its yices/z3 children) is SIGKILLed when the cap is hit.
  * The per-query timeout is passed with an explicit unit (`300s`). Halmos 0.3.3 parses a bare
    number as MILLISECONDS (halmos/config.py `ParseTimeout.parse` -> `parse_time(values,
    default_unit="ms")`), so the archived `300000` and `300s` are the same 300 s; the unit is
    spelled out only so nobody has to know that.

Verdict (printed as the last line `# VERDICT: ...`, also encoded in the exit code)
  ACCEPT        exit 0  the expected `[FAIL] <check>(` result line, carrying the --statistics
                        breakdown `(paths: N, time: Xs (paths: Ys, models: Zs)`, AND at least
                        one `Counterexample:` block in the log. Only this is a reproduction.
  REJECT        exit 1  the check reported [PASS] (the witness did NOT reach the state), or
                        [FAIL] without a counterexample / without statistics, or [ERROR].
  INCONCLUSIVE  exit 2  wall cap hit, [TIMEOUT] result, or no result line at all. Never a PASS,
                        never an ACCEPT: it says nothing about the property.

Usage (repo root):
  python3 script/halmos/run-i9-witness.py --wall-cap 14400 --log i9-witness.log
"""
import argparse
import os
import re
import signal
import subprocess
import sys
import time

DEFAULT_CONTRACT = "SuperPaymasterI9HalmosTest"
DEFAULT_CHECK = "check_witness_I9_freshBalanceSettlementReachable"


def judge(text, check, walled):
    if walled:
        return "INCONCLUSIVE", 2, "wall cap hit before halmos reported a result"
    m = re.search(r"\[(PASS|FAIL|TIMEOUT|ERROR)\]\S*\s*" + re.escape(check) + r"\(", text)
    if not m:
        return "INCONCLUSIVE", 2, "no result line for the check"
    res = m.group(1)
    if res == "TIMEOUT":
        return "INCONCLUSIVE", 2, "halmos reported [TIMEOUT] (a solver query hit the per-query timeout)"
    if res == "PASS":
        return "REJECT", 1, "check PASSED: the witness state was NOT reached (expected [FAIL])"
    if res == "ERROR":
        return "REJECT", 1, "halmos reported [ERROR]"
    line = text[m.start():text.find("\n", m.start())]
    if not re.search(r"\(paths: \d+, time: [0-9.]+s \(paths: [0-9.]+s, models: [0-9.]+s\)", line):
        return "REJECT", 1, "[FAIL] line lacks the --statistics breakdown"
    if "Counterexample:" not in text:
        return "REJECT", 1, "[FAIL] without any Counterexample block"
    return "ACCEPT", 0, "expected [FAIL] with counterexample and statistics: " + line.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--wall-cap", type=int, required=True, help="total wall-clock cap in SECONDS")
    ap.add_argument("--log", required=True, help="log file to write (halmos stdout+stderr + header/trailer)")
    ap.add_argument("--contract", default=DEFAULT_CONTRACT)
    ap.add_argument("--check", default=DEFAULT_CHECK)
    ap.add_argument("--solver-timeout-assertion", default="300s",
                    help="per-query timeout WITH an explicit unit (default 300s)")
    ap.add_argument("--keep-cache", action="store_true",
                    help="do not delete cache/solidity-files-cache.json first (see H-06 note)")
    ap.add_argument("--self-test", action="store_true", help="run judge() fixtures and exit")
    a = ap.parse_args()

    if not re.fullmatch(r"(0|[0-9.]+(ms|s|m|h))", a.solver_timeout_assertion):
        ap.error("--solver-timeout-assertion needs an explicit unit (ms|s|m|h), e.g. 300s")
    if a.wall_cap <= 0:
        ap.error("--wall-cap must be > 0 seconds")

    if not a.keep_cache and os.path.exists("cache/solidity-files-cache.json"):
        os.remove("cache/solidity-files-cache.json")

    argv = ["halmos", "--contract", a.contract, "--function", a.check, "--loop", "2",
            "--solver-timeout-assertion", a.solver_timeout_assertion, "--statistics"]
    env = dict(os.environ, PYTHONUNBUFFERED="1",
               PATH=os.path.expanduser("~/.foundry/bin") + ":" + os.path.expanduser("~/.local/bin")
               + ":" + os.environ.get("PATH", ""))
    head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    ver = subprocess.run(["halmos", "--version"], capture_output=True, text=True, env=env).stdout.strip()

    t0 = time.time()
    with open(a.log, "w") as f:
        f.write(f"# run-i9-witness: head={head or '-'} halmos={ver or '-'} wall_cap_s={a.wall_cap}\n")
        f.write(f"# command: {' '.join(argv)}\n")
        f.flush()
        # own process group so the cap kills halmos AND its solver children
        pr = subprocess.Popen(argv, stdout=f, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        walled = False
        try:
            rc = pr.wait(timeout=a.wall_cap)
        except subprocess.TimeoutExpired:
            walled = True
            os.killpg(pr.pid, signal.SIGKILL)
            rc = pr.wait()
        wall = int(time.time() - t0)
        if walled:
            f.write(f"\n# WALL-CAP: killed after {a.wall_cap} s; INCONCLUSIVE, not PASS\n")
        f.write(f"\n# exit_code: {rc}  wall_seconds: {wall}\n")
    text = open(a.log, errors="replace").read()
    verdict, code, why = judge(text, a.check, walled)
    with open(a.log, "a") as f:
        f.write(f"# VERDICT: {verdict} ({why})\n")
    print(f"# VERDICT: {verdict} ({why}); wall_seconds={wall}; log={a.log}")
    sys.exit(code)


def self_test():
    c = DEFAULT_CHECK
    stat = "(paths: 478, time: 2881.59s (paths: 17.48s, models: 2864.11s), bounds: [])"
    cases = [
        (f"Counterexample: \n    p_x = 0x00\n[FAIL] {c}(address) {stat}\n", False, "ACCEPT"),
        (f"[FAIL] {c}(address) {stat}\n", False, "REJECT"),                         # no cex
        (f"Counterexample: \n[FAIL] {c}(address) (paths: 4, time: 1.00s, bounds: [])\n", False, "REJECT"),
        (f"[PASS] {c}(address) {stat}\n", False, "REJECT"),
        (f"[TIMEOUT] {c}(address) {stat}\n", False, "INCONCLUSIVE"),
        ("Compiling...\n", False, "INCONCLUSIVE"),
        (f"Counterexample: \n[FAIL] {c}(address) {stat}\n", True, "INCONCLUSIVE"),   # walled wins
        (f"Counterexample: \n[FAIL] {c}_other(address) {stat}\n", False, "INCONCLUSIVE"),  # other check
    ]
    bad = 0
    for i, (text, walled, want) in enumerate(cases):
        got = judge(text, c, walled)[0]
        ok = got == want
        bad += not ok
        print(f"case {i}: want {want} got {got} {'ok' if ok else 'MISMATCH'}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    if "--self-test" in sys.argv[1:]:
        self_test()
    main()

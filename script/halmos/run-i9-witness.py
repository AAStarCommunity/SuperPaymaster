#!/usr/bin/env python3
"""Wall-capped, self-judging, EXPECTATION-AWARE runner for the D5c-2 I9 Halmos checks.

Default target: SuperPaymasterI9HalmosTest.check_witness_I9_freshBalanceSettlementReachable
(EVIDENCE-INDEX H-06; archived run: data/halmos-i9/all-checks-final.log, 478 paths, 2881.59 s).

Why this exists
  * The archived H-06 command has only a PER-QUERY solver timeout
    (`--solver-timeout-assertion`), no total wall-clock bound, so a slow run can go on for
    hours with no verdict. This runner adds an independent TOTAL wall cap that works on macOS
    (no coreutils `timeout` needed): halmos runs in its own process group and the whole group
    (halmos + its yices/z3 children) is terminated when the cap is hit or the run is cancelled.
  * The per-query timeout is passed with an explicit unit (`300s`). Halmos 0.3.3 parses a bare
    number as MILLISECONDS (halmos/config.py `ParseTimeout.parse` -> `parse_time(values,
    default_unit="ms")`), so the archived `300000` and `300s` are the same 300 s; the unit is
    spelled out only so nobody has to know that.

Expectation (DSR CC-125 d030f6e8 item 3)
  Every target declares what a correct run looks like: `PASS` (a property that must be proven,
  e.g. CF-3) or `FAIL` (a reachability witness that must be refuted with a model). Known checks
  carry their expectation in EXPECTATIONS below; `--expect` must agree with it, and an unknown
  check REQUIRES `--expect` (the runner refuses to guess). ACCEPT only when the outcome matches.
  Halmos selection is EXACT (`--match-test '^<check>\('`): halmos' `--function X` is a PREFIX
  regex (`^X.*`) and would also run any check whose name merely extends X.

Verdict (printed as the last line `# VERDICT: ...`, also encoded in the exit code)
  ACCEPT        exit 0  expect FAIL: the `[FAIL] <check>(` result line, carrying the --statistics
                        breakdown `(paths: N, time: Xs (paths: Ys, models: Zs)`, AND at least
                        one valid `Counterexample:` block in the log.
                        expect PASS: the `[PASS] <check>(` line with the same full statistics.
  REJECT        exit 1  the opposite outcome ([PASS] for a FAIL-expected witness: the state was
                        NOT reached; [FAIL] for a PASS-expected property: a counterexample), or
                        the expected outcome without statistics / without a counterexample, or
                        [ERROR], or more than one result line (selection was not exact).
  INCONCLUSIVE  exit 2  wall cap hit, [TIMEOUT] result, no result line at all, or the run was
                        cancelled (SIGINT / SIGTERM / SIGHUP -> `cancelled: SIGINT` etc.) or
                        aborted by a runner exception. Never a PASS, never an ACCEPT: it says
                        nothing about the property.

Cleanup (every exit path: natural exit, wall cap, signal, exception)
  The runner's process group (pgid = halmos pid; halmos' yices/z3 Popens stay in it) gets
  SIGTERM, then SIGKILL after --kill-grace seconds, and only then is the leader reaped. No other
  group is ever signalled. Tests: python3 script/halmos/test_run_i9_witness.py

Usage (repo root):
  python3 script/halmos/run-i9-witness.py --wall-cap 14400 --log i9-witness.log
  python3 script/halmos/run-i9-witness.py --wall-cap 600 --log cf3-384.log \
      --contract SuperPaymasterI9Rc2HalmosTest --check check_I9_CF3ctx384_settleCannotSilentlyFail
  (exit 3 = configuration error: unknown check without --expect, or --expect contradicting
  EXPECTATIONS; nothing is run)
"""
import argparse
import os
import re
import select
import signal
import subprocess
import sys
import time
import traceback

DEFAULT_CONTRACT = "SuperPaymasterI9HalmosTest"
DEFAULT_CHECK = "check_witness_I9_freshBalanceSettlementReachable"

# check name -> expected halmos outcome. FAIL = reachability witness, PASS = property.
EXPECTATIONS = {
    "check_I9_CF1_emptyContext": "PASS",
    "check_I9_CF2_idempotentNoOp": "PASS",
    "check_I9_CF3_settleCannotSilentlyFail": "PASS",
    "check_I9_CF3ctx384_settleCannotSilentlyFail": "PASS",
    "check_witness_I9_settleRevertsButCallerObservesSuccess": "PASS",   # misnamed: a property
    "check_witness_I9_CF2_idempotentSucceedsWithEnoughGas": "FAIL",
    "check_witness_I9_freshBalanceSettlementReachable": "FAIL",
    "check_witness_I9_posCharge352Reachable": "FAIL",
    "check_witness_I9_posCharge384Reachable": "FAIL",
}

STATS_RE = r"\(paths: \d+, time: [0-9.]+s \(paths: [0-9.]+s, models: [0-9.]+s\)"
RESULT_RE = r"\[(PASS|FAIL|TIMEOUT|ERROR)\]\S*\s*"


def resolve_expect(check, expect):
    """Return the expectation for `check`, or raise ValueError (never guesses)."""
    known = EXPECTATIONS.get(check)
    if expect is None:
        if known is None:
            raise ValueError(f"unknown check {check!r}: --expect PASS|FAIL is required")
        return known
    if known is not None and known != expect:
        raise ValueError(f"--expect {expect} contradicts the declared expectation {known} for {check}")
    return expect


def judge(text, check, walled, expect="FAIL"):
    if expect not in ("PASS", "FAIL"):
        raise ValueError(f"expect must be PASS or FAIL, got {expect!r}")
    if walled:
        return "INCONCLUSIVE", 2, "wall cap hit before halmos reported a result"
    m = re.search(RESULT_RE + re.escape(check) + r"\(", text)
    if not m:
        return "INCONCLUSIVE", 2, "no result line for the check"
    if len(re.findall(RESULT_RE + r"\w+\(", text)) != 1:
        return "REJECT", 1, "more than one halmos result line (check selection was not exact)"
    res = m.group(1)
    if res == "TIMEOUT":
        return "INCONCLUSIVE", 2, "halmos reported [TIMEOUT] (a solver query hit the per-query timeout)"
    if res == "ERROR":
        return "REJECT", 1, "halmos reported [ERROR]"
    line = text[m.start():text.find("\n", m.start())]
    if expect == "FAIL":
        if res == "PASS":
            return "REJECT", 1, "check PASSED: the witness state was NOT reached (expected [FAIL])"
        if not re.search(STATS_RE, line):
            return "REJECT", 1, "[FAIL] line lacks the --statistics breakdown"
        if "Counterexample:" not in text:
            return "REJECT", 1, "[FAIL] without any Counterexample block"
        return "ACCEPT", 0, "expected [FAIL] with counterexample and statistics: " + line.strip()
    # expect == "PASS"
    if res == "FAIL":
        return "REJECT", 1, "check FAILED: counterexample to a PASS-expected property (expected [PASS])"
    if not re.search(STATS_RE, line):
        return "REJECT", 1, "[PASS] line lacks the --statistics breakdown"
    return "ACCEPT", 0, "expected [PASS] with statistics: " + line.strip()


class Cancelled(BaseException):
    """Raised from a signal handler; BaseException so no `except Exception` can swallow it."""

    def __init__(self, signame):
        super().__init__(signame)
        self.signame = signame


class _SignalState:
    """Deferred-raise signal handling.

    `armed` is False while the child is being spawned and while cleanup runs: a signal arriving
    then is only RECORDED (so it can neither orphan a just-forked child whose Popen object has not
    been assigned yet, nor abort a cleanup half-way). Once armed again the pending signal raises.
    The first signal wins; later ones (a second Ctrl-C) are recorded but never re-raise.
    """

    def __init__(self):
        self.armed = True
        self.pending = None
        self.raised = False

    def handler(self, signum, _frame):
        if self.pending is None:
            self.pending = signal.Signals(signum).name
        if self.armed and not self.raised:
            self.raised = True
            raise Cancelled(self.pending)

    def arm(self):
        self.armed = True
        if self.pending is not None and not self.raised:
            self.raised = True
            raise Cancelled(self.pending)


def _group_members(pgid):
    """Live (non-zombie) pids in group `pgid` via ps -- DIAGNOSTICS ONLY (None if ps fails).

    Not used to decide anything on the kill path: under heavy load (load avg ~200 measured
    2026-10-09) `ps -A` took > 30 s, so cleanup must not depend on it.
    """
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid=,pgid=,stat="], capture_output=True, text=True,
                             timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    live = []
    for row in out.splitlines():
        parts = row.split()
        if len(parts) >= 3 and parts[1] == str(pgid) and not parts[2].startswith("Z"):
            live.append(int(parts[0]))
    return live


def _signal_group(pgid, sig):
    """killpg that tolerates an already-empty group. Returns True if the signal was delivered.

    ESRCH: no member left at all. EPERM: on macOS killpg returns EPERM when the group holds
    only zombies (measured: zombie-only group -> PermissionError for sig 0 and SIGKILL). The
    runner and halmos run as the same uid, so EPERM cannot mean "a live member we may not
    signal" here.
    """
    try:
        os.killpg(pgid, sig)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def _wait_group_gone(pgid, seconds):
    deadline = time.monotonic() + seconds
    while _signal_group(pgid, 0) and time.monotonic() < deadline:
        time.sleep(0.1)


def terminate_group(pr, grace):
    """SIGTERM, then SIGKILL after `grace` s, THIS run's process group only; then reap the leader.

    Only ever targets pgid == pr.pid (the session/group the runner created for halmos with
    start_new_session=True); never killpg(0) and never any other group. The leader is reaped
    (pr.wait) only AFTER the group has been signalled: until then its pid -- hence the pgid --
    is still held by our unreaped child (alive or zombie) and cannot be recycled into an
    unrelated group, so the killpg calls cannot hit a stranger. Both signals are sent
    unconditionally (a no-op on an empty group), so a natural exit also sweeps any solver the
    leader left behind. Returns surviving live pids ([] = clean, None = could not check).
    """
    pgid = pr.pid
    _signal_group(pgid, signal.SIGTERM)
    _wait_group_gone(pgid, grace)
    _signal_group(pgid, signal.SIGKILL)
    _wait_group_gone(pgid, 5)
    try:
        pr.wait(timeout=10)
    except subprocess.TimeoutExpired:   # leader unkillable (D state); do not hang forever
        pass
    return _group_members(pgid)


def run(a):
    """Spawn halmos, enforce the wall cap, and ALWAYS clean up its group and write a trailer."""
    argv = [a.halmos_bin, "--contract", a.contract, "--match-test", "^" + re.escape(a.check) + r"\(",
            "--loop", "2",
            "--solver-timeout-assertion", a.solver_timeout_assertion, "--statistics"]
    env = dict(os.environ, PYTHONUNBUFFERED="1",
               PATH=os.path.expanduser("~/.foundry/bin") + ":" + os.path.expanduser("~/.local/bin")
               + ":" + os.environ.get("PATH", ""))

    st = _SignalState()
    t0 = time.monotonic()
    pr = None
    walled = False
    abort = None        # reason string when the run was cancelled / aborted
    survivors = []
    rc = None
    f = open(a.log, "w")
    try:
        try:
            # installed INSIDE the try, so a signal can never escape without a trailer
            for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                signal.signal(sig, st.handler)
            head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True,
                                  timeout=30).stdout.strip()
            try:
                ver = subprocess.run([a.halmos_bin, "--version"], capture_output=True, text=True,
                                     env=env, timeout=120).stdout.strip()
            except (OSError, subprocess.TimeoutExpired):
                ver = ""
            f.write(f"# run-i9-witness: head={head or '-'} halmos={ver or '-'} wall_cap_s={a.wall_cap}"
                    f" halmos_bin={a.halmos_bin} check={a.check} expect={a.expect}\n")
            f.write(f"# command: {' '.join(argv)}\n")
            f.flush()

            # EOF on this pipe == halmos has exited (its write end is passed to halmos only;
            # halmos' own solver Popens use close_fds=True so they do not hold it). Waiting on it
            # instead of pr.wait() lets us detect exit WITHOUT reaping the leader -- see
            # terminate_group() for why reaping must come last.
            rfd, wfd = os.pipe()
            st.armed = False          # a signal during spawn is deferred, never orphans the child
            try:
                # own session/process group so cleanup reaches halmos AND its solver children
                pr = subprocess.Popen(argv, stdout=f, stderr=subprocess.STDOUT, env=env,
                                      start_new_session=True, pass_fds=(wfd,))
            finally:
                os.close(wfd)
            st.arm()                  # raises Cancelled now if a signal arrived during spawn
            f.write(f"# pgid: {pr.pid}\n")
            f.flush()

            deadline = t0 + a.wall_cap
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    walled = True
                    break
                r, _, _ = select.select([rfd], [], [], min(left, 60))
                if r and os.read(rfd, 4096) == b"":
                    break             # EOF: halmos exited (not yet reaped)
            os.close(rfd)
        except Cancelled as c:
            abort = f"cancelled: {c.signame}"
        except BaseException as e:   # noqa: B902 -- any failure must still clean up + trail
            abort = f"aborted: {type(e).__name__}: {e}"
            f.write("\n# RUNNER EXCEPTION:\n" + traceback.format_exc())
        finally:
            st.armed = False          # no signal may interrupt cleanup from here on
            if pr is not None:
                try:
                    survivors = terminate_group(pr, a.kill_grace)
                except BaseException as e:   # noqa: B902 -- e.g. ps unavailable: fall back blind
                    abort = abort or f"aborted: cleanup {type(e).__name__}: {e}"
                    f.write(f"\n# CLEANUP-FALLBACK: {type(e).__name__}: {e}; blind SIGKILL of pgid {pr.pid}\n")
                    _signal_group(pr.pid, signal.SIGKILL)   # leader still unreaped: pgid is ours
                    try:
                        pr.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        pass
                rc = pr.returncode
        wall = int(time.monotonic() - t0)
        if walled:
            f.write(f"\n# WALL-CAP: process group killed after {a.wall_cap} s; INCONCLUSIVE, not PASS\n")
        if abort:
            f.write(f"\n# CANCELLED: {abort}; process group terminated; INCONCLUSIVE, not PASS\n")
        if survivors:
            f.write(f"# WARNING: pids still alive in pgid {pr.pid} after SIGKILL: {survivors}\n")
        elif survivors is None:
            f.write(f"# NOTE: survivor check (ps) unavailable; pgid {pr.pid} was sent SIGTERM+SIGKILL\n")
        f.write(f"\n# exit_code: {rc}  wall_seconds: {wall}\n")
        f.flush()
        if abort:
            verdict, code, why = "INCONCLUSIVE", 2, abort
        else:
            text = open(a.log, errors="replace").read()
            verdict, code, why = judge(text, a.check, walled, a.expect)
        f.write(f"# VERDICT: {verdict} ({why})\n")
    finally:
        f.close()
    try:
        print(f"# VERDICT: {verdict} ({why}); wall_seconds={wall}; log={a.log}", flush=True)
    except OSError:   # e.g. terminal gone after SIGHUP; the log trailer is already written
        pass
    return code


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
    ap.add_argument("--kill-grace", type=float, default=5.0,
                    help="seconds between SIGTERM and SIGKILL of the process group (default 5)")
    ap.add_argument("--halmos-bin", default="halmos",
                    help="halmos executable (TEST HOOK; recorded in the log header as halmos_bin=)")
    ap.add_argument("--expect", choices=("PASS", "FAIL"), default=None,
                    help="expected halmos outcome; defaults to EXPECTATIONS[check], required otherwise")
    ap.add_argument("--self-test", action="store_true", help="run judge() fixtures and exit")
    a = ap.parse_args()
    try:
        a.expect = resolve_expect(a.check, a.expect)
    except ValueError as e:
        # exit 3 (not argparse's 2, which would read as INCONCLUSIVE): a misdeclared target is a
        # configuration error, and no halmos run / log is produced at all
        print(f"run-i9-witness: error: {e}", file=sys.stderr)
        sys.exit(3)

    if not re.fullmatch(r"(0|[0-9.]+(ms|s|m|h))", a.solver_timeout_assertion):
        ap.error("--solver-timeout-assertion needs an explicit unit (ms|s|m|h), e.g. 300s")
    if a.wall_cap <= 0:
        ap.error("--wall-cap must be > 0 seconds")
    if a.kill_grace < 0:
        ap.error("--kill-grace must be >= 0 seconds")

    if not a.keep_cache and os.path.exists("cache/solidity-files-cache.json"):
        os.remove("cache/solidity-files-cache.json")
    sys.exit(run(a))


def self_test():
    c = DEFAULT_CHECK
    stat = "(paths: 478, time: 2881.59s (paths: 17.48s, models: 2864.11s), bounds: [])"
    p = "check_I9_CF3_settleCannotSilentlyFail"
    cases = [
        # (text, walled, check, expect, want) -- FAIL-expected witness
        (f"Counterexample: \n    p_x = 0x00\n[FAIL] {c}(address) {stat}\n", False, c, "FAIL", "ACCEPT"),
        (f"[FAIL] {c}(address) {stat}\n", False, c, "FAIL", "REJECT"),                         # no cex
        (f"Counterexample: \n[FAIL] {c}(address) (paths: 4, time: 1.00s, bounds: [])\n", False, c, "FAIL", "REJECT"),
        (f"[PASS] {c}(address) {stat}\n", False, c, "FAIL", "REJECT"),                         # reverse control
        (f"[TIMEOUT] {c}(address) {stat}\n", False, c, "FAIL", "INCONCLUSIVE"),
        ("Compiling...\n", False, c, "FAIL", "INCONCLUSIVE"),
        (f"Counterexample: \n[FAIL] {c}(address) {stat}\n", True, c, "FAIL", "INCONCLUSIVE"),   # walled wins
        (f"Counterexample: \n[FAIL] {c}_other(address) {stat}\n", False, c, "FAIL", "INCONCLUSIVE"),  # other check
        # PASS-expected property
        (f"[PASS] {p}(bool) {stat}\n", False, p, "PASS", "ACCEPT"),
        (f"Counterexample: \n    p_x = 0x00\n[FAIL] {p}(bool) {stat}\n", False, p, "PASS", "REJECT"),  # reverse control
        (f"[FAIL] {p}(bool) {stat}\n", False, p, "PASS", "REJECT"),
        (f"[PASS] {p}(bool) (paths: 4, time: 1.00s, bounds: [])\n", False, p, "PASS", "REJECT"),  # no stats
        (f"[TIMEOUT] {p}(bool) {stat}\n", False, p, "PASS", "INCONCLUSIVE"),                  # never PASS
        (f"[PASS] {p}(bool) {stat}\n", True, p, "PASS", "INCONCLUSIVE"),                      # walled wins
        (f"[ERROR] {p}(bool) {stat}\n", False, p, "PASS", "REJECT"),
        ("Compiling...\n", False, p, "PASS", "INCONCLUSIVE"),
        # selection not exact: a second result line (e.g. a prefix-matched sibling) -> REJECT
        (f"[PASS] {p}(bool) {stat}\n[PASS] {p}X(bool) {stat}\n", False, p, "PASS", "REJECT"),
    ]
    bad = 0
    for i, (text, walled, chk, exp, want) in enumerate(cases):
        got = judge(text, chk, walled, exp)[0]
        ok = got == want
        bad += not ok
        print(f"case {i}: want {want} got {got} {'ok' if ok else 'MISMATCH'}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    if "--self-test" in sys.argv[1:]:
        self_test()
    main()

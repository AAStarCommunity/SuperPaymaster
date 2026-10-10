#!/usr/bin/env python3
"""Integration tests for run-i9-witness.py cleanup + verdict paths, with REAL processes.

No mocks on the kill path: `--halmos-bin` points the runner at a fake halmos (written to a temp
dir) that spawns a child and a grandchild that sleep, so every test exercises the real
start_new_session / killpg / reap sequence. After every scenario the test asserts that no pid
of the runner's process group survives, plus the log trailer and the runner's exit code.

Positive controls: before any signal is sent, each scenario first asserts that all three fake
pids (leader, child, grandchild) are alive AND share one pgid distinct from the test's own --
otherwise "nothing survived" could just mean "nothing was ever started".

Run (repo root):  python3 script/halmos/test_run_i9_witness.py
"""
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
# I9W_RUNNER: point the suite at a mutated copy (mutation checks); default is the real runner
RUNNER = os.environ.get("I9W_RUNNER") or os.path.join(HERE, "run-i9-witness.py")
CHECK = "check_witness_I9_freshBalanceSettlementReachable"
STAT = "(paths: 478, time: 2881.59s (paths: 17.48s, models: 2864.11s), bounds: [])"

FAKE_HALMOS = textwrap.dedent(f"""\
    #!{sys.executable}
    # Fake halmos for run-i9-witness tests. Mode from FAKE_MODE:
    #   hang       leader + child + grandchild all sleep (default SIGTERM disposition)
    #   stubborn   same, but all three IGNORE SIGTERM (forces the SIGKILL escalation)
    #   fail       print a counterexample + [FAIL] line with statistics, leave a sleeping
    #              grandchild behind, exit 1
    #   pass       print a [PASS] line, leave a sleeping grandchild behind, exit 0
    import os, signal, subprocess, sys, time
    if "--version" in sys.argv:
        print("halmos 0.0.0-fake"); sys.exit(0)
    mode = os.environ["FAKE_MODE"]
    pidfile = os.environ["FAKE_PIDFILE"]
    if mode == "stubborn":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)   # inherited as SIG_IGN through exec
    # child = a python that itself spawns the grandchild (`sleep`), like halmos -> solver
    child = subprocess.Popen([sys.executable, "-c",
        "import subprocess,sys; g=subprocess.Popen(['sleep','300']);"
        "open(sys.argv[1],'w').write(str(g.pid)); g.wait()", pidfile + ".g"])
    for _ in range(200):
        if os.path.exists(pidfile + ".g") and open(pidfile + ".g").read():
            break
        time.sleep(0.02)
    gpid = open(pidfile + ".g").read()
    with open(pidfile + ".tmp", "w") as fh:
        fh.write(f"{{os.getpid()}} {{child.pid}} {{gpid}}")
    os.rename(pidfile + ".tmp", pidfile)
    if mode in ("hang", "stubborn"):
        print("Compiling...", flush=True)
        time.sleep(300)
    elif mode == "fail":
        print("Counterexample: \\n    p_x = 0x00", flush=True)
        print("[FAIL] {CHECK}(address) {STAT}", flush=True)
        sys.exit(1)
    elif mode == "pass":
        print("[PASS] {CHECK}(address) {STAT}", flush=True)
        sys.exit(0)
""")


def read(path):
    with open(path) as fh:
        return fh.read()


def alive(pid):
    """True if pid exists and is not a zombie."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    st = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(st) and not st.startswith("Z")


def group_live(pgid):
    out = subprocess.run(["ps", "-A", "-o", "pid=,pgid=,stat="], capture_output=True, text=True).stdout
    return [int(p[0]) for p in (r.split() for r in out.splitlines())
            if len(p) >= 3 and p[1] == str(pgid) and not p[2].startswith("Z")]


class RunnerIntegration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="i9w-test-")
        self.fake = os.path.join(self.tmp, "halmos")
        with open(self.fake, "w") as fh:
            fh.write(FAKE_HALMOS)
        os.chmod(self.fake, 0o755)
        self.pidfile = os.path.join(self.tmp, "pids")
        self.log = os.path.join(self.tmp, "run.log")
        self.pids = []

    def tearDown(self):
        # never leave anything behind even if an assertion failed mid-test
        # (only pids still in the fake leader's group, so a recycled pid is never hit)
        for pid in self.pids:
            try:
                if os.getpgid(pid) == self.pids[0]:
                    os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    def start(self, mode, wall_cap=60, grace=1):
        env = dict(os.environ, FAKE_MODE=mode, FAKE_PIDFILE=self.pidfile)
        return subprocess.Popen(
            [sys.executable, RUNNER, "--wall-cap", str(wall_cap), "--log", self.log, "--keep-cache",
             "--kill-grace", str(grace), "--halmos-bin", self.fake],
            cwd=self.tmp, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def wait_pids(self):
        for _ in range(500):
            if os.path.exists(self.pidfile):
                self.pids = [int(x) for x in read(self.pidfile).split()]
                return self.pids
            time.sleep(0.02)
        self.fail("fake halmos never wrote its pid file")

    def control_alive(self, runner):
        """Positive control: three live pids in ONE group, which is not the runner's/ours."""
        leader, child, grand = self.wait_pids()
        for p in (leader, child, grand):
            self.assertTrue(alive(p), f"setup: pid {p} not alive")
        pg = {os.getpgid(p) for p in (leader, child, grand)}
        self.assertEqual(pg, {leader}, "setup: child/grandchild not in the leader's group")
        self.assertNotEqual(leader, os.getpgid(runner.pid))
        self.assertNotEqual(leader, os.getpgid(0))
        self.assertEqual(sorted(group_live(leader)), sorted(self.pids))
        return leader

    def assert_clean(self, pgid):
        deadline = time.monotonic() + 3      # orphans reparented to init/launchd: allow reaping
        while time.monotonic() < deadline and (group_live(pgid) or any(alive(p) for p in self.pids)):
            time.sleep(0.05)
        self.assertEqual(group_live(pgid), [], f"survivors in pgid {pgid}")
        for p in self.pids:
            self.assertFalse(alive(p), f"pid {p} survived")

    def finish(self, runner, timeout=30):
        out, _ = runner.communicate(timeout=timeout)
        trailer = read(self.log).rstrip("\n").splitlines()[-1]
        return runner.returncode, trailer, out

    def _signal_case(self, sig, mode="hang"):
        r = self.start(mode)
        pgid = self.control_alive(r)
        os.kill(r.pid, sig)
        rc, trailer, out = self.finish(r)
        name = signal.Signals(sig).name
        self.assertEqual(rc, 2, out)
        self.assertEqual(trailer, f"# VERDICT: INCONCLUSIVE (cancelled: {name})")
        self.assertIn(f"# CANCELLED: cancelled: {name}", read(self.log))
        self.assert_clean(pgid)

    def test_sigint(self):
        self._signal_case(signal.SIGINT)

    def test_sigterm(self):
        self._signal_case(signal.SIGTERM)

    def test_sighup(self):
        self._signal_case(signal.SIGHUP)

    def test_sigint_stubborn_group_needs_sigkill(self):
        # every member ignores SIGTERM: only the SIGKILL escalation can clean this up
        self._signal_case(signal.SIGINT, mode="stubborn")

    def test_double_sigint_does_not_abort_cleanup(self):
        r = self.start("stubborn", grace=2)
        pgid = self.control_alive(r)
        os.kill(r.pid, signal.SIGINT)
        time.sleep(0.5)                      # second Ctrl-C lands inside the SIGTERM grace window
        os.kill(r.pid, signal.SIGINT)
        rc, trailer, out = self.finish(r)
        self.assertEqual(rc, 2, out)
        self.assertEqual(trailer, "# VERDICT: INCONCLUSIVE (cancelled: SIGINT)")
        # the 2nd signal must be absorbed, not raise into terminate_group (which would only be
        # rescued by the blind fallback)
        self.assertNotIn("CLEANUP-FALLBACK", read(self.log))
        self.assert_clean(pgid)

    def test_wall_cap(self):
        r = self.start("hang", wall_cap=2)
        pgid = self.control_alive(r)
        rc, trailer, out = self.finish(r)
        self.assertEqual(rc, 2, out)
        self.assertEqual(trailer, "# VERDICT: INCONCLUSIVE (wall cap hit before halmos reported a result)")
        self.assertIn("# WALL-CAP:", read(self.log))
        self.assert_clean(pgid)

    def test_natural_fail_is_accept_and_leftover_grandchild_killed(self):
        r = self.start("fail")
        leader, child, grand = self.wait_pids()   # leader exits right away: no live control here
        rc, trailer, out = self.finish(r)
        self.assertEqual(rc, 0, out)
        self.assertTrue(trailer.startswith(f"# VERDICT: ACCEPT (expected [FAIL] with counterexample "
                                           f"and statistics: [FAIL] {CHECK}(address)"), trailer)
        self.assertIn("# exit_code: 1 ", read(self.log))
        self.assert_clean(leader)

    def test_natural_pass_is_reject(self):
        r = self.start("pass")
        leader, _, _ = self.wait_pids()
        rc, trailer, out = self.finish(r)
        self.assertEqual(rc, 1, out)
        self.assertEqual(trailer, "# VERDICT: REJECT (check PASSED: the witness state was NOT reached "
                                  "(expected [FAIL]))")
        self.assert_clean(leader)

    def test_spawn_exception_is_inconclusive(self):
        # real exception path: the halmos binary does not exist -> Popen raises FileNotFoundError
        r = subprocess.Popen([sys.executable, RUNNER, "--wall-cap", "10", "--log", self.log, "--keep-cache",
                              "--halmos-bin", os.path.join(self.tmp, "no-such-halmos")],
                             cwd=self.tmp, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        rc, trailer, out = self.finish(r)
        self.assertEqual(rc, 2, out)
        self.assertTrue(trailer.startswith("# VERDICT: INCONCLUSIVE (aborted: FileNotFoundError"), trailer)

    def test_judge_fixtures(self):
        p = subprocess.run([sys.executable, RUNNER, "--self-test"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertEqual(p.stdout.count(" ok"), 8, p.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)

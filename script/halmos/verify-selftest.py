#!/usr/bin/env python3
"""D5c-1 — negative / positive controls for the verdict authority (verify-d5c1.py) and the
orchestrator entry point (run-step-d5c1.sh verify).

Each control builds a small FAKE tree (its own git repo with a source set, a harness file and out/
artifacts whose ABI defines the partition set) plus a fake evidence root whose logs carry real
`# binding:` trailers computed by d5c1_binding.py on that fake tree, perturbs ONE thing, and checks
the exit code:

  P1  all expectations met                                      -> 0
  N1  a PASS-expected partition FAILs                           -> != 0
  N2  a witness (expect FAIL) PASSes (vacuous harness)          -> != 0
  N3  a witness FAILs but WITHOUT a counterexample              -> != 0
  N4  a TIMEOUT partition not on the allow-list                 -> != 0
  P2  the same TIMEOUT partition on the allow-list              -> 0
  N5  a partition log with no result line (aborted run)         -> != 0
  N6  a mutation that stays green (Halmos PASS, scenario PASS)  -> != 0
  N7  a mutation whose source was not restored (sha differs)    -> != 0
  N8  a fuzz liveness mutation that stays green                 -> != 0
  N9  the unmutated fuzz run is not green                       -> != 0
  N10 a partition missing (one expected log absent)             -> != 0
  N11 an extra partition (a log for a label not in the ABI)     -> != 0
  N12 source-hash mismatch (the source changed after the run)   -> != 0
  N13 dirty_src != 0 in a normal run's binding                  -> != 0
  N14 bytecode-hash mismatch (out/ rebuilt differently)         -> != 0
  N15 allow_bounded entry for a partition that does not exist   -> != 0
  N16 a log without a binding trailer (unbound)                 -> != 0
  N17 a leftover .retry.log (two logs for one partition)        -> != 0
  N18 a mutation log bound to the PRISTINE tree (not mutated)   -> != 0
  N19 an unpartitioned log with an extra check result           -> != 0
  N20 out/ is not the build of the sources (metadata keccak256 differs; everything else consistent) -> != 0
  N21 header and trailer bindings of one log disagree (source changed during the run) -> != 0
  N22 allow_bounded on a FAIL expectation (a witness may not be "bounded") -> != 0
  N23 a result line printed AFTER the wall cap (halmos total >= cap, killed) -> counts as TIMEOUT-WALL -> != 0
  P4  a result printed inside the cap, process killed only during shutdown -> the result counts -> 0
  O1  run-step-d5c1.sh verify propagates a mismatch             -> != 0
  O2  run-step-d5c1.sh verify on a clean fake tree              -> 0
  P3  the REAL evidence under docs/design/aoa-balance-mode/data/halmos against the real tree -> 0
      (skipped with --no-real)

usage (repo root): python3 script/halmos/verify-selftest.py [--no-real]   (exit 0 iff every control behaves)
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
V = [sys.executable, os.path.join(HERE, "verify-d5c1.py")]
BIND = [sys.executable, os.path.join(HERE, "d5c1_binding.py")]
H64 = lambda c: c * 64  # noqa: E731
FAILS = []
TMP = tempfile.mkdtemp(prefix="d5c1-selftest-")


def sh(cmd, cwd, **kw):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, **kw)


def git(tree, *a):
    r = sh(["git", "-c", "user.name=selftest", "-c", "user.email=selftest@invalid", *a], tree)
    assert r.returncode == 0, r.stderr


sys.path.insert(0, HERE)
import d5c1_binding as B  # noqa: E402

SRC_OF = {"xPNTsTokenV2": "contracts/src/tokens/v2/X.sol", "xPNTsTokenV2Ext": "contracts/src/tokens/v2/X.sol",
          "APNTsCapped": "contracts/src/tokens/APNTsCapped.sol"}


def artifact(tree, name, fns, code, stale=False):
    """fns: [(name, selector_hex8, mutability)]. The metadata records the keccak256 of the source as it
    is NOW in `tree` (stale=True records a wrong one: out/ not rebuilt after a source change)."""
    d = os.path.join(tree, "out", f"{name}.sol")
    os.makedirs(d, exist_ok=True)
    src = SRC_OF[name]
    k = "0x" + ("0" * 64 if stale else B._keccak(open(os.path.join(tree, src), "rb").read()))
    json.dump({"abi": [{"type": "function", "name": n, "inputs": [], "outputs": [], "stateMutability": m} for n, _, m in fns],
               "methodIdentifiers": {f"{n}()": s for n, s, _ in fns},
               "metadata": {"sources": {src: {"keccak256": k}}},
               "deployedBytecode": {"object": code}}, open(os.path.join(d, f"{name}.json"), "w"))


CORE_FNS = [("foo", "00000001", "nonpayable"), ("bar", "00000002", "nonpayable"), ("v", "00000003", "view")]


def artifacts(t, core_code="0x6001", stale=False):
    artifact(t, "xPNTsTokenV2", CORE_FNS, core_code, stale)
    artifact(t, "xPNTsTokenV2Ext", [("foo", "00000001", "nonpayable")], "0x6002", stale)
    artifact(t, "APNTsCapped", [("mint", "40c10f19", "nonpayable")], "0x6003", stale)


def write(p, s):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(s)


def mk_tree(t, stale=False):
    write(os.path.join(t, "contracts/src/tokens/v2/X.sol"), "contract X {\n    uint256 a;\n    function foo() external { a = 1; }\n}\n")
    write(os.path.join(t, "contracts/src/tokens/APNTsCapped.sol"), "contract A {}\n")
    write(os.path.join(t, "contracts/src/Unrelated.sol"), "contract U {}\n")
    write(os.path.join(t, "contracts/test/halmos/H.t.sol"), "contract H {}\n")
    artifacts(t, stale=stale)
    git(t, "init", "-q")
    git(t, "add", "-A")
    git(t, "commit", "-q", "-m", "fake")


def bline(tree):
    return sh(BIND + ["xpnts", "--line"], tree).stdout.strip() + "\n"


def res(kind, check, cex=False):
    c = "Counterexample: \n    p_x = 0x01\n" if cex else ""
    if kind == "ABORT":
        return "# halmos started\n"
    return f"{c}[{kind}] {check}() (paths: 3, time: 0.1s, bounds: [])\n# exit_code: {0 if kind == 'PASS' else 1}  wall_seconds: 1\n"


DIFF = """--- a/contracts/src/tokens/v2/X.sol
+++ b/contracts/src/tokens/v2/X.sol
@@ -1,4 +1,4 @@
 contract X {
     uint256 a;
-    function foo() external { a = 1; }
+    function foo() external { a = 2; }
 }
"""


def mk_evidence(t, r):
    """t: fake tree, r: fake evidence root. Returns the mutated-tree binding line."""
    b = bline(t)
    for lab in ("OTHER", "foo-00000001", "bar-00000002"):
        write(os.path.join(r, f"C.check_P/check_P.{lab}.log"), res("PASS", "check_P") + b)
    write(os.path.join(r, "W.check_W/check_W.OTHER.log"), res("FAIL", "check_W", True) + b)
    write(os.path.join(r, "u.log"), res("PASS", "check_U") + b)
    # mutated copy of the fake tree: diff applied, different bytecode
    m = os.path.join(TMP, "mut-" + os.path.basename(r))
    shutil.copytree(t, m)
    shutil.rmtree(os.path.join(m, ".git"))
    assert sh(["patch", "-s", "-p1", "-i", "-"], m, input=DIFF).returncode == 0
    artifacts(m, core_code="0x6009")
    mb = bline(m)
    pristine = sh(["shasum", "-a", "256", "contracts/src/tokens/v2/X.sol"], t).stdout.split()[0]
    md = os.path.join(r, "mutations/M-X")
    write(os.path.join(md, "C.check_P/check_P.foo-00000001.log"), res("FAIL", "check_P", True) + mb)
    write(os.path.join(md, "apply.txt"), f"applied M-X to contracts/src/tokens/v2/X.sol (pristine sha256 {pristine}; diff in x)\n")
    write(os.path.join(md, "summary.txt"), f"reverted M-X: contracts/src/tokens/v2/X.sol sha256 {pristine}\n")
    write(os.path.join(md, "scenario.log"), "[FAIL: bitmask: 1 != 0] test_scen() (gas: 1)\n" + mb)
    write(os.path.join(md, "M-X.diff"), DIFF)
    write(os.path.join(md, "binding-mutated.json"), sh(BIND + ["xpnts"], m).stdout)
    write(os.path.join(md, "binding-restored.json"), sh(BIND + ["xpnts"], t).stdout)
    f = os.path.join(r, "fuzz-liveness")
    write(os.path.join(r, "unmutated.log"), "[PASS] testFuzz_t(uint256) (runs: 10000, μ: 1, ~: 1)\n" + b)
    write(os.path.join(f, "M-Y.apply.txt"), f"applied M-Y to contracts/src/tokens/v2/X.sol (pristine sha256 {pristine}; diff in x)\n")
    write(os.path.join(f, "M-Y.fuzz.log"), "[FAIL: red; counterexample: calldata=0x args=[1]] testFuzz_t(uint256) (runs: 3)\n"
          + mb + f"reverted M-Y: contracts/src/tokens/v2/X.sol sha256 {pristine}\n")
    write(os.path.join(f, "M-Y.diff"), DIFF)
    write(os.path.join(f, "M-Y.restored.json"), sh(BIND + ["xpnts"], t).stdout)
    return b, mb


EXPECT = {"logs": [{"log": "u.log", "check": "check_U", "expect": "PASS", "family": "xpnts"}],
          "partitioned": [
              {"dir": "C.check_P", "abi": "core", "expect": "PASS",
               "allow_bounded": {"bar-00000002": {"reason": "r", "substitute": "s"}}},
              {"dir": "W.check_W", "abi": "core", "parts": ["OTHER"], "expect": "FAIL"}],
          "mutations": [{"id": "M-X", "family": "xpnts", "halmos_logs": [],
                         "halmos_parts": [{"dir": "C.check_P", "labels": ["foo-00000001"]}],
                         "scenario_test": "test_scen", "scenario_msg": "1 != 0"}],
          "fuzz_liveness": {"unmutated_log": "unmutated.log", "unmutated_tests": ["testFuzz_t"],
                            "mutations": [{"id": "M-Y", "must_fail": ["testFuzz_t"]}]}}

n = [0]


def fresh(expect=None, stale=False):
    n[0] += 1
    t, r = os.path.join(TMP, f"t{n[0]}"), os.path.join(TMP, f"r{n[0]}")
    mk_tree(t, stale)
    b, mb = mk_evidence(t, r)
    e = os.path.join(TMP, f"e{n[0]}.json")
    json.dump(expect or EXPECT, open(e, "w"))
    return t, r, e, b, mb


def expect(name, want_zero, t, r, e, orchestrator=False, why=None):
    """A negative control must fail FOR ITS REASON: `why` (regex) must match one of the MISMATCH rows;
    a non-zero exit caused by some other row does not count."""
    if orchestrator:
        env = dict(os.environ, D5C1_ROOT=r, D5C1_EXPECT=e, D5C1_TREE_ROOT=t)
        p = subprocess.run([os.path.join(HERE, "run-step-d5c1.sh"), "verify"], cwd=REPO, env=env, capture_output=True, text=True)
    else:
        p = subprocess.run(V + ["--root", r, "--expect", e, "--tree", t], cwd=REPO, capture_output=True, text=True)
    mism = [l for l in p.stdout.splitlines() if "MISMATCH" in l and not l.startswith("VERDICT")]
    hit = [l for l in mism if why and re.search(why, l)]
    ok = (p.returncode == 0) == want_zero and (want_zero or bool(hit))
    print(f"{'ok  ' if ok else 'FAIL'}  {name} (rc={p.returncode}, wanted {'0' if want_zero else '!=0'}"
          + (f", {len(mism)} mismatch row(s), reason matched: {bool(hit)}" if not want_zero else "") + ")")
    if hit:
        print("      " + re.sub(r"\s+", " ", hit[0])[:170])
    if not ok or name.startswith("P3"):
        tail = [l for l in p.stdout.splitlines() if "MISMATCH" in l or "VERDICT" in l][:8]
        print("      " + "\n      ".join(tail))
    if not ok:
        FAILS.append(name)


def main():
    t, r, e, b, mb = fresh(); expect("P1_all_met", True, t, r, e)
    t, r, e, b, mb = fresh(); write(f"{r}/C.check_P/check_P.foo-00000001.log", res("FAIL", "check_P", True) + b)
    expect("N1_pass_check_fails", False, t, r, e, why=r"FAIL foo-00000001")
    t, r, e, b, mb = fresh(); write(f"{r}/W.check_W/check_W.OTHER.log", res("PASS", "check_W") + b)
    expect("N2_witness_passes", False, t, r, e, why=r"no counterexample")
    t, r, e, b, mb = fresh(); write(f"{r}/W.check_W/check_W.OTHER.log", res("FAIL", "check_W") + b)
    expect("N3_witness_no_cex", False, t, r, e, why=r"no counterexample")
    t, r, e, b, mb = fresh(); write(f"{r}/C.check_P/check_P.foo-00000001.log", res("TIMEOUT", "check_P") + b)
    expect("N4_timeout_not_allowed", False, t, r, e, why=r"BOUNDED foo-00000001")
    t, r, e, b, mb = fresh(); write(f"{r}/C.check_P/check_P.bar-00000002.log", res("TIMEOUT", "check_P") + b)
    expect("P2_timeout_allowed", True, t, r, e)
    t, r, e, b, mb = fresh(); write(f"{r}/C.check_P/check_P.foo-00000001.log", res("ABORT", "check_P") + b)
    expect("N5_aborted_part", False, t, r, e, why=r"ABORTED/ERROR foo-00000001")
    t, r, e, b, mb = fresh(); write(f"{r}/mutations/M-X/C.check_P/check_P.foo-00000001.log", res("PASS", "check_P") + mb)
    write(f"{r}/mutations/M-X/scenario.log", "[PASS] test_scen() (gas: 1)\n" + mb)
    expect("N6_mutation_survives", False, t, r, e, why=r"scenario test_scen.*green / missing")
    t, r, e, b, mb = fresh(); write(f"{r}/mutations/M-X/summary.txt", f"reverted M-X: contracts/src/tokens/v2/X.sol sha256 {H64('c')}\n")
    expect("N7_not_restored", False, t, r, e, why=r"M-X source restored")
    t, r, e, b, mb = fresh()
    lt = open(f"{r}/fuzz-liveness/M-Y.fuzz.log").read().replace("[FAIL: red; counterexample: calldata=0x args=[1]]", "[PASS]")
    write(f"{r}/fuzz-liveness/M-Y.fuzz.log", lt)
    expect("N8_fuzz_mutation_survives", False, t, r, e, why=r"M-Y reddens testFuzz_t.*green")
    t, r, e, b, mb = fresh(); write(f"{r}/unmutated.log", "[FAIL: x] testFuzz_t(uint256) (runs: 3)\n" + b)
    expect("N9_unmutated_fuzz_red", False, t, r, e, why=r"unmutated testFuzz_t.*not green")
    t, r, e, b, mb = fresh(); os.remove(f"{r}/C.check_P/check_P.bar-00000002.log")
    expect("N10_missing_partition", False, t, r, e, why=r"missing \['bar-00000002'\]")
    t, r, e, b, mb = fresh(); write(f"{r}/C.check_P/check_P.baz-00000009.log", res("PASS", "check_P") + b)
    expect("N11_extra_partition", False, t, r, e, why=r"extra \['baz-00000009'\]")
    t, r, e, b, mb = fresh()   # a committed source change after the evidence was produced
    with open(f"{t}/contracts/src/tokens/v2/X.sol", "a") as f:
        f.write("// changed after the run\n")
    git(t, "commit", "-q", "-am", "src change")
    artifacts(t)   # out/ rebuilt from the changed source, same bytecode: ONLY the source hash differs
    expect("N12_source_hash_mismatch", False, t, r, e, why=r"STALE \(src_sha differ.*X\.sol")
    t, r, e, b, mb = fresh()   # a log produced while contracts/src had an uncommitted change OUTSIDE the source set
    with open(f"{t}/contracts/src/Unrelated.sol", "a") as f:
        f.write("// dirty\n")
    dirty_b = bline(t)
    git(t, "checkout", "--", "contracts/src/Unrelated.sol")
    assert '"dirty_src": 1' in dirty_b and json.loads(dirty_b[len("# binding: "):])["src_sha"] == json.loads(b[len("# binding: "):])["src_sha"]
    write(f"{r}/C.check_P/check_P.OTHER.log", res("PASS", "check_P") + dirty_b)
    expect("N13_dirty_src", False, t, r, e, why=r"DIRTY \(dirty_src=1\)")
    t, r, e, b, mb = fresh()
    artifacts(t, core_code="0x60ff")
    expect("N14_bytecode_hash_mismatch", False, t, r, e, why=r"STALE \(bytecode_sha")
    ex = json.loads(json.dumps(EXPECT)); ex["partitioned"][0]["allow_bounded"]["zzz-000000ff"] = {"reason": "r", "substitute": "s"}
    t, r, e, b, mb = fresh(ex)
    expect("N15_allow_bounded_ghost", False, t, r, e, why=r"not an expected partition: \['zzz-000000ff'\]")
    t, r, e, b, mb = fresh(); write(f"{r}/C.check_P/check_P.OTHER.log", res("PASS", "check_P"))
    expect("N16_unbound_log", False, t, r, e, why=r"UNBOUND")
    t, r, e, b, mb = fresh(); write(f"{r}/C.check_P/check_P.foo-00000001.retry.log", res("PASS", "check_P") + b)
    expect("N17_leftover_retry_log", False, t, r, e, why=r"retry\.log")
    t, r, e, b, mb = fresh(); write(f"{r}/mutations/M-X/C.check_P/check_P.foo-00000001.log", res("FAIL", "check_P", True) + b)
    expect("N18_mutation_log_bound_to_pristine", False, t, r, e, why=r"src_sha != current src \+ diff")
    t, r, e, b, mb = fresh(); write(f"{r}/u.log", res("PASS", "check_U") + res("PASS", "check_Extra") + b)
    expect("N19_unpartitioned_extra_check", False, t, r, e, why=r"extra \['check_Extra'\]")
    t, r, e, b, mb = fresh(stale=True)   # every log consistently bound to a build whose metadata disagrees with the source
    expect("N20_out_not_built_from_sources", False, t, r, e, why=r"out/ \[xpnts\].*stale")
    t, r, e, b, mb = fresh()
    hb = json.loads(b[len("# binding: "):]); hb["src_sha"] = H64("d")
    write(f"{r}/C.check_P/check_P.OTHER.log", "# binding: " + json.dumps(hb) + "\n" + res("PASS", "check_P") + b)
    expect("N21_header_trailer_drift", False, t, r, e, why=r"DRIFT")
    ex = json.loads(json.dumps(EXPECT)); ex["partitioned"][1]["allow_bounded"] = {"OTHER": {"reason": "r", "substitute": "s"}}
    t, r, e, b, mb = fresh(ex)
    expect("N22_allow_bounded_on_fail_expectation", False, t, r, e, why=r"allow_bounded is not permitted")
    def walled(total):
        return ("[PASS] check_P() (paths: 3, time: 1.0s, bounds: [])\nSymbolic test result: 1 passed; 0 failed\n"
                f"[time] total: {total}s (build: 1s)\n\n# WALL-CAP: killed after 600 s (per-partition cap)\n"
                "\n# exit_code: -9  wall_seconds: 601\n")
    t, r, e, b, mb = fresh(); write(f"{r}/C.check_P/check_P.foo-00000001.log", walled("612.40") + b)
    expect("N23_result_after_wall_cap", False, t, r, e, why=r"BOUNDED foo-00000001")
    t, r, e, b, mb = fresh(); write(f"{r}/C.check_P/check_P.foo-00000001.log", walled("577.56") + b)
    expect("P4_result_inside_cap_teardown_killed", True, t, r, e)
    t, r, e, b, mb = fresh(); write(f"{r}/C.check_P/check_P.OTHER.log", res("FAIL", "check_P", True) + b)
    expect("O1_orchestrator_propagates", False, t, r, e, orchestrator=True, why=r"FAIL OTHER")
    t, r, e, b, mb = fresh(); expect("O2_orchestrator_clean", True, t, r, e, orchestrator=True)
    if "--no-real" not in sys.argv:
        p = subprocess.run(V, cwd=REPO, capture_output=True, text=True)
        ok = p.returncode == 0
        print(f"{'ok  ' if ok else 'FAIL'}  P3_real_evidence (rc={p.returncode}, wanted 0)")
        print("      " + "\n      ".join(l for l in p.stdout.splitlines() if l.startswith(("expectations:", "current tree", "VERDICT"))))
        if not ok:
            print("      " + "\n      ".join([l for l in p.stdout.splitlines() if "MISMATCH" in l][:10]))
            FAILS.append("P3_real_evidence")
    shutil.rmtree(TMP, ignore_errors=True)
    total = n[0] + (0 if "--no-real" in sys.argv else 1)
    print()
    if not FAILS:
        print(f"SELFTEST: all {total} controls behave"); sys.exit(0)
    print(f"SELFTEST: {len(FAILS)} of {total} control(s) misbehave: {FAILS}"); sys.exit(1)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""D5c-1 — negative / positive controls for the verdict authority (verify-d5c1.py) and the
orchestrator entry point (run-step-d5c1.sh verify).

Each control builds a small FAKE tree (its own git repo with a source set, harness artifacts and out/
artifacts whose ABI defines the partition set) plus a fake evidence root whose logs carry real
`# meta:` headers and `# binding:` lines computed by d5c1_binding.py on that fake tree, and a fake
mandatory suite (passed to verify through D5C1_REQUIRED), perturbs ONE thing, and checks the exit
code. A negative control must fail FOR ITS OWN REASON: a regex must match one of the MISMATCH rows
(a non-zero exit caused by some other row does not count). The list is printed as the controls run;
the first output line records the sha256 of the scripts under test (`# scripts: {...}`), which
verify-d5c1.py compares with the current scripts when it checks this log as an archive.

usage (repo root): python3 script/halmos/verify-selftest.py [--no-real]   (exit 0 iff every control behaves)
  P3 runs the REAL evidence against the real tree (every item kind except the archives, because this
  very log is one of them); skipped with --no-real.
"""
import hashlib
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
SCRIPTS = ("verify-d5c1.py", "verify-selftest.py", "d5c1_binding.py")

sys.path.insert(0, HERE)
import d5c1_binding as B  # noqa: E402


def sh(cmd, cwd, **kw):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, **kw)


def git(tree, *a):
    r = sh(["git", "-c", "user.name=selftest", "-c", "user.email=selftest@invalid", *a], tree)
    assert r.returncode == 0, r.stderr


SRC_OF = {"xPNTsTokenV2": "contracts/src/tokens/v2/X.sol", "xPNTsTokenV2Ext": "contracts/src/tokens/v2/X.sol",
          "APNTsCapped": "contracts/src/tokens/APNTsCapped.sol"}
HDIR = "XPNTsV2Halmos.t.sol"          # one of d5c1_binding.HARNESS_ARTIFACT_DIRS
HARNESS = ["C", "D", "W", "U", "Q"]   # fake harness contracts


def write(p, s):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(s)


def artifact(tree, name, fns, code, stale=False):
    """fns: [(name, selector_hex8, mutability)]. The metadata records the keccak256 of the source as it
    is NOW in `tree` (stale=True records a wrong one: out/ not rebuilt after a source change)."""
    src = SRC_OF[name]
    k = "0x" + ("0" * 64 if stale else B._keccak(open(os.path.join(tree, src), "rb").read()))
    write(os.path.join(tree, "out", f"{name}.sol", f"{name}.json"), json.dumps(
        {"abi": [{"type": "function", "name": n, "inputs": [], "outputs": [], "stateMutability": m} for n, _, m in fns],
         "methodIdentifiers": {f"{n}()": s for n, s, _ in fns},
         "metadata": {"sources": {src: {"keccak256": k}}},
         "deployedBytecode": {"object": code}, "bytecode": {"object": code}}))


CORE_FNS = [("foo", "00000001", "nonpayable"), ("bar", "00000002", "nonpayable"), ("v", "00000003", "view")]
SEL = {"OTHER": 1, "foo-00000001": 1, "bar-00000002": 2}


def artifacts(t, core_code="0x6001", stale=False, harness_code="0x60aa"):
    artifact(t, "xPNTsTokenV2", CORE_FNS, core_code, stale)
    artifact(t, "xPNTsTokenV2Ext", [("foo", "00000001", "nonpayable")], "0x6002", stale)
    artifact(t, "APNTsCapped", [("mint", "40c10f19", "nonpayable")], "0x6003", stale)
    for c in HARNESS:
        write(os.path.join(t, "out", HDIR, f"{c}.json"), json.dumps(
            {"bytecode": {"object": harness_code + c.encode().hex()}, "metadata": {"sources": {}}}))


def mk_tree(t, stale=False):
    write(os.path.join(t, "contracts/src/tokens/v2/X.sol"), "contract X {\n    uint256 a;\n    function foo() external { a = 1; }\n}\n")
    write(os.path.join(t, "contracts/src/tokens/APNTsCapped.sol"), "contract A {}\n")
    write(os.path.join(t, "contracts/src/Unrelated.sol"), "contract U {}\n")
    write(os.path.join(t, "contracts/test/halmos/H.t.sol"), "contract H {}\n")
    artifacts(t, stale=stale)
    git(t, "init", "-q")
    git(t, "add", "-A")
    git(t, "commit", "-q", "-m", "fake")


def bline(tree, contract=None, alla=False):
    return sh(BIND + ["xpnts", "--line"] + (["--contract", contract] if contract else []) +
              (["--all-artifacts"] if alla else []), tree).stdout.strip() + "\n"


def meta(**kw):
    return B.meta_line(**kw) + "\n"


def pmeta(contract, check, label, profile, abi="core", sel=None, wall=None):
    return meta(runner="run-partitioned", contract=contract, check=check, abi=abi, label=label,
                part=SEL[label] if sel is None else sel, argv=B.halmos_argv(contract, profile, function=check),
                profile=profile, wall_cap_s=B.WALL_CAP_S if wall is None else wall)


def body(contract, kind, check, cex=False, bounds="", exitc=None, ran=None):
    if kind == "ABORT":
        return f"Running 1 tests for contracts/test/halmos/H.t.sol:{ran or contract}\n# halmos started\n"
    c = "Counterexample: \n    p_x = 0x01\n" if cex else ""
    rc = (0 if kind == "PASS" else 1) if exitc is None else exitc
    return (f"Running 1 tests for contracts/test/halmos/H.t.sol:{ran or contract}\n{c}"
            f"[{kind}] {check}() (paths: 3, time: 0.1s, bounds: [{bounds}])\n# exit_code: {rc}  wall_seconds: 1\n")


def plog(t, contract, check, label, kind, cex=False, profile="xp", **kw):
    """a complete partition log bound to fake tree t (header binding + trailer binding)."""
    return "# D5c1 partitioned run\n" + pmeta(contract, check, label, profile) + bline(t) + \
        body(contract, kind, check, cex, **kw) + bline(t, contract)


DIFF = """--- a/contracts/src/tokens/v2/X.sol
+++ b/contracts/src/tokens/v2/X.sol
@@ -1,4 +1,4 @@
 contract X {
     uint256 a;
-    function foo() external { a = 1; }
+    function foo() external { a = 2; }
 }
"""
DOC = "docs/design/aoa-balance-mode/D5c-1-halmos.md"


def mk_evidence(t, r):
    """t: fake tree, r: fake evidence root."""
    for lab in ("OTHER", "foo-00000001", "bar-00000002"):
        write(os.path.join(r, f"C.check_P/check_P.{lab}.log"), plog(t, "C", "check_P", lab, "PASS"))
    for lab in ("OTHER", "foo-00000001"):
        write(os.path.join(r, f"D.check_D/check_D.{lab}.log"), plog(t, "D", "check_D", lab, "PASS"))
    write(os.path.join(r, "D.check_D/check_D.bar-00000002.log"), plog(t, "D", "check_D", "bar-00000002", "FAIL", True))
    write(os.path.join(r, "W.check_W/check_W.OTHER.log"), plog(t, "W", "check_W", "OTHER", "FAIL", True, "xp-fail"))
    write(os.path.join(r, "u.log"), "# D5c-1 halmos run\n" + meta(runner="run-d5c1", contract="U", argv=B.halmos_argv("U", "xp"),
          profile="xp", wall_cap_s=B.WALL_CAP_S) + bline(t) + body("U", "PASS", "check_U") + bline(t, "U"))
    # mutated copy of the fake tree: diff applied, different token AND harness bytecode
    m = os.path.join(TMP, "mut-" + os.path.basename(r))
    shutil.copytree(t, m)
    shutil.rmtree(os.path.join(m, ".git"))
    assert sh(["patch", "-s", "-p1", "-i", "-"], m, input=DIFF).returncode == 0
    artifacts(m, core_code="0x6009", harness_code="0x60bb")
    pristine = sh(["shasum", "-a", "256", "contracts/src/tokens/v2/X.sol"], t).stdout.split()[0]
    md = os.path.join(r, "mutations/M-X")
    write(os.path.join(md, "C.check_P/check_P.foo-00000001.log"), plog(m, "C", "check_P", "foo-00000001", "FAIL", True, "xp-fail"))
    write(os.path.join(md, "Q.check_Q/check_Q.bar-00000002.log"), plog(m, "Q", "check_Q", "bar-00000002", "PASS"))
    write(os.path.join(md, "apply.txt"), f"applied M-X to contracts/src/tokens/v2/X.sol (pristine sha256 {pristine}; diff in x)\n")
    write(os.path.join(md, "summary.txt"), f"reverted M-X: contracts/src/tokens/v2/X.sol sha256 {pristine}\n")
    write(os.path.join(md, "scenario.log"), "[FAIL: bitmask: 1 != 0] test_scen() (gas: 1)\n" + bline(m))
    write(os.path.join(md, "M-X.diff"), DIFF)
    write(os.path.join(md, "binding-mutated.json"), sh(BIND + ["xpnts", "--all-artifacts"], m).stdout)
    write(os.path.join(md, "binding-restored.json"), sh(BIND + ["xpnts"], t).stdout)
    f = os.path.join(r, "fuzz-liveness")
    write(os.path.join(r, "unmutated.log"), "[PASS] testFuzz_t(uint256) (runs: 10000, μ: 1, ~: 1)\n" + bline(t))
    write(os.path.join(f, "M-Y.apply.txt"), f"applied M-Y to contracts/src/tokens/v2/X.sol (pristine sha256 {pristine}; diff in x)\n")
    write(os.path.join(f, "M-Y.fuzz.log"), "[FAIL: red; counterexample: calldata=0x args=[1]] testFuzz_t(uint256) (runs: 3)\n"
          + bline(m) + f"reverted M-Y: contracts/src/tokens/v2/X.sol sha256 {pristine}\n")
    write(os.path.join(f, "M-Y.diff"), DIFF)
    write(os.path.join(f, "M-Y.restored.json"), sh(BIND + ["xpnts"], t).stdout)
    # archives
    ba, bap = bline(t, alla=True), sh(BIND + ["apnts", "--line", "--all-artifacts"], t).stdout
    write(os.path.join(r, "parity.log"), "# pass 1: after the halmos build\nRESULT: OK\n" + ba + bap +
          "# pass 2: after a plain forge build\nRESULT: OK\n" + ba + bap)
    shas = {s: hashlib.sha256(open(os.path.join(HERE, s), "rb").read()).hexdigest() for s in SCRIPTS}
    write(os.path.join(r, "selftest.log"), "# scripts: " + json.dumps(shas, sort_keys=True) + "\nok    A\nok    B\n\nSELFTEST: all 2 controls behave\n")
    write(os.path.join(r, "suite.log"), "[PASS] test_a() (gas: 1)\n[PASS] test_b() (gas: 1)\n"
          "Ran 1 test suites in 1.00ms (1.00ms CPU time): 2 tests passed, 0 failed, 0 skipped (2 total tests)\n" + bline(t))
    write(os.path.join(r, "cap.log"), "[PASS] check_CAP1_a_x() (paths: 5, time: 1.00s, bounds: [])\n")
    write(os.path.join(t, DOC), "判定器自己的对照（x）：共 2 个。\n(a) PASS，5 条路径，1.00 s\n")


REQ = {"logs": [{"log": "u.log", "contract": "U", "family": "xpnts", "profile": "xp", "match_test": None,
                 "checks": {"check_U": "PASS"}}],
       "partitioned": [
           {"dir": "C.check_P", "abi": "core", "expect": "PASS", "profile": "xp",
            "bounded_ceiling": ["bar-00000002"], "expect_fail_parts": []},
           {"dir": "D.check_D", "abi": "core", "expect": "PASS", "profile": "xp",
            "bounded_ceiling": [], "expect_fail_parts": ["bar-00000002"]},
           {"dir": "W.check_W", "abi": "core", "expect": "FAIL", "profile": "xp", "parts": ["OTHER"],
            "bounded_ceiling": [], "expect_fail_parts": []}],
       "mutations": [{"id": "M-X", "family": "xpnts", "halmos_logs": [],
                      "halmos_parts": [{"dir": "C.check_P", "abi": "core", "labels": ["foo-00000001"]}],
                      "green_parts": [{"dir": "Q.check_Q", "abi": "core", "labels": ["bar-00000002"]}],
                      "scenario_test": "test_scen", "scenario_msg": "1 != 0"}],
       "fuzz_liveness": {"unmutated_log": "unmutated.log", "unmutated_tests": ["testFuzz_t"],
                         "mutations": [{"id": "M-Y", "must_fail": ["testFuzz_t"]}]},
       "archives": [{"file": "parity.log", "kind": "artifact-parity"},
                    {"file": "selftest.log", "kind": "selftest", "min_controls": 2},
                    {"file": "suite.log", "kind": "forge-suite", "tests": ["test_a"]},
                    {"file": "cap.log", "kind": "doc-cap1"}]}


def to_json(req):
    """the expectation file = the mandatory suite + text (reasons for the whole ceiling, notes)."""
    ex = json.loads(json.dumps(req))
    for p in ex["partitioned"]:
        p["allow_bounded"] = {l: {"reason": "r", "substitute": "s"} for l in p.pop("bounded_ceiling")}
        p["discrepancies"] = {l: "note" for l in p.pop("expect_fail_parts")}
    return ex


n = [0]


def fresh(req=None, ex=None, stale=False):
    n[0] += 1
    t, r = os.path.join(TMP, f"t{n[0]}"), os.path.join(TMP, f"r{n[0]}")
    mk_tree(t, stale)
    mk_evidence(t, r)
    rq = req or REQ
    q, e = os.path.join(TMP, f"q{n[0]}.json"), os.path.join(TMP, f"e{n[0]}.json")
    json.dump(rq, open(q, "w"))
    json.dump(ex or to_json(rq), open(e, "w"))
    return t, r, e, q


def expect(name, want_zero, t, r, e, q, orchestrator=False, why=None):
    env = dict(os.environ, D5C1_REQUIRED=q)
    if orchestrator:
        env.update(D5C1_ROOT=r, D5C1_EXPECT=e, D5C1_TREE_ROOT=t)
        p = subprocess.run([os.path.join(HERE, "run-step-d5c1.sh"), "verify"], cwd=REPO, env=env, capture_output=True, text=True)
    else:
        p = subprocess.run(V + ["--root", r, "--expect", e, "--tree", t], cwd=t, env=env, capture_output=True, text=True)
    mism = [l for l in p.stdout.splitlines() if "MISMATCH" in l and not l.startswith("VERDICT")]
    hit = [l for l in mism if why and re.search(why, l)]
    ok = (p.returncode == 0) == want_zero and (want_zero or bool(hit))
    print(f"{'ok  ' if ok else 'FAIL'}  {name} (rc={p.returncode}, wanted {'0' if want_zero else '!=0'}"
          + (f", {len(mism)} mismatch row(s), reason matched: {bool(hit)}" if not want_zero else "") + ")", flush=True)
    if hit:
        print("      " + re.sub(r"\s+", " ", hit[0])[:190])
    if not ok:
        tail = [l for l in p.stdout.splitlines() if "MISMATCH" in l or "VERDICT" in l][:8]
        print("      " + "\n      ".join(tail + p.stderr.splitlines()[-5:]))
        FAILS.append(name)


def mod(req, f):
    x = json.loads(json.dumps(req))
    f(x)
    return x


def main():
    shas = {s: hashlib.sha256(open(os.path.join(HERE, s), "rb").read()).hexdigest() for s in SCRIPTS}
    print("# scripts: " + json.dumps(shas, sort_keys=True))
    P = "C.check_P/check_P"
    F = lambda: fresh()  # noqa: E731
    t, r, e, q = F(); expect("P1_all_met", True, t, r, e, q)
    # --- results
    t, r, e, q = F(); write(f"{r}/{P}.foo-00000001.log", plog(t, "C", "check_P", "foo-00000001", "FAIL", True))
    expect("N1_pass_check_fails", False, t, r, e, q, why=r"FAIL foo-00000001")
    t, r, e, q = F(); write(f"{r}/W.check_W/check_W.OTHER.log", plog(t, "W", "check_W", "OTHER", "PASS", profile="xp-fail"))
    expect("N2_witness_passes", False, t, r, e, q, why=r"no counterexample")
    t, r, e, q = F(); write(f"{r}/W.check_W/check_W.OTHER.log", plog(t, "W", "check_W", "OTHER", "FAIL", profile="xp-fail"))
    expect("N3_witness_no_cex", False, t, r, e, q, why=r"no counterexample")
    t, r, e, q = F(); write(f"{r}/{P}.foo-00000001.log", plog(t, "C", "check_P", "foo-00000001", "TIMEOUT"))
    expect("N4_timeout_not_on_ceiling", False, t, r, e, q, why=r"BOUNDED foo-00000001")
    t, r, e, q = F(); write(f"{r}/{P}.bar-00000002.log", plog(t, "C", "check_P", "bar-00000002", "TIMEOUT"))
    expect("P2_timeout_on_ceiling_with_reason", True, t, r, e, q)
    t, r, e, q = F(); write(f"{r}/{P}.foo-00000001.log", plog(t, "C", "check_P", "foo-00000001", "ABORT"))
    expect("N5_aborted_part", False, t, r, e, q, why=r"ABORTED/ERROR/LOOP foo-00000001")
    # --- mutations / fuzz liveness
    t, r, e, q = F()
    mt = os.path.join(TMP, f"mut-r{n[0]}")
    write(f"{r}/mutations/M-X/{P}.foo-00000001.log", plog(mt, "C", "check_P", "foo-00000001", "PASS", profile="xp-fail"))
    write(f"{r}/mutations/M-X/scenario.log", "[PASS] test_scen() (gas: 1)\n" + bline(mt))
    expect("N6_mutation_survives", False, t, r, e, q, why=r"scenario test_scen.*green / missing")
    t, r, e, q = F(); write(f"{r}/mutations/M-X/summary.txt", f"reverted M-X: contracts/src/tokens/v2/X.sol sha256 {H64('c')}\n")
    expect("N7_not_restored", False, t, r, e, q, why=r"M-X source restored")
    t, r, e, q = F()
    lt = open(f"{r}/fuzz-liveness/M-Y.fuzz.log").read().replace("[FAIL: red; counterexample: calldata=0x args=[1]]", "[PASS]")
    write(f"{r}/fuzz-liveness/M-Y.fuzz.log", lt)
    expect("N8_fuzz_mutation_survives", False, t, r, e, q, why=r"M-Y reddens testFuzz_t.*green")
    t, r, e, q = F(); write(f"{r}/unmutated.log", "[FAIL: x] testFuzz_t(uint256) (runs: 3)\n" + bline(t))
    expect("N9_unmutated_fuzz_red", False, t, r, e, q, why=r"unmutated testFuzz_t.*not green")
    t, r, e, q = F(); mt = os.path.join(TMP, f"mut-r{n[0]}")
    write(f"{r}/mutations/M-X/Q.check_Q/check_Q.bar-00000002.log", plog(mt, "Q", "check_Q", "bar-00000002", "FAIL", True))
    expect("N10_mutation_green_part_goes_red", False, t, r, e, q, why=r"still PASS \(independence\).*green \[\]")
    t, r, e, q = F(); write(f"{r}/mutations/M-X/{P}.foo-00000001.log", plog(t, "C", "check_P", "foo-00000001", "FAIL", True, "xp-fail"))
    expect("N11_mutation_log_bound_to_pristine", False, t, r, e, q, why=r"src_sha \(!= current src \+ diff\)")
    t, r, e, q = F(); mt = os.path.join(TMP, f"mut-r{n[0]}")
    lg = plog(mt, "C", "check_P", "foo-00000001", "FAIL", True, "xp-fail").replace(bline(mt, "C"), bline(t, "C").replace(
        json.loads(bline(t, "C")[11:])["src_sha"], json.loads(bline(mt)[11:])["src_sha"]))
    write(f"{r}/mutations/M-X/{P}.foo-00000001.log", lg)
    expect("N12_mutation_log_on_pristine_harness_build", False, t, r, e, q, why=r"HARNESS-ARTIFACT|STALE")
    # --- partition set
    t, r, e, q = F(); os.remove(f"{r}/{P}.bar-00000002.log")
    expect("N13_missing_partition", False, t, r, e, q, why=r"missing \['bar-00000002'\]")
    t, r, e, q = F(); write(f"{r}/{P}.baz-00000009.log", plog(t, "C", "check_P", "OTHER", "PASS"))
    expect("N14_extra_partition", False, t, r, e, q, why=r"extra \['baz-00000009'\]")
    t, r, e, q = F(); write(f"{r}/{P}.foo-00000001.retry.log", plog(t, "C", "check_P", "foo-00000001", "PASS"))
    expect("N15_leftover_retry_log", False, t, r, e, q, why=r"retry\.log")
    # --- binding
    t, r, e, q = F()
    with open(f"{t}/contracts/src/tokens/v2/X.sol", "a") as fh:
        fh.write("// changed after the run\n")
    git(t, "commit", "-q", "-am", "src change")
    artifacts(t)   # out/ rebuilt from the changed source, same bytecode: ONLY the source hash differs
    expect("N16_source_hash_mismatch", False, t, r, e, q, why=r"STALE \(src_sha differ.*X\.sol")
    t, r, e, q = F()
    with open(f"{t}/contracts/src/Unrelated.sol", "a") as fh:
        fh.write("// dirty\n")
    lg = plog(t, "C", "check_P", "OTHER", "PASS")
    git(t, "checkout", "--", "contracts/src/Unrelated.sol")
    assert '"dirty_src": 1' in lg
    write(f"{r}/{P}.OTHER.log", lg)
    expect("N17_dirty_src", False, t, r, e, q, why=r"DIRTY \(dirty_src=1\)")
    t, r, e, q = F(); artifacts(t, core_code="0x60ff")
    expect("N18_bytecode_hash_mismatch", False, t, r, e, q, why=r"STALE \(bytecode_sha")
    t, r, e, q = F(); write(f"{r}/{P}.OTHER.log", "# D5c1 partitioned run\n" + pmeta("C", "check_P", "OTHER", "xp") + body("C", "PASS", "check_P"))
    expect("N19_unbound_log", False, t, r, e, q, why=r"UNBOUND")
    t, r, e, q = fresh(stale=True)
    expect("N20_out_not_built_from_sources", False, t, r, e, q, why=r"out/ \[xpnts\].*stale")
    t, r, e, q = F()
    hb = json.loads(bline(t)[len("# binding: "):]); hb["src_sha"] = H64("d")
    write(f"{r}/{P}.OTHER.log", plog(t, "C", "check_P", "OTHER", "PASS").replace(bline(t), "# binding: " + json.dumps(hb) + "\n", 1))
    expect("N21_header_trailer_drift", False, t, r, e, q, why=r"DRIFT")
    t, r, e, q = F(); artifacts(t, harness_code="0x60cc")
    expect("N22_harness_artifact_rebuilt_differently", False, t, r, e, q, why=r"HARNESS-ARTIFACT")
    t, r, e, q = F(); write(f"{r}/{P}.OTHER.log", plog(t, "C", "check_P", "OTHER", "PASS").replace(bline(t, "C"), bline(t, "D")))
    expect("N23_trailer_names_another_harness_contract", False, t, r, e, q, why=r"HARNESS-CONTRACT")
    # --- meta / argv / contract (H3)
    t, r, e, q = F(); write(f"{r}/{P}.bar-00000002.log", plog(t, "C", "check_P", "foo-00000001", "PASS"))
    expect("N24_log_copied_under_another_partition", False, t, r, e, q, why=r"bar-00000002: meta\.label='foo-00000001'")
    t, r, e, q = F(); write(f"{r}/W.check_W/check_W.OTHER.log", plog(t, "C", "check_P", "OTHER", "FAIL", True, "xp-fail"))
    expect("N25_log_copied_from_another_check", False, t, r, e, q, why=r"OTHER: meta\.check='check_P'")
    t, r, e, q = F()
    lg = plog(t, "C", "check_P", "foo-00000001", "PASS").replace('"300000"', '"60000"')
    write(f"{r}/{P}.foo-00000001.log", lg)
    expect("N26_wrong_halmos_args", False, t, r, e, q, why=r"foo-00000001: meta\.argv=")
    t, r, e, q = F(); write(f"{r}/{P}.foo-00000001.log", plog(t, "C", "check_P", "foo-00000001", "PASS", profile="xp-fail"))
    expect("N27_early_exit_on_a_pass_item", False, t, r, e, q, why=r"meta\.argv=.*--early-exit")
    t, r, e, q = F(); write(f"{r}/W.check_W/check_W.OTHER.log", plog(t, "W", "check_W", "OTHER", "FAIL", True, "xp"))
    expect("N28_fail_item_without_early_exit", False, t, r, e, q, why=r"meta\.argv=")
    t, r, e, q = F(); write(f"{r}/{P}.OTHER.log", plog(t, "C", "check_P", "OTHER", "PASS", ran="D"))
    expect("N29_halmos_ran_another_contract", False, t, r, e, q, why=r"halmos ran \['D'\]")
    t, r, e, q = F()
    write(f"{r}/{P}.bar-00000002.log", "# D5c1 partitioned run\n" + pmeta("C", "check_P", "bar-00000002", "xp", sel=1)
          + bline(t) + body("C", "PASS", "check_P") + bline(t, "C"))
    expect("N30_partition_selector_differs_from_abi", False, t, r, e, q, why=r"meta\.part=1 != 2")
    t, r, e, q = F()
    write(f"{r}/{P}.OTHER.log", "# D5c1 partitioned run\n" + pmeta("C", "check_P", "OTHER", "xp", wall=3600)
          + bline(t) + body("C", "PASS", "check_P") + bline(t, "C"))
    expect("N31_wall_cap_differs", False, t, r, e, q, why=r"meta\.wall_cap_s=3600")
    t, r, e, q = F(); write(f"{r}/{P}.OTHER.log", plog(t, "C", "check_P", "OTHER", "PASS", exitc=1))
    expect("N32_exit_code_inconsistent", False, t, r, e, q, why=r"exit_code 1 inconsistent with PASS")
    t, r, e, q = F(); write(f"{r}/{P}.OTHER.log", plog(t, "C", "check_P", "OTHER", "PASS", bounds="'loop@0x12: 2'"))
    expect("N33_pass_with_loop_bound_hit", False, t, r, e, q, why=r"PASS-LOOP-BOUNDED")
    t, r, e, q = F(); write(f"{r}/u.log", open(f"{r}/u.log").read().replace("[PASS] check_U()", "[PASS] check_U() (x)\n[PASS] check_Extra()", 1))
    expect("N34_unpartitioned_extra_check", False, t, r, e, q, why=r"other checks: \['check_Extra'\]")
    # --- mandatory suite vs expectation file (H3)
    ex = to_json(REQ); ex["partitioned"] = [p for p in ex["partitioned"] if p["dir"] != "W.check_W"]
    t, r, e, q = fresh(ex=ex); shutil.rmtree(f"{r}/W.check_W")
    expect("N35_mandatory_item_removed_with_its_evidence", False, t, r, e, q, why=r"partitioned:W\.check_W.*MISSING \(mandatory item\)")
    ex = to_json(REQ); ex["partitioned"].append({"dir": "Z.check_Z", "abi": "core", "expect": "PASS", "profile": "xp"})
    t, r, e, q = fresh(ex=ex)
    expect("N36_item_not_in_the_mandatory_suite", False, t, r, e, q, why=r"Z\.check_Z.*NOT in the mandatory suite")
    ex = to_json(REQ); ex["partitioned"][0]["allow_bounded"]["foo-00000001"] = {"reason": "r", "substitute": "s"}
    t, r, e, q = fresh(ex=ex)
    expect("N37_allow_bounded_beyond_ceiling", False, t, r, e, q, why=r"beyond the mandatory ceiling: \['foo-00000001'\]")
    ex = to_json(REQ); ex["partitioned"][2]["expect"] = "PASS"
    t, r, e, q = fresh(ex=ex)
    expect("N38_pinned_field_changed_in_json", False, t, r, e, q, why=r"W\.check_W.*fields differ: \['expect'\]")
    ex = to_json(REQ); ex["partitioned"][0]["allow_bounded"]["bar-00000002"] = {"reason": "r"}
    t, r, e, q = fresh(ex=ex)
    expect("N39_bounded_without_substitute", False, t, r, e, q, why=r"without reason\+substitute")
    t, r, e, q = fresh(req=mod(REQ, lambda x: x["partitioned"][0].update(bounded_ceiling=["bar-00000002", "zzz-000000ff"])))
    expect("N40_ceiling_label_not_a_partition", False, t, r, e, q, why=r"not a partition: \['zzz-000000ff'\]")
    t, r, e, q = fresh(req=mod(REQ, lambda x: x["partitioned"][2].update(bounded_ceiling=["OTHER"])))
    expect("N41_ceiling_on_a_fail_expectation", False, t, r, e, q, why=r"must produce a counterexample")
    # --- discrepancy partitions
    t, r, e, q = F(); write(f"{r}/D.check_D/check_D.bar-00000002.log", plog(t, "D", "check_D", "bar-00000002", "PASS"))
    expect("N42_discrepancy_part_passes", False, t, r, e, q, why=r"discrepancy part not FAIL\+cex")
    # --- wall cap
    def walled(total):
        return ("Running 1 tests for contracts/test/halmos/H.t.sol:C\n[PASS] check_P() (paths: 3, time: 1.0s, bounds: [])\n"
                f"Symbolic test result: 1 passed; 0 failed\n[time] total: {total}s (build: 1s)\n\n# WALL-CAP: killed after 600 s\n"
                "\n# exit_code: -9  wall_seconds: 601\n")
    t, r, e, q = F()
    write(f"{r}/{P}.foo-00000001.log", "# D5c1 partitioned run\n" + pmeta("C", "check_P", "foo-00000001", "xp") + bline(t) + walled("612.40") + bline(t, "C"))
    expect("N43_result_after_wall_cap", False, t, r, e, q, why=r"BOUNDED foo-00000001")
    t, r, e, q = F()
    write(f"{r}/{P}.foo-00000001.log", "# D5c1 partitioned run\n" + pmeta("C", "check_P", "foo-00000001", "xp") + bline(t) + walled("577.56") + bline(t, "C"))
    expect("P4_result_inside_cap_teardown_killed", True, t, r, e, q)
    # --- archives (M6)
    t, r, e, q = F(); os.remove(f"{r}/suite.log")
    expect("N44_archive_missing", False, t, r, e, q, why=r"suite\.log.*MISSING")
    t, r, e, q = F(); write(f"{r}/parity.log", open(f"{r}/parity.log").read().split("# pass 2")[0])
    expect("N45_parity_log_single_pass", False, t, r, e, q, why=r"want two passes")
    t, r, e, q = F(); write(f"{r}/selftest.log", open(f"{r}/selftest.log").read().replace('"verify-d5c1.py": "', '"verify-d5c1.py": "0', 1))
    expect("N46_selftest_log_of_other_scripts", False, t, r, e, q, why=r"tested scripts differ.*verify-d5c1\.py")
    t, r, e, q = F(); write(f"{r}/selftest.log", open(f"{r}/selftest.log").read().replace("ok    B\n", ""))
    expect("N47_selftest_count_mismatch", False, t, r, e, q, why=r"ok-lines 1")
    t, r, e, q = F(); write(f"{t}/{DOC}", "判定器自己的对照（x）：共 29 个。\n(a) PASS，5 条路径，1.00 s\n")
    expect("N48_report_quotes_another_control_count", False, t, r, e, q, why=r"quotes 29 controls, the log has 2")
    t, r, e, q = F(); write(f"{r}/suite.log", open(f"{r}/suite.log").read().replace("[PASS] test_a()", "[FAIL: x] test_a()"))
    expect("N49_forge_suite_not_green", False, t, r, e, q, why=r"not all green")
    t, r, e, q = F(); write(f"{t}/{DOC}", "判定器自己的对照（x）：共 2 个。\n(a) PASS，109 条路径，1.93 s\n")
    expect("N50_report_quotes_other_cap1_numbers", False, t, r, e, q, why=r"doc lacks '\(a\) PASS，5 条路径，1\.00 s'")
    t, r, e, q = F(); artifacts(t, harness_code="0x60dd"); write(f"{r}/parity.log", open(f"{r}/parity.log").read())
    expect("N51_parity_log_for_another_harness_build", False, t, r, e, q, why=r"harness artifacts differ")
    # --- orchestrator
    t, r, e, q = F(); write(f"{r}/{P}.OTHER.log", plog(t, "C", "check_P", "OTHER", "FAIL", True))
    expect("O1_orchestrator_propagates", False, t, r, e, q, orchestrator=True, why=r"FAIL OTHER")
    t, r, e, q = F(); expect("O2_orchestrator_clean", True, t, r, e, q, orchestrator=True)
    total = n[0]
    if "--no-real" not in sys.argv:
        total += 1
        p = subprocess.run(V + ["--only", "suite,logs,partitioned,mutations,fuzz"], cwd=REPO, capture_output=True, text=True)
        ok = p.returncode == 0
        print(f"{'ok  ' if ok else 'FAIL'}  P3_real_evidence_except_archives (rc={p.returncode}, wanted 0)")
        print("      " + "\n      ".join(l for l in p.stdout.splitlines() if l.startswith(("mandatory suite:", "expectations:", "current tree", "VERDICT"))))
        if not ok:
            print("      " + "\n      ".join([l for l in p.stdout.splitlines() if "MISMATCH" in l][:10]))
            FAILS.append("P3_real_evidence")
    shutil.rmtree(TMP, ignore_errors=True)
    print()
    if not FAILS:
        print(f"SELFTEST: all {total} controls behave"); sys.exit(0)
    print(f"SELFTEST: {len(FAILS)} of {total} control(s) misbehave: {FAILS}"); sys.exit(1)


if __name__ == "__main__":
    main()

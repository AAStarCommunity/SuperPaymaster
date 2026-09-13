#!/usr/bin/env python3
"""D5b mutation matrix (spec 03 §10.7b GOV-2 D + D5b-design §2.1).

For each mutation: copy the current tree into a scratch project, apply the mutation (the anchor text
MUST be present — a mutation that does not apply is an error, not a silent "green"), run the D5b GOV-2
suite (and, for the routing mutations, the C2 suite), and record which tests fail. Each mutation has
  - `red`   : the tests that MUST fail (the named assertion is printed from forge's reason string);
  - `blind` : tests that exercise the same code but are EXPECTED to stay green for this mutation —
              run to show the red set is specific, not "everything broke".
A mutation whose red set is missing a test, or whose blind set turns red, fails the matrix.
The unmutated tree is run first as column 0 (everything green), so a red is attributable to the
mutation. Usage: python3 scripts/d5b-mutation-matrix.py [--only NAME] > log
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

FORGE = os.environ.get("FORGE") or shutil.which("forge") or os.path.expanduser("~/.foundry/bin/forge")
ROOT = os.getcwd()
GOV2 = "contracts/test/v2/SuperPaymasterD5bGov2.t.sol"
RACE = "contracts/test/v2/SuperPaymasterD5bUpgradeRace.t.sol"
O2S = "contracts/src/utils/Ownable2StepNamespaced.sol"
ADM = "contracts/src/paymasters/superpaymaster/v3/SuperPaymasterAdmin.sol"
CORE = "contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol"

PAUSE_LINE = '        if (paused) return ("", _packValidationData(true, 0, 0));\n'

MUTATIONS = [
    {
        "name": "b-transferOwnership-without-onlyOwner",
        "what": "GOV-2 D / B.1: the transferOwnership override drops its explicit onlyOwner",
        "edits": [(O2S, "function transferOwnership(address newOwner) public virtual override onlyOwner {",
                   "function transferOwnership(address newOwner) public virtual override {")],
        "red": ["test_gov2_sp_transferOwnership_requires_owner", "test_gov2_registry_two_step"],
        "blind": ["test_gov2_sp_transferOwnership_via_proxy_is_two_step", "test_gov2_sp_nomination_replace_and_cancel",
                  "test_gov2_sp_accept_only_by_pending_and_clears_it", "test_gov2_sp_renounce_always_reverts"],
    },
    {
        "name": "c-core-two-step-override-deleted",
        "what": "§2.1: the core chain's two-step transferOwnership is deleted → OZ single-step is live",
        "edits": [(O2S, """    function transferOwnership(address newOwner) public virtual override onlyOwner {
        _setPendingOwner(newOwner);
        emit OwnershipTransferStarted(owner(), newOwner);
    }
""", "")],
        "red": ["test_gov2_sp_transferOwnership_via_proxy_is_two_step", "test_gov2_registry_two_step",
                "test_gov2_timelock_scheduleBatch_accepts_both_and_sets_guardian"],
        "blind": ["test_gov2_sp_transferOwnership_requires_owner", "test_gov2_sp_renounce_always_reverts",
                  "test_gov2_guardian_cannot_unpause_operator"],
    },
    {
        "name": "d-guardian-may-unpause",
        "what": "GOV-2 B.6: the guardian may also pass false (unpause)",
        "edits": [(ADM, "if (pausing && g != address(0) && msg.sender == g) return;",
                   "if (g != address(0) && msg.sender == g) return;")],
        "red": ["test_gov2_guardian_cannot_unpause_operator", "test_gov2_guardian_cannot_lift_global_pause"],
        "blind": ["test_gov2_guardian_pauses_operator", "test_gov2_strangers_cannot_pause",
                  "test_gov2_guardian_has_no_other_power"],
    },
    {
        "name": "e1-pause-check-after-pmd-parsing",
        "what": "GOV-2 B.6: the global pause check moved after operator / paymasterAndData / token / rate parsing",
        "edits": [(CORE, PAUSE_LINE, ""),
                  (CORE, "        // 3. Reservation a0 (spec §10.3)", PAUSE_LINE + "        // 3. Reservation a0 (spec §10.3)")],
        "red": ["test_gov2_global_pause_sigFails_before_parsing"],
        "blind": ["test_gov2_pause_does_not_block_postOp_settlement", "test_gov2_pause_does_not_block_stale_release",
                  "test_d5b_lens_through_fallback_agrees_with_validation"],
    },
    {
        "name": "e2-pause-check-after-reservation-math",
        "what": "GOV-2 B.6: the global pause check moved after the a0 price math",
        "edits": [(CORE, PAUSE_LINE, ""),
                  (CORE, "        // 4. Operator solvency", PAUSE_LINE + "        // 4. Operator solvency")],
        "red": ["test_gov2_global_pause_sigFails_before_parsing"],
        "blind": ["test_gov2_pause_does_not_block_postOp_settlement", "test_gov2_pause_does_not_block_stale_release"],
    },
    {
        "name": "e3-pause-check-after-extractOperator",
        "what": ("EQUIVALENT-MUTATION PROBE: pause check moved just after _extractOperator (before any external "
                 "call). No observable difference is expected — recorded to state the blind spot, not hidden."),
        "edits": [(CORE, PAUSE_LINE, ""),
                  (CORE, "        ISuperPaymaster.OperatorConfig storage config = operators[operator];\n",
                   "        ISuperPaymaster.OperatorConfig storage config = operators[operator];\n" + PAUSE_LINE)],
        "red": [],
        "blind": ["test_gov2_global_pause_sigFails_before_parsing"],
        "equivalent": True,
    },
    {
        "name": "f-pause-blocks-postOp",
        "what": "GOV-2 B.6: postOp also refuses while paused",
        "edits": [(CORE, "        if (context.length == 0) return;\n",
                   "        if (context.length == 0) return;\n        if (paused) revert Unauthorized();\n")],
        "red": ["test_gov2_pause_does_not_block_postOp_settlement", "test_d5b_forward_mid_bundle_upgrade_with_extension_calls"],
        "blind": ["test_gov2_pause_does_not_block_stale_release", "test_gov2_global_pause_sigFails_before_parsing"],
        "suites": [GOV2, RACE],
    },
    {
        "name": "g-transferOwnership-override-only-in-extension",
        "what": ("§2.1: the two-step override is removed from the shared chain and re-added ONLY in the "
                 "extension (dead code behind the core's selector)"),
        "edits": [(O2S, """    function transferOwnership(address newOwner) public virtual override onlyOwner {
        _setPendingOwner(newOwner);
        emit OwnershipTransferStarted(owner(), newOwner);
    }
""", ""),
                  (O2S, "    function _setPendingOwner(address p) private {", "    function _setPendingOwner(address p) internal {"),
                  (ADM, "    // ====================================\n    // GOV-2: guardian + pauses",
                   """    function transferOwnership(address newOwner) public override onlyOwner {
        _setPendingOwner(newOwner);
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    // ====================================
    // GOV-2: guardian + pauses""")],
        "red": ["test_gov2_sp_transferOwnership_via_proxy_is_two_step"],
        "blind": ["test_gov2_sp_transferOwnership_requires_owner"],
    },
]


def scratch():
    tmp = tempfile.mkdtemp(prefix="d5b-mut-")
    shutil.copy(os.path.join(ROOT, "foundry.toml"), tmp)
    os.makedirs(os.path.join(tmp, "contracts", "test", "v2"))
    shutil.copytree(os.path.join(ROOT, "contracts", "src"), os.path.join(tmp, "contracts", "src"))
    shutil.copytree(os.path.join(ROOT, "contracts", "test", "fixtures"), os.path.join(tmp, "contracts", "test", "fixtures"))
    os.makedirs(os.path.join(tmp, "contracts", "test", "helpers"))
    for h in ["UUPSDeployHelper.sol", "V55TestFixtures.sol", "V55FuzzFixtures.sol"]:
        shutil.copy(os.path.join(ROOT, "contracts", "test", "helpers", h), os.path.join(tmp, "contracts", "test", "helpers", h))
    for t in [GOV2, RACE]:
        shutil.copy(os.path.join(ROOT, t), os.path.join(tmp, t))
    os.symlink(os.path.join(ROOT, "contracts", "lib"), os.path.join(tmp, "contracts", "lib"))
    os.symlink(os.path.join(ROOT, "singleton-paymaster"), os.path.join(tmp, "singleton-paymaster"))
    return tmp


def run_suite(tmp, suite):
    r = subprocess.run([FORGE, "test", "--match-path", suite, "--json"], cwd=tmp, capture_output=True, text=True)
    out = r.stdout.strip()
    start = out.find("{")
    if start < 0:
        raise SystemExit(f"forge test produced no JSON (compile error?):\n{r.stdout[-4000:]}\n{r.stderr[-4000:]}")
    data = json.loads(out[start:])
    res = {}
    for _, s in data.items():
        for tname, t in s["test_results"].items():
            res[tname.split("(")[0]] = (t["status"], t.get("reason") or "")
    return res


def main():
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
    tmp = scratch()
    failed = False
    try:
        pristine = {}
        for s in [GOV2, RACE]:
            pristine.update(run_suite(tmp, s))
        reds = [k for k, v in pristine.items() if v[0] != "Success"]
        print(f"column 0 (unmutated): {len(pristine)} tests, red = {reds}")
        if reds:
            raise SystemExit("unmutated tree is not green — matrix meaningless")
        for mu in MUTATIONS:
            if only and mu["name"] != only:
                continue
            work = scratch()
            try:
                for path, a, b in mu["edits"]:
                    p = os.path.join(work, path)
                    s = open(p).read()
                    if s.count(a) != 1:
                        raise SystemExit(f"{mu['name']}: anchor not found exactly once in {path}: {a[:60]!r}")
                    open(p, "w").write(s.replace(a, b))
                res = {}
                for s in mu.get("suites", [GOV2]):
                    res.update(run_suite(work, s))
            finally:
                shutil.rmtree(work, ignore_errors=True)
            red = sorted(k for k, v in res.items() if v[0] != "Success")
            print(f"\n== {mu['name']}: {mu['what']}")
            print(f"   red ({len(red)}/{len(res)}):")
            for k in red:
                print(f"     - {k}: {res[k][1][:160]}")
            missing = [t for t in mu["red"] if t not in red]
            leaked = [t for t in mu["blind"] if t in red]
            ok = not missing and not leaked
            if mu.get("equivalent"):
                ok = not red  # an equivalent mutation must NOT be claimed as caught
                print(f"   equivalent-mutation probe: {'no test distinguishes it (as expected)' if ok else 'unexpectedly caught'}")
            print(f"   expected red {mu['red']} -> missing {missing}")
            print(f"   blind columns {mu['blind']} -> turned red {leaked}")
            print(f"   RESULT: {'OK' if ok else 'FAIL'}")
            failed |= not ok
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

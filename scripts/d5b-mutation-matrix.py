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
mutation. Usage: python3 scripts/d5b-mutation-matrix.py [--only NAME[,NAME...]] > log
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
PF = "contracts/test/v2/D5bTimelockPreflight.t.sol"
UVT = "contracts/script/v3/UpgradeViaTimelock.s.sol"

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
        "name": "h-upgrade-allowed-with-pending-nomination",
        "what": "Codex D5b High: _authorizeUpgrade no longer refuses while a nomination is pending",
        "edits": [("contracts/src/paymasters/superpaymaster/v3/BasePaymasterUpgradeable.sol",
                   "function _authorizeUpgrade(address) internal override onlyOwner { _requireNoPendingOwner(); }",
                   "function _authorizeUpgrade(address) internal override onlyOwner {}")],
        "red": ["test_gov2_upgrade_refused_while_nomination_pending", "test_gov2_rollback_cannot_carry_a_stale_nomination"],
        "blind": ["test_d5b_sp_inplace_upgrade_from_previous_release_preserves_state",
                  "test_gov2_timelock_scheduleBatch_accepts_both_and_sets_guardian"],
    },
    {
        "name": "i-postOp-refund-lost",
        "what": ("Codex closing review (Low): postOp books the charge as revenue but credits the operator's "
                 "refund (a0 - charge) nowhere"),
        "edits": [(CORE, "        operators[c.operator].aPNTsBalance += uint128(c.a0 - charge);\n", "")],
        "red": ["test_d5b_forward_mid_bundle_upgrade_with_extension_calls"],
        "blind": ["test_d5b_rollback_mid_bundle_with_extension_calls"],
        "suites": [RACE],
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
    # ---- Codex re-check of ed2a4762 (M1 / M3 / L1): the operator preflight in UpgradeViaTimelock
    {
        "name": "j-manifest-validation-skipped",
        "what": "Codex re-check M1/M3: m1Preflight no longer runs validateManifest (chainId, non-vacuous manifest)",
        "edits": [(UVT, "        validateManifest(m);\n", "")],
        "red": ["test_manifest_chainid_mismatch_reverts", "test_manifest_vacuous_fields_each_rejected"],
        "blind": ["test_preflight_rejects_72h_delay", "test_attestation_stale_head_reverts",
                  "test_preflight_correct_timelock_passes_and_M1_completes"],
        "suites": [PF],
    },
    {
        "name": "k-placeholder-manifest-accepted",
        "what": "Codex re-check M3: parseManifest accepts the committed example (FAKE placeholder addresses)",
        "edits": [(UVT, """        require(!vm.keyExistsJson(j, "._placeholder"),
            "M1 manifest: placeholder (the example schema with FAKE addresses) - not a network manifest");
""", "")],
        "red": ["test_manifest_example_placeholder_refused"],
        "blind": ["test_manifest_file_missing_field_each_rejected"],
        "suites": [PF],
    },
    {
        "name": "l-governed-call-accepts-upgrade",
        "what": "Codex re-check L1: schedule-call no longer refuses upgradeToAndCall (bypassing the upgrade read-backs)",
        "edits": [(UVT, """        require(bytes4(data) != ID5bOwned.upgradeToAndCall.selector, "governed call: use schedule-upgrade for upgrades");
""", "")],
        "red": ["test_governed_call_refuses_upgrade"],
        "blind": ["test_governed_call_unpause_runs_operator_preflight"],
        "suites": [PF],
    },
    {
        "name": "m-governed-call-skips-operator-preflight",
        "what": "Codex re-check L1: scheduleCallWith (the M2 unpause path) skips operatorPreflight",
        "edits": [(UVT, """        operatorPreflight(tl, m);
        address safe = _safeOf(m);
        address proxy = _governedCall(c, isSP, data);
        require(ID5bOwned(proxy).owner() == address(tl), "schedule: proxy owner is not the timelock");""",
                   """        address safe = _safeOf(m);
        address proxy = _governedCall(c, isSP, data);
        require(ID5bOwned(proxy).owner() == address(tl), "schedule: proxy owner is not the timelock");""")],
        "red": ["test_governed_call_unpause_runs_operator_preflight"],
        "blind": ["test_governed_call_refuses_upgrade", "test_attestation_missing_reverts"],
        "suites": [PF],
    },
    # ---- Codex re-check of 626b6ea8 (Medium + operator-safety items): still an operator preflight
    {
        "name": "n-attestation-schema-unchecked",
        "what": "Codex re-check of 626b6ea8 (Medium): the attestation .schema is no longer checked",
        "edits": [(UVT, """        require(vm.keyExistsJson(j, ".schema")
            && keccak256(bytes(vm.parseJsonString(j, ".schema"))) == keccak256(bytes(ATTEST_SCHEMA)),
            "roles attestation: schema != d5b-timelock-roles-attestation/2");
""", "")],
        "red": ["test_attestation_wrong_schema_reverts"],
        "blind": ["test_attestation_result_fail_reverts", "test_preflight_correct_timelock_passes_and_M1_completes"],
        "suites": [PF],
    },
    {
        "name": "o-whitespace-label-accepted",
        "what": "Codex re-check of 626b6ea8 (Medium): labels are no longer trimmed (whitespace-only accepted)",
        "edits": [(UVT, "            require(!_isBlank(m.mustHoldNothingLabels[i]), \"M1 manifest: empty mustHoldNothing label\");",
                   "            require(bytes(m.mustHoldNothingLabels[i]).length != 0, \"M1 manifest: empty mustHoldNothing label\");")],
        "red": ["test_manifest_whitespace_only_label_rejected"],
        "blind": ["test_manifest_vacuous_fields_each_rejected"],
        "suites": [PF],
    },
    {
        "name": "p-extra-role-key-accepted",
        "what": "Codex re-check of 626b6ea8 (Medium): an extra key under .roles is no longer rejected",
        "edits": [(UVT, """        require(vm.parseJsonKeys(j, ".roles").length == 4, "M1 manifest: unknown role key in .roles");
""", "")],
        "red": ["test_manifest_extra_role_key_rejected"],
        "blind": ["test_manifest_file_missing_field_each_rejected"],
        "suites": [PF],
    },
    {
        "name": "q-head-block-hash-unchecked",
        "what": "Codex re-check of 626b6ea8 (operator safety): headBlockHash is no longer compared with blockhash()",
        "edits": [(UVT, """            require(chainHash == attestedHash, "roles attestation: headBlockHash != this chain's block (fork / reorg)");
""", "")],
        "red": ["test_attestation_head_block_hash_checked_when_available"],
        "blind": ["test_attestation_stale_head_reverts", "test_attestation_wrong_chainid_reverts"],
        "suites": [PF],
    },
    {
        "name": "r-max-age-raise-anywhere",
        "what": "Codex re-check of 626b6ea8 (operator safety): TL_ATTEST_MAX_AGE may be raised on a live chain",
        "edits": [(UVT, """        require(requested <= ATTEST_MAX_AGE_BLOCKS || _isLocalChain(),
            "roles attestation: TL_ATTEST_MAX_AGE above 256 is local-only");
""", "")],
        "red": ["test_attest_max_age_raise_is_local_only"],
        "blind": ["test_attestation_stale_head_reverts"],
        "suites": [PF],
    },
    # ---- Codex re-check of 7ca43549 (L1); (s) was dropped with forge's raw-text canonicalUint (48cba3bd)
    {
        "name": "t-live-head-hash-not-fail-closed",
        "what": "Codex re-check of 7ca43549 (L1): live chain ids no longer fail closed on an unverifiable head hash",
        "edits": [(UVT, """            require(inWindow, "roles attestation: live chain: head must be 1..256 blocks older than block.number");
            require(chainHash != bytes32(0), "roles attestation: live chain: blockhash(head) unavailable");
""", "")],
        "red": ["test_live_chain_head_block_hash_fail_closed"],
        "blind": ["test_attestation_head_block_hash_checked_when_available", "test_attestation_opt_out_rejected_on_live_chain"],
        "suites": [PF],
    },
    {
        "name": "v-attested-values-unchecked",
        "what": ("Codex re-check of 48cba3bd: forge no longer requires the attested manifest values to equal "
                 "the values it read (the transitive canonical-form link)"),
        "edits": [(UVT, """        require(vm.parseJsonUint(j, ".manifestChainId") == m.chainId, "roles attestation: attested manifest chainId != manifest");
        require(vm.parseJsonUint(j, ".deploymentBlock") == m.deploymentBlock, "roles attestation: attested deploymentBlock != manifest");
        address[] memory attMhn = vm.parseJsonAddressArray(j, ".mustHoldNothing");
        require(attMhn.length == m.mustHoldNothing.length, "roles attestation: attested mustHoldNothing != manifest");
        for (uint256 i; i < attMhn.length; ++i) {
            require(attMhn[i] == m.mustHoldNothing[i], "roles attestation: attested mustHoldNothing != manifest");
        }
        string[] memory attLabels = vm.parseJsonStringArray(j, ".mustHoldNothingLabels");
        require(attLabels.length == m.mustHoldNothingLabels.length, "roles attestation: attested labels != manifest");
        for (uint256 i; i < attLabels.length; ++i) {
            require(keccak256(bytes(attLabels[i])) == keccak256(bytes(m.mustHoldNothingLabels[i])),
                "roles attestation: attested labels != manifest");
        }
""", "")],
        "red": ["test_attested_values_must_equal_the_manifest_forge_read"],
        "blind": ["test_attestation_manifest_changed_reverts", "test_preflight_correct_timelock_passes_and_M1_completes"],
        "suites": [PF],
    },
]


# ---- mutations of the event-history checker (JS), killed by its anvil self-test (not by forge)
CHK = "script/governance/check-timelock-roles.mjs"
SELFTEST = "scripts/d5b-timelock-roles-selftest.sh"
CANON_STEPS = ["non-canonical bytes: " + x for x in
               ["esc-key", "esc-value", "dup-key", "reorder", "trailing-space", "crlf", "bom", "no-final-newline"]]
CHECKER_MUTATIONS = [
    {
        "name": "u-checker-canonical-bytes-check-removed",
        "what": "Codex re-check of 48cba3bd: the checker no longer requires manifest bytes == canonical serialization",
        "edit": ("  if (Buffer.compare(canon, manifestBytes) !== 0) {", "  if (false) {"),
        "red": CANON_STEPS,
        # the decoy also carries a non-decimal chainId and an unknown key: with the canonical check gone it
        # is STILL refused (exit 1, FAIL), only for another reason -> "failed, but not with <needle>"
        "other_reason": ["non-canonical bytes: nested-decoy"],
        "blind": ["correct M1 timelock == manifest", "the committed example"],
    },
]


def run_selftest(check_cmd, work):
    env = dict(os.environ, KEEP_GOING="1", CHECK=check_cmd)
    r = subprocess.run(["bash", SELFTEST, work], cwd=ROOT, env=env, capture_output=True, text=True, timeout=1500)
    import re
    return r.stdout, re.findall(r"SELF-TEST FAILED at step \d+: (.*)", r.stdout)


def run_checker_mutations(only):
    failed = False
    work0 = tempfile.mkdtemp(prefix="d5b-chk-col0-")
    try:
        out, reds = run_selftest(f"node {CHK}", work0)
        print(f"\nchecker column 0 (unmutated self-test): {out.strip().splitlines()[-1]}; red = {reds}")
        if reds:
            raise SystemExit("unmutated checker self-test is not green — matrix meaningless")
    finally:
        shutil.rmtree(work0, ignore_errors=True)
    for mu in CHECKER_MUTATIONS:
        if only and mu["name"] not in only:
            continue
        src = open(os.path.join(ROOT, CHK)).read()
        a, b = mu["edit"]
        if src.count(a) != 1:
            raise SystemExit(f"{mu['name']}: anchor not found exactly once in {CHK}")
        mpath = os.path.join(ROOT, "script", "governance", f".mut-{mu['name']}.mjs")
        work = tempfile.mkdtemp(prefix="d5b-chk-mut-")
        try:
            open(mpath, "w").write(src.replace(a, b))
            out, reds = run_selftest(f"node {os.path.relpath(mpath, ROOT)}", work)
        finally:
            os.remove(mpath)
            shutil.rmtree(work, ignore_errors=True)
        hit = lambda lbl: any(r.startswith(lbl) for r in reds)
        missing = [t for t in mu["red"] if not any(r.startswith(t + " (exit 0, expected 1)") for r in reds)]
        leaked = [t for t in mu["blind"] if hit(t)]
        other = mu.get("other_reason", [])
        # still refused, for another reason: the only allowed self-test complaint is the needle mismatch
        wrong_other = [t for t in other if not any(r.startswith(t + " — failed, but not with") for r in reds)]
        ok = not missing and not leaked and not wrong_other
        print(f"\n== {mu['name']}: {mu['what']}")
        print(f"   self-test red ({len(reds)}):")
        for r in reds:
            print(f"     - {r[:160]}")
        print(f"   expected red {mu['red']} -> missing {missing}")
        print(f"   (red = the self-test step now PASSES the non-canonical file: exit 0 where 1 is required)")
        print(f"   still refused for another reason {other} -> not so {wrong_other}")
        print(f"   blind steps {mu['blind']} -> turned red {leaked}")
        print(f"   RESULT: {'OK' if ok else 'FAIL'}")
        failed |= not ok
    return failed


def scratch():
    tmp = tempfile.mkdtemp(prefix="d5b-mut-")
    shutil.copy(os.path.join(ROOT, "foundry.toml"), tmp)
    os.makedirs(os.path.join(tmp, "contracts", "test", "v2"))
    shutil.copytree(os.path.join(ROOT, "contracts", "src"), os.path.join(tmp, "contracts", "src"))
    shutil.copytree(os.path.join(ROOT, "contracts", "test", "fixtures"), os.path.join(tmp, "contracts", "test", "fixtures"))
    os.makedirs(os.path.join(tmp, "contracts", "test", "helpers"))
    for h in ["UUPSDeployHelper.sol", "V55TestFixtures.sol", "V55FuzzFixtures.sol"]:
        shutil.copy(os.path.join(ROOT, "contracts", "test", "helpers", h), os.path.join(tmp, "contracts", "test", "helpers", h))
    for t in [GOV2, RACE, PF]:
        shutil.copy(os.path.join(ROOT, t), os.path.join(tmp, t))
    shutil.copytree(os.path.join(ROOT, "contracts", "script"), os.path.join(tmp, "contracts", "script"))
    os.makedirs(os.path.join(tmp, "deployments"))
    shutil.copy(os.path.join(ROOT, "deployments", "timelock-roles.example.json"), os.path.join(tmp, "deployments"))
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
    only = sys.argv[sys.argv.index("--only") + 1].split(",") if "--only" in sys.argv else None
    chk_names = {m["name"] for m in CHECKER_MUTATIONS}
    run_chk = only is None or any(n in chk_names for n in only)
    run_forge = only is None or any(n not in chk_names for n in only)
    failed = run_checker_mutations(only) if run_chk else False
    if not run_forge:
        sys.exit(1 if failed else 0)
    tmp = scratch()
    try:
        pristine = {}
        for s in [GOV2, RACE, PF]:
            pristine.update(run_suite(tmp, s))
        reds = [k for k, v in pristine.items() if v[0] != "Success"]
        print(f"column 0 (unmutated): {len(pristine)} tests, red = {reds}")
        if reds:
            raise SystemExit("unmutated tree is not green — matrix meaningless")
        for mu in MUTATIONS:
            if only and mu["name"] not in only:
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

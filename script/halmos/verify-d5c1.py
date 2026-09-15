#!/usr/bin/env python3
"""D5c-1 — the ONLY verdict authority for the Halmos evidence (orchestrators exit with its code).

It reads evidence under ROOT (default docs/design/aoa-balance-mode/data/halmos) — never re-runs
anything — and checks it against the CURRENT tree (--tree, default the repo root).

WHAT is required is fixed HERE, in REQUIRED (the mandatory suite), not in the editable
expectation file: every item of REQUIRED must be present in script/halmos/d5c1-expectations.json
with identical pinned fields (the file only adds the human text: reasons, substitutes, notes), and
the file may not contain items REQUIRED does not name. Removing a property and its evidence from
the JSON therefore fails verification. A partition may be BOUNDED (TIMEOUT / TIMEOUT-WALL) only
if REQUIRED lists it in `bounded_ceiling` AND the JSON gives it a reason and a substitute.

Per log (partitioned and unpartitioned, including mutation logs), bound from the log's OWN header
and trailer, never from its file name alone:
  meta       `# meta: {json}` (written by the runner from the values it launched with): runner,
             contract, check, abi, partition label, D5C1_PART selector (must equal the selector the
             current ABI gives that label), wall cap, and the FULL Halmos argument list, which must
             equal d5c1_binding.halmos_argv(<item>) for the item's profile — `--early-exit` only on
             expected-FAIL items. A log copied under another partition's (or check's) name fails
             here. Halmos' own `Running N tests for <file>:<Contract>` line must name the contract,
             and every result line must name the item's check.
  binding    header and trailer `# binding:` lines agree on src/lib/harness (no drift during the
             run); the trailer's src/lib/harness/bytecode hashes equal the current tree's, out/ was
             the build of its sources, dirty_src == 0, and harness_contract / harness_artifact_sha
             name the item's contract and equal the current creation bytecode of that harness
             contract (mutation logs: the mutated tree's, from binding-mutated.json).
  exit code  `# exit_code:` is consistent with the result (PASS 0, FAIL / TIMEOUT 1, wall-killed -9).
  bounds     a PASS counts only with `bounds: []` (no loop reached its unrolling bound).

Items: logs (unpartitioned: the set of checks in the log must EQUAL the item's checks);
partitioned (the partition set is derived from the current build ABI and must EQUAL the logs in the
directory; expect PASS -> every part PASS except bounded_ceiling parts, which may be BOUNDED, and
expect_fail_parts, which MUST FAIL with a counterexample — a documented spec-vs-code discrepancy;
expect FAIL -> at least one part FAILs with a counterexample, none aborted); mutations (named
partitions FAIL+cex, `green_parts` stay PASS, scenario test red with the named message; logs bound
to current source + recorded diff; source restored); fuzz liveness; archives (artifact-parity
two-pass log, the verify self-test log bound to the current verifier scripts, the forge suite of
the replay / layout / priming / boundary tests, and the numbers the report quotes from them).

Prints one row per item: kind, item, expected, verdict, actual. Exit 0 iff every row is OK.
usage: python3 script/halmos/verify-d5c1.py [--root DIR] [--expect FILE] [--tree DIR]
                  [--only suite,logs,partitioned,mutations,fuzz,archives] [--filter a,b]
The mandatory suite can be replaced ONLY through the environment variable D5C1_REQUIRED (a JSON
file; used by verify-selftest.py on its fake trees); the verdict line then says so.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import d5c1_binding as B  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DOC = "docs/design/aoa-balance-mode/D5c-1-halmos.md"

# ------------------------------------------------------------------------------------------------
# The mandatory suite. Pinned fields only; the expectation JSON must repeat them verbatim.
# ------------------------------------------------------------------------------------------------


def _p(dir_, abi, expect, profile="xp", parts=None, ceiling=(), fail_parts=()):
    d = {"dir": dir_, "abi": abi, "expect": expect, "profile": profile}
    if parts:
        d["parts"] = list(parts)
    d["bounded_ceiling"] = sorted(ceiling)
    d["expect_fail_parts"] = sorted(fail_parts)
    return d


MINT = "mint-40c10f19"
REQUIRED = {
    "logs": [
        {"log": "cap1.log", "contract": "APNTsCappedHalmosTest", "family": "apnts", "profile": "cap1",
         "match_test": None, "checks": {"check_CAP1_a_supplyIncreaseStaysUnderCap": "PASS",
                                        "check_CAP1_b_onlyMinterMintIncreasesSupply": "PASS",
                                        "check_CAP1_c_mintDoesNotMoveCap": "PASS"}},
        {"log": "cap1-witness.log", "contract": "APNTsCappedWitnessHalmosTest", "family": "apnts",
         "profile": "cap1", "match_test": None, "checks": {"check_witness_CAP1_supplyCanIncrease": "FAIL"}},
        {"log": "rate-base.log", "contract": "XPNTsV2RateHalmosTest", "family": "xpnts", "profile": "xp",
         "match_test": "^check_RATE_base", "checks": {"check_RATE_base_initialize": "PASS",
                                                      "check_RATE_base_realFactory": "PASS"}},
        {"log": "i4b-base.log", "contract": "XPNTsV2I4BHalmosTest", "family": "xpnts", "profile": "xp",
         "match_test": "^check_I4B_base", "checks": {"check_I4B_base_initialize": "PASS",
                                                     "check_I4B_base_realFactory": "PASS"}},
    ],
    "partitioned": [
        _p("XPNTsV2RateHalmosTest.check_RATE_step_coreAbi", "core", "PASS"),
        _p("XPNTsV2RateHalmosTest.check_RATE_step_extAbi", "ext", "PASS"),
        # A-3, spec-literal bit 1: burn(address,uint256) by an SP always fails. The code lets an SP
        # burn its OWN balance (xPNTsTokenV2.sol:134) -> that partition must FAIL (discrepancy D-A3-2)
        _p("XPNTsV2A3HalmosTest.check_A3_coreAbi", "core", "PASS", fail_parts=["burn-9dc29fac"],
           ceiling=["tryLockForGas-ec290731", "settleLocked-7e48bbce"]),
        _p("XPNTsV2A3HalmosTest.check_A3_extAbi", "ext", "PASS", ceiling=[MINT]),
        _p("XPNTsV2A3NoSelfBurnHalmosTest.check_A3_coreAbi", "core", "PASS", parts=["burn-9dc29fac"]),
        _p("XPNTsV2A3Bit0HalmosTest.check_A3_coreAbi", "core", "PASS", parts=["transferFrom-23b872dd"]),
        _p("XPNTsV2A3Bit1HalmosTest.check_A3_coreAbi", "core", "PASS", parts=["burn-9dc29fac"]),
        _p("XPNTsV2A3HalmosTest.check_A3_selfBurnDiscrepancy", "core", "FAIL", profile="xp", parts=["burn-9dc29fac"]),
        _p("XPNTsV2A3MintNoDebtHalmosTest.check_A3_extAbi", "ext", "PASS", parts=["mint"]),
        _p("XPNTsV2A3xHalmosTest.check_A3x_exactCeilBound", "core", "PASS", parts=["settleLocked"],
           ceiling=["settleLocked-7e48bbce"]),
        _p("XPNTsV2I2HalmosTest.check_I2_coreAbi", "core", "PASS",
           ceiling=["tryLockForGas-ec290731", "settleLocked-7e48bbce", "transferFrom-23b872dd", "burn-9dc29fac"]),
        _p("XPNTsV2I2HalmosTest.check_I2_extAbi", "ext", "PASS", ceiling=["transferFrom-23b872dd", MINT]),
        _p("XPNTsV2I2MintNoDebtHalmosTest.check_I2_extAbi", "ext", "PASS", parts=["mint"]),
        _p("XPNTsV2I4BHalmosTest.check_I4B_coreAbi", "core", "PASS",
           ceiling=["tryLockForGas-ec290731", "settleLocked-7e48bbce", "transferFrom-23b872dd", "burn-9dc29fac"]),
        _p("XPNTsV2I4BHalmosTest.check_I4B_extAbi", "ext", "PASS", ceiling=["transferFrom-23b872dd", MINT]),
        _p("XPNTsV2I4BMintNoDebtHalmosTest.check_I4B_extAbi", "ext", "PASS", parts=["mint"]),
        _p("XPNTsV2I6HalmosTest.check_I6_coreAbi", "core", "PASS"),
        _p("XPNTsV2I6HalmosTest.check_I6_extAbi", "ext", "PASS", ceiling=[MINT]),
        _p("XPNTsV2I6HalmosTest.check_I6J_coreAbi", "core", "PASS"),
        _p("XPNTsV2I6HalmosTest.check_I6J_extAbi", "ext", "PASS", ceiling=[MINT]),
        _p("XPNTsV2I6MintNoDebtHalmosTest.check_I6_extAbi", "ext", "PASS", parts=["mint"]),
        _p("XPNTsV2I6MintNoDebtHalmosTest.check_I6J_extAbi", "ext", "PASS", parts=["mint"]),
        _p("XPNTsV2I2NoRHalmosTest.check_I2_coreAbi", "core", "FAIL", parts=["tryLockForGas"]),
        _p("XPNTsV2WitnessPinnedHalmosTest.check_witness_A3_spSettleBurnsVictim", "core", "FAIL", parts=["settleLocked"]),
        _p("XPNTsV2WitnessHalmosTest.check_witness_I2_spRenewIncrements", "core", "FAIL", parts=["tryLockForGas"]),
        _p("XPNTsV2WitnessPinnedHalmosTest.check_witness_I2_meteredPull", "core", "FAIL", parts=["transferFrom"]),
        _p("XPNTsV2WitnessHalmosTest.check_witness_I2_explicitPull", "core", "FAIL", parts=["transferFrom"]),
        _p("XPNTsV2WitnessHalmosTest.check_witness_I4B_outgoingWithLock", "core", "FAIL", parts=["transfer"]),
        _p("XPNTsV2WitnessHalmosTest.check_witness_I6_reservationAdmitted", "core", "FAIL", parts=["tryReserveCredit"]),
        _p("XPNTsV2WitnessHalmosTest.check_witness_I6_debtGrows", "core", "FAIL", parts=["settleCredit"]),
    ] + [_p(f"MintRepayLemmaHalmosTest.{c}", "core", "PASS", profile="lemma", parts=["OTHER"], ceiling=["OTHER"])
         for c in ("check_LEMMA_M_repayNeverExceedsMint", "check_LEMMA_M1_floorDivTimesDivisor",
                   "check_LEMMA_M2_monotoneProduct", "check_LEMMA_M3_ceilDivByConstant")],
    "mutations": [
        {"id": "M-CAP1", "family": "apnts",
         "halmos_logs": [{"log": "APNTsCappedHalmosTest.log", "contract": "APNTsCappedHalmosTest",
                          "check": "check_CAP1_a_supplyIncreaseStaysUnderCap", "match_test": None}],
         "halmos_parts": [], "green_parts": [],
         "scenario_test": "test_D5c1_CAP1_scenario_mintBeyondCapReverts",
         "scenario_msg": "next call did not revert as expected"},
        {"id": "M-A3", "family": "xpnts", "halmos_logs": [],
         "halmos_parts": [{"dir": "XPNTsV2A3HalmosTest.check_A3_extAbi", "abi": "ext", "labels": ["spPull-20992765"]},
                          {"dir": "XPNTsV2A3HalmosTest.check_A3_coreAbi", "abi": "core", "labels": ["OTHER"]}],
         "green_parts": [], "scenario_test": "test_D5c1_A3_scenario_spCannotMoveUserTokens", "scenario_msg": "28 != 0"},
        {"id": "M-A3TF", "family": "xpnts", "halmos_logs": [],
         "halmos_parts": [{"dir": "XPNTsV2A3Bit0HalmosTest.check_A3_coreAbi", "abi": "core", "labels": ["transferFrom-23b872dd"]}],
         "green_parts": [{"dir": "XPNTsV2A3Bit1HalmosTest.check_A3_coreAbi", "abi": "core", "labels": ["burn-9dc29fac"]}],
         "scenario_test": "test_D5c1_A3_scenario_spFirewallBits",
         "scenario_msg": "A-3 firewall bits (bit0 transferFrom, bit1 burn(from)): 1 != 0"},
        {"id": "M-A3BF", "family": "xpnts", "halmos_logs": [],
         "halmos_parts": [{"dir": "XPNTsV2A3Bit1HalmosTest.check_A3_coreAbi", "abi": "core", "labels": ["burn-9dc29fac"]}],
         "green_parts": [{"dir": "XPNTsV2A3Bit0HalmosTest.check_A3_coreAbi", "abi": "core", "labels": ["transferFrom-23b872dd"]}],
         "scenario_test": "test_D5c1_A3_scenario_spFirewallBits",
         "scenario_msg": "A-3 firewall bits (bit0 transferFrom, bit1 burn(from)): 2 != 0"},
        {"id": "M-I2", "family": "xpnts", "halmos_logs": [],
         "halmos_parts": [{"dir": "XPNTsV2I2HalmosTest.check_I2_coreAbi", "abi": "core", "labels": ["tryLockForGas-ec290731"]}],
         "green_parts": [], "scenario_test": "test_D5c1_I2_scenario_lockBeyondSpCapRejected", "scenario_msg": "1 != 0"},
        {"id": "M-I4B", "family": "xpnts", "halmos_logs": [],
         "halmos_parts": [{"dir": "XPNTsV2I4BHalmosTest.check_I4B_coreAbi", "abi": "core", "labels": ["transfer-a9059cbb"]}],
         "green_parts": [], "scenario_test": "test_D5c1_I4B_scenario_transferBelowLockedRejected",
         "scenario_msg": "I4-B predicate bitmask on the over-lock transfer: 1 != 0"},
        {"id": "M-I6", "family": "xpnts", "halmos_logs": [],
         "halmos_parts": [{"dir": "XPNTsV2I6HalmosTest.check_I6_coreAbi", "abi": "core", "labels": ["tryReserveCredit-de9e4cae"]},
                          {"dir": "XPNTsV2I6HalmosTest.check_I6J_coreAbi", "abi": "core", "labels": ["tryReserveCredit-de9e4cae"]}],
         "green_parts": [], "scenario_test": "test_D5c1_I6_scenario_reservationBoundedByRequestedCap", "scenario_msg": "1 != 0"},
        {"id": "M-F1", "family": "xpnts", "halmos_logs": [
            {"log": "XPNTsV2RateHalmosTest.log", "contract": "XPNTsV2RateHalmosTest", "check": "check_RATE_base_initialize",
             "match_test": "^check_RATE_base"},
            {"log": "XPNTsV2RateHalmosTest.log", "contract": "XPNTsV2RateHalmosTest", "check": "check_RATE_base_realFactory",
             "match_test": "^check_RATE_base"}],
         "halmos_parts": [], "green_parts": [],
         "scenario_test": "test_D5c1_REGRESSION_F1_rateOutOfRangeRejectedAtInit",
         "scenario_msg": "next call did not revert as expected"},
    ],
    "fuzz_liveness": {
        "unmutated_log": "fuzz-liveness/fuzz-bounded-partitions.log",
        "unmutated_tests": ["testFuzz_D5c1_I2_tryLockForGas", "testFuzz_D5c1_I2_settleLocked",
                            "testFuzz_D5c1_I2_transferFrom", "testFuzz_D5c1_I2_burnFrom",
                            "testFuzz_D5c1_I4B_mintWithDebt", "testFuzz_D5c1_lemmaM_mintWithDebtNeverLowersBalance"],
        "mutations": [
            {"id": "M-I2", "must_fail": ["testFuzz_D5c1_I2_tryLockForGas"]},
            {"id": "M-PULL", "must_fail": ["testFuzz_D5c1_I2_transferFrom", "testFuzz_D5c1_I2_burnFrom"]},
            {"id": "M-EXPL", "must_fail": ["testFuzz_D5c1_I2_transferFrom", "testFuzz_D5c1_I2_burnFrom"]},
            {"id": "M-BURNALL", "must_fail": ["testFuzz_D5c1_I2_settleLocked"]},
            {"id": "M-REPAY", "must_fail": ["testFuzz_D5c1_lemmaM_mintWithDebtNeverLowersBalance"]},
            {"id": "M-REPAYLOCK", "must_fail": ["testFuzz_D5c1_I4B_mintWithDebt"]},
        ],
    },
    "archives": [
        {"file": "artifact-parity.log", "kind": "artifact-parity"},
        {"file": "verify-selftest.log", "kind": "selftest", "min_controls": 40},
        {"file": "forge-halmos-suite.log", "kind": "forge-suite",
         "tests": ["test_D5c1_layout_allowancesSlotAndInitSlot", "test_D5c1_layout_snapshotMatchesGetters",
                   "test_D5c1_selectorListMatchesArtifacts", "test_D5c1_priming_lockMakesExactlyTheRecordLive",
                   "test_D5c1_priming_creditMakesExactlyTheRecordLive",
                   "test_D5c1_replay_I2_transferFrom_wrapNeedsUnreachableState",
                   "test_D5c1_REGRESSION_F1_rateOutOfRangeRejectedAtInit", "test_D5c1_REGRESSION_F1_maxRateMaxLockIsExact",
                   "test_D5c1_DISCREPANCY_A3_2_spBurnsOwnBalance", "test_D5c1_A3_scenario_spFirewallBits",
                   "test_D5c1_I4B_scenario_transferBelowLockedRejected"]},
        {"file": "cap1.log", "kind": "doc-cap1"},
    ],
}

# expectation-file keys that carry text only (never compared with REQUIRED)
TEXT_KEYS = {"_doc", "reason", "substitute", "note", "allow_bounded", "discrepancies"}

RES = re.compile(r"\[(PASS|FAIL|TIMEOUT|ERROR)\]\S*\s*(check_\w+)\([^)]*\) \(paths: (\d+)[^\n]*?bounds: \[([^\]]*)\]")
RES_LOOSE = re.compile(r"\[(PASS|FAIL|TIMEOUT|ERROR)\]\S*\s*(check_\w+)\(")
BIND = re.compile(r"^# binding: (\{.*\})\s*$", re.M)
META = re.compile(r"^# meta: (\{.*\})\s*$", re.M)
RUNNING = re.compile(r"^Running \d+ tests for (\S+):(\w+)\s*$", re.M)
EXITC = re.compile(r"^# exit_code: (-?\d+)", re.M)
WALL = re.compile(r"^# WALL-CAP: killed after (\d+) s", re.M)
TOTAL = re.compile(r"^\[time\] total: ([0-9.]+)s", re.M)
ABI_OF = {"core": "xPNTsTokenV2", "ext": "xPNTsTokenV2Ext"}
BOUND_KEYS = ("src_sha", "lib_sha", "harness_sha", "bytecode_sha")
TREE = "."
_cur = {}
_arts = {}
rows = []


def row(kind, item, expected, actual, ok):
    rows.append((kind, item, expected, actual, "OK" if ok else "MISMATCH"))


def cur(fam):
    if fam not in _cur:
        _cur[fam] = B.binding(fam, TREE)
    return _cur[fam]


def cur_arts():
    if "a" not in _arts:
        _arts["a"] = B.harness_artifacts(TREE)
    return _arts["a"]


def read(p):
    return open(p, errors="replace").read() if os.path.exists(p) else ""


def sha_file(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.exists(p) else None


def binding_of(text):
    ms = BIND.findall(text)
    return json.loads(ms[-1]) if ms else None


def meta_of(text):
    ms = META.findall(text)
    return json.loads(ms[0]) if len(ms) == 1 else None


# ------------------------------------------------------------------------------------------------
# per-log validation
# ------------------------------------------------------------------------------------------------


def bind_problem(text, fam, contract=None, arts=None, want_src=None, want_bc=None):
    """None if the log is bound to the current, clean tree (or, for a mutation log, to `want_src` +
    the mutated harness artifacts `arts`); else a short reason. The LAST `# binding:` line (the
    trailer, written after the run's build) is authoritative; every earlier one must agree with it on
    src/lib/harness (the source did not change while the run was in progress)."""
    bs = [json.loads(m) for m in BIND.findall(text)]
    if not bs:
        return "UNBOUND (no # binding: trailer)"
    b = bs[-1]
    drift = [k for k in ("src_sha", "lib_sha", "harness_sha") if any(x.get(k) != b.get(k) for x in bs[:-1])]
    if drift:
        return "DRIFT (header and trailer bindings differ on " + ",".join(drift) + ")"
    c = cur(fam)
    if b.get("family") != fam:
        return f"WRONG-FAMILY ({b.get('family')} != {fam})"
    keys = BOUND_KEYS if want_src is None else ("lib_sha", "harness_sha")
    bad = [k for k in keys if b.get(k) != c[k]]
    if want_src is not None and b.get("src_sha") != want_src:
        bad.insert(0, "src_sha (!= current src + diff)")
    if want_src is not None and want_bc is not None and b.get("bytecode_sha") != want_bc:
        bad.append("bytecode_sha (!= binding-mutated.json)")
    if bad:
        files = sorted(p for p in set(b.get("src_files", {})) | set(c["src_files"])
                       if b.get("src_files", {}).get(p) != c["src_files"].get(p)) if want_src is None else []
        return "STALE (" + ",".join(bad) + " differ from the current tree" + \
            (f"; files: {','.join(os.path.basename(f) for f in files[:4])}" if files else "") + ")"
    if b.get("out_stale"):
        return f"STALE-BUILD (the run's out/ was not the build of its sources: {b['out_stale'][:2]})"
    if want_src is None and b.get("dirty_src") != 0:
        return f"DIRTY (dirty_src={b.get('dirty_src')})"
    if contract is not None:
        a = (arts if arts is not None else cur_arts()).get(contract)
        if b.get("harness_contract") != contract:
            return f"HARNESS-CONTRACT (trailer names {b.get('harness_contract')}, item is {contract})"
        if a is None or b.get("harness_artifact_sha") != a:
            return f"HARNESS-ARTIFACT (creation bytecode of {contract} differs from the " + \
                ("mutated" if arts is not None else "current") + " build)"
    return None


def teardown_walled(text):
    """(total_s, cap_s) when halmos finished (result + 'Symbolic test result' + '[time] total' below
    the cap) but the process was killed by the wall cap while shutting down; else None."""
    w, t = WALL.search(text), TOTAL.search(text)
    if w and t and "Symbolic test result:" in text and float(t.group(1)) < int(w.group(1)):
        return float(t.group(1)), int(w.group(1))
    return None


def results_in(text):
    """check -> [(result, bounds)]; a result line without a parseable bounds field -> bounds None."""
    out = {}
    full = {(m.start(), m.group(2)): (m.group(1), m.group(4).strip()) for m in RES.finditer(text)}
    for m in RES_LOOSE.finditer(text):
        r = full.get((m.start(), m.group(2)), (m.group(1), None))
        out.setdefault(m.group(2), []).append(r)
    return out


def part_result(text, check):
    r = results_in(text).get(check)
    if r is None:
        return "TIMEOUT-WALL" if "# WALL-CAP:" in text else "ABORTED"
    if "# WALL-CAP:" in text and not teardown_walled(text):
        return "TIMEOUT-WALL"   # a result line without a completed run inside the cap does not count
    if len(r) != 1:
        return "DUPLICATE-RESULT"
    res, bounds = r[0]
    if res == "PASS" and bounds != "":
        return "PASS-LOOP-BOUNDED" if bounds else "PASS-NO-BOUNDS-FIELD"
    return res


def exit_ok(text, result):
    m = EXITC.search(text)
    if not m:
        return "no # exit_code line"
    rc = int(m.group(1))
    if result == "TIMEOUT-WALL" or teardown_walled(text):
        want = {-9}
    elif result == "PASS":
        want = {0}
    elif result in ("FAIL", "TIMEOUT"):
        want = {1}
    else:
        return None   # aborted / error results are mismatches on their own
    return None if rc in want else f"exit_code {rc} inconsistent with {result} (want {sorted(want)})"


def meta_problems(text, want):
    """want: dict of meta fields that must match exactly (argv included)."""
    m = meta_of(text)
    if m is None:
        return ["no (or more than one) # meta: header"]
    probs = [f"meta.{k}={m.get(k)!r} != {v!r}" for k, v in want.items() if m.get(k) != v]
    run = RUNNING.findall(text)
    if len(run) != 1 or run[0][1] != want["contract"]:
        probs.append(f"halmos ran {[r[1] for r in run] or 'nothing'} (want {want['contract']})")
    return probs


def validate(text, want, fam, arts=None, want_src=None, checks=None, want_bc=None):
    """All per-log problems (list of strings) independent of the result."""
    probs = meta_problems(text, want)
    bp = bind_problem(text, fam, want["contract"], arts, want_src, want_bc)
    if bp:
        probs.append(bp)
    names = set(results_in(text))
    if checks is not None and not names <= set(checks):
        probs.append(f"result lines for other checks: {sorted(names - set(checks))}")
    return probs


# ------------------------------------------------------------------------------------------------
# suite reconciliation (REQUIRED vs the expectation file)
# ------------------------------------------------------------------------------------------------


def strip(x):
    if isinstance(x, dict):
        return {k: strip(v) for k, v in x.items() if k not in TEXT_KEYS}
    if isinstance(x, list):
        return [strip(v) for v in x]
    return x


def key_of(kind, it):
    return it.get("dir") or it.get("log") or it.get("id") or it.get("file")


def check_suite(req, ex):
    for kind in ("logs", "partitioned", "mutations", "archives"):
        rq = {key_of(kind, i): i for i in req.get(kind, [])}
        js = {key_of(kind, i): i for i in ex.get(kind, [])}
        for k, i in rq.items():
            if k not in js:
                row("suite", f"{kind}:{k}", "in the expectation file", "MISSING (mandatory item)", False)
                continue
            j = js[k]
            if kind == "partitioned":
                allow = set(j.get("allow_bounded", {}))
                over = sorted(allow - set(i["bounded_ceiling"]))
                untext = sorted(l for l, v in j.get("allow_bounded", {}).items()
                                if not (isinstance(v, dict) and v.get("reason") and v.get("substitute")))
                disc = set(j.get("discrepancies", {}))
                pin = {kk: vv for kk, vv in i.items() if kk not in ("bounded_ceiling", "expect_fail_parts")}
                jp = {kk: vv for kk, vv in strip(j).items() if kk not in ("bounded_ceiling", "expect_fail_parts")}
                diff = sorted(kk for kk in set(pin) | set(jp) if pin.get(kk) != jp.get(kk))
                probs = ([f"fields differ: {diff}"] if diff else []) + \
                    ([f"allow_bounded beyond the mandatory ceiling: {over}"] if over else []) + \
                    ([f"allow_bounded without reason+substitute: {untext}"] if untext else []) + \
                    ([f"discrepancies {sorted(disc)} != {i['expect_fail_parts']}"] if disc != set(i["expect_fail_parts"]) else [])
            else:
                probs = [] if strip(j) == i else ["pinned fields differ from the mandatory suite"]
            row("suite", f"{kind}:{k}", "== mandatory suite", "; ".join(probs) or "equal", not probs)
        for k in sorted(set(js) - set(rq)):
            row("suite", f"{kind}:{k}", "only mandatory items", "NOT in the mandatory suite", False)
    rf, jf = req.get("fuzz_liveness"), ex.get("fuzz_liveness")
    if rf is not None:
        row("suite", "fuzz_liveness", "== mandatory suite", "equal" if strip(jf) == rf else "differs / missing",
            strip(jf) == rf)


# ------------------------------------------------------------------------------------------------
# evidence checks
# ------------------------------------------------------------------------------------------------


def label_selectors(abi):
    return {l: p for p, l in B.partition_specs(ABI_OF[abi], os.path.join(TREE, "out"))}


def expected_labels(abi, parts=None):
    labels = set(label_selectors(abi))
    if parts:
        labels = {l for l in labels if l in parts or l.split("-")[0] in parts}
    return labels


def part_logs(d, check):
    """label -> path for `<check>.<label>.log`; any other log file in d is returned as extra."""
    got, extra = {}, []
    if not os.path.isdir(d):
        return None, []
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".log"):
            continue
        if not fn.startswith(check + ".") or fn.count(".") != 2:
            extra.append(fn)
            continue
        got[fn[len(check) + 1:-4]] = os.path.join(d, fn)
    return got, extra


def part_want(contract, check, abi, label, sel, profile):
    return {"runner": "run-partitioned", "contract": contract, "check": check, "abi": abi, "label": label,
            "part": sel, "argv": B.halmos_argv(contract, profile, function=check), "profile": profile,
            "wall_cap_s": B.WALL_CAP_S}


def check_logs(root, req, ex):
    for e in req.get("logs", []):
        p = os.path.join(root, e["log"])
        t = read(p)
        if not t:
            row("log", e["log"], "present", "MISSING", False)
            continue
        fail = any(v == "FAIL" for v in e["checks"].values())
        prof = e["profile"] + ("-fail" if fail else "")
        want = {"runner": "run-d5c1", "contract": e["contract"], "profile": prof,
                "argv": B.halmos_argv(e["contract"], prof, match_test=e["match_test"]), "wall_cap_s": B.WALL_CAP_S}
        probs = validate(t, want, e["family"], checks=e["checks"])
        res = results_in(t)
        missing = sorted(set(e["checks"]) - set(res))
        if missing:
            probs.append(f"missing checks {missing}")
        got = {c: part_result(t, c) for c in e["checks"]}
        allpass = all(v == "PASS" for v in got.values())
        ep = exit_ok(t, "PASS" if allpass else "FAIL")
        if ep and not any(v.startswith("TIMEOUT") for v in got.values()):
            probs.append(ep)
        row("binding", e["log"], f"meta/argv/contract/binding/exit ({e['family']}, {prof})",
            "; ".join(probs[:3]) or "bound, fresh, dirty_src=0, argv and contract match", not probs)
        for c, want_r in e["checks"].items():
            r = got[c]
            ok = r == want_r and (want_r != "FAIL" or "Counterexample" in t)
            row("log", f"{e['log']}:{c}", want_r, r, ok)


def check_partitioned(root, req, ex):
    jtext = {i["dir"]: i for i in ex.get("partitioned", [])}
    for e in req.get("partitioned", []):
        d = os.path.join(root, e["dir"])
        contract, check = e["dir"].split(".", 1)
        fam = B.family_of(contract)
        try:
            sels = label_selectors(e["abi"])
            want = expected_labels(e["abi"], e.get("parts"))
        except Exception as err:  # noqa: BLE001
            row("partitioned", e["dir"], "expected set from ABI", f"cannot derive: {err}", False)
            continue
        allow = {k: v for k, v in jtext.get(e["dir"], {}).get("allow_bounded", {}).items() if k in e["bounded_ceiling"]}
        disc = jtext.get(e["dir"], {}).get("discrepancies", {})
        ghost = sorted((set(e["bounded_ceiling"]) | set(e["expect_fail_parts"])) - want)
        if ghost:
            row("partitioned", f"{e['dir']}: ceiling/discrepancy labels", "⊆ expected partitions", f"not a partition: {ghost}", False)
        if e["expect"] != "PASS" and (e["bounded_ceiling"] or e["expect_fail_parts"]):
            row("partitioned", f"{e['dir']}: allow_bounded", "none on a FAIL expectation",
                "a witness / negative control must produce a counterexample", False)
        got, extra = part_logs(d, check)
        if got is None:
            row("partitioned", e["dir"], e["expect"], "MISSING", False)
            continue
        missing = sorted(want - set(got))
        extra = sorted(extra + [l for l in got if l not in want])
        row("partitioned", f"{e['dir']}: partition set", f"exactly {len(want)} (from current ABI)",
            "equal" if not (missing or extra) else f"missing {missing} extra {extra}", not (missing or extra))
        prof = e["profile"] + ("-fail" if e["expect"] == "FAIL" else "")
        parts, probs = {}, []
        for l in sorted(set(got) & want):
            t = read(got[l])
            r = part_result(t, check)
            parts[l] = (r, "Counterexample" in t)
            pr = validate(t, part_want(contract, check, e["abi"], l, sels[l], prof), fam, checks=[check])
            ep = exit_ok(t, r)
            if ep:
                pr.append(ep)
            probs += [f"{l}: {x}" for x in pr]
        row("binding", e["dir"], f"{len(parts)} logs: meta/argv/contract/binding/exit ({prof})",
            "all bound, fresh, dirty_src=0, argv/label/selector match" if not probs else "; ".join(probs[:3]) +
            (f" (+{len(probs) - 3} more)" if len(probs) > 3 else ""), not probs and bool(parts))
        n = len(parts)
        fparts = set(e["expect_fail_parts"])
        bounded = [l for l, (r, _) in parts.items() if r in ("TIMEOUT", "TIMEOUT-WALL")]
        bad_bounded = [l for l in bounded if l not in allow]
        fails = [l for l, (r, _) in parts.items() if r == "FAIL" and l not in fparts]
        other = [l for l, (r, _) in parts.items() if r not in ("PASS", "FAIL", "TIMEOUT", "TIMEOUT-WALL")]
        disc_bad = [l for l in fparts if l in parts and not (parts[l][0] == "FAIL" and parts[l][1])]
        if e["expect"] == "PASS":
            ok = n > 0 and not fails and not other and not bad_bounded and not disc_bad
            npass = sum(r == "PASS" for r, _ in parts.values())
            actual = f"PASS ({n}/{n})" if npass == n and not fparts else f"{npass}/{n} PASS" + \
                (f"; BOUNDED {','.join(bounded)}" if bounded else "") + \
                (f"; DISCREPANCY-FAIL {','.join(sorted(fparts & set(parts)))}" if fparts else "") + \
                (f"; FAIL {','.join(fails)}" if fails else "") + (f"; ABORTED/ERROR/LOOP {','.join(f'{l}={parts[l][0]}' for l in other)}" if other else "") + \
                (f"; discrepancy part not FAIL+cex: {disc_bad}" if disc_bad else "")
        else:
            cex_fail = [l for l, (r, c) in parts.items() if r == "FAIL" and c]
            ok = bool(cex_fail) and not other
            actual = f"FAIL+cex in {','.join(cex_fail)}" if cex_fail else \
                ("BOUNDED " + ",".join(bounded) if bounded else "no counterexample (vacuous?)")
        row("partitioned", e["dir"], e["expect"] + (" (ceiling: " + ",".join(e["bounded_ceiling"]) + ")" if e["bounded_ceiling"] else ""),
            actual, ok)
        for l in sorted(parts):
            tw = teardown_walled(read(got[l]))
            if tw and parts[l][0] in ("PASS", "FAIL"):
                row("  teardown", f"{e['dir']}:{l}", "result inside the cap",
                    f"{parts[l][0]} printed, halmos total {tw[0]:.1f} s < cap {tw[1]} s; process killed during shutdown", True)
        for l in bounded:
            if l in allow:
                row("  bounded", f"{e['dir']}:{l}", "BOUNDED (allowed)",
                    f"{parts[l][0]} — {allow[l]['reason']}; substitute: {allow[l]['substitute']}", True)
        for l in sorted(fparts & set(parts)):
            row("  discrepancy", f"{e['dir']}:{l}", "FAIL+cex (documented spec-vs-code discrepancy)",
                f"{parts[l][0]}{'+cex' if parts[l][1] else ''} — {disc.get(l, '(no note)')}", parts[l][0] == "FAIL" and parts[l][1])


def diffed_src_sha(fam, diff_path):
    """tree_sha of (current source set of `fam` + the unified diff), computed in a temp copy."""
    if not os.path.exists(diff_path):
        return None
    tmp = tempfile.mkdtemp(prefix="d5c1-verify-")
    try:
        files = B.src_list(fam, TREE)
        for f in files:
            os.makedirs(os.path.join(tmp, os.path.dirname(f)), exist_ok=True)
            shutil.copyfile(os.path.join(TREE, f), os.path.join(tmp, f))
        r = subprocess.run(["patch", "-s", "-p1", "-d", tmp, "-i", os.path.abspath(diff_path)], capture_output=True)
        if r.returncode != 0:
            return None
        return B.tree_sha(files, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def restored_row(kind, item, fam, restored_json):
    c = cur(fam)
    rj = json.load(open(restored_json)) if os.path.exists(restored_json) else None
    bad = ["missing"] if rj is None else [k for k in BOUND_KEYS if rj.get(k) != c[k]] + (["out_stale"] if rj.get("out_stale") else [])
    row(kind, f"{item} restored tree", "src/lib/harness/bytecode == current", "equal" if not bad else f"differs: {bad}", not bad)


def restore_row(kind, mid, ap, rv_text):
    a = re.search(r"applied \S+ to (\S+) \(pristine sha256 ([0-9a-f]{64})", ap)
    r = re.search(r"reverted " + re.escape(mid) + r": \S+ sha256 ([0-9a-f]{64})", rv_text)
    now = sha_file(os.path.join(TREE, a.group(1))) if a else None
    ok = bool(a and r and a.group(2) == r.group(1) == now)
    row(kind, f"{mid} source restored", "pristine == reverted == current file",
        (r.group(1)[:12] if r else "no revert line") + ("" if ok else f" (pristine {a.group(2)[:12] if a else '?'}, current {str(now)[:12]})"), ok)


def check_mutations(root, req, mroot=None):
    mroot = mroot or os.path.join(root, "mutations")
    for m in req.get("mutations", []):
        md = os.path.join(mroot, m["id"])
        fam = m.get("family", "xpnts")
        if not os.path.isdir(md):
            row("mutation", m["id"], "killed", "MISSING", False)
            continue
        want_src = diffed_src_sha(fam, os.path.join(md, f"{m['id']}.diff"))
        mj = json.load(open(os.path.join(md, "binding-mutated.json"))) if os.path.exists(os.path.join(md, "binding-mutated.json")) else None
        probs = []
        if want_src is None:
            probs.append("diff missing or does not apply to the current source set")
        elif want_src == cur(fam)["src_sha"]:
            probs.append("diff is a no-op")
        if mj is None:
            probs.append("binding-mutated.json missing")
        else:
            if mj.get("src_sha") != want_src:
                probs.append("binding-mutated.json src_sha != current src + diff")
            if mj.get("bytecode_sha") == cur(fam)["bytecode_sha"]:
                probs.append("mutated bytecode_sha equals the pristine one (mutation not compiled)")
            if mj.get("out_stale"):
                probs.append(f"mutated out/ is not the build of the mutated source: {mj['out_stale'][:2]}")
            for k in ("lib_sha", "harness_sha"):
                if mj.get(k) != cur(fam)[k]:
                    probs.append(f"binding-mutated.json {k} != current")
        arts = (mj or {}).get("harness_artifacts") or {}
        by_log = {}
        for h in m.get("halmos_logs", []):
            by_log.setdefault(h["log"], []).append(h)
        for log, hs in by_log.items():
            t = read(os.path.join(md, log))
            prof = ("cap1" if fam == "apnts" else "xp") + "-fail"
            want = {"runner": "run-d5c1", "contract": hs[0]["contract"], "profile": prof,
                    "argv": B.halmos_argv(hs[0]["contract"], prof, match_test=hs[0].get("match_test")),
                    "wall_cap_s": B.WALL_CAP_S}
            probs += [f"{log}: {x}" for x in validate(t, want, fam, arts, want_src, want_bc=(mj or {}).get("bytecode_sha"))] if t else [f"{log}: missing"]
            for h in hs:
                r = part_result(t, h["check"]) if t else "MISSING"
                row("mutation", f"{m['id']} halmos {h['check']}", "FAIL+cex", r, r == "FAIL" and "Counterexample" in t)
        for grp, want_red in (("halmos_parts", True), ("green_parts", False)):
            for h in m.get(grp, []):
                contract, check = h["dir"].split(".", 1)
                got, extra = part_logs(os.path.join(md, h["dir"]), check)
                got = got or {}
                want = set(h["labels"])
                missing = sorted(want - set(got))
                extra = sorted(extra + [l for l in got if l not in want])
                try:
                    sels = {l: p for p, l in B.partition_specs(ABI_OF[h["abi"]], os.path.join(md, "abi-out"))} \
                        if os.path.isdir(os.path.join(md, "abi-out")) else label_selectors(h["abi"])
                except Exception:  # noqa: BLE001
                    sels = {}
                hit = []
                prof = "xp-fail" if want_red else "xp"
                for l in sorted(set(got) & want):
                    t = read(got[l])
                    r = part_result(t, check)
                    pr = validate(t, part_want(contract, check, h["abi"], l, sels.get(l), prof), fam, arts, want_src, [check],
                                  want_bc=(mj or {}).get("bytecode_sha"))
                    ep = exit_ok(t, r)
                    probs += [f"{h['dir']}/{l}: {x}" for x in pr + ([ep] if ep else [])]
                    if (want_red and r == "FAIL" and "Counterexample" in t) or (not want_red and r == "PASS"):
                        hit.append(l)
                ok = not missing and not extra and len(hit) == len(want)
                row("mutation", f"{m['id']} halmos {h['dir']}:{','.join(sorted(want))}",
                    "exactly these parts, all FAIL+cex" if want_red else "exactly these parts, still PASS (independence)",
                    f"{'red' if want_red else 'green'} {hit}" + (f"; missing {missing}" if missing else "") +
                    (f"; extra {extra}" if extra else ""), ok)
        st = read(os.path.join(md, "scenario.log"))
        red = re.search(r"^\[FAIL: (.*)\] " + re.escape(m["scenario_test"]) + r"\(", st, re.M)
        ok = bool(red) and m["scenario_msg"] in red.group(1)
        row("mutation", f"{m['id']} scenario {m['scenario_test']}", f"red ({m['scenario_msg']})",
            red.group(1) if red else "green / missing", ok)
        b = binding_of(st)
        if b is None or b.get("src_sha") != want_src:
            probs.append("scenario.log: not bound to current src + diff")
        row("mutation", f"{m['id']} binding (mutated)", "logs bound to current src + diff, mutated harness build",
            "ok" if not probs else "; ".join(probs[:3]) + (f" (+{len(probs) - 3} more)" if len(probs) > 3 else ""), not probs)
        restored_row("mutation", m["id"], fam, os.path.join(md, "binding-restored.json"))
        restore_row("mutation", m["id"], read(os.path.join(md, "apply.txt")), read(os.path.join(md, "summary.txt")))


def check_fuzz(root, req, fdir=None):
    fz = req.get("fuzz_liveness")
    if not fz:
        return
    fdir = fdir or os.path.join(root, "fuzz-liveness")
    t = read(os.path.join(root, fz["unmutated_log"]))
    bp = bind_problem(t, "xpnts") if t else "MISSING"
    row("binding", fz["unmutated_log"], "bound to current tree (xpnts)", bp or "bound, fresh, dirty_src=0", bp is None)
    for tn in fz["unmutated_tests"]:
        ok = re.search(r"\[PASS\] " + re.escape(tn) + r"\(.*runs: (\d+)", t)
        row("fuzz", f"unmutated {tn}", "PASS (>=10000 runs)", f"PASS runs={ok.group(1)}" if ok else "not green",
            bool(ok) and int(ok.group(1)) >= 10000)
    for m in fz["mutations"]:
        lt = read(os.path.join(fdir, f"{m['id']}.fuzz.log"))
        for tn in m["must_fail"]:
            red = re.search(r"^\[FAIL: .*\] " + re.escape(tn) + r"\(", lt, re.M)
            row("fuzz", f"{m['id']} reddens {tn}", "red", "red" if red else "green / missing", bool(red))
        want_src = diffed_src_sha("xpnts", os.path.join(fdir, f"{m['id']}.diff"))
        b = binding_of(lt)
        probs = []
        if want_src is None:
            probs.append("diff missing or does not apply")
        elif want_src == cur("xpnts")["src_sha"]:
            probs.append("diff is a no-op")
        if b is None:
            probs.append("UNBOUND")
        elif b.get("src_sha") != want_src:
            probs.append("src_sha != current src + diff (stale)")
        elif any(b.get(k) != cur("xpnts")[k] for k in ("lib_sha", "harness_sha")):
            probs.append("lib/harness stale")
        row("fuzz", f"{m['id']} binding (mutated)", "log bound to current src + diff", "ok" if not probs else "; ".join(probs), not probs)
        restored_row("fuzz", m["id"], "xpnts", os.path.join(fdir, f"{m['id']}.restored.json"))
        restore_row("fuzz", m["id"], read(os.path.join(fdir, f"{m['id']}.apply.txt")), lt)


SCRIPTS = ("verify-d5c1.py", "verify-selftest.py", "d5c1_binding.py")


def check_archives(root, req):
    doc = read(os.path.join(TREE, DOC))
    for a in req.get("archives", []):
        t = read(os.path.join(root, a["file"]))
        k = a["kind"]
        if not t:
            row("archive", a["file"], k, "MISSING", False)
            continue
        if k == "artifact-parity":
            passes = re.findall(r"^# pass (\d): (.*)$", t, re.M)
            oks = re.findall(r"^RESULT: (OK|MISMATCH)$", t, re.M)
            probs = [] if [p for p, _ in passes] == ["1", "2"] and oks == ["OK", "OK"] else \
                [f"passes {[p for p, _ in passes]} results {oks} (want two passes, both OK)"]
            for fam in ("xpnts", "apnts"):
                bl = [json.loads(x) for x in BIND.findall(t) if json.loads(x).get("family") == fam]
                if not bl:
                    probs.append(f"no {fam} binding")
                    continue
                bp = bind_problem("# binding: " + json.dumps(bl[-1]), fam)
                if bp:
                    probs.append(f"{fam}: {bp}")
                if bl[-1].get("harness_artifacts") != cur_arts():
                    probs.append(f"{fam}: harness artifacts differ from the current build")
            row("archive", a["file"], "two passes RESULT: OK, bound to the current tree + harness build",
                "; ".join(probs) or f"2/2 OK ({'; '.join(d for _, d in passes)})", not probs)
        elif k == "selftest":
            sm = re.search(r"^# scripts: (\{.*\})$", t, re.M)
            got = json.loads(sm.group(1)) if sm else {}
            now = {s: sha_file(os.path.join(HERE, s)) for s in SCRIPTS}
            fin = re.search(r"^SELFTEST: all (\d+) controls behave$", t, re.M)
            nok = len(re.findall(r"^ok  ", t, re.M))
            nfail = len(re.findall(r"^FAIL  ", t, re.M))
            probs = []
            if got != now:
                probs.append("tested scripts differ from the current ones: " + ",".join(s for s in SCRIPTS if got.get(s) != now[s]))
            if not fin or int(fin.group(1)) != nok or nfail:
                probs.append(f"final line {fin.group(0) if fin else None!r}, ok-lines {nok}, FAIL-lines {nfail}")
            elif nok < a["min_controls"]:
                probs.append(f"{nok} controls < mandatory {a['min_controls']}")
            dm = re.search(r"判定器自己的对照[^\n]*?共 (\d+) 个", doc)
            if fin and (not dm or int(dm.group(1)) != nok):
                probs.append(f"{DOC} quotes {dm.group(1) if dm else 'no'} controls, the log has {nok}")
            row("archive", a["file"], "self-test of THESE scripts, all controls behave, count quoted in the report",
                "; ".join(probs) or f"{nok}/{nok} controls behave", not probs)
        elif k == "forge-suite":
            probs = []
            bp = bind_problem(t, "xpnts")
            if bp:
                probs.append(bp)
            if re.search(r"^\[FAIL", t, re.M) or not re.search(r"\d+ tests passed, 0 failed", t):
                probs.append("not all green")
            miss = [x for x in a["tests"] if not re.search(r"^\[PASS\] " + re.escape(x) + r"\(", t, re.M)]
            if miss:
                probs.append(f"missing / not green: {miss}")
            tot = re.findall(r"Ran \d+ test suites[^\n]*?(\d+) tests passed, (\d+) failed", t)
            row("archive", a["file"], "replay/layout/priming/boundary forge suite green, bound",
                "; ".join(probs) or f"green ({tot[-1][0] if tot else '?'} tests), {len(a['tests'])} named tests present", not probs)
        elif k == "doc-cap1":
            probs = []
            for m in RES.finditer(t):
                letter = re.match(r"check_CAP1_([abc])_", m.group(2))
                if not letter:
                    continue
                tm = re.search(re.escape(m.group(2)) + r"\([^)]*\) \(paths: \d+, time: ([0-9.]+)s", t)
                claim = f"({letter.group(1)}) PASS，{m.group(3)} 条路径，{tm.group(1)} s"
                if claim not in doc:
                    probs.append(f"doc lacks '{claim}'")
            row("archive", f"{a['file']} numbers in {os.path.basename(DOC)}", "paths/times quoted = the final log",
                "; ".join(probs) or "equal", not probs)
        else:
            row("archive", a["file"], k, "unknown archive kind", False)


def main():
    global TREE, rows
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.environ.get("D5C1_ROOT", "docs/design/aoa-balance-mode/data/halmos"))
    ap.add_argument("--expect", default=os.environ.get("D5C1_EXPECT", "script/halmos/d5c1-expectations.json"))
    ap.add_argument("--tree", default=os.environ.get("D5C1_TREE_ROOT", "."))
    ap.add_argument("--mutations-dir", default="")
    ap.add_argument("--fuzz-dir", default="")
    ap.add_argument("--filter", default="", help="keep only rows whose item contains one of these comma-separated substrings")
    ap.add_argument("--only", default="suite,logs,partitioned,mutations,fuzz,archives")
    ap.add_argument("--markdown", default="")
    a = ap.parse_args()
    TREE = a.tree
    req, req_src = REQUIRED, "builtin"
    if os.environ.get("D5C1_REQUIRED"):
        req, req_src = json.load(open(os.environ["D5C1_REQUIRED"])), "OVERRIDE " + os.environ["D5C1_REQUIRED"] + " (not a release verdict)"
    req_sha = hashlib.sha256(json.dumps(req, sort_keys=True).encode()).hexdigest()
    exp_sha = sha_file(a.expect)
    ex = json.load(open(a.expect)) if exp_sha else {}
    print(f"mandatory suite: {req_src} sha256 {req_sha}")
    print(f"expectations: {a.expect} sha256 {exp_sha}")
    for fam in ("xpnts", "apnts"):
        c = cur(fam)
        print(f"current tree [{fam}]: src {c['src_sha'][:16]} harness {c['harness_sha'][:16]} "
              f"bytecode {c['bytecode_sha'][:16]} dirty_src {c['dirty_src']} head {c['git_head'][:12]}")
    for fam in ("xpnts", "apnts"):
        st = cur(fam)["out_stale"]
        row("tree", f"out/ [{fam}]", "the build of the current sources (metadata keccak256)",
            "fresh" if not st else f"stale: {st[:3]}", not st)
    sel = set(a.only.split(","))
    if "suite" in sel: check_suite(req, ex)
    if "logs" in sel: check_logs(a.root, req, ex)
    if "partitioned" in sel: check_partitioned(a.root, req, ex)
    if "mutations" in sel: check_mutations(a.root, req, a.mutations_dir or None)
    if "fuzz" in sel: check_fuzz(a.root, req, a.fuzz_dir or None)
    if "archives" in sel: check_archives(a.root, req)
    if a.filter:
        keys = a.filter.split(",")
        rows = [r for r in rows if any(k in r[1] for k in keys)]
        if not rows:
            print("VERDICT: filter matched nothing"); sys.exit(2)
    bad = [r for r in rows if r[4] != "OK"]
    w = [max(len(str(r[i])) for r in rows) for i in range(4)] if rows else [0] * 4
    for r in rows:
        print(f"{r[0]:<12} {r[1]:<{w[1]}}  {r[2]:<{min(w[2], 40)}}  {r[4]:<8}  {r[3]}")
    scope = "" if sel >= {"suite", "logs", "partitioned", "mutations", "fuzz", "archives"} and not a.filter else f" [partial: --only {a.only}{' --filter ' + a.filter if a.filter else ''}]"
    print(f"\nVERDICT: {'ALL EXPECTATIONS MET' if not bad else f'{len(bad)} MISMATCH(ES)'} ({len(rows)} rows){scope}; mandatory suite {req_src}")
    if a.markdown:
        with open(a.markdown, "w") as f:
            f.write(f"mandatory suite sha256 `{req_sha}`; expectations `{a.expect}` sha256 `{exp_sha}`; tree xpnts src "
                    f"`{cur('xpnts')['src_sha'][:16]}` bytecode `{cur('xpnts')['bytecode_sha'][:16]}`, apnts src `{cur('apnts')['src_sha'][:16]}`\n\n")
            f.write("| 类别 | 项 | 期望 | 实际 | 判定 |\n|---|---|---|---|---|\n")
            for r in rows:
                f.write("| " + " | ".join(str(x).replace("|", "\\|") for x in (r[0].strip(), r[1], r[2], r[3], r[4])) + " |\n")
    sys.exit(0 if not bad else 1)


if __name__ == "__main__":
    main()

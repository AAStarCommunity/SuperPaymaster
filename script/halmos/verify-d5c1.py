#!/usr/bin/env python3
"""D5c-1 — the ONLY verdict authority for the Halmos evidence (orchestrators exit with its code).

Reads the expectation table (script/halmos/d5c1-expectations.json; its sha256 is printed and written
into the markdown table) and the evidence under ROOT (default docs/design/aoa-balance-mode/data/halmos)
— never re-runs anything — and checks, against the CURRENT tree (--tree, default the repo root):

  binding       every log carries a `# binding: {json}` trailer (script/halmos/d5c1_binding.py) written
                after its build. For a normal run the trailer's src_sha (source set of the tested
                contracts), harness_sha (contracts/test/halmos + helpers) and bytecode_sha (runtime
                bytecode of the tested contracts in out/) must equal the values recomputed now, and
                dirty_src must be exactly 0. A log without a trailer is UNBOUND, one whose hashes
                differ is STALE — both are mismatches (no grandfathering).
  logs          unpartitioned logs: the set of check results in each log must EQUAL the set of
                checks the table names for it (a missing or an extra check is a mismatch), and each
                matches its expect (PASS; or FAIL WITH a counterexample for witnesses);
  partitioned   the expected partition set is derived from the current build ABI
                (d5c1_binding.partition_labels: OTHER + one label per non-view function of
                xPNTsTokenV2 / xPNTsTokenV2Ext), optionally restricted to the table's `parts` names.
                The set of partition logs in the directory must EQUAL it: a missing or an extra
                partition (including a leftover .retry.log) is a mismatch — exactly one log per
                partition. expect=PASS -> every part PASS, except parts on allow_bounded, which may be
                TIMEOUT / TIMEOUT-WALL (reported BOUNDED with reason + substitute). An allow_bounded key
                that is not a currently expected partition is itself a mismatch. expect=FAIL -> at
                least one part FAIL with a counterexample, no ERROR / aborted part;
  mutations     per mutation: the partition logs of each named check equal its `labels` exactly and
                every one FAILs with a counterexample; unpartitioned logs name the check red; the forge
                scenario test fails with the named message. Binding: every mutation log's src_sha
                equals binding-mutated.json, which equals (current source set + the recorded diff)
                and differs from the current tree; harness_sha equals the current one;
                binding-restored.json equals the current tree (src_sha AND bytecode_sha); apply.txt's
                pristine file sha256 is the current file's sha256 and the revert line restores it;
  fuzz_liveness the unmutated fuzz log (a normal, bound, clean-tree run) is all green with every listed
                test present at >= 10,000 runs; every mutation reddens each must_fail test, its log is
                bound to (current source set + diff), and <m>.restored.json equals the current tree.

Prints one row per item: kind, item, expected, verdict, actual. Exit 0 iff every row is OK.
usage: python3 script/halmos/verify-d5c1.py [--root DIR] [--expect FILE] [--tree DIR]
                                            [--only logs,partitioned,mutations,fuzz] [--filter a,b]
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

RES = re.compile(r"\[(PASS|FAIL|TIMEOUT|ERROR)\]\S*\s*(check_\w+)\([^)]*\) \(paths: (\d+)")
BIND = re.compile(r"^# binding: (\{.*\})\s*$", re.M)
ABI_OF = {"core": "xPNTsTokenV2", "ext": "xPNTsTokenV2Ext"}
TREE = "."
_cur = {}


def cur(fam):
    if fam not in _cur:
        _cur[fam] = B.binding(fam, TREE)
    return _cur[fam]


def read(p):
    return open(p, errors="replace").read() if os.path.exists(p) else ""


def binding_of(text):
    ms = BIND.findall(text)
    return json.loads(ms[-1]) if ms else None


BOUND_KEYS = ("src_sha", "lib_sha", "harness_sha", "bytecode_sha")


def bind_problem(text, fam):
    """None if the log is bound to the current, clean tree; else a short reason.
    The LAST `# binding:` line (the trailer, written after the run's build) is authoritative; any
    earlier one (the header, written before the run) must agree with it on src/lib/harness, i.e.
    the source did not change while the run was in progress."""
    bs = [json.loads(m) for m in BIND.findall(text)]
    if not bs:
        return "UNBOUND (no # binding: trailer)"
    b = bs[-1]
    drift = [k for k in ("src_sha", "lib_sha", "harness_sha") if any(x.get(k) != b.get(k) for x in bs[:-1])]
    if drift:
        return "DRIFT (header and trailer bindings differ on " + ",".join(drift) + ")"
    c = cur(fam)
    bad = [k for k in BOUND_KEYS if b.get(k) != c[k]]
    if b.get("family") != fam:
        bad.insert(0, "family")
    if bad:
        files = sorted(p for p in set(b.get("src_files", {})) | set(c["src_files"])
                       if b.get("src_files", {}).get(p) != c["src_files"].get(p))
        return "STALE (" + ",".join(bad) + " differ from the current tree" + \
            (f"; files: {','.join(os.path.basename(f) for f in files[:4])}" if files else "") + ")"
    if b.get("out_stale"):
        return f"STALE-BUILD (the run's out/ was not the build of its sources: {b['out_stale'][:2]})"
    if b.get("dirty_src") != 0:
        return f"DIRTY (dirty_src={b.get('dirty_src')})"
    return None


def results_in(text):
    out = {}
    for m in RES.finditer(text):
        out.setdefault(m.group(2), []).append(m.group(1))
    return out


WALL = re.compile(r"^# WALL-CAP: killed after (\d+) s", re.M)
TOTAL = re.compile(r"^\[time\] total: ([0-9.]+)s", re.M)


def teardown_walled(text):
    """(total_s, cap_s) when halmos finished the test (result line + 'Symbolic test result' + its
    '[time] total' below the cap) but the process was killed by the wall cap while shutting down;
    else None."""
    w, t = WALL.search(text), TOTAL.search(text)
    if w and t and "Symbolic test result:" in text and float(t.group(1)) < int(w.group(1)):
        return float(t.group(1)), int(w.group(1))
    return None


def part_result(text, check):
    r = results_in(text).get(check)
    if r is None:
        return "TIMEOUT-WALL" if "# WALL-CAP:" in text else "ABORTED"
    if "# WALL-CAP:" in text and not teardown_walled(text):
        return "TIMEOUT-WALL"   # a result line without a completed run inside the cap does not count
    return r[-1] if len(r) == 1 else "DUPLICATE-RESULT"


def expected_labels(abi, parts=None):
    labels = B.partition_labels(ABI_OF[abi], os.path.join(TREE, "out"))
    if parts:
        labels = [l for l in labels if l in parts or l.split("-")[0] in parts]
    return set(labels)


def part_logs(d, check):
    """label -> path for `<check>.<label>.log`; any other log file in d is returned as extra."""
    got, extra = {}, []
    if not os.path.isdir(d):
        return None, []
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".log"):
            continue
        if not fn.startswith(check + ".") or fn.endswith(".retry.log"):
            extra.append(fn)
            continue
        got[fn[len(check) + 1:-4]] = os.path.join(d, fn)
    return got, extra


rows = []


def row(kind, item, expected, actual, ok):
    rows.append((kind, item, expected, actual, "OK" if ok else "MISMATCH"))


def check_logs(root, ex):
    by_log = {}
    for e in ex.get("logs", []):
        by_log.setdefault(e["log"], []).append(e)
    for log, es in by_log.items():
        p = os.path.join(root, log)
        t = read(p)
        if not t:
            row("log", log, "present", "MISSING", False)
            continue
        fam = es[0]["family"]
        bp = bind_problem(t, fam)
        row("binding", log, f"bound to current tree ({fam})", bp or "bound, fresh, dirty_src=0", bp is None)
        res = results_in(t)
        want = {e["check"] for e in es}
        extra = sorted(set(res) - want)
        missing = sorted(want - set(res))
        row("log", f"{log}: check set", f"exactly {len(want)} checks", "equal" if not (extra or missing) else
            f"missing {missing} extra {extra}", not (extra or missing))
        for e in es:
            r = res.get(e["check"], ["NO-RESULT"])
            r = r[0] if len(r) == 1 else "DUPLICATE-RESULT"
            ok = r == e["expect"] and (e["expect"] != "FAIL" or "Counterexample" in t)
            row("log", f"{log}:{e['check']}", e["expect"], r, ok)


def check_partitioned(root, ex):
    for e in ex.get("partitioned", []):
        d = os.path.join(root, e["dir"])
        check = e["dir"].split(".", 1)[1]
        fam = B.family_of(e["dir"])
        try:
            want = expected_labels(e["abi"], e.get("parts"))
        except Exception as err:  # noqa: BLE001
            row("partitioned", e["dir"], "expected set from ABI", f"cannot derive: {err}", False)
            continue
        allow = e.get("allow_bounded", {})
        if allow and e["expect"] != "PASS":
            row("partitioned", f"{e['dir']}: allow_bounded", "none on a FAIL expectation",
                "a witness / negative control must produce a counterexample; allow_bounded is not permitted", False)
        ghost = sorted(set(allow) - want)
        if ghost:
            row("partitioned", f"{e['dir']}: allow_bounded", "keys ⊆ expected partitions",
                f"not an expected partition: {ghost}", False)
        got, extra = part_logs(d, check)
        if got is None:
            row("partitioned", e["dir"], e["expect"], "MISSING", False)
            continue
        missing = sorted(want - set(got))
        extra = sorted(extra + [l for l in got if l not in want])
        row("partitioned", f"{e['dir']}: partition set", f"exactly {len(want)} (from current ABI)",
            "equal" if not (missing or extra) else f"missing {missing} extra {extra}", not (missing or extra))
        parts = {}
        unbound = []
        for l in sorted(set(got) & want):
            t = read(got[l])
            parts[l] = (part_result(t, check), "Counterexample" in t)
            bp = bind_problem(t, fam)
            if bp:
                unbound.append(f"{l}: {bp}")
        row("binding", e["dir"], f"{len(parts)} logs bound to current tree",
            "all bound, fresh, dirty_src=0" if not unbound else "; ".join(unbound[:3]) +
            (f" (+{len(unbound) - 3} more)" if len(unbound) > 3 else ""), not unbound and bool(parts))
        n = len(parts)
        bounded = [l for l, (r, _) in parts.items() if r in ("TIMEOUT", "TIMEOUT-WALL")]
        bad_bounded = [l for l in bounded if l not in allow]
        fails = [l for l, (r, _) in parts.items() if r == "FAIL"]
        other = [l for l, (r, _) in parts.items() if r not in ("PASS", "FAIL", "TIMEOUT", "TIMEOUT-WALL")]
        if e["expect"] == "PASS":
            ok = n > 0 and not fails and not other and not bad_bounded
            actual = "PASS" if not bounded and not fails and not other else \
                f"{n - len(bounded) - len(fails) - len(other)}/{n} PASS" + \
                (f"; BOUNDED {','.join(bounded)}" if bounded else "") + \
                (f"; FAIL {','.join(fails)}" if fails else "") + (f"; ABORTED/ERROR {','.join(other)}" if other else "")
            if actual == "PASS":
                actual = f"PASS ({n}/{n})"
        else:  # expect FAIL (witness / negative control): a real counterexample somewhere
            cex_fail = [l for l, (r, c) in parts.items() if r == "FAIL" and c]
            ok = bool(cex_fail) and not other
            actual = f"FAIL+cex in {','.join(cex_fail)}" if cex_fail else \
                ("BOUNDED " + ",".join(bounded) if bounded else "no counterexample (vacuous?)")
        row("partitioned", e["dir"], e["expect"] + (" (allow-list: " + ",".join(sorted(allow)) + ")" if allow else ""), actual, ok)
        for l in sorted(parts):
            tw = teardown_walled(read(got[l]))
            if tw and parts[l][0] in ("PASS", "FAIL"):
                row("  teardown", f"{e['dir']}:{l}", "result inside the cap",
                    f"{parts[l][0]} printed, halmos total {tw[0]:.1f} s < cap {tw[1]} s; process killed during shutdown", True)
        for l in bounded:
            if l in allow:
                row("  bounded", f"{e['dir']}:{l}", "BOUNDED (allowed)",
                    f"{parts[l][0]} — {allow[l]['reason']}; substitute: {allow[l]['substitute']}", True)


def sha_file(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.exists(p) else None


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
        r = subprocess.run(["patch", "-s", "-p1", "-d", tmp, "-i", os.path.abspath(diff_path)],
                           capture_output=True)
        if r.returncode != 0:
            return None
        return B.tree_sha(files, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def mutation_bind_rows(kind, item, fam, logs, mutated_json, restored_json, diff_path):
    """logs: list of (name, text) produced on the mutated tree."""
    c = cur(fam)
    want_mut = diffed_src_sha(fam, diff_path)
    mj = json.load(open(mutated_json)) if mutated_json and os.path.exists(mutated_json) else None
    probs = []
    if want_mut is None:
        probs.append("diff missing or does not apply to the current source set")
    elif want_mut == c["src_sha"]:
        probs.append("diff is a no-op")
    if mutated_json is not None:
        if mj is None:
            probs.append("binding-mutated.json missing")
        elif mj.get("src_sha") != want_mut:
            probs.append("binding-mutated.json src_sha != current src + diff")
        elif mj.get("bytecode_sha") == c["bytecode_sha"]:
            probs.append("mutated bytecode_sha equals the pristine one (mutation not compiled)")
        elif mj.get("out_stale"):
            probs.append(f"mutated out/ is not the build of the mutated source: {mj['out_stale'][:2]}")
        for k in ("lib_sha", "harness_sha"):
            if mj is not None and mj.get(k) != c[k]:
                probs.append(f"binding-mutated.json {k} != current")
    for name, t in logs:
        b = binding_of(t)
        if b is None:
            probs.append(f"{name}: UNBOUND")
            continue
        if b.get("src_sha") != want_mut:
            probs.append(f"{name}: src_sha != current src + diff (stale)")
        for k in ("harness_sha", "lib_sha"):
            if b.get(k) != c[k]:
                probs.append(f"{name}: {k} stale")
        if mj is not None and b.get("bytecode_sha") != mj.get("bytecode_sha"):
            probs.append(f"{name}: bytecode_sha != binding-mutated.json")
    row(kind, f"{item} binding (mutated)", "logs bound to current src + diff", "ok" if not probs else "; ".join(probs[:3]), not probs)
    rj = json.load(open(restored_json)) if os.path.exists(restored_json) else None
    bad = ["missing"] if rj is None else [k for k in BOUND_KEYS if rj.get(k) != c[k]] + (["out_stale"] if rj.get("out_stale") else [])
    row(kind, f"{item} restored tree", "src/lib/harness/bytecode == current", "equal" if not bad else f"differs: {bad}", not bad)


def check_mutations(root, ex, mroot=None):
    mroot = mroot or os.path.join(root, "mutations")
    for m in ex.get("mutations", []):
        md = os.path.join(mroot, m["id"])
        fam = m.get("family", "xpnts")
        if not os.path.isdir(md):
            row("mutation", m["id"], "killed", "MISSING", False)
            continue
        logs = []
        for h in m.get("halmos_logs", []):
            t = read(os.path.join(md, h["log"]))
            logs.append((h["log"], t))
            r = results_in(t).get(h["check"], ["NO-RESULT"])[-1]
            row("mutation", f"{m['id']} halmos {h['check']}", "FAIL+cex", r, r == "FAIL" and "Counterexample" in t)
        for h in m.get("halmos_parts", []):
            check = h["dir"].split(".", 1)[1]
            got, extra = part_logs(os.path.join(md, h["dir"]), check)
            got = got or {}
            want = set(h["labels"])
            missing = sorted(want - set(got))
            extra = sorted(extra + [l for l in got if l not in want])
            red = []
            for l in sorted(set(got) & want):
                t = read(got[l])
                logs.append((f"{h['dir']}/{l}", t))
                if part_result(t, check) == "FAIL" and "Counterexample" in t:
                    red.append(l)
            ok = not missing and not extra and len(red) == len(want)
            row("mutation", f"{m['id']} halmos {h['dir']}:{','.join(sorted(want))}", "exactly these parts, all FAIL+cex",
                f"red {red}" + (f"; missing {missing}" if missing else "") + (f"; extra {extra}" if extra else ""), ok)
        st = read(os.path.join(md, "scenario.log"))
        logs.append(("scenario.log", st))
        red = re.search(r"^\[FAIL: (.*)\] " + re.escape(m["scenario_test"]) + r"\(", st, re.M)
        ok = bool(red) and m["scenario_msg"] in red.group(1)
        row("mutation", f"{m['id']} scenario {m['scenario_test']}", f"red ({m['scenario_msg']})",
            red.group(1) if red else "green / missing", ok)
        mutation_bind_rows("mutation", m["id"], fam, logs, os.path.join(md, "binding-mutated.json"),
                           os.path.join(md, "binding-restored.json"), os.path.join(md, f"{m['id']}.diff"))
        restore_row("mutation", m["id"], read(os.path.join(md, "apply.txt")), read(os.path.join(md, "summary.txt")))


def restore_row(kind, mid, ap, rv_text):
    a = re.search(r"applied \S+ to (\S+) \(pristine sha256 ([0-9a-f]{64})", ap)
    r = re.search(r"reverted " + re.escape(mid) + r": \S+ sha256 ([0-9a-f]{64})", rv_text)
    now = sha_file(os.path.join(TREE, a.group(1))) if a else None
    ok = bool(a and r and a.group(2) == r.group(1) == now)
    row(kind, f"{mid} source restored", "pristine == reverted == current file",
        (r.group(1)[:12] if r else "no revert line") + ("" if ok else f" (pristine {a.group(2)[:12] if a else '?'}, current {str(now)[:12]})"), ok)


def check_fuzz(root, ex, fdir=None):
    fz = ex.get("fuzz_liveness")
    if not fz:
        return
    fdir = fdir or os.path.join(root, "fuzz-liveness")
    p = os.path.join(root, fz["unmutated_log"])
    t = read(p)
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
        mutation_bind_rows("fuzz", m["id"], "xpnts", [(f"{m['id']}.fuzz.log", lt)], None,
                           os.path.join(fdir, f"{m['id']}.restored.json"), os.path.join(fdir, f"{m['id']}.diff"))
        restore_row("fuzz", m["id"], read(os.path.join(fdir, f"{m['id']}.apply.txt")), lt)


def main():
    global TREE, rows
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.environ.get("D5C1_ROOT", "docs/design/aoa-balance-mode/data/halmos"))
    ap.add_argument("--expect", default=os.environ.get("D5C1_EXPECT", "script/halmos/d5c1-expectations.json"))
    ap.add_argument("--tree", default=os.environ.get("D5C1_TREE_ROOT", "."))
    ap.add_argument("--mutations-dir", default="")
    ap.add_argument("--fuzz-dir", default="")
    ap.add_argument("--filter", default="", help="keep only rows whose item contains one of these comma-separated substrings")
    ap.add_argument("--only", default="logs,partitioned,mutations,fuzz")
    ap.add_argument("--markdown", default="")
    a = ap.parse_args()
    TREE = a.tree
    exp_sha = sha_file(a.expect)
    ex = json.load(open(a.expect))
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
    if "logs" in sel: check_logs(a.root, ex)
    if "partitioned" in sel: check_partitioned(a.root, ex)
    if "mutations" in sel: check_mutations(a.root, ex, a.mutations_dir or None)
    if "fuzz" in sel: check_fuzz(a.root, ex, a.fuzz_dir or None)
    if a.filter:
        keys = a.filter.split(",")
        rows = [r for r in rows if any(k in r[1] for k in keys)]
        if not rows:
            print("VERDICT: filter matched nothing"); sys.exit(2)
    bad = [r for r in rows if r[4] != "OK"]
    w = [max(len(str(r[i])) for r in rows) for i in range(4)] if rows else [0] * 4
    for r in rows:
        print(f"{r[0]:<12} {r[1]:<{w[1]}}  {r[2]:<{min(w[2], 40)}}  {r[4]:<8}  {r[3]}")
    print(f"\nVERDICT: {'ALL EXPECTATIONS MET' if not bad else f'{len(bad)} MISMATCH(ES)'} ({len(rows)} rows)")
    if a.markdown:
        with open(a.markdown, "w") as f:
            f.write(f"expectations `{a.expect}` sha256 `{exp_sha}`; tree xpnts src `{cur('xpnts')['src_sha'][:16]}` "
                    f"bytecode `{cur('xpnts')['bytecode_sha'][:16]}`, apnts src `{cur('apnts')['src_sha'][:16]}`\n\n")
            f.write("| 类别 | 项 | 期望 | 实际 | 判定 |\n|---|---|---|---|---|\n")
            for r in rows:
                f.write("| " + " | ".join(str(x).replace("|", "\\|") for x in (r[0].strip(), r[1], r[2], r[3], r[4])) + " |\n")
    sys.exit(0 if not bad else 1)


if __name__ == "__main__":
    main()

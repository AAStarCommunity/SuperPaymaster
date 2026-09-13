#!/usr/bin/env python3
"""D5c-1 — the ONLY verdict authority for the Halmos evidence (orchestrators exit with its code).

Reads the expectation table (script/halmos/d5c1-expectations.json) and the evidence under ROOT
(default docs/design/aoa-balance-mode/data/halmos) — never re-runs anything — and checks:

  logs          each named check's result line in an unpartitioned log matches expect
                (PASS; or FAIL WITH a counterexample for witnesses / negative controls);
  partitioned   every partition log of a check directory is parsed again from the log itself (the
                summary file is not trusted): expect=PASS -> every part PASS, except parts on that
                check's allow_bounded list, which may be TIMEOUT / TIMEOUT-WALL (reported BOUNDED with
                reason + substitute); any FAIL / ERROR / aborted part, or fewer parts than min_parts,
                is a mismatch. expect=FAIL -> at least one part FAIL with a counterexample, and no
                part may be un-allowed TIMEOUT that could hide the result;
  mutations     for each mutation: every named Halmos check / partition FAILs with a counterexample,
                the named forge scenario test fails with the named message, and the source file was
                restored to the pristine sha256 (apply.txt vs the revert line);
  fuzz_liveness the unmutated fuzz log is all green with every listed test present, and every
                mutation reddens each of its must_fail tests.

Prints one table row per item: kind, item, expected, actual, verdict. Exit 0 iff every row is OK.
usage: python3 script/halmos/verify-d5c1.py [--root DIR] [--expect FILE] [--only logs,partitioned,mutations,fuzz]
"""
import argparse
import json
import os
import re
import sys

RES = re.compile(r"\[(PASS|FAIL|TIMEOUT|ERROR)\]\S*\s*(check_\w+)\([^)]*\) \(paths: (\d+)")


def results_in(text):
    """check name -> (result, has_counterexample_before_it)"""
    out = {}
    for m in RES.finditer(text):
        out[m.group(2)] = m.group(1)
    return out


def part_result(path, check):
    t = open(path, errors="replace").read()
    r = results_in(t).get(check)
    if r is None:
        r = "TIMEOUT-WALL" if "# WALL-CAP:" in t else "ABORTED"
    return r, ("Counterexample" in t)


def partitions(d, check):
    """label -> (result, cex, logname); a .retry.log supersedes the first attempt."""
    out = {}
    if not os.path.isdir(d):
        return None
    for fn in sorted(os.listdir(d)):
        if not (fn.startswith(check + ".") and fn.endswith(".log")):
            continue
        label = fn[len(check) + 1:-4]
        retry = label.endswith(".retry")
        label = label[:-6] if retry else label
        r = part_result(os.path.join(d, fn), check)
        if retry or label not in out:
            out[label] = (r[0], r[1], fn)
    return out


rows = []


def row(kind, item, expected, actual, ok):
    rows.append((kind, item, expected, actual, "OK" if ok else "MISMATCH"))


def check_logs(root, ex):
    for e in ex.get("logs", []):
        p = os.path.join(root, e["log"])
        if not os.path.exists(p):
            row("log", f"{e['log']}:{e['check']}", e["expect"], "MISSING", False)
            continue
        t = open(p, errors="replace").read()
        r = results_in(t).get(e["check"], "NO-RESULT")
        ok = r == e["expect"] and (e["expect"] != "FAIL" or "Counterexample" in t)
        row("log", f"{e['log']}:{e['check']}", e["expect"], r, ok)


def check_partitioned(root, ex):
    for e in ex.get("partitioned", []):
        d = os.path.join(root, e["dir"])
        check = e["dir"].split(".", 1)[1]
        parts = partitions(d, check)
        if not parts:
            row("partitioned", e["dir"], e["expect"], "MISSING", False)
            continue
        allow = e.get("allow_bounded", {})
        n = len(parts)
        bounded = [l for l, (r, _, _) in parts.items() if r in ("TIMEOUT", "TIMEOUT-WALL")]
        bad_bounded = [l for l in bounded if l not in allow]
        fails = [l for l, (r, c, _) in parts.items() if r == "FAIL"]
        other = [l for l, (r, _, _) in parts.items() if r not in ("PASS", "FAIL", "TIMEOUT", "TIMEOUT-WALL")]
        if e["expect"] == "PASS":
            ok = n >= e.get("min_parts", 1) and not fails and not other and not bad_bounded
            actual = "PASS" if not bounded and not fails and not other else \
                f"{n - len(bounded) - len(fails) - len(other)}/{n} PASS" + \
                (f"; BOUNDED {','.join(bounded)}" if bounded else "") + \
                (f"; FAIL {','.join(fails)}" if fails else "") + (f"; ABORTED/ERROR {','.join(other)}" if other else "")
        else:  # expect FAIL (witness / negative control): a real counterexample somewhere
            cex_fail = [l for l, (r, c, _) in parts.items() if r == "FAIL" and c]
            ok = bool(cex_fail) and not other
            actual = f"FAIL+cex in {','.join(cex_fail)}" if cex_fail else \
                ("BOUNDED " + ",".join(bounded) if bounded else "no counterexample (vacuous?)")
        row("partitioned", e["dir"], e["expect"] + (" (allow-list: " + ",".join(allow) + ")" if allow else ""), actual, ok)
        for l in bounded:
            if l in allow:
                row("  bounded", f"{e['dir']}:{l}", "BOUNDED (allowed)",
                    f"{parts[l][0]} — {allow[l]['reason']}; substitute: {allow[l]['substitute']}", True)


def check_mutations(root, ex, mroot=None):
    mroot = mroot or os.path.join(root, "mutations")
    for m in ex.get("mutations", []):
        md = os.path.join(mroot, m["id"])
        if not os.path.isdir(md):
            row("mutation", m["id"], "killed", "MISSING", False)
            continue
        for h in m.get("halmos_logs", []):
            p = os.path.join(md, h["log"])
            t = open(p, errors="replace").read() if os.path.exists(p) else ""
            r = results_in(t).get(h["check"], "NO-RESULT")
            row("mutation", f"{m['id']} halmos {h['check']}", "FAIL+cex", r, r == "FAIL" and "Counterexample" in t)
        for h in m.get("halmos_parts", []):
            check = h["dir"].split(".", 1)[1]
            parts = partitions(os.path.join(md, h["dir"]), check) or {}
            hit = [l for l, (r, c, _) in parts.items() if l.startswith(h["part_prefix"]) and r == "FAIL" and c]
            row("mutation", f"{m['id']} halmos {h['dir']}:{h['part_prefix']}", "FAIL+cex",
                "FAIL+cex" if hit else "not red", bool(hit))
        sp = os.path.join(md, "scenario.log")
        st = open(sp, errors="replace").read() if os.path.exists(sp) else ""
        red = re.search(r"^\[FAIL: (.*)\] " + re.escape(m["scenario_test"]) + r"\(", st, re.M)
        ok = bool(red) and m["scenario_msg"] in red.group(1)
        row("mutation", f"{m['id']} scenario {m['scenario_test']}", f"red ({m['scenario_msg']})",
            red.group(1) if red else "green / missing", ok)
        ap = open(os.path.join(md, "apply.txt")).read() if os.path.exists(os.path.join(md, "apply.txt")) else ""
        sm = open(os.path.join(md, "summary.txt")).read() if os.path.exists(os.path.join(md, "summary.txt")) else ""
        a = re.search(r"pristine sha256 ([0-9a-f]{64})", ap)
        r = re.search(r"reverted " + re.escape(m["id"]) + r": \S+ sha256 ([0-9a-f]{64})", sm)
        row("mutation", f"{m['id']} source restored", "sha256(pristine)",
            r.group(1)[:12] if r else "no revert line", bool(a and r and a.group(1) == r.group(1)))


def check_fuzz(root, ex, fdir=None):
    fz = ex.get("fuzz_liveness")
    if not fz:
        return
    fdir = fdir or os.path.join(root, "fuzz-liveness")
    p = os.path.join(root, fz["unmutated_log"])
    if not os.path.exists(p) and os.path.exists(os.path.join(fdir, fz["unmutated_log"])):
        p = os.path.join(fdir, fz["unmutated_log"])
    t = open(p, errors="replace").read() if os.path.exists(p) else ""
    for tn in fz["unmutated_tests"]:
        ok = re.search(r"\[PASS\] " + re.escape(tn) + r"\(.*runs: (\d+)", t)
        row("fuzz", f"unmutated {tn}", "PASS (>=10000 runs)", f"PASS runs={ok.group(1)}" if ok else "not green",
            bool(ok) and int(ok.group(1)) >= 10000)
    for m in fz["mutations"]:
        lp = os.path.join(fdir, f"{m['id']}.fuzz.log")
        lt = open(lp, errors="replace").read() if os.path.exists(lp) else ""
        for tn in m["must_fail"]:
            red = re.search(r"^\[FAIL: .*\] " + re.escape(tn) + r"\(", lt, re.M)
            row("fuzz", f"{m['id']} reddens {tn}", "red", "red" if red else "green / missing", bool(red))
        rv = re.search(r"reverted " + re.escape(m["id"]) + r": \S+ sha256 ([0-9a-f]{64})", lt)
        apf = os.path.join(fdir, f"{m['id']}.apply.txt")
        pa = re.search(r"pristine sha256 ([0-9a-f]{64})", open(apf).read()) if os.path.exists(apf) else None
        row("fuzz", f"{m['id']} source restored", "sha256(pristine)", rv.group(1)[:12] if rv else "missing",
            bool(rv and pa and rv.group(1) == pa.group(1)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.environ.get("D5C1_ROOT", "docs/design/aoa-balance-mode/data/halmos"))
    ap.add_argument("--expect", default=os.environ.get("D5C1_EXPECT", "script/halmos/d5c1-expectations.json"))
    ap.add_argument("--mutations-dir", default="")
    ap.add_argument("--fuzz-dir", default="")
    ap.add_argument("--filter", default="", help="keep only rows whose item contains one of these comma-separated substrings")
    ap.add_argument("--only", default="logs,partitioned,mutations,fuzz")
    ap.add_argument("--markdown", default="")
    a = ap.parse_args()
    ex = json.load(open(a.expect))
    sel = set(a.only.split(","))
    if "logs" in sel: check_logs(a.root, ex)
    if "partitioned" in sel: check_partitioned(a.root, ex)
    if "mutations" in sel: check_mutations(a.root, ex, a.mutations_dir or None)
    if "fuzz" in sel: check_fuzz(a.root, ex, a.fuzz_dir or None)
    global rows
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
            f.write("| 类别 | 项 | 期望 | 实际 | 判定 |\n|---|---|---|---|---|\n")
            for r in rows:
                f.write("| " + " | ".join(str(x).replace("|", "\\|") for x in (r[0].strip(), r[1], r[2], r[3], r[4])) + " |\n")
    sys.exit(0 if not bad else 1)


if __name__ == "__main__":
    main()

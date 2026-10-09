#!/usr/bin/env python3
"""Offline fixture tests for the STRICT (non --ci) mode of scripts/merge-preflight.sh.

The workflow that runs merge-preflight.sh only ever uses --ci, and the
required-checks leg runs only in strict mode, so without this suite CI had zero
coverage of the code that decides whether a merge is safe (DSR on #452).

A fake `gh` is put first on PATH. It serves JSON fixtures per endpoint and
emulates the three gh behaviours the script depends on: `--jq` (applied per
page with real jq, raw output), `--paginate` (one output per page) and
`--slurp` (all pages as one JSON array). Nothing touches the network.

Every scenario asserts BOTH the overall exit status AND the exact line the
required-checks leg printed, so a scenario cannot pass for an unrelated reason
(e.g. failing early on the approval leg).

Usage: python3 scripts/test_merge_preflight_strict.py   (exit 0 = all pass)
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.environ.get("PREFLIGHT_SCRIPT") or os.path.join(ROOT, "scripts", "merge-preflight.sh")
REPO = "o/r"
PR = "7"
HEAD = "a" * 40
APP = 15368

FAKE_GH = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
fx = json.load(open(os.environ["FAKE_GH_FIXTURE"]))
a = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a") as f:
    f.write(json.dumps(a) + "\n")

def jq(expr, doc):
    p = subprocess.run(["jq", "-r", expr], input=json.dumps(doc), capture_output=True, text=True)
    sys.stdout.write(p.stdout)
    return p.returncode

if a[:2] == ["pr", "view"]:
    expr = a[a.index("-q") + 1]
    sys.exit(1 if jq(expr, fx["pr"]) else 0)

if a and a[0] == "api":
    rest, flags, expr, i = a[1:], set(), None, 0
    paths = []
    while i < len(rest):
        t = rest[i]
        if t in ("--paginate", "--slurp"):
            flags.add(t)
        elif t in ("--jq", "-q"):
            expr = rest[i + 1]; i += 1
        else:
            paths.append(t)
        i += 1
    ep = fx["api"].get(paths[0])
    if ep is None:
        print(json.dumps({"message": "Not Found"}))
        sys.exit(1)
    if "raw" in ep:
        sys.stdout.write(ep["raw"])
        sys.exit(ep.get("rc", 0))
    pages = ep["pages"]
    if ep.get("rc", 0):
        print(json.dumps(pages[0] if pages else {}))
        sys.exit(ep["rc"])
    if "--slurp" in flags:
        print(json.dumps(pages)); sys.exit(0)
    for pg in pages:
        if expr is not None:
            if jq(expr, pg):
                sys.exit(1)
        else:
            print(json.dumps(pg))
    sys.exit(0)
sys.exit(2)
'''

# jq wrapper: makes one specific jq invocation exit non-zero AFTER printing,
# to prove the script checks jq's status and not only its output.
FAKE_JQ = r'''#!/bin/bash
real=$(PATH="${FAKE_REAL_PATH}" command -v jq)
if [ -n "${FAKE_JQ_FAIL_ON:-}" ] && [[ "$*" == *"${FAKE_JQ_FAIL_ON}"* ]]; then
  "$real" "$@"; exit 7
fi
exec "$real" "$@"
'''


def run_rec(name, conclusion="success", status="completed", app=APP, rid=1):
    return {"name": name, "status": status, "conclusion": conclusion, "id": rid,
            "app": {"id": app}, "details_url": f"https://x/runs/1/job/{rid}"}


def base_fixture(base):
    runs = [run_rec("build", rid=11), run_rec("test", rid=12),
            run_rec("cla-check", rid=13), run_rec("preflight-report", rid=14)]
    enc = base.replace("/", "%2F").replace("#", "%23")
    api = {
        f"repos/{REPO}/pulls/{PR}/reviews": {"pages": [[{
            "state": "APPROVED", "commit_id": HEAD, "submitted_at": "2026-10-01T00:00:00Z",
            "body": f"APPROVE at {HEAD}"}]]},
        f"repos/{REPO}/issues/{PR}/timeline": {"pages": [[]]},
        f"repos/{REPO}/pulls/{PR}/commits": {"pages": [[
            {"commit": {"committer": {"date": "2026-09-30T00:00:00Z"}}}]]},
        f"repos/{REPO}/commits/{HEAD}/check-runs": {"pages": [
            {"total_count": len(runs), "check_runs": runs}]},
        f"repos/{REPO}/commits/{HEAD}/status": {"pages": [{"state": "pending", "statuses": []}]},
        f"repos/{REPO}/rules/branches/{enc}": {"pages": [[]]},
    }
    if base == "main":
        api[f"repos/{REPO}/branches/main/protection"] = {"pages": [{
            "url": f"https://api.github.com/repos/{REPO}/branches/main/protection",
            "enforce_admins": {"enabled": False},
            "required_pull_request_reviews": {"dismiss_stale_reviews": True},
            "required_status_checks": {
                "contexts": ["build", "test"],
                "checks": [{"context": "build", "app_id": APP}, {"context": "test", "app_id": APP}]}}]}
        api[f"repos/{REPO}/branches/main"] = {"pages": [{"name": "main", "protected": True}]}
    else:
        api[f"repos/{REPO}/branches/{enc}/protection"] = {
            "rc": 1, "pages": [{"message": "Branch not protected"}]}
        api[f"repos/{REPO}/branches/{enc}"] = {"pages": [{"name": base, "protected": False}]}
    return {"pr": {"headRefOid": HEAD, "baseRefName": base, "reviewDecision": "APPROVED"}, "api": api}


U, P = "feat/x", "main"
UE = "feat%2Fx"
PROT = f"repos/{REPO}/branches/main/protection"
CR = f"repos/{REPO}/commits/{HEAD}/check-runs"


def set_prot(fx, rsc=None, raw=None, **top):
    if raw is not None:
        fx["api"][PROT] = {"raw": raw}
        return
    body = {"url": "https://u", "enforce_admins": {"enabled": False}}
    body.update(top)
    if rsc is not ...:
        body["required_status_checks"] = rsc
    fx["api"][PROT] = {"pages": [body]}


def set_rules(fx, base, pages=None, rc=0, raw=None):
    k = f"repos/{REPO}/rules/branches/{base}"
    fx["api"][k] = {"raw": raw, "rc": rc} if raw is not None else {"pages": pages, "rc": rc}


def set_branch(fx, body=None, rc=0, raw=None):
    k = f"repos/{REPO}/branches/{UE}"
    fx["api"][k] = {"raw": raw, "rc": rc} if raw is not None else {"pages": [body], "rc": rc}


def set_runs(fx, runs):
    fx["api"][CR] = {"pages": [{"total_count": len(runs), "check_runs": runs}]}


def rs_rule(*ctx):
    return {"type": "required_status_checks", "parameters": {
        "required_status_checks": [dict(c) for c in ctx]}}


OK_ALL = r"^OK    all \d+ required checks succeeded"
INFO_NONE = r"^INFO  .* requires no status checks"
UNREAD = r"^FAIL  could not read .* required checks"
UNMET = r"^FAIL  required check\(s\) not satisfied on this head: "
BASE_UNREAD = r"^FAIL  base branch unreadable"

# (name, base, mutate, expect_exit_zero, leg_regex, env)
S = []
def sc(name, base, mut, ok, leg, env=None):
    S.append((name, base, mut, ok, leg, env or {}))

# --- positive controls -------------------------------------------------------
sc("unprotected, no rulesets", U, lambda f: None, True, INFO_NONE)
sc("protected, contexts+checks all succeeded", P, lambda f: None, True, OK_ALL)
sc("unprotected, ruleset requires present cla-check", U,
   lambda f: set_rules(f, UE, [[rs_rule({"context": "cla-check"})]]), True, OK_ALL)
sc("unprotected, ruleset integration matches", U,
   lambda f: set_rules(f, UE, [[rs_rule({"context": "cla-check", "integration_id": APP})]]), True, OK_ALL)
sc("unprotected, non-check rule only", U, lambda f: set_rules(f, UE, [[{"type": "deletion"}]]), True, INFO_NONE)
sc("protected, required_status_checks null = genuine zero", P, lambda f: set_prot(f, rsc=None), True, INFO_NONE)
sc("protected, latest run of a check is success after an older one", P,
   lambda f: set_runs(f, [run_rec("build", "neutral", rid=1), run_rec("build", rid=11),
                          run_rec("test", rid=12), run_rec("preflight-report", rid=14)]), True, OK_ALL)

# --- unprotected base: classic-protection read --------------------------------
sc("branch body has no protected field", U, lambda f: set_branch(f, {"name": "x"}), False, UNREAD)
sc("protected is the string 'false'", U, lambda f: set_branch(f, {"protected": "false"}), False, UNREAD)
sc("gh exits 1 but prints protected:false", U, lambda f: set_branch(f, {"protected": False}, rc=1), False, UNREAD)
sc("branch body not JSON", U, lambda f: set_branch(f, raw="not json"), False, UNREAD)
sc("base name with # is URL-encoded (unknown branch -> unread)", U,
   lambda f: f["pr"].update(baseRefName="feat/x#y"), False, UNREAD)
sc("@uri encoding: jq prints then exits 7", U, lambda f: None, False, BASE_UNREAD,
   {"FAKE_JQ_FAIL_ON": "@uri"})

# --- rulesets -----------------------------------------------------------------
sc("rules: gh exits 1 printing [[]]", U, lambda f: set_rules(f, UE, [[]], rc=1), False, UNREAD)
sc("rules: object instead of pages", U, lambda f: set_rules(f, UE, raw='{"message":"x"}'), False, UNREAD)
sc("rules: not JSON", U, lambda f: set_rules(f, UE, raw="[[ broken"), False, UNREAD)
sc("rules: zero pages []", U, lambda f: set_rules(f, UE, []), False, UNREAD)
sc("rules: entry {}", U, lambda f: set_rules(f, UE, [[{}]]), False, UNREAD)
sc("rules: entry null", U, lambda f: set_rules(f, UE, [[None]]), False, UNREAD)
sc("rules: type 42", U, lambda f: set_rules(f, UE, [[{"type": 42}]]), False, UNREAD)
sc("rules: type empty string", U, lambda f: set_rules(f, UE, [[{"type": ""}]]), False, UNREAD)
sc("rules: required_status_checks without parameters", U,
   lambda f: set_rules(f, UE, [[{"type": "required_status_checks", "parameters": {}}]]), False, UNREAD)
sc("rules: requirement on page 2 is absent", U,
   lambda f: set_rules(f, UE, [[{"type": "deletion"}], [rs_rule({"context": "security"})]]), False, UNMET)
sc("rules: required check from the wrong integration", U,
   lambda f: set_rules(f, UE, [[rs_rule({"context": "cla-check", "integration_id": 999})]]), False, UNMET)
sc("protected base also honours rulesets", P,
   lambda f: set_rules(f, "main", [[rs_rule({"context": "security"})]]), False, UNMET)

# --- protected base: protection object shape -----------------------------------
sc("protection: garbage after object", P, lambda f: set_prot(f, raw='{"enforce_admins":{},"url":"u"} garbage'), False, UNREAD)
sc("protection: enforce_admins null", P, lambda f: set_prot(f, rsc=None, enforce_admins=None), False, UNREAD)
sc("protection: no url", P, lambda f: f["api"][PROT]["pages"][0].pop("url"), False, UNREAD)
sc("protection: required_status_checks {}", P, lambda f: set_prot(f, rsc={}), False, UNREAD)
sc("protection: contexts null", P, lambda f: set_prot(f, rsc={"contexts": None}), False, UNREAD)
sc("protection: contexts 42", P, lambda f: set_prot(f, rsc={"contexts": 42}), False, UNREAD)
sc("protection: contexts false with checks", P,
   lambda f: set_prot(f, rsc={"contexts": False, "checks": [{"context": "build"}]}), False, UNREAD)
sc("protection: checks false", P, lambda f: set_prot(f, rsc={"contexts": [], "checks": False}), False, UNREAD)
sc("protection: empty name", P, lambda f: set_prot(f, rsc={"contexts": [""]}), False, UNREAD)
sc("protection: whitespace-only name", P, lambda f: set_prot(f, rsc={"contexts": [" \t"]}), False, UNREAD)
sc("protection: NUL inside name", P, lambda f: set_prot(f, rsc={"contexts": ["bu\u0000ild"]}), False, UNREAD)
sc("protection: newline inside name", P, lambda f: set_prot(f, rsc={"contexts": ["build\ntest"]}), False, UNREAD)
sc("protection: app_id is a string", P,
   lambda f: set_prot(f, rsc={"contexts": [], "checks": [{"context": "build", "app_id": "15368"}]}), False, UNREAD)
sc("protection: checks-only requirement absent", P,
   lambda f: set_prot(f, rsc={"contexts": [], "checks": [{"context": "never-ran", "app_id": APP}]}), False, UNMET)
sc("protection: '-ebuild' must not act as a grep option", P,
   lambda f: set_prot(f, rsc={"contexts": ["-ebuild"]}), False, UNMET)

# --- conclusion allowlist and App identity --------------------------------------
def runs_with(build):
    return lambda f: set_runs(f, [build, run_rec("test", rid=12), run_rec("preflight-report", rid=14)])
sc("required check skipped", P, runs_with(run_rec("build", "skipped", rid=11)), False, UNMET)
sc("required check neutral", P, runs_with(run_rec("build", "neutral", rid=11)), False, UNMET)
sc("required check stale", P, runs_with(run_rec("build", "stale", rid=11)), False, UNMET)
sc("required check still running", P, runs_with(run_rec("build", None, "in_progress", rid=11)), False, UNMET)
sc("required check from another App (same name)", P, runs_with(run_rec("build", app=999, rid=11)), False, UNMET)
sc("latest run failed after an older success", P,
   lambda f: set_runs(f, [run_rec("build", rid=1), run_rec("build", "failure", rid=11),
                          run_rec("test", rid=12), run_rec("preflight-report", rid=14)]), False, UNMET)
sc("check-run record malformed (id missing)", P,
   lambda f: set_runs(f, [{k: v for k, v in run_rec("build", rid=11).items() if k != "id"},
                          run_rec("test", rid=12), run_rec("preflight-report", rid=14)]), False, UNREAD)
sc("required-set union: jq prints then exits 7", P, lambda f: None, False,
   r"^FAIL  could not evaluate", {"FAKE_JQ_FAIL_ON": "--argjson runs"})

LEG = re.compile(r"^(OK    all \d+ required checks|INFO  .*requires no status checks|"
                 r"FAIL  (could not (read|evaluate) .*required checks|required check\(s\) not satisfied|base branch unreadable))")


def main():
    tmp = tempfile.mkdtemp(prefix="preflight-strict-")
    try:
        bindir = os.path.join(tmp, "bin")
        os.mkdir(bindir)
        for name, body in (("gh", FAKE_GH), ("jq", FAKE_JQ)):
            p = os.path.join(bindir, name)
            open(p, "w").write(body)
            os.chmod(p, 0o755)
        failures = 0
        for i, (name, base, mut, ok, leg, env) in enumerate(S):
            fx = base_fixture(base)
            mut(fx)
            fpath = os.path.join(tmp, f"fx{i}.json")
            json.dump(fx, open(fpath, "w"))
            e = dict(os.environ, FAKE_GH_FIXTURE=fpath, FAKE_GH_LOG=os.path.join(tmp, "calls.log"),
                     FAKE_REAL_PATH=os.environ["PATH"], PATH=bindir + os.pathsep + os.environ["PATH"],
                     REPO=REPO, GH_TOKEN="offline")
            # The script derives SELF_NAME from GITHUB_JOB / GITHUB_RUN_ID; inside
            # Actions those name THIS test job, not the fixture's run. Strip every
            # GITHUB_* and pin SELF_NAME so local and CI runs see the same input
            # (the first CI run failed all 7 positive controls on exactly this).
            for k in [k for k in e if k.startswith("GITHUB_")]:
                e.pop(k)
            e["SELF_NAME"] = "preflight-report"
            e.update(env)
            p = subprocess.run(["bash", SCRIPT, PR], capture_output=True, text=True, env=e, timeout=120)
            out = p.stdout + p.stderr
            legs = [l for l in out.splitlines() if LEG.match(l)]
            got_leg = legs[0] if legs else "<no required-checks line>"
            exit_ok = (p.returncode == 0) == ok
            leg_ok = re.search(leg, got_leg) is not None
            mark = "ok  " if exit_ok and leg_ok else "FAIL"
            if not (exit_ok and leg_ok):
                failures += 1
            print(f"{mark} [{'PASS' if ok else 'FAIL'} expected, exit {p.returncode}] {name}")
            if not (exit_ok and leg_ok):
                print(f"       leg: {got_leg}")
                print("       output:\n" + "\n".join("         " + l for l in out.splitlines()))
        print(f"\n{len(S) - failures}/{len(S)} scenarios as expected")
        return 1 if failures else 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())

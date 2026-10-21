#!/usr/bin/env python3
"""D3 M-layer source-mutation harness: apply -> forge test (the 22 migrated files) -> restore.

Usage (from the repo root, or with ROOT=<tree>):
    python3 docs/design/aoa-balance-mode/d3m/mut.py docs/design/aoa-balance-mode/d3m/muts_final.py [ids...]
Env: ROOT (tree to mutate, default cwd), SHARD=i/n (run every n-th mutation), TAG (results file tag),
     OUT (directory for results/logs, default ./d3m-out).

A mutation = dict(id, edits=[(file, old, new)], tests=[paths]); every `old` must occur exactly once.
Before the first mutation contracts/src is snapshotted; after EVERY mutation the touched files are
copied back from the snapshot and compared byte-for-byte (the run aborts if any differs).
Results: <OUT>/results-<TAG>.jsonl (one record per mutation: failing tests + failure messages);
raw forge output: <OUT>/logs/<id>.log.
"""
import json, os, re, subprocess, sys, time, importlib.util, filecmp, shutil, tempfile

ROOT = os.path.abspath(os.environ.get("ROOT", os.getcwd()))
OUT = os.path.abspath(os.environ.get("OUT", os.path.join(os.getcwd(), "d3m-out")))
FORGE = os.environ.get("FORGE", os.path.expanduser("~/.foundry/bin/forge"))
LOGS = os.path.join(OUT, "logs")
os.makedirs(LOGS, exist_ok=True)
PRISTINE = tempfile.mkdtemp(prefix="d3m-pristine-")
shutil.rmtree(PRISTINE)
shutil.copytree(os.path.join(ROOT, "contracts/src"), PRISTINE)
TOUCHED = set()


def restore():
    for rel in list(TOUCHED):
        shutil.copyfile(os.path.join(PRISTINE, rel), os.path.join(ROOT, "contracts/src", rel))
        if not filecmp.cmp(os.path.join(PRISTINE, rel), os.path.join(ROOT, "contracts/src", rel), shallow=False):
            raise SystemExit("SRC NOT RESTORED: " + rel)
    TOUCHED.clear()


def parse(out):
    """Failures from forge's final summary ('Encountered N failing tests in <file>:<C>' + [FAIL...])."""
    fails, cur = [], None
    if "Failing tests:" not in out:
        return fails
    for line in out.split("Failing tests:", 1)[1].splitlines():
        m = re.match(r"Encountered \d+ failing tests? in (\S+):(\w+)", line)
        if m:
            cur = m.group(1); continue
        m = re.match(r"\[FAIL(?:: (.*))?\] (\w+)\(", line)
        if m and cur:
            fails.append((cur, m.group(2), (m.group(1) or "").strip()))
    return fails


def apply(m):
    for (f, old, new) in m["edits"]:
        assert f.startswith("contracts/src/")
        path = os.path.join(ROOT, f)
        src = open(path).read()
        n = src.count(old)
        if n != 1:
            raise ValueError(f"{m['id']}: 'old' occurs {n} times in {f}")
        TOUCHED.add(f[len("contracts/src/"):])
        open(path, "w").write(src.replace(old, new))


def main():
    spec = importlib.util.spec_from_file_location("muts", sys.argv[1])
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    muts = mod.MUTATIONS
    if sys.argv[2:]:
        muts = [m for m in muts if m["id"] in sys.argv[2:]]
    if os.environ.get("SHARD"):
        i, n = map(int, os.environ["SHARD"].split("/"))
        muts = muts[i::n]
    resf = open(os.path.join(OUT, f"results-{os.environ.get('TAG', 'main')}.jsonl"), "a")
    for m in muts:
        try:
            apply(m)
            glob = "{" + ",".join(m["tests"]) + "}"
            t0 = time.time()
            p = subprocess.run([FORGE, "test", "--match-path", glob, "-vv"], cwd=ROOT, capture_output=True, text=True)
            out, dt = p.stdout + "\n" + p.stderr, time.time() - t0
        finally:
            restore()
        open(os.path.join(LOGS, m["id"] + ".log"), "w").write(out)
        fails = parse(out)
        rec = dict(id=m["id"], rc=p.returncode, secs=round(dt), compile_error="Ran " not in out,
                   fails=[dict(file=f, test=t, reason=r) for f, t, r in fails])
        resf.write(json.dumps(rec) + "\n"); resf.flush()
        print(f"== {m['id']}  rc={p.returncode} {round(dt)}s fails={len(fails)}")
        for f, t, r in fails:
            print(f"   RED {os.path.basename(f)}::{t}  <- {r[:200]}")
        sys.stdout.flush()


if __name__ == "__main__":
    main()

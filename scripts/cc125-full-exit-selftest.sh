#!/usr/bin/env bash
# Run the complete real driver with throwaway fixtures and fake evidence commands.
# Optional argument: an old driver to compare against the fixed driver.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
python3 - "$HERE/cc125-full.sh" "$@" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile

new = Path(sys.argv[1]).resolve()
old = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None
steps = ["0-ast-build", "1-run-all", "2-mutations", "3-fuzz-liveness", "4-archive", "5-verify"]
cases = [
    ("all succeed", {}, 0, 0),
    ("middle fails", {"FAIL_STEPS": "3-fuzz-liveness"}, 0, 1),
    ("mutation subshell fails", {"FAIL_STEPS": "2-mutations"}, 0, 1),
    ("verify MISMATCH", {"FAIL_STEPS": "5-verify"}, 0, 1),
    ("step killed by TERM", {"KILL_STEP": "3-fuzz-liveness"}, 0, 1),
    ("multiple failures", {"FAIL_STEPS": "1-run-all 2-mutations 5-verify"}, 0, 1),
    *[(f"driver {sig}", {"PARENT_SIGNAL": sig}, 130, 130) for sig in ("INT", "TERM", "HUP")],
    ("failure + dirty cleanup", {"FAIL_STEPS": "5-verify", "DIRTY": "1"}, 99, 1),
    ("TERM + dirty cleanup", {"PARENT_SIGNAL": "TERM", "DIRTY": "1"}, 99, 130),
]


def executable(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)


def run(driver, root, settings, expected):
    work = root / "work"
    bin_dir = root / "home/.foundry/bin"
    (work / "contracts/src").mkdir(parents=True)
    sentinel = work / "contracts/src/sentinel.sol"
    sentinel.write_text("must survive\n")
    data = work / "docs/design/aoa-balance-mode/data/halmos"
    data.mkdir(parents=True)
    stub = root / "step"
    executable(stub, '''#!/usr/bin/env bash
id="$1"
echo "$id" >> "$TRACE"
echo "fake evidence: $id"
if [ "$id" = 3-fuzz-liveness ] && [ -n "${PARENT_SIGNAL:-}" ]; then
  kill -s "$PARENT_SIGNAL" "$PPID"
fi
if [ "$id" = "${KILL_STEP:-}" ]; then kill -s TERM "$$"; fi
case " ${FAIL_STEPS:-} " in *" $id "*) exit 7;; esac
exit 0
''')
    executable(bin_dir / "forge", '#!/usr/bin/env bash\n[ "$1" = --version ] && exit 0\nexec bash "$STUB" 0-ast-build\n')
    executable(bin_dir / "halmos", '#!/usr/bin/env bash\necho fake-halmos\n')
    executable(bin_dir / "git", '''#!/usr/bin/env bash
case " $* " in *" status "*)
  [ "${DIRTY:-0}" = 1 ] && echo ' M contracts/src/sentinel.sol'
  exit 0;;
esac
echo fake-head
''')
    executable(bin_dir / "rsync", '#!/usr/bin/env bash\ncp -R "$CC125_WORKTREE/script" "${!#}/"\n')
    for filename, step in zip(
        ("run-all-d5c1.sh", "run-mutations-all.sh", "run-fuzz-liveness.sh", "archive-d5c1.sh"), steps[1:5]
    ):
        executable(work / "script/halmos" / filename, f'#!/usr/bin/env bash\nexec bash "$STUB" {step}\n')
    (work / "script/halmos/verify-d5c1.py").write_text(
        'import os\nos.execv("/bin/bash", ["bash", os.environ["STUB"], "5-verify"])\n'
    )
    # Strip inherited CC125/test settings so no invocation can reach the real checkout.
    env = {k: v for k, v in os.environ.items() if not k.startswith("CC125_")}
    for key in ("FAIL_STEPS", "KILL_STEP", "PARENT_SIGNAL", "DIRTY"):
        env.pop(key, None)
    env.update(HOME=str(root / "home"), CC125_WORKTREE=str(work),
               CC125_SCRATCH=str(root / "scratch"), CC125_OUT=str(root / "output"),
               CC125_MUTCOPY=str(root / "mutcopy"), TRACE=str(root / "trace"), STUB=str(stub))
    env.update(settings)
    result = subprocess.run(["bash", str(driver)], cwd=root, env=env,
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == expected, (driver, settings, result.returncode, expected, result.stderr)
    assert sentinel.read_text() == "must survive\n"
    assert not (root / "mutcopy").exists(), "cleanup left mutation copy behind"
    trace = (root / "trace").read_text().splitlines()
    if "PARENT_SIGNAL" in settings:
        assert trace == steps[:4], trace
    else:
        assert trace == steps, ("later steps did not run", trace)
        ledger = [line.split("\t") for line in (root / "output/steps.tsv").read_text().splitlines()]
        assert [row[0] for row in ledger] == steps, ledger
        failed = settings.get("FAIL_STEPS", "").split()
        for name, rc, *_ in ledger:
            want = 143 if name == settings.get("KILL_STEP") else 7 if name in failed else 0
            assert int(rc) == want, (name, rc, want)
            if driver == new and want:
                assert f"  {name} (exit {want})" in result.stderr, result.stderr
        if driver == new:
            assert ("Failed steps:" in result.stderr) == bool(failed or settings.get("KILL_STEP"))
    return result.returncode


print("| Case | Old exit | New exit | Result |")
print("|---|---:|---:|---|")
runs = 0
with tempfile.TemporaryDirectory(prefix="cc125-exit-") as temp:
    for index, (label, settings, old_rc, new_rc) in enumerate(cases):
        results = []
        for version, driver, expected in (("old", old, old_rc), ("new", new, new_rc)):
            if driver is None:
                results.append("—")
                continue
            root = Path(temp) / f"{index}-{version}"
            root.mkdir()
            results.append(str(run(driver, root, settings, expected)))
            runs += 1
        print(f"| {label} | {results[0]} | {results[1]} | PASS |", flush=True)
print(f"{len(cases)} scenarios passed, 0 failed; {runs} driver runs")
PY

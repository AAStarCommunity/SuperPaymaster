#!/usr/bin/env bash
# Exercise the real guard only in a throwaway copy; never run the evidence pipeline.
# Optional argument: the pre-fix driver, to prove it accepts the new case-variant cases.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
T="$(mktemp -d "${TMPDIR:-/tmp}/cc125-guard.XXXXXX")"
T="$(cd "$T" && pwd -P)"
readonly T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/worktree/scripts" "$T/worktree/contracts/src" "$T/home"
cp "$HERE/cc125-full.sh" "$T/worktree/scripts/"
printf 'must survive\n' > "$T/worktree/contracts/src/sentinel.sol"
cp -R "$T/worktree" "$T/before"
ln -s "$T/worktree/contracts" "$T/alias"
export CC125_WORKTREE="$T/worktree" CC125_SCRATCH="$T/scratch"
export CC125_OUT="$T/output" HOME="$T/home"
unset CC125_MUTCOPY
cd "$T/worktree"
passed=0
check() {
  local label="$1" expected="$2" rc=0
  bash scripts/cc125-full.sh --check-mutcopy > "$T/stdout" 2> "$T/stderr" || rc=$?
  if [ "$expected" = refused ]; then
    [ "$rc" -eq 2 ] || { echo "FAIL: $label: exit $rc"; exit 1; }
  else
    [ "$rc" -eq 0 ] && [ "$(cat "$T/stdout")" = "$expected" ] || {
      echo "FAIL: $label: exit $rc or incorrect canonical path"; exit 1;
    }
  fi
  diff -r "$T/before" "$T/worktree" >/dev/null
  [ ! -e "$CC125_OUT" ] && [ ! -e "$CC125_SCRATCH" ]
  passed=$((passed + 1))
  printf 'PASS: %s (exit %s; tree intact)\n' "$label" "$rc"
}
for p in . contracts contracts/src "$T/worktree/contracts/src" / "$HOME" "$T/alias/src" contracts/../contracts/src "$T"; do
  export CC125_MUTCOPY="$p"
  check "$p" refused
done
unset CC125_MUTCOPY
check default "$T/scratch/mutcopy"
export CC125_MUTCOPY="$T/outside/missing/copy"
check outside "$T/outside/missing/copy"
export CC125_MUTCOPY=../relative-copy
check relative-outside "$T/relative-copy"
printf 'Existing cases: %s passed, 0 failed\n' "$passed"
python3 - "$T" "$HERE/cc125-full.sh" "${1:-}" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(sys.argv[1]) / "case-variants"
root.mkdir()
parent = root / "parent"
work = parent / "worktree"
(work / "contracts/src").mkdir(parents=True)
(work / "contracts/src/sentinel.sol").write_text("must survive\n")
home = root / "home"
home.mkdir()
new = root / "new.sh"
shutil.copyfile(sys.argv[2], new)
old = root / "old.sh" if sys.argv[3] else None
if old:
    shutil.copyfile(sys.argv[3], old)

# Case-sensitive hosts cannot reproduce this filesystem-identity bypass.
upper_work = parent / "WORKTREE"
if not upper_work.exists() or not os.path.samefile(work, upper_work):
    print("Case-variant cases: SKIP (requires a case-insensitive filesystem)")
    sys.exit(0)
upper_parent = root / "PARENT"
assert os.path.samefile(parent, upper_parent)
cases = [
    ("same worktree, different case", work, upper_work),
    ("ancestor, different case", work, upper_parent),
    ("existing descendant via different-case ancestor", work, upper_parent / "worktree/contracts"),
    ("missing descendant via different-case ancestor", work, upper_parent / "worktree/missing/copy"),
    ("different-case worktree, existing descendant", upper_work, work / "contracts"),
]


def snapshot():
    return {str(p.relative_to(parent)): p.read_bytes() if p.is_file() else None
            for p in parent.rglob("*")}


before = snapshot()
env = {k: v for k, v in os.environ.items() if not k.startswith("CC125_")}
env.update(HOME=str(home), CC125_OUT=str(root / "output"), CC125_SCRATCH=str(root / "scratch"))
old_accepted = new_refused = 0
for label, w, c in cases:
    env.update(CC125_WORKTREE=str(w), CC125_MUTCOPY=str(c))
    results = []
    for name, driver, expected in (("old", old, 0), ("new", new, 2)):
        if driver is None:
            continue
        # Only the validation entry point is invoked, even for the vulnerable old driver.
        result = subprocess.run(["bash", str(driver), "--check-mutcopy"], cwd=root,
                                env=env, capture_output=True, text=True, timeout=10)
        assert result.returncode == expected, (label, name, result.returncode, result.stderr)
        assert snapshot() == before, (label, name, "worktree changed")
        assert not (root / "output").exists() and not (root / "scratch").exists()
        results.append(f"{name} exit {result.returncode}")
        old_accepted += name == "old"
        new_refused += name == "new"
    print(f"PASS: {label} ({'; '.join(results)}; tree intact)")
print(f"New case-variant cases: {new_refused}/{len(cases)} refused, 0 failed")
if old:
    print(f"Old guard comparison: {old_accepted}/{len(cases)} accepted (bypasses)")
print(f"Total new guard: {12 + new_refused} passed, 0 failed")
PY

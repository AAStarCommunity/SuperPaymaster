#!/usr/bin/env bash
# Exercise the real guard only in a throwaway copy; never run the evidence pipeline.
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
printf '%s passed, 0 failed\n' "$passed"

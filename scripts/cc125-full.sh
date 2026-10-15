#!/usr/bin/env bash
# CC-125: the FULL D5c-1 procedure (D5c-1-halmos.md §9) on a clean worktree. Raw stdout of each
# step is kept; exit codes recorded in steps.tsv.
#
# Hardened successor of docs/design/aoa-balance-mode/data/d5c1-rc2-rerun/scripts/cc125-full.sh.
# That archived copy is kept byte-identical because EVIDENCE.sha256 of the rc2 rerun pins it.
# Differences:
#   - no hard-coded absolute paths: work tree, mutation copy and output dir are args / env;
#   - env.txt no longer records the hostname (`uname -srm` instead of `uname -a`; `uptime`
#     carries no host name) and the scratch paths are written relative to $HOME as `~`;
#   - an EXIT/INT/TERM/HUP trap removes the scratch mutation copy and reports whether
#     contracts/src in the work tree is still clean (mutations only ever run in the copy).
#
# Usage: scripts/cc125-full.sh [JOBS]
#   --check-mutcopy validates paths and prints the canonical copy path, without side effects.
#   CC125_WORKTREE  clean checkout to run in   (default: repo root of this script)
#   CC125_SCRATCH   scratch root               (default: ${TMPDIR:-/tmp}/cc125)
#   CC125_MUTCOPY   mutation copy of the tree  (default: $CC125_SCRATCH/mutcopy; deleted on exit
#                   unless CC125_KEEP_MUTCOPY=1)
#   CC125_OUT       output dir                 (default: $CC125_SCRATCH/run)
set -uo pipefail
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"

HERE="$(dirname "${BASH_SOURCE[0]}")"
W="${CC125_WORKTREE:-$(git -C "$HERE" rev-parse --show-toplevel)}"
S="${CC125_SCRATCH:-${TMPDIR:-/tmp}/cc125}"
C="${CC125_MUTCOPY:-$S/mutcopy}"
O="${CC125_OUT:-$S/run}"
J="${1:-4}"

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi; }
ncpu() { nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "?"; }
redact() { sed -e "s#$HOME#~#g"; }   # keep user/home paths out of the archived env record

# Resolve relative paths, symlinks and missing suffixes before any directory change or deletion.
canonical() { python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
W="$(canonical "$W")" || exit 2
C="$(canonical "$C")" || exit 2
H="$(canonical "$HOME")" || exit 2
case "$C" in "$W"|"$W"/*|/|"$H"|"") echo "refusing unsafe mutation copy: $C" >&2; exit 2;; esac
# An ancestor of the checkout would also delete the checkout.
case "$W" in "$C"/*) echo "refusing mutation copy containing the work tree: $C" >&2; exit 2;; esac
readonly W C
if [ "${1:-}" = --check-mutcopy ]; then printf '%s\n' "$C"; exit 0; fi

mkdir -p "$O"; cd "$W" || { echo "cannot cd to $W" >&2; exit 2; }

cleanup() {
  local rc=$?
  [ "${CC125_KEEP_MUTCOPY:-0}" = 1 ] || rm -rf "$C"
  if [ -n "$(git -C "$W" status --porcelain -- contracts/src)" ]; then
    echo "WARNING: contracts/src in $W is not clean" >&2; rc=99
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

D=docs/design/aoa-balance-mode/data/halmos
step() { # name cmd...
  local n="$1"; shift
  echo "# step $n start $(date -u +%FT%TZ) cwd=$PWD cmd: $*" | redact >> "$O/steps.log"
  local t0; t0=$(date +%s)
  "$@" > "$O/$n.stdout" 2>&1; local rc=$?
  echo -e "$n\t$rc\t$(( $(date +%s) - t0 ))\t$*" | redact >> "$O/steps.tsv"
  echo "# step $n end $(date -u +%FT%TZ) rc=$rc" >> "$O/steps.log"
}
{
  echo "date_utc: $(date -u +%FT%TZ)"
  echo "head: $(git rev-parse HEAD)"
  echo "tag v5.5.0-rc.2 peeled: $(git rev-parse 'v5.5.0-rc.2^{commit}' 2>/dev/null)"
  echo "git status --porcelain (must be only the new test file):"; git status --porcelain
  echo "submodules:"; git submodule status contracts/lib/solady contracts/lib/chainlink-brownie-contracts
  echo "halmos: $(halmos --version 2>&1)"
  echo "forge: $(forge --version 2>&1 | tr '\n' ' ')"
  echo "python3: $(python3 --version 2>&1)"
  echo "z3/yices: $(ls ~/.local/share/uv/tools/halmos/lib/python3*/site-packages 2>/dev/null | grep -iE '^(z3|yices)' | tr '\n' ' ')"
  echo "os: $(uname -srm)"   # no hostname (uname -a would print it)
  echo "ncpu: $(ncpu)  load: $(uptime)"
  echo "jobs: $J"
  for t in contracts/test/halmos/D5c1A3Negatives.t.sol contracts/test/halmos/D5c1A3HistoricalSP.t.sol; do
    [ -f "$t" ] && echo "test sha256: $(sha "$t")"
  done
} 2>&1 | redact > "$O/env.txt"
: > "$O/steps.tsv"
# 0. the AST build §9 asks for BEFORE the evidence runs (outside any wall cap).
step 0-ast-build forge build --ast --extra-output storageLayout metadata
# 1. Halmos evidence (all groups)
step 1-run-all script/halmos/run-all-d5c1.sh all "$J"
echo "load after step 1: $(uptime)" >> "$O/env.txt"
# 2. mutations in a scratch copy of the tree (never compiles mutated source in W)
rm -rf "$C"; mkdir -p "$C"
rsync -a contracts singleton-paymaster standards foundry.toml foundry.lock out cache script "$C"/
( cd "$C" && step 2-mutations script/halmos/run-mutations-all.sh "$W/$D/mutations" )
# 3. fuzz-substitute liveness (in the git checkout, clean contracts/src)
step 3-fuzz-liveness script/halmos/run-fuzz-liveness.sh "$D/fuzz-liveness"
# 4. archive items: artifact parity x2, forge halmos suite, verifier self-test
step 4-archive script/halmos/archive-d5c1.sh all
# 5. verdict
step 5-verify python3 script/halmos/verify-d5c1.py --markdown "$D/verify-final.md"
cp "$O/5-verify.stdout" "$D/verify-final.txt"
echo "git status after:" >> "$O/env.txt"; git status --porcelain >> "$O/env.txt"
echo "load at end: $(uptime)" >> "$O/env.txt"
echo DONE >> "$O/steps.log"

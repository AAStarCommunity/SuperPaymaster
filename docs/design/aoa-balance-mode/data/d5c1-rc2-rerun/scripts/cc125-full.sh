#!/usr/bin/env bash
# CC-125 d030f6e8 (1b): the FULL D5c-1 procedure (D5c-1-halmos.md §9) on a clean worktree of
# v5.5.0-rc.2 (1ac0e1c5) + contracts/test/halmos/D5c1A3Negatives.t.sol only. Raw stdout of each
# step is kept; exit codes recorded in steps.tsv.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
S=/private/tmp/claude-502/-Users-jason-Dev-aastar-SuperPaymaster/13f6212e-b200-423b-852b-995b2d8a30a5/scratchpad
W=$S/cc125-rc2
C=$S/cc125-mutcopy
O=$S/cc125-arch/run
J="${1:-4}"
mkdir -p "$O"; cd "$W"
D=docs/design/aoa-balance-mode/data/halmos
step() { # name cmd...
  local n="$1"; shift
  echo "# step $n start $(date -u +%FT%TZ) cwd=$PWD cmd: $*" >> "$O/steps.log"
  local t0=$(date +%s)
  "$@" > "$O/$n.stdout" 2>&1; local rc=$?
  echo -e "$n\t$rc\t$(( $(date +%s) - t0 ))\t$*" >> "$O/steps.tsv"
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
  echo "uname: $(uname -a)"
  echo "ncpu: $(sysctl -n hw.ncpu)  load: $(uptime)"
  echo "jobs: $J"
  echo "new test sha256: $(shasum -a 256 contracts/test/halmos/D5c1A3Negatives.t.sol)"
} > "$O/env.txt" 2>&1
: > "$O/steps.tsv"
# 0. the AST build §9 asks for BEFORE the evidence runs (outside any wall cap: on this loaded host a
#    cold solc build alone exceeds the 600 s per-run cap — aborted-run-1 shows that).
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

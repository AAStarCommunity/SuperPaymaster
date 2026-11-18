#!/bin/bash
# Fail-first controls for XPNTs-4.0.2 (I-01, C2-02, empty-name checks): each run reverts one fix in
# place, runs the new tests, and restores contracts/src from HEAD. Every mutated run must show
# [FAIL] rows; the baseline must show none.
# The script is evidence that the tests turn red before the fix, so it must fail loudly when it
# fails itself: exit 1 if a mutation does not apply, if forge does not produce a test result
# (e.g. a compile error), if the baseline has a failure, or if a mutant shows no failure.
# Usage: script/evidence/xpnts-402-mutants.sh (forge on PATH or in ~/.foundry/bin).
set -u
cd "$(dirname "$0")/../.." || exit 1
export PATH=$HOME/.foundry/bin:/usr/bin:/bin
SRC=contracts/src
git diff --quiet HEAD -- "$SRC" || { echo "contracts/src differs from HEAD; refusing"; exit 1; }
trap 'git checkout HEAD -- "$SRC"' EXIT
T=contracts/test/v2/xPNTsTokenV2.t.sol
NEW='test_regression_|test_C2_02|test_factory_rejects_empty_token_name|test_initialize_rejects_empty_token_name|test_implementation_domain|test_I_01_'
status=0

forge_run() { # prints the PASS/FAIL rows and the suite line; returns 2 when forge produced no result
  local out
  out=$(SEPOLIA_FORK_RPC='' nice -n 15 forge test --offline --match-path $T --match-test "$NEW" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
  echo "$out" | grep -E "^\[PASS|^\[FAIL|^Suite result"
  echo "$out" | grep -q "^Suite result" || { echo "$out" | tail -20; return 2; }
}

echo "=== baseline (unmutated $(git rev-parse --short HEAD))"
base=$(forge_run); rc=$?; echo "$base"
if [ $rc -ne 0 ]; then echo "BASELINE: no test result"; exit 1; fi
if echo "$base" | grep -q "^\[FAIL"; then echo "BASELINE: has failures"; exit 1; fi

run() { # label file old new
  local label=$1 f=$2 old=$3 new=$4 out rc
  echo "=== $label"
  if ! python3 - "$f" "$old" "$new" <<'P'
import sys; f,o,n=sys.argv[1:]; s=open(f).read()
if s.count(o) != 1: sys.exit(1)
open(f,'w').write(s.replace(o,n))
P
  then echo "$label: APPLY FAILED"; status=1; git checkout HEAD -- "$SRC"; return; fi
  out=$(forge_run); rc=$?; echo "$out"
  if [ $rc -ne 0 ]; then echo "$label: NO TEST RESULT"; status=1
  elif ! echo "$out" | grep -q "^\[FAIL"; then echo "$label: SURVIVED"; status=1
  else echo "$label: RED"; fi
  git checkout HEAD -- "$SRC"
}
# Pre-fix behaviour is OZ's EIP712 with name "": the clone's name hash is keccak256(""). (Deleting the
# assignment instead leaves bytes32(0), which is not the pre-fix state and does not reject old signatures.)
run "M1 C2-02 reverted (clone domain name hash = keccak256(\"\"))" contracts/src/tokens/v2/xPNTsTokenV2.sol "_eip712NameHash = keccak256(bytes(c.name));" "_eip712NameHash = keccak256(\"\");"
run "M2 I-01 over-strict (cap checked on gross mint, not net)" contracts/src/tokens/v2/xPNTsV2Base.sol "_checkIssuanceCap(value - repayXPNTs);" "_checkIssuanceCap(value);"
run "M4 I-01 removed (cap never checked)" contracts/src/tokens/v2/xPNTsV2Base.sol "function _checkIssuanceCap(uint256 amount) internal view {" "function _checkIssuanceCap(uint256 amount) internal view { return;"
run "M3 factory empty-name check removed" contracts/src/tokens/v2/xPNTsFactoryV2.sol "if (bytes(name).length == 0 || exchangeRate == 0)" "if (exchangeRate == 0)"
run "M5 initialize empty-name check removed" contracts/src/tokens/v2/xPNTsTokenV2.sol "if (bytes(c.name).length == 0) revert InvalidParam();" ""
git status --short "$SRC"
echo "RESULT status=$status"
exit $status

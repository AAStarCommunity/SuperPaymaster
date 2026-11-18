#!/bin/bash
# Fail-first controls for XPNTs-4.0.2 (I-01, C2-02, factory empty name): each run reverts one fix in
# place, runs the new tests, and restores the file with git. Every mutated run must show [FAIL] rows.
# Usage: script/evidence/xpnts-402-mutants.sh (from any directory; forge on PATH or in ~/.foundry/bin).
cd "$(dirname "$0")/../.." || exit 1
git diff --quiet -- contracts/src || { echo "contracts/src has local changes; refusing"; exit 1; }
export PATH=$HOME/.foundry/bin:/usr/bin:/bin
T=contracts/test/v2/xPNTsTokenV2.t.sol
NEW='test_regression_|test_C2_02|test_factory_rejects_empty_token_name|test_implementation_domain|test_I_01_'
run() { # label file old new
  label=$1; f=$2; old=$3; new=$4
  python3 - "$f" "$old" "$new" <<'P' || { echo "$label: APPLY FAILED"; return; }
import sys; f,o,n=sys.argv[1:]; s=open(f).read(); assert s.count(o)==1, 'count'; open(f,'w').write(s.replace(o,n))
P
  out=$(SEPOLIA_FORK_RPC='' nice -n 15 forge test --offline --match-path $T --match-test "$NEW" 2>&1)
  echo "=== $label"; echo "$out" | grep -E "^\[FAIL|^Ran [0-9]+ test suites|Suite result" | sed 's/\x1b\[[0-9;]*m//g'
  git checkout -- "$f"
}
echo "=== baseline (unmutated $(git rev-parse --short HEAD))"; SEPOLIA_FORK_RPC='' nice -n 15 forge test --offline --match-path $T --match-test "$NEW" 2>&1 | grep -E "^\[PASS|^\[FAIL|^Ran [0-9]+ test suites" | sed 's/\x1b\[[0-9;]*m//g'
# Pre-fix behaviour is OZ's EIP712 with name "": the clone's name hash is keccak256(""). (Deleting the
# assignment instead leaves bytes32(0), which is not the pre-fix state and does not reject old signatures.)
run "M1 C2-02 reverted (clone domain name hash = keccak256(\"\"))" contracts/src/tokens/v2/xPNTsTokenV2.sol "_eip712NameHash = keccak256(bytes(c.name));" "_eip712NameHash = keccak256(\"\");"
run "M2 I-01 over-strict (cap checked on gross mint, not net)" contracts/src/tokens/v2/xPNTsV2Base.sol "_checkIssuanceCap(value - repayXPNTs);" "_checkIssuanceCap(value);"
run "M4 I-01 removed (cap never checked)" contracts/src/tokens/v2/xPNTsV2Base.sol "function _checkIssuanceCap(uint256 amount) internal view {" "function _checkIssuanceCap(uint256 amount) internal view { return;"
run "M3 factory empty-name check removed" contracts/src/tokens/v2/xPNTsFactoryV2.sol "if (bytes(name).length == 0 || exchangeRate == 0)" "if (exchangeRate == 0)"
git status --short contracts/src; echo DONE

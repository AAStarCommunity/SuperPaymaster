#!/usr/bin/env bash
# Proves run-tests.sh and run-negative-controls.sh are fail-closed: each is run with an injected failure
# and must exit non-zero. Logs go to results/selftest/; summary in results/selftest/selftest.txt.
# Injections:
#   S1 run-tests.sh with one test assertion broken (FEE_NEW expected where FEE0 is charged in a control)
#   S2 run-negative-controls.sh with INJECT=noapply (a mutant that does not apply)
#   S3 run-negative-controls.sh with INJECT=undetected (a mutant that keeps the suite green)
# The test file is restored from a backup and its sha256 re-checked. Exit 0 only if S1-S3 all exit
# non-zero AND the restore check holds. Run from the repo root.
set -uo pipefail
D=docs/design/aoa-balance-mode/data/d5b/a2-item5-midflight
T=contracts/test/v2/SuperPaymasterRc1Rc2MidBundle.t.sol
S=$D/results/selftest
mkdir -p "$S"
BK=$(mktemp)
cp "$T" "$BK" || exit 1
SHA0=$(shasum -a 256 "$T" | cut -d' ' -f1)
trap 'cp "$BK" "$T"' EXIT
SUM="$S/selftest.txt"
: > "$SUM"
BAD=0
expect_fail() { # name, exit code
  if [ "$2" -ne 0 ]; then echo "$1: exit $2 (non-zero, as required)" | tee -a "$SUM"
  else echo "$1: exit 0 -- NOT FAIL-CLOSED" | tee -a "$SUM"; BAD=1; fi
}

# S1: break one assertion of a passing test, then run the archive runner into a scratch OUT
sed -i.bak 's/_assertSettled(h, r, FEE0, FEE_NEW, b0, rv0, s0, "control rc.2->rc.2");/_assertSettled(h, r, FEE_NEW, FEE0, b0, rv0, s0, "control rc.2->rc.2");/' "$T" && rm -f "$T.bak"
if cmp -s "$T" "$BK"; then echo "S1: injection did not apply" | tee -a "$SUM"; BAD=1; fi
OUT=$S/s1-run-tests bash $D/run-tests.sh > "$S/s1-run-tests.out" 2>&1
expect_fail "S1 run-tests.sh with a failing test" $?
cp "$BK" "$T"

# S2 / S3: negative-control runner with an injected bad mutant
OUT=$S/s2-noapply INJECT=noapply bash $D/run-negative-controls.sh > "$S/s2-noapply.out" 2>&1
expect_fail "S2 run-negative-controls.sh INJECT=noapply" $?
OUT=$S/s3-undetected INJECT=undetected bash $D/run-negative-controls.sh > "$S/s3-undetected.out" 2>&1
expect_fail "S3 run-negative-controls.sh INJECT=undetected" $?

cp "$BK" "$T"
trap - EXIT
SHA1=$(shasum -a 256 "$T" | cut -d' ' -f1)
if [ "$SHA0" = "$SHA1" ]; then echo "restored: $T sha256 $SHA1" | tee -a "$SUM"; else echo "RESTORE MISMATCH" | tee -a "$SUM"; BAD=1; fi
if [ "$BAD" -ne 0 ]; then echo "SELFTEST: FAILED" | tee -a "$SUM"; exit 1; fi
echo "SELFTEST: OK (all injected failures produced a non-zero exit)" | tee -a "$SUM"

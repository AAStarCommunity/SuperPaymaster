#!/usr/bin/env bash
# Negative controls for SuperPaymasterRc1Rc2MidBundleTest (N1-N9) and SuperPaymasterV542ToRc2MidBundleTest
# (N10-N12). Each mutant is one sed substitution on ONE test file (an expectation, a fixture path, or one batch entry). Per mutant, `run` prints exactly one of:
#   RED as expected       forge exited non-zero AND the log contains the named assertion message
#   MUTATION DID NOT APPLY  sed left the file byte-identical            -> counted as a failure
#   NOT DETECTED          forge exited 0, or failed without the named message -> counted as a failure
# Both files are copied back from backups before each mutant and on exit; each final sha256 must equal the
# one taken at start. Exit status: 0 only if every mutant is "RED as expected" AND the restore check holds;
# otherwise 1. Run from the repo root.
# Self-test hooks (selftest-fail-closed.sh): INJECT=noapply adds a mutant whose pattern matches nothing;
# INJECT=undetected adds a mutant that only edits a comment (tests stay green). OUT may be overridden.
set -uo pipefail
FORGE=${FORGE:-$(command -v forge || echo "$HOME/.foundry/bin/forge")}
T=contracts/test/v2/SuperPaymasterRc1Rc2MidBundle.t.sol
T2=contracts/test/v2/SuperPaymasterV542ToRc2MidBundle.t.sol
OUT=${OUT:-docs/design/aoa-balance-mode/data/d5b/a2-item5-midflight/results}
mkdir -p "$OUT"
BK=$(mktemp)
BK2=$(mktemp)
cp "$T" "$BK" || exit 1
cp "$T2" "$BK2" || exit 1
SHA0=$(shasum -a 256 "$T" | cut -d' ' -f1)
SHA0B=$(shasum -a 256 "$T2" | cut -d' ' -f1)
restore() { cp "$BK" "$T"; cp "$BK2" "$T2"; }
trap restore EXIT
BAD=0
SUMMARY="$OUT/negative-controls.txt"
: > "$SUMMARY"

run() { # name, sed-expr, match-test, expected message  (mutates $T, runs the rc.1/rc.2 suite)
  mutant "$1" "$T" "$BK" SuperPaymasterRc1Rc2MidBundleTest "$2" "$3" "$4"
}
run542() { # same, on $T2 / the 5.4.2 -> rc.2 suite
  mutant "$1" "$T2" "$BK2" SuperPaymasterV542ToRc2MidBundleTest "$2" "$3" "$4"
}
mutant() { # name, file, backup, contract, sed-expr, match-test, expected message
  local name=$1 f=$2 bk=$3 mc=$4 expr=$5 mt=$6 msg=$7
  restore
  sed -i.bak "$expr" "$f" && rm -f "$f.bak"
  if cmp -s "$f" "$bk"; then echo "$name: MUTATION DID NOT APPLY" | tee -a "$SUMMARY"; BAD=1; return; fi
  "$FORGE" test --match-contract "$mc" --match-test "$mt" -vv > "$OUT/neg-$name.log" 2>&1
  local rc=$?
  if [ $rc -ne 0 ] && grep -qF "$msg" "$OUT/neg-$name.log"; then
    echo "$name: RED as expected (exit $rc; message: $msg)" | tee -a "$SUMMARY"
  else
    echo "$name: NOT DETECTED (exit $rc)" | tee -a "$SUMMARY"; BAD=1
  fi
}

# N1: claim rc.2 applies a fee snapshot to rc.1 contexts (forward)
run N1-forward-fee 's/_assertSettled(h, r, FEE_NEW, FEE0, b0, rv0, s0, "forward/_assertSettled(h, r, FEE0, FEE_NEW, b0, rv0, s0, "forward/' \
  test_rc1_to_rc2_forward_mid_bundle "charged at the expected protocol fee"
# N2: claim rc.1 honours rc.2's fee snapshot after rollback
run N2-rollback-fee 's/_assertSettled(h, r, FEE_NEW, FEE0, b0, rv0, s0, "rollback/_assertSettled(h, r, FEE0, FEE_NEW, b0, rv0, s0, "rollback/' \
  test_rc2_to_rc1_rollback_mid_bundle "charged at the expected protocol fee"
# N3: load the rc.2 bytes as "rc.1"
run N3-fixture-identity 's/superpaymaster-5.5.0-rc.1-7ae5b340-impl.creation.hex/superpaymaster-5.5.0-rc.2-1ac0e1c5-impl.creation.hex/' \
  test_rc1_to_rc2_forward_mid_bundle "fixture identity"
# N4: load the old c30854f9 fixture as "rc.1"
run N4-old-fixture 's/superpaymaster-5.5.0-rc.1-7ae5b340-impl.creation.hex/superpaymaster-5.5.0-c30854f9-impl.creation.hex/' \
  test_rc1_to_rc2_forward_mid_bundle "fixture identity"
# N5: drop the gas-parameter execution from the forward batch
run N5-no-gasparams 's/p\[1\] = abi.encodeCall(SuperPaymasterAdmin.executeGasParams, ()); \/\/ extension of the NEW core/p[1] = abi.encodeCall(SuperPaymasterAdmin.setProtocolFee, (FEE_NEW));/' \
  test_rc1_to_rc2_forward_mid_bundle "gas params changed mid-bundle"
# N6/N7: live-param interpretation of the gas buffer, bundle level (both directions share _assertSettled)
run N6-bundle-live-buffer-fwd 's/uint256 bufExp = bufSnap;/uint256 bufExp = bufLive;/' \
  test_rc1_to_rc2_forward_mid_bundle "gas buffer"
run N7-bundle-live-buffer-rb 's/uint256 bufExp = bufSnap;/uint256 bufExp = bufLive;/' \
  test_rc2_to_rc1_rollback_mid_bundle "gas buffer"
# N8/N9: live-param interpretation, exact direct-postOp check
run N8-exact-live-fwd 's/uint256 expAGas = expSnap;/uint256 expAGas = expLive;/' \
  test_exact_forward_rc1ctx_settledByRc2 "exact aGas under the validation-time gas snapshot"
run N9-exact-live-rb 's/uint256 expAGas = expSnap;/uint256 expAGas = expLive;/' \
  test_exact_rollback_rc2ctx_settledByRc1 "exact aGas under the validation-time gas snapshot"

# N10: claim the in-flight 5.4.2 ops are NOT rejected for their context length
run542 N10-v542-no-invalidlen 's/assertEq(r.nInvalidLen, 2,/assertEq(r.nInvalidLen, 0,/' \
  test_v542_to_rc2_forward_mid_bundle_inflightOpsFail "revert reason is PostOpReverted(InvalidContextLength())"
# N11: claim the operator gets its validation debit back (the failure mode says it does not)
run542 N11-v542-operator-refunded 's/assertEq(uint256(s0.opBal) - s1.opBal, 2 \* a0,/assertEq(uint256(s0.opBal) - s1.opBal, 0,/' \
  test_v542_to_rc2_forward_mid_bundle_inflightOpsFail "operator lost the full validation debit"
# N12: control actually upgrades -> its "settles normally" claims must fail
run542 N12-v542-control-upgrades 's/ops\[0\] = _ownerOp(abi.encodeWithSignature("version()"));/ops[0] = _ownerOp(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", rc2, bytes("")));/' \
  test_control_v542_stays_settlesNormally "precondition: still 5.4.2"

case "${INJECT:-}" in
  noapply) run X-noapply 's/THIS_PATTERN_DOES_NOT_EXIST_IN_THE_FILE/x/' test_rc1_to_rc2_forward_mid_bundle "n/a" ;;
  undetected) run X-undetected 's/(state rolled back afterwards)/(state rolled back afterwards; injected)/' \
    test_rc1_to_rc2_forward_mid_bundle "n/a" ;;
esac

restore
trap - EXIT
SHA1=$(shasum -a 256 "$T" | cut -d' ' -f1)
SHA1B=$(shasum -a 256 "$T2" | cut -d' ' -f1)
if [ "$SHA0" = "$SHA1" ] && [ "$SHA0B" = "$SHA1B" ]; then
  echo "restored: $T sha256 $SHA1" | tee -a "$SUMMARY"
  echo "restored: $T2 sha256 $SHA1B" | tee -a "$SUMMARY"
else
  echo "RESTORE MISMATCH: $SHA0 -> $SHA1 / $SHA0B -> $SHA1B" | tee -a "$SUMMARY"; BAD=1
fi
if [ "$BAD" -ne 0 ]; then echo "RESULT: FAILED" | tee -a "$SUMMARY"; exit 1; fi
echo "RESULT: ALL MUTANTS RED" | tee -a "$SUMMARY"

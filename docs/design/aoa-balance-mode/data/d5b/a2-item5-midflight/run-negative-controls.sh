#!/usr/bin/env bash
# Negative controls for SuperPaymasterRc1Rc2MidBundleTest: each mutant is one sed substitution on the
# test file (an expected fee, a fixture path, or one batch entry); `run` reports "RED as expected" only if
# forge exits non-zero AND its log contains the named assertion message, and "MUTATION DID NOT APPLY" if
# sed left the file unchanged. Before each mutant and on exit the file is copied back from a backup; the
# final sha256 is compared with the one taken at start (script exits 1 on mismatch). Run from the repo root.
set -u
FORGE=${FORGE:-$(command -v forge || echo "$HOME/.foundry/bin/forge")}
T=contracts/test/v2/SuperPaymasterRc1Rc2MidBundle.t.sol
OUT=docs/design/aoa-balance-mode/data/d5b/a2-item5-midflight/results
BK=$(mktemp)
cp "$T" "$BK"
SHA0=$(shasum -a 256 "$T" | cut -d' ' -f1)
restore() { cp "$BK" "$T"; }
trap restore EXIT

run() { # name, sed-expr, match-test, expected message
  local name=$1 expr=$2 mt=$3 msg=$4
  restore
  sed -i.bak "$expr" "$T" && rm -f "$T.bak"
  if cmp -s "$T" "$BK"; then echo "$name: MUTATION DID NOT APPLY" | tee -a "$OUT/negative-controls.txt"; return; fi
  "$FORGE" test --match-contract SuperPaymasterRc1Rc2MidBundleTest --match-test "$mt" -vv > "$OUT/neg-$name.log" 2>&1
  local rc=$?
  if [ $rc -ne 0 ] && grep -q "$msg" "$OUT/neg-$name.log"; then
    echo "$name: RED as expected (exit $rc; message: $msg)" | tee -a "$OUT/negative-controls.txt"
  else
    echo "$name: NOT DETECTED (exit $rc)" | tee -a "$OUT/negative-controls.txt"
  fi
}

: > "$OUT/negative-controls.txt"
# N1: claim rc.2 applies a fee snapshot to rc.1 contexts (forward) -> charge assertion must fail
run N1-forward-fee 's/_assertSettled(h, r, FEE_NEW, FEE0, b0, rv0, s0, "forward/_assertSettled(h, r, FEE0, FEE_NEW, b0, rv0, s0, "forward/' \
  test_rc1_to_rc2_forward_mid_bundle "charged at the expected protocol fee"
# N2: claim rc.1 honours rc.2's fee snapshot after rollback -> charge assertion must fail
run N2-rollback-fee 's/_assertSettled(h, r, FEE_NEW, FEE0, b0, rv0, s0, "rollback/_assertSettled(h, r, FEE0, FEE_NEW, b0, rv0, s0, "rollback/' \
  test_rc2_to_rc1_rollback_mid_bundle "charged at the expected protocol fee"
# N3: load the rc.2 bytes as "rc.1" -> fixture identity assertion must fail
run N3-fixture-identity 's/superpaymaster-5.5.0-rc.1-7ae5b340-impl.creation.hex/superpaymaster-5.5.0-rc.2-1ac0e1c5-impl.creation.hex/' \
  test_rc1_to_rc2_forward_mid_bundle "fixture identity"
# N4: load the old c30854f9 fixture as "rc.1" -> fixture identity assertion must fail
run N4-old-fixture 's/superpaymaster-5.5.0-rc.1-7ae5b340-impl.creation.hex/superpaymaster-5.5.0-c30854f9-impl.creation.hex/' \
  test_rc1_to_rc2_forward_mid_bundle "fixture identity"
# N5: drop the gas-parameter execution from the forward batch -> the mid-bundle-state precondition must fail
run N5-no-gasparams 's/p\[1\] = abi.encodeCall(SuperPaymasterAdmin.executeGasParams, ()); \/\/ extension of the NEW core/p[1] = abi.encodeCall(SuperPaymasterAdmin.setProtocolFee, (FEE_NEW));/' \
  test_rc1_to_rc2_forward_mid_bundle "gas params changed mid-bundle"

restore
trap - EXIT
SHA1=$(shasum -a 256 "$T" | cut -d' ' -f1)
[ "$SHA0" = "$SHA1" ] && echo "restored: $T sha256 $SHA1" | tee -a "$OUT/negative-controls.txt" || { echo "RESTORE MISMATCH"; exit 1; }

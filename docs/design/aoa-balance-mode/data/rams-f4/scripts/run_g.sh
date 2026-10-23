#!/bin/bash
# R2-F4 G-layer re-run: the R-AMS-2a scratch fixture (contracts/test/zz_rams2a/Rams2a.t.sol, + one added
# test test_B4b) in a throwaway copy of the v5.5.0-rc.4 tree (/tmp/f4g), with every product contract the
# fixture deploys taken from the rc.4 forge-1.7.1 profile.default ARTIFACT BYTES (f4art/*.json via
# deployCode, see fixture.diff). Test helpers/mocks are still compiled by the test (nightly, prague, as in
# R-AMS-2a). Runtime: --hardfork amsterdam, same flags as R-AMS-2a scratch/scr_run.sh.
set -u
cd /tmp/f4g
export FOUNDRY_ISOLATE=false FOUNDRY_DISABLE_NIGHTLY_WARNING=1 FOUNDRY_OUT=/tmp/f4g-out FOUNDRY_CACHE_PATH=/tmp/f4g-cache
F=/tmp/fd/nightly/forge
L=/tmp/f4g-logs
M="--offline --no-isolate --evm-version prague --match-path contracts/test/zz_rams2a/Rams2a.t.sol -vv"
for t in test_B1 test_B2 test_B3_TR1409 test_B3_min_postOp test_B3_min_paymasterVerificationGasLimit \
         test_B3_min_verificationGasLimit_account test_B3_min_callGasLimit test_B4_no_oog test_B4b \
         test_B5 test_B6 test_B7 test_B8 test_C_wrap; do
  n=$t; [ "$n" = test_B4_no_oog ] && n=test_B4
  echo "[$(date -u +%FT%TZ)] start $n" >> $L/timeline.txt
  $F test $M --match-test "$t" --hardfork amsterdam > $L/${n}_amsterdam.log 2>&1; rc=$?
  echo "[$(date -u +%FT%TZ)] end $n exit $rc" >> $L/timeline.txt
done
echo DONE >> $L/timeline.txt

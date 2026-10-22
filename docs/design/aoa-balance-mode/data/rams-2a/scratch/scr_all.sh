#!/bin/bash
S=/home/user/SuperPaymaster/docs/design/aoa-balance-mode/data/rams-2a/scratch
cd /tmp/rams/wt
export FOUNDRY_ISOLATE=false FOUNDRY_DISABLE_NIGHTLY_WARNING=1 FOUNDRY_OUT=/tmp/rams/out_wtp FOUNDRY_CACHE_PATH=/tmp/rams/cache_wtp
F=/tmp/fd/nightly/forge
M="--offline --no-isolate --evm-version prague --match-path contracts/test/zz_rams2a/Rams2a.t.sol -vv"
echo "[$(date -u +%FT%TZ)] start A" >> /tmp/rams/scr/timeline.txt
$F test $M --match-test test_A > /tmp/rams/scr/A_prague.log 2>&1
$F test $M --match-test test_A --hardfork amsterdam > /tmp/rams/scr/A_amsterdam.log 2>&1
$F test $M --match-test test_A --hardfork amsterdam --enable-tx-gas-limit > /tmp/rams/scr/A_amsterdam_reservoir.log 2>&1
echo "[$(date -u +%FT%TZ)] end A" >> /tmp/rams/scr/timeline.txt
bash $S/scr_run.sh test_B1 test_B2 test_B3_TR1409 test_B3_min_postOp test_B3_min_paymasterVerificationGasLimit test_B3_min_verificationGasLimit_account test_B3_min_callGasLimit test_B4 test_B5 test_B6 test_B7 test_B8 test_C_wrap
echo DONE >> /tmp/rams/scr/timeline.txt

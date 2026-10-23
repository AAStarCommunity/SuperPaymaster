#!/bin/bash
# R2-F4 G-layer re-run: the R-AMS-2a scratch fixture (contracts/test/zz_rams2a/Rams2a.t.sol, + added tests
# test_B4b and test_F2_matrix) in a throwaway copy of the v5.5.0-rc.4 tree (/tmp/f4g, built by
# scripts/setup_f4g.sh), with every product contract the fixture deploys taken from the rc.4 forge-1.7.1
# profile.default ARTIFACT BYTES (f4art/*.json = committed artifacts/, via deployCode, see
# fixture/artifact-run.diff). Test helpers/mocks are still compiled by the test (nightly, prague, as in
# R-AMS-2a). Runtime: --hardfork amsterdam, same flags as R-AMS-2a scratch/scr_run.sh.
#
# Usage: scripts/run_g.sh <log dir>                  --no-isolate (R-AMS-2a mode; §4.3)
#        ISOLATE=1 scripts/run_g.sh <log dir>        --isolate --gas-limit 100000000000 (§4.4); or run_g_isolate.sh
# Every log starts with '# cmd:' / '# env:' / '# forge:' header lines recording the exact invocation.
#
# History: the first --no-isolate invocation (2026-10-23T05:01:59Z, logs/g/timeline.txt line 15) used the
# B4 pattern 'test_B4_no_oog_band$', which matches no test (forge matches the regex against the name with
# its '()' suffix); B4 was re-run by hand with 'test_B4_no_oog' at 05:02:30Z (line 30). This script uses
# 'test_B4_no_oog' from the start.
set -u
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
L=${1:?log dir}; mkdir -p "$L"; L=$(cd "$L" && pwd)
cd /tmp/f4g
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1 FOUNDRY_OUT=/tmp/f4g-out FOUNDRY_CACHE_PATH=/tmp/f4g-cache
F=/tmp/fd/nightly/forge
if [ "${ISOLATE:-0}" = 1 ]; then
  export FOUNDRY_ISOLATE=true
  M=(--offline --isolate --gas-limit 100000000000 --evm-version prague --match-path contracts/test/zz_rams2a/Rams2a.t.sol -vv)
  sfx=_amsterdam_isolate
  # B4/B4b are not applicable under --isolate (direct postOp after a separate validation call)
  T=(test_B1 test_B2 test_B3_TR1409 test_B3_min_postOp test_B3_min_paymasterVerificationGasLimit
     test_B3_min_verificationGasLimit_account test_B3_min_callGasLimit test_B5 test_B6 test_B7 test_B8
     test_C_wrap test_F2_matrix)
else
  export FOUNDRY_ISOLATE=false
  M=(--offline --no-isolate --evm-version prague --match-path contracts/test/zz_rams2a/Rams2a.t.sol -vv)
  sfx=_amsterdam
  T=(test_B1 test_B2 test_B3_TR1409 test_B3_min_postOp test_B3_min_paymasterVerificationGasLimit
     test_B3_min_verificationGasLimit_account test_B3_min_callGasLimit test_B4_no_oog test_B4b
     test_B5 test_B6 test_B7 test_B8 test_C_wrap)
fi
echo "# run_g.sh ISOLATE=${ISOLATE:-0} sha256 $(sha256sum "$SELF" | cut -c1-64) tree $(git rev-parse HEAD) $(date -u +%FT%TZ)" >> "$L/timeline.txt"
for t in "${T[@]}"; do
  n=$t; [ "$n" = test_B4_no_oog ] && n=test_B4
  cmd=("$F" test "${M[@]}" --match-test "$t" --hardfork amsterdam)
  echo "[$(date -u +%FT%TZ)] start $n" >> "$L/timeline.txt"
  {
    echo "# cmd: (cd $PWD && ${cmd[*]})"
    echo "# env: FOUNDRY_ISOLATE=$FOUNDRY_ISOLATE FOUNDRY_OUT=$FOUNDRY_OUT FOUNDRY_CACHE_PATH=$FOUNDRY_CACHE_PATH FOUNDRY_DISABLE_NIGHTLY_WARNING=1"
    echo "# forge: $("$F" --version | tr '\n' ' ')sha256 $(sha256sum "$F" | cut -c1-64)"
    echo "# tree: $(git rev-parse HEAD) contracts/src $(git rev-parse HEAD:contracts/src) foundry.toml $(git rev-parse HEAD:foundry.toml); Rams2a.t.sol $(sha256sum contracts/test/zz_rams2a/Rams2a.t.sol | cut -c1-64); SuperPaymasterV55Gas.t.sol $(sha256sum contracts/test/v2/SuperPaymasterV55Gas.t.sol | cut -c1-64)"
    echo "# start: $(date -u +%FT%TZ)"
  } > "$L/${n}${sfx}.log"
  "${cmd[@]}" >> "$L/${n}${sfx}.log" 2>&1; rc=$?
  echo "[$(date -u +%FT%TZ)] end $n exit $rc" >> "$L/timeline.txt"
done
echo DONE >> "$L/timeline.txt"

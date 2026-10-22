#!/bin/bash
# Re-run the suites that read profile.default artifacts from ./out, after ./out was filled from
# the nightly cancun profile.default build (/tmp/rams/out_nc). Same flags as run.sh per config.
cd /home/user/SuperPaymaster
L=/tmp/rams/logs; export FOUNDRY_ISOLATE=false; SEED=0x5eed
P='contracts/test/{halmos/D5c1Replay.t.sol,scripts/CheckDefaultArtifacts.t.sol,scripts/DeployAPNTsCapped.t.sol,tokens/APNTsCappedSPIntegration.t.sol,v2/SuperPaymasterV55Adversarial.t.sol}'
rr() { local name=$1 F=$2 out=$3 cache=$4; shift 4
  local iso=""; [ "$F" != /tmp/fd/v1.7.1/forge ] && iso=--no-isolate
  echo "[$(date -u +%FT%TZ)] start ${name}_rerun: $F test --offline $iso --fuzz-seed $SEED -vv --match-path '$P' $*" | tee -a $L/timeline.txt
  FOUNDRY_OUT=$out FOUNDRY_CACHE_PATH=$cache $F test --offline $iso --fuzz-seed $SEED -vv --match-path "$P" "$@" > $L/${name}_rerun.log 2>&1
  local rc=$?
  echo "[$(date -u +%FT%TZ)] end ${name}_rerun exit=$rc" | tee -a $L/timeline.txt; }
rr n_prague    /tmp/fd/nightly/forge /tmp/rams/out_np /tmp/rams/cache_np --evm-version prague
rr n_amsterdam /tmp/fd/nightly/forge /tmp/rams/out_np /tmp/rams/cache_np --evm-version prague --hardfork amsterdam
rr n_cancun    /tmp/fd/nightly/forge /tmp/rams/out_nc /tmp/rams/cache_nc
rr d_171_cancun /tmp/fd/v1.7.1/forge /tmp/rams/out_171 /tmp/rams/cache_171
echo RERUN_DONE >> $L/timeline.txt

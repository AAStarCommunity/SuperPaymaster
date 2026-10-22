#!/bin/bash
# Sequential full-suite sweep (R-AMS-2a). Logs to /tmp/rams/logs.
cd /home/user/SuperPaymaster
L=/tmp/rams/logs; mkdir -p $L
export FOUNDRY_ISOLATE=false
SEED=0x5eed
run() { # name forge outdir cachedir extra...
  local name=$1 F=$2 out=$3 cache=$4; shift 4
  local iso=""; [ "$F" != /tmp/fd/v1.7.1/forge ] && iso=--no-isolate
  echo "[$(date -u +%FT%TZ)] start $name: $F test --offline $iso --fuzz-seed $SEED -vv $*" | tee -a $L/timeline.txt
  local t0=$(date +%s)
  FOUNDRY_OUT=$out FOUNDRY_CACHE_PATH=$cache $F test --offline $iso --fuzz-seed $SEED -vv "$@" > $L/$name.log 2>&1
  local rc=$?
  echo "[$(date -u +%FT%TZ)] end $name exit=$rc secs=$(( $(date +%s)-t0 ))" | tee -a $L/timeline.txt
}
run n_prague    /tmp/fd/nightly/forge /tmp/rams/out_np /tmp/rams/cache_np --evm-version prague
run n_amsterdam /tmp/fd/nightly/forge /tmp/rams/out_np /tmp/rams/cache_np --evm-version prague --hardfork amsterdam
run n_cancun    /tmp/fd/nightly/forge /tmp/rams/out_nc /tmp/rams/cache_nc
run d_171_cancun /tmp/fd/v1.7.1/forge /tmp/rams/out_171 /tmp/rams/cache_171
echo DONE >> $L/timeline.txt

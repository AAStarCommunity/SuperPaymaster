#!/bin/bash
# Sequential full-suite sweep. Logs to /tmp/sweep/logs.
cd /home/user/SuperPaymaster
L=/tmp/sweep/logs; mkdir -p $L
export FOUNDRY_ISOLATE=false
SEED=0x5eed
run() { # name forge outdir cachedir extra...
  local name=$1 F=$2 out=$3 cache=$4; shift 4
  echo "[$(date -u +%FT%TZ)] start $name: $F test --offline --no-isolate --fuzz-seed $SEED -vv $*" | tee -a $L/timeline.txt
  local t0=$(date +%s)
  FOUNDRY_OUT=$out FOUNDRY_CACHE_PATH=$cache $F test --offline $([ "$F" = /tmp/fd/v1.8.6/forge ] && echo --no-isolate) --fuzz-seed $SEED -vv "$@" > $L/$name.log 2>&1
  echo "[$(date -u +%FT%TZ)] end $name exit=$? secs=$(( $(date +%s)-t0 ))" | tee -a $L/timeline.txt
}
run a_186_cancun    /tmp/fd/v1.8.6/forge out        cache
run b_186_prague    /tmp/fd/v1.8.6/forge /tmp/sweep/out_prague /tmp/sweep/cache_prague --evm-version prague
run c_186_amsterdam /tmp/fd/v1.8.6/forge /tmp/sweep/out_prague /tmp/sweep/cache_prague --evm-version prague --hardfork amsterdam
run d_171_cancun    /tmp/fd/v1.7.1/forge /tmp/sweep/out_171 /tmp/sweep/cache_171
echo DONE >> $L/timeline.txt

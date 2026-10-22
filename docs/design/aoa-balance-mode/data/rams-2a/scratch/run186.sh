#!/bin/bash
# 1.8.6 (old-sweep engine) prague / amsterdam, same flags as the nightly runs; main runs without ./out, then ./out reruns.
cd /home/user/SuperPaymaster
L=/tmp/rams/logs; export FOUNDRY_ISOLATE=false; SEED=0x5eed; F=/tmp/fd/v1.8.6/forge
P='contracts/test/{halmos/D5c1Replay.t.sol,scripts/CheckDefaultArtifacts.t.sol,scripts/DeployAPNTsCapped.t.sol,tokens/APNTsCappedSPIntegration.t.sol,v2/SuperPaymasterV55Adversarial.t.sol}'
r() { local name=$1; shift
  echo "[$(date -u +%FT%TZ)] start $name: $F test --offline --no-isolate --fuzz-seed $SEED -vv $*" | tee -a $L/timeline.txt
  FOUNDRY_OUT=/tmp/rams/out_186p FOUNDRY_CACHE_PATH=/tmp/rams/cache_186p $F test --offline --no-isolate --fuzz-seed $SEED -vv "$@" > $L/$name.log 2>&1
  local rc=$?; echo "[$(date -u +%FT%TZ)] end $name exit=$rc" | tee -a $L/timeline.txt; }
r v186_prague --evm-version prague
r v186_amsterdam --evm-version prague --hardfork amsterdam
cp -a /tmp/rams/out_filled out
r v186_prague_rerun --evm-version prague --match-path "$P"
r v186_amsterdam_rerun --evm-version prague --hardfork amsterdam --match-path "$P"
rm -rf out
echo V186_DONE >> $L/timeline.txt

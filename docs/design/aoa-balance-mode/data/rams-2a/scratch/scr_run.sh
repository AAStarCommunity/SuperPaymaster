#!/bin/bash
# Scratch G-layer runs (copy of the tree at /tmp/rams/wt; scratch test contracts/test/zz_rams2a/Rams2a.t.sol)
cd /tmp/rams/wt
export FOUNDRY_ISOLATE=false FOUNDRY_DISABLE_NIGHTLY_WARNING=1 FOUNDRY_OUT=/tmp/rams/out_wtp FOUNDRY_CACHE_PATH=/tmp/rams/cache_wtp
F=/tmp/fd/nightly/forge
M="--offline --no-isolate --evm-version prague --match-path contracts/test/zz_rams2a/Rams2a.t.sol -vv"
for t in "$@"; do
  echo "[$(date -u +%FT%TZ)] start $t" >> /tmp/rams/scr/timeline.txt
  $F test $M --match-test "$t" > /tmp/rams/scr/${t}_prague.log 2>&1
  $F test $M --match-test "$t" --hardfork amsterdam > /tmp/rams/scr/${t}_amsterdam.log 2>&1
  echo "[$(date -u +%FT%TZ)] end $t" >> /tmp/rams/scr/timeline.txt
done

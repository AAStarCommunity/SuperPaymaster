#!/bin/bash
# D5c-1 full suite first (600 s per-partition caps are load-sensitive), then I9 targets.
S=$SCRATCH
( while [ ! -f $S/out/CHAIN-DONE ]; do echo "$(date -u +%FT%TZ) $(sysctl -n vm.loadavg)"; sleep 60; done ) > $S/out/load.log 2>&1 &
date -u +%FT%TZ > $S/out/chain.start
bash $S/out/d5c1-full.sh 1; echo "d5c1 rc=$?" >> $S/out/chain.log
bash $S/out/i9-drive.sh; echo "i9 rc=$?" >> $S/out/chain.log
date -u +%FT%TZ > $S/out/CHAIN-DONE

#!/bin/zsh
# Usage: fetch_logs.sh <rpcfile> <label> <address> <from> <to> [topic0]
# Fetches eth_getLogs in 100k-block pages; on error halves the page (recursive). Never prints RPC URL.
C=~/.foundry/bin/cast; U=$(cat $1); L=$2; ADDR=$3; FROM=$4; TO=$5; T0=$6
OUT=/Users/jason/Dev/aastar/manifest-live/reg02-sepolia-evidence/logs/$L; mkdir -p $OUT
page() { local f=$1 t=$2; local fn=$OUT/${f}-${t}.json
  if [ -n "$T0" ]; then $C logs --from-block $f --to-block $t --address $ADDR $T0 --json -r $U > $fn 2> $fn.err
  else $C logs --from-block $f --to-block $t --address $ADDR --json -r $U > $fn 2> $fn.err; fi
  if [ $? -ne 0 ] || ! python3 -c "import json,sys;json.load(open('$fn'))" 2>/dev/null; then
    echo "ERR $f-$t: $(sed -E 's#https?://[^ \"]+#<url>#g' $fn.err | head -c 200)"; rm -f $fn
    if [ $((t-f)) -lt 1000 ]; then echo "GAP $f-$t"; return; fi
    local m=$(((f+t)/2)); page $f $m; page $((m+1)) $t
  else rm -f $fn.err; echo "OK $f-$t $(python3 -c "import json;print(len(json.load(open('$fn'))))")"; fi; }
s=$FROM; while [ $s -le $TO ]; do e=$((s+99999)); [ $e -gt $TO ] && e=$TO; page $s $e; s=$((e+1)); done

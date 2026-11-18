#!/bin/bash
# usage: start_fork.sh PROXY_PORT ANVIL_PORT FORK_BLOCK EVIDENCE_DIR  ; Tenderly upstream via file -> loopback proxy -> anvil
PP=$1; AP=$2; BLK=$3; E=$4
nohup python3 -I "$E/helpers/rpc_forward_proxy.py" "$PP" /Users/jason/Dev/aastar/manifest-live/.rpc/rpcb "$E/proxy-errors.log" >/dev/null 2>&1 &
echo $! > "$E/proxy.pid"; sleep 1
nohup "$HOME/Dev/aastar/tools/foundry-rams/nightly-4e8874b/anvil" --fork-url "http://127.0.0.1:$PP" --fork-block-number "$BLK" --hardfork amsterdam --port "$AP" --silent >/dev/null 2>&1 &
echo $! > "$E/anvil.pid"

#!/bin/bash
# usage: start_anvil.sh PORT PIDFILE [extra anvil args...]
PORT=$1; PIDFILE=$2; shift 2
OP_RPC=$(cat /Users/jason/Dev/aastar/manifest-live/.rpc/opa)
nohup ~/.foundry/bin/anvil --fork-url "$OP_RPC" --hardfork prague --port "$PORT" --silent "$@" >/dev/null 2>&1 &
echo $! > "$PIDFILE"
unset OP_RPC

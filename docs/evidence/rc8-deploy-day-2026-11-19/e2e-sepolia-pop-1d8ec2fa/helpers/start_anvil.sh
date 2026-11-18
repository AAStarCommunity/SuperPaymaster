#!/bin/bash
# usage: start_anvil.sh ENGINE_DIR PORT PIDFILE FORK_BLOCK HARDFORK [extra anvil args...]
# Fork upstream = Tenderly Sepolia (rpcb). URL is read into env only, never printed.
ENGINE=$1; PORT=$2; PIDFILE=$3; BLK=$4; HF=$5; shift 5
SRC=$(cat /Users/jason/Dev/aastar/manifest-live/.rpc/rpcb)
nohup "$ENGINE/anvil" --fork-url "$SRC" --fork-block-number "$BLK" --hardfork "$HF" --port "$PORT" --silent "$@" >/dev/null 2>&1 &
echo $! > "$PIDFILE"
unset SRC

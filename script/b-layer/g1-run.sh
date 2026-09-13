#!/usr/bin/env bash
# D5 gate G1 — full B1–B10 run: ONE local anvil (Osaka, chain 31337), the 5.5.0 stack, the setup,
# then the same case list against Rundler v0.11.0 (primary), Alto v1.2.5 with its defaults, and
# Alto v1.2.5 with the ERC-7562 unstake delay (86400 s). Between bundlers the chain is reverted to
# the post-setup snapshot, so every bundler sees the identical starting state.
# Each bundler reaches anvil through script/b-layer/g1-proxy.mjs (trace capture).
# Local node only, anvil's public dev keys only, no public RPC.
# Usage: script/b-layer/g1-run.sh <workDir> <rundlerDir> <altoDir>
set -euo pipefail
W="$1"; RUNDLER_DIR="$2"; ALTO_DIR="$3"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ANVIL="${ANVIL:-$HOME/.foundry/bin/anvil}"; CAST="${CAST:-$HOME/.foundry/bin/cast}"
RPC=http://127.0.0.1:18645
CASES="$ROOT/docs/design/aoa-balance-mode/b-layer/cases"
mkdir -p "$W" "$CASES"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

wait_rpc() { for _ in $(seq 1 120); do curl -sf -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$1" >/dev/null && return 0; sleep 0.5; done; echo "no rpc at $1" >&2; return 1; }

"$ANVIL" --port 18645 --chain-id 31337 --hardfork osaka >"$W/anvil.log" 2>&1 & PIDS+=($!)
wait_rpc "$RPC"
"$ROOT/script/b-layer/g1-deploy.sh" "$RPC" docs/design/aoa-balance-mode/b-layer/cases/deploy.json "$W/deploy.log"
node "$ROOT/script/b-layer/g1-setup.mjs" "$RPC" "$CASES/setup.json" | tee "$W/setup.log"
SNAP=$("$CAST" rpc evm_snapshot --rpc-url "$RPC" | tr -d '"')

run_one() { # <label> <proxyPort> <bundlerPort> <kind> <start command...>
  local label="$1" pport="$2" bport="$3" kind="$4"; shift 4
  node "$ROOT/script/b-layer/g1-proxy.mjs" "$pport" "$RPC" "$W/$label-traces.jsonl" >"$W/proxy-$label.log" 2>&1 & local ppid=$!
  wait_rpc "http://127.0.0.1:$pport" # the bundler must not start before its upstream answers
  "$@" >"$W/$label.log" 2>&1 & local bpid=$!
  PIDS+=("$ppid" "$bpid")
  wait_rpc "http://127.0.0.1:$bport"
  sleep 2
  node "$ROOT/script/b-layer/g1-cases.mjs" "$CASES/setup.json" "$kind" "http://127.0.0.1:$bport" "http://127.0.0.1:$pport" \
    "$W/$label-results.json" | tee "$W/$label-cases.log" || true
  kill "$bpid" "$ppid" 2>/dev/null || true; sleep 2
  "$CAST" rpc evm_revert "$SNAP" --rpc-url "$RPC" >/dev/null
  SNAP=$("$CAST" rpc evm_snapshot --rpc-url "$RPC" | tr -d '"')
}

# Rundler v0.11.0 (2a3db237): safe mode is its default; one chain spec for chain 31337.
run_one rundler 18646 18650 rundler bash -c 'cd "$0" && exec env RUST_LOG=info ./target/release/rundler node "$@"' "$RUNDLER_DIR" \
  --chain_spec "$ROOT/docs/design/aoa-balance-mode/b-layer/rundler-chain-31337.toml" \
  --node_http http://127.0.0.1:18646 \
  --signer.private_keys 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba \
  --rpc.port 18650 --metrics.port 18651 --rpc.api eth,debug,rundler

# Alto v1.2.5 (45bbf341), safe mode, its default thresholds (1 ETH / 1 s).
ALTO=(bash -c 'cd "$0" && exec node src/lib/cli/alto.js "$@"' "$ALTO_DIR" run --entrypoints 0x0000000071727De22E5E9d8BAf0edAc6f37da032
  --executor-private-keys 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e
  --utility-private-key 0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356
  --rpc-url http://127.0.0.1:18647 --port 18660 --safe-mode true --enable-debug-endpoints true)
run_one alto 18647 18660 alto "${ALTO[@]}"
# Alto v1.2.5, third data point: thresholds aligned to Rundler / ERC-7562 (1 ETH in wei — v1.2.5
# compares the raw wei stake with --min-entity-stake, reputationManager.ts:307, despite the
# "(in 10e18)" help text — and 86400 s) AND several ops per sender per bundle allowed
# (--enforce-unique-senders-per-bundle defaults to true, i.e. one op per sender per bundle).
ALTO[${#ALTO[@]}]=--min-entity-stake; ALTO[${#ALTO[@]}]=1000000000000000000
ALTO[${#ALTO[@]}]=--min-entity-unstake-delay; ALTO[${#ALTO[@]}]=86400
ALTO[${#ALTO[@]}]=--enforce-unique-senders-per-bundle; ALTO[${#ALTO[@]}]=false
run_one altoMulti 18647 18660 alto "${ALTO[@]}"
echo "G1 run complete: $W"

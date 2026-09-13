#!/usr/bin/env bash
# F1 investigation — one local anvil (Osaka, 31337), the G1 stack + F1 fixtures, then each scenario
# group on a FRESH bundler process from the SAME post-setup snapshot (bundler reputation is
# in-memory, so a ban in one group cannot leak into the next). Bundlers reach anvil through
# g1-proxy.mjs (trace capture). Local node only, anvil's public dev keys only.
# Usage: script/b-layer/f1-run.sh <workDir> <rundlerDir> <altoDir>
set -euo pipefail
W="$1"; RUNDLER_DIR="$2"; ALTO_DIR="$3"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ANVIL="${ANVIL:-$HOME/.foundry/bin/anvil}"; CAST="${CAST:-$HOME/.foundry/bin/cast}"
RPC=http://127.0.0.1:18645
C="$ROOT/docs/design/aoa-balance-mode/b-layer/cases/f1"
export G1_DEPLOY_JSON=docs/design/aoa-balance-mode/b-layer/cases/f1/deploy.json
mkdir -p "$W" "$C"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
wait_rpc() { for _ in $(seq 1 120); do curl -sf -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$1" >/dev/null && return 0; sleep 0.5; done; echo "no rpc at $1" >&2; return 1; }

"$ANVIL" --port 18645 --chain-id 31337 --hardfork osaka >"$W/anvil.log" 2>&1 & PIDS+=($!)
wait_rpc "$RPC"
"$ROOT/script/b-layer/g1-deploy.sh" "$RPC" "$G1_DEPLOY_JSON" "$W/deploy.log"
node "$ROOT/script/b-layer/g1-setup.mjs" "$RPC" "$C/g1-setup.json" >"$W/g1-setup.log"
node "$ROOT/script/b-layer/f1-setup.mjs" "$C/g1-setup.json" "$C/setup.json" | tee "$W/f1-setup.log"
SNAP=$("$CAST" rpc evm_snapshot --rpc-url "$RPC" | tr -d '"')

run_group() { # <label> <kind> <bundlerPort> <scenarios(space-separated)> <start command...>
  local label="$1" kind="$2" bport="$3" scen="$4"; shift 4
  node "$ROOT/script/b-layer/g1-proxy.mjs" 18646 "$RPC" "$W/$label-traces.jsonl" >"$W/proxy-$label.log" 2>&1 & local ppid=$!
  # the bundler must not start before its upstream answers (Rundler reads its signer balance once at
  # start-up; a refused connection leaves it at 0 → "Max bundle fee is zero, skipping bundle")
  wait_rpc http://127.0.0.1:18646
  "$@" >"$W/$label.log" 2>&1 & local bpid=$!
  PIDS+=("$ppid" "$bpid")
  wait_rpc "http://127.0.0.1:$bport"; sleep 2
  # shellcheck disable=SC2086
  node "$ROOT/script/b-layer/f1-cases.mjs" "$C/setup.json" "$kind" "http://127.0.0.1:$bport" http://127.0.0.1:18646 \
    "$W/$label-results.json" $scen | tee "$W/$label-cases.log" || true
  kill "$bpid" "$ppid" 2>/dev/null || true; sleep 2
  "$CAST" rpc evm_revert "$SNAP" --rpc-url "$RPC" >/dev/null
  SNAP=$("$CAST" rpc evm_snapshot --rpc-url "$RPC" | tr -d '"')
}

RUNDLER=(bash -c 'cd "$0" && exec env RUST_LOG=info ./target/release/rundler node "$@"' "$RUNDLER_DIR"
  --chain_spec "$ROOT/docs/design/aoa-balance-mode/b-layer/rundler-chain-31337.toml" --node_http http://127.0.0.1:18646
  --signer.private_keys 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba
  --rpc.port 18650 --metrics.port 18651 --rpc.api eth,debug,rundler)
# Alto v1.2.5, same flags as the G1 "altoMulti" configuration (several ops per sender per bundle allowed)
ALTO=(bash -c 'cd "$0" && exec node src/lib/cli/alto.js "$@"' "$ALTO_DIR" run --entrypoints 0x0000000071727De22E5E9d8BAf0edAc6f37da032
  --executor-private-keys 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e
  --utility-private-key 0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356
  --rpc-url http://127.0.0.1:18646 --port 18660 --safe-mode true --enable-debug-endpoints true
  --min-entity-stake 1000000000000000000 --min-entity-unstake-delay 86400 --enforce-unique-senders-per-bundle false)

for grp in "tpm:tpm1 tpm3" "gSig:gSig" "gRev:gRev" "sp3:sp3"; do
  name="${grp%%:*}"; scen="${grp#*:}"
  run_group "rundler-$name" rundler 18650 "$scen" "${RUNDLER[@]}"
  run_group "alto-$name" alto 18660 "$scen" "${ALTO[@]}"
done
# Self-hosted Rundler config for the paper experiments: one op per sender in the mempool.
for grp in "sp3:sp3" "tpm:tpm1 tpm3"; do
  name="${grp%%:*}"; scen="${grp#*:}"
  run_group "rundlerSSMC1-$name" rundler 18650 "$scen" "${RUNDLER[@]}" --pool.same_sender_mempool_count 1
done
echo "F1 run complete: $W"

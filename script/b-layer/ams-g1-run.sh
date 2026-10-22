#!/usr/bin/env bash
# R-AMS-2 (B layer on an Amsterdam-level chain): G1 B1–B10 as script/b-layer/g1-run.sh, with these
# adaptations only (documented in docs/design/aoa-balance-mode/b-layer/amsterdam/REPORT.md):
#  - anvil = foundry nightly 926eb1d0 (anvil 1.8.7-nightly, the engine calibrated against live Sepolia
#    Amsterdam gas), --hardfork amsterdam --gas-limit 60000000 (was: anvil 1.7.1 --hardfork osaka, 30M);
#    under EIP-8037 a 24 KB contract CREATE costs ~37.8M gas, so the 30M default cannot deploy SP;
#  - evidence goes to amsterdam/<variant>/ instead of cases/ (deploy.json, setup.json);
#  - G1_ESTIMATE=1: per-case bundler estimate + minimum-need + sufficiency probe (ams-probe.mjs);
#  - variant b: GasParams set via queueGasParams → warp 48 h → executeGasParams before the setup, and
#    the op gas fields overridden through G1_GAS_JSON / G1_MIN_POST_OP_GAS.
# Local node only, anvil's public dev keys only, no public RPC.
# Usage: script/b-layer/ams-g1-run.sh <workDir> <rundlerDir> <altoDir> <a|b>
set -euo pipefail
W="$1"; RUNDLER_DIR="$2"; ALTO_DIR="$3"; VARIANT="$4"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ANVIL="${ANVIL:-/tmp/fd/nightly/anvil}"; CAST="${CAST:-/tmp/fd/nightly/cast}"
export FORGE="${FORGE:-/tmp/fd/v171/forge}" FOUNDRY_DISABLE_NIGHTLY_WARNING=1
RPC=http://127.0.0.1:18645
REL="docs/design/aoa-balance-mode/b-layer/amsterdam/$VARIANT"
CASES="$ROOT/$REL"
export G1_DEPLOY_JSON="$REL/deploy.json" G1_ESTIMATE=1
case "$VARIANT" in
  a) ;;
  b) export G1_GAS_JSON='{"pmVerificationGasLimit":"820000","pmPostOpGasLimit":"400000"}' G1_MIN_POST_OP_GAS=400000 ;;
  *) echo "variant a|b" >&2; exit 1 ;;
esac
mkdir -p "$W" "$CASES"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

wait_rpc() { for _ in $(seq 1 120); do curl -sf -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$1" >/dev/null && return 0; sleep 0.5; done; echo "no rpc at $1" >&2; return 1; }

"$ANVIL" --port 18645 --chain-id 31337 --hardfork amsterdam --gas-limit 60000000 >"$W/anvil.log" 2>&1 & PIDS+=($!)
wait_rpc "$RPC"
"$ANVIL" --version > "$W/versions.txt"; "$FORGE" --version >> "$W/versions.txt"
node "$ROOT/script/b-layer/ams-calibrate.mjs" "$RPC" "$W/calibration.json" | tee "$W/calibration.log"
"$ROOT/script/b-layer/ams-g1-deploy.sh" "$RPC" "$G1_DEPLOY_JSON" "$W/deploy.log"
if [ "$VARIANT" = b ]; then
  node "$ROOT/script/b-layer/ams-gasparams.mjs" "$RPC" "$CASES/deploy.json" 400000 380000 5000 340000 "$CASES/gasparams.json" | tee "$W/gasparams.log"
fi
node "$ROOT/script/b-layer/g1-setup.mjs" "$RPC" "$CASES/setup.json" | tee "$W/setup.log"
SNAP=$("$CAST" rpc evm_snapshot --rpc-url "$RPC" | tr -d '"')

run_one() { # <label> <proxyPort> <bundlerPort> <kind> <start command...>
  local label="$1" pport="$2" bport="$3" kind="$4"; shift 4
  node "$ROOT/script/b-layer/g1-proxy.mjs" "$pport" "$RPC" "$W/$label-traces.jsonl" >"$W/proxy-$label.log" 2>&1 & local ppid=$!
  wait_rpc "http://127.0.0.1:$pport"
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

run_one rundler 18646 18650 rundler bash -c 'cd "$0" && exec env RUST_LOG=info ./target/release/rundler node "$@"' "$RUNDLER_DIR" \
  --chain_spec "$ROOT/docs/design/aoa-balance-mode/b-layer/rundler-chain-31337.toml" \
  --node_http http://127.0.0.1:18646 \
  --signer.private_keys 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba \
  --rpc.port 18650 --metrics.port 18651 --rpc.api eth,debug,rundler

ALTO=(bash -c 'cd "$0" && exec node src/lib/cli/alto.js "$@"' "$ALTO_DIR" run --entrypoints 0x0000000071727De22E5E9d8BAf0edAc6f37da032
  --executor-private-keys 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e
  --utility-private-key 0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356
  --rpc-url http://127.0.0.1:18647 --port 18660 --safe-mode true --enable-debug-endpoints true)
run_one alto 18647 18660 alto "${ALTO[@]}"
ALTO[${#ALTO[@]}]=--min-entity-stake; ALTO[${#ALTO[@]}]=1000000000000000000
ALTO[${#ALTO[@]}]=--min-entity-unstake-delay; ALTO[${#ALTO[@]}]=86400
ALTO[${#ALTO[@]}]=--enforce-unique-senders-per-bundle; ALTO[${#ALTO[@]}]=false
run_one altoMulti 18647 18660 alto "${ALTO[@]}"
echo "R-AMS-2 G1 run ($VARIANT) complete: $W"

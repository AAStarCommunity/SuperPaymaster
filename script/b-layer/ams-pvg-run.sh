#!/usr/bin/env bash
# R2-F2 item 3: preVerificationGas on the Amsterdam B-layer stack (variant d op gas, (c) GasParams).
# Fresh anvil (nightly 926eb1d0, --hardfork amsterdam, 60M), calibration gate, the same deploy + governance
# + setup as ams-g1-run.sh, then ams-pvg.mjs: "direct" (handleOps sent by a dev EOA, no bundler) and
# "bundler" for Rundler v0.11.0 (default config) and Alto v1.2.5 (safe mode), each from the same snapshot.
# Local node only, anvil's public dev keys only.
# Usage: script/b-layer/ams-pvg-run.sh <workDir> <rundlerDir> <altoDir> <outDir (relative to repo root)>
set -euo pipefail
FAILS=()
W="$1"; RUNDLER_DIR="$2"; ALTO_DIR="$3"; REL="$4"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ANVIL="${ANVIL:-/tmp/fd/nightly/anvil}"; CAST="${CAST:-/tmp/fd/nightly/cast}"
export FORGE="${FORGE:-/tmp/fd/v171/forge}" FOUNDRY_DISABLE_NIGHTLY_WARNING=1
RPC=http://127.0.0.1:18745
OUT="$ROOT/$REL"
export G1_DEPLOY_JSON="$REL/deploy.json"
export G1_GAS_JSON='{"verificationGasLimit":"175000","verificationGasLimitInit":"4585000","pmVerificationGasLimit":"1150000","pmPostOpGasLimit":"440000"}' G1_MIN_POST_OP_GAS=440000
mkdir -p "$W" "$OUT"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
wait_rpc() { for _ in $(seq 1 120); do curl -sf -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$1" >/dev/null && return 0; sleep 0.5; done; echo "no rpc at $1" >&2; return 1; }

"$ANVIL" --port 18745 --chain-id 31337 --hardfork amsterdam --gas-limit 60000000 >"$W/anvil.log" 2>&1 & PIDS+=($!)
wait_rpc "$RPC"
"$ANVIL" --version > "$OUT/versions.txt"; "$FORGE" --version >> "$OUT/versions.txt"
node "$ROOT/script/b-layer/ams-calibrate.mjs" "$RPC" "$OUT/calibration.json" | tee "$OUT/calibration.log"
"$ROOT/script/b-layer/ams-g1-deploy.sh" "$RPC" "$G1_DEPLOY_JSON" "$W/deploy.log"
sed 's/\x1b\[[0-9;]*m//g' "$W/deploy.log" > "$OUT/deploy.log"
node "$ROOT/script/b-layer/ams-receipts.mjs" "$RPC" "$ROOT/broadcast/DeployBLayerAnvil.s.sol/31337/run-latest.json" "$OUT/deploy-receipts.json" > "$OUT/receipts.log"
node "$ROOT/script/b-layer/ams-gasparams.mjs" "$RPC" "$OUT/deploy.json" 440000 420000 5000 340000 "$OUT/gasparams.json" > "$OUT/gasparams.log"
node "$ROOT/script/b-layer/g1-setup.mjs" "$RPC" "$OUT/setup.json" > "$OUT/setup.log"
SNAP=$("$CAST" rpc evm_snapshot --rpc-url "$RPC" | tr -d '"')
revert() { "$CAST" rpc evm_revert "$SNAP" --rpc-url "$RPC" >/dev/null; SNAP=$("$CAST" rpc evm_snapshot --rpc-url "$RPC" | tr -d '"'); }

node "$ROOT/script/b-layer/ams-pvg.mjs" "$OUT/setup.json" direct "$OUT/pvg-direct.json" | tee "$OUT/pvg-direct.log"
revert

"$RUNDLER_DIR/target/release/rundler" node --chain_spec "$ROOT/docs/design/aoa-balance-mode/b-layer/rundler-chain-31337.toml" \
  --node_http "$RPC" --signer.private_keys 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba \
  --rpc.port 18750 --metrics.port 18751 --rpc.api eth,debug,rundler >"$W/rundler.log" 2>&1 & RP=$!; PIDS+=($RP)
wait_rpc http://127.0.0.1:18750; sleep 2
# A failing bundler run must not look like a short JSON: record it and fail the script at the end (#525 L1).
if ! node "$ROOT/script/b-layer/ams-pvg.mjs" "$OUT/setup.json" bundler rundler http://127.0.0.1:18750 "$OUT/pvg-rundler.json" | tee "$OUT/pvg-rundler.log"; then
  echo "FAILED rundler rc=${PIPESTATUS[0]}" | tee -a "$OUT/pvg-rundler.log"; FAILS+=(rundler)
fi
kill "$RP" 2>/dev/null || true; sleep 2
sed 's/\x1b\[[0-9;]*m//g' "$W/rundler.log" > "$OUT/pvg-rundler-bundler.log"
revert

(cd "$ALTO_DIR" && exec node src/lib/cli/alto.js run --entrypoints 0x0000000071727De22E5E9d8BAf0edAc6f37da032 \
  --executor-private-keys 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e \
  --utility-private-key 0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356 \
  --rpc-url "$RPC" --port 18760 --safe-mode true --enable-debug-endpoints true) >"$W/alto.log" 2>&1 & AP=$!; PIDS+=($AP)
wait_rpc http://127.0.0.1:18760; sleep 2
# A failing bundler run must not look like a short JSON: record it and fail the script at the end (#525 L1).
if ! node "$ROOT/script/b-layer/ams-pvg.mjs" "$OUT/setup.json" bundler alto http://127.0.0.1:18760 "$OUT/pvg-alto.json" | tee "$OUT/pvg-alto.log"; then
  echo "FAILED alto rc=${PIPESTATUS[0]}" | tee -a "$OUT/pvg-alto.log"; FAILS+=(alto)
fi
kill "$AP" 2>/dev/null || true; sleep 2
sed 's/\x1b\[[0-9;]*m//g' "$W/alto.log" > "$OUT/pvg-alto-bundler.log"
if [ "${#FAILS[@]}" -gt 0 ]; then echo "ams-pvg-run: FAILED bundler runs: ${FAILS[*]} (outputs in $OUT are incomplete)" >&2; exit 1; fi
echo "R2-F2 PVG run complete: $OUT"

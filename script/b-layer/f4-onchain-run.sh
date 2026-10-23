#!/usr/bin/env bash
# R2-F4 (B layer): re-deploy the B-layer stack exactly as ams-g1-run.sh does (fresh anvil nightly 926eb1d0,
# --hardfork amsterdam, 60M, calibration gate, ams-g1-deploy.sh with forge 1.7.1, g1-setup.mjs), then read
# eth_getCode of every address and match it against the rc.4 artifact identity (f4-identity-onchain.mjs).
# Local node only, anvil's public dev keys only.
# Usage: script/b-layer/f4-onchain-run.sh <workDir> <outDir (relative to repo root)> <identity.json>
set -euo pipefail
W="$1"; REL="$2"; IDJ="$3"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ANVIL="${ANVIL:-/tmp/fd/nightly/anvil}"
export FORGE="${FORGE:-/tmp/fd/v171/forge}" FOUNDRY_DISABLE_NIGHTLY_WARNING=1
RPC=http://127.0.0.1:18845
OUT="$ROOT/$REL"; export G1_DEPLOY_JSON="$REL/deploy.json"
mkdir -p "$W" "$OUT"
"$ANVIL" --port 18845 --chain-id 31337 --hardfork amsterdam --gas-limit 60000000 >"$W/anvil.log" 2>&1 & AP=$!
trap 'kill $AP 2>/dev/null || true' EXIT
for _ in $(seq 1 120); do curl -sf -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$RPC" >/dev/null && break; sleep 0.5; done
"$ANVIL" --version > "$OUT/versions.txt"; "$FORGE" --version >> "$OUT/versions.txt"
node "$ROOT/script/b-layer/ams-calibrate.mjs" "$RPC" "$OUT/calibration.json" | tee "$OUT/calibration.log"
"$ROOT/script/b-layer/ams-g1-deploy.sh" "$RPC" "$G1_DEPLOY_JSON" "$W/deploy.log"
sed 's/\x1b\[[0-9;]*m//g' "$W/deploy.log" > "$OUT/deploy.log"
node "$ROOT/script/b-layer/ams-receipts.mjs" "$RPC" "$ROOT/broadcast/DeployBLayerAnvil.s.sol/31337/run-latest.json" "$OUT/deploy-receipts.json" > "$OUT/receipts.log"
node "$ROOT/script/b-layer/g1-setup.mjs" "$RPC" "$OUT/setup.json" > "$OUT/setup.log"
node "$ROOT/script/b-layer/f4-identity-onchain.mjs" "$RPC" "$OUT/deploy.json" "$OUT/setup.json" "$IDJ" "$OUT/onchain-identity.json" | tee "$OUT/onchain-identity.txt"

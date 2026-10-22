#!/usr/bin/env bash
# R-AMS-2: B0 (bundler rule checks) on an Amsterdam-level anvil, using the unchanged b0-setup.mjs /
# b0-send.mjs. Adaptations vs the recorded Osaka B0 (README §3), documented in amsterdam/REPORT.md:
#  - anvil nightly 926eb1d0 --hardfork amsterdam --gas-limit 60000000, chain 31337 for BOTH bundlers
#    (Rundler via rundler-chain-31337.toml, as in G1, instead of `--network dev` on chain 1337);
#  - each configuration gets a fresh anvil; B0_PM_VGL sets the paymaster verification gas
#    (100000 = the recorded value; a raised value shows whether the rules or the gas decide).
# Local node only, anvil public dev keys only.
# Usage: script/b-layer/ams-b0-run.sh <workDir> <rundlerDir> <altoDir> <outDir> <pmVgl...>
set -euo pipefail
W="$1"; RUNDLER_DIR="$2"; ALTO_DIR="$3"; OUT="$4"; shift 4
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ANVIL="${ANVIL:-/tmp/fd/nightly/anvil}"; export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
mkdir -p "$W" "$OUT"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
wait_rpc() { for _ in $(seq 1 120); do curl -sf -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$1" >/dev/null && return 0; sleep 0.5; done; echo "no rpc at $1" >&2; return 1; }

one() { # <label> <pmVgl> <bundlerPort> <cmd...>
  local label="$1" vgl="$2" bport="$3"; shift 3
  "$ANVIL" --port 18745 --chain-id 31337 --hardfork amsterdam --gas-limit 60000000 >"$W/anvil-$label.log" 2>&1 & local apid=$!
  wait_rpc http://127.0.0.1:18745
  node "$ROOT/script/b-layer/b0-setup.mjs" http://127.0.0.1:18745 "$W/setup-$label.json" >"$W/setup-$label.log"
  "$@" >"$W/$label.log" 2>&1 & local bpid=$!
  PIDS+=("$apid" "$bpid")
  wait_rpc "http://127.0.0.1:$bport"; sleep 2
  B0_PM_VGL="$vgl" node "$ROOT/script/b-layer/b0-send.mjs" "$W/setup-$label.json" "http://127.0.0.1:$bport" "$label" "$OUT/b0-$label.json" | tee "$W/send-$label.log" || true
  kill "$bpid" "$apid" 2>/dev/null || true; sleep 2
  # keep the evidence: bundler process log, sender log, setup (gzip if > 5 MB)
  sed 's/\x1b\[[0-9;]*m//g' "$W/$label.log" > "$OUT/b0-$label-bundler.log"
  cp "$W/send-$label.log" "$OUT/b0-$label-send.log"; cp "$W/setup-$label.log" "$OUT/b0-$label-setup.log"
  if [ "$(stat -c %s "$OUT/b0-$label-bundler.log")" -gt 5242880 ]; then gzip -9 -f "$OUT/b0-$label-bundler.log"; fi
}
RUNDLER=(bash -c 'cd "$0" && exec env RUST_LOG=info ./target/release/rundler node "$@"' "$RUNDLER_DIR"
  --chain_spec "$ROOT/docs/design/aoa-balance-mode/b-layer/rundler-chain-31337.toml" --node_http http://127.0.0.1:18745
  --signer.private_keys 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba --rpc.port 18750 --metrics.port 18751)
ALTO=(bash -c 'cd "$0" && exec node src/lib/cli/alto.js "$@"' "$ALTO_DIR" run --entrypoints 0x0000000071727De22E5E9d8BAf0edAc6f37da032
  --executor-private-keys 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e
  --utility-private-key 0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356
  --rpc-url http://127.0.0.1:18745 --port 18760)
for vgl in "$@"; do
  one "rundler-ams-vgl$vgl" "$vgl" 18750 "${RUNDLER[@]}"
  one "alto125-ams-vgl$vgl" "$vgl" 18760 "${ALTO[@]}" --safe-mode true
  one "alto125-unsafe-ams-vgl$vgl" "$vgl" 18760 "${ALTO[@]}" --safe-mode false
done

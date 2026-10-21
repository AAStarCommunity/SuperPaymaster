#!/usr/bin/env bash
# D5 gate G1 (B1–B10): the SuperPaymaster 5.5.0 validation stack on a FRESH LOCAL anvil
# (--hardfork osaka, chain 31337) with the canonical EntryPoint v0.7 etched at its canonical
# address. Local node only; anvil's public dev key #0 only.
# Usage: script/b-layer/g1-deploy.sh <rpcUrl> <configOut (relative to repo root)> <logFile>
set -euo pipefail
RPC="$1"; OUT="$2"; LOG="$3"
case "$RPC" in http://127.0.0.1:*|http://localhost:*) ;; *) echo "local node only" >&2; exit 1;; esac
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FORGE="${FORGE:-$HOME/.foundry/bin/forge}"
cd "$ROOT"
node -e 'import("./script/b-layer/lib.mjs").then(async (l)=>{const c=l.clients(process.argv[1]); await l.etchEntryPoint(process.argv[1], c.pub); console.log("canonical EntryPoint v0.7 etched, codehash ok");})' "$RPC"
BLAYER_CONFIG_OUT="$OUT" "$FORGE" script contracts/script/v3/DeployBLayerAnvil.s.sol:DeployBLayerAnvil \
  --rpc-url "$RPC" --broadcast --slow --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 >"$LOG" 2>&1
tail -3 "$LOG"

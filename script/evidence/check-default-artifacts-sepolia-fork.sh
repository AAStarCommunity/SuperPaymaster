#!/usr/bin/env bash
# Read-only: CheckDefaultArtifacts against deployments/config.sepolia.json on a LOCAL anvil fork of
# Sepolia (no --broadcast; the fork only serves state). Reproduces the "real Sepolia config"
# counter-example J of D5-deploy-migration §8.2 (pre-upgrade on-chain state).
# Usage: script/evidence/check-default-artifacts-sepolia-fork.sh <env file holding RPC_URL> <fork block|latest> <out.log>
set -uo pipefail
ENVFILE="$1"; BLOCK="$2"; OUTLOG="$3"
export PATH="$HOME/.foundry/bin:$PATH"
W="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$W"
RPC="$(grep -E '^RPC_URL=' "$ENVFILE" | head -1 | cut -d= -f2- | tr -d '"'"'"' ')"
PORT=28564
if [ "$BLOCK" = latest ]; then anvil --fork-url "$RPC" --port $PORT --silent >/dev/null 2>&1 &
else anvil --fork-url "$RPC" --fork-block-number "$BLOCK" --port $PORT --silent >/dev/null 2>&1 & fi
PID=$!; trap 'kill $PID 2>/dev/null' EXIT
for _ in $(seq 1 60); do cast chain-id --rpc-url http://127.0.0.1:$PORT >/dev/null 2>&1 && break; sleep 1; done
FB="$(cast block-number --rpc-url http://127.0.0.1:$PORT)"
CONFIG_FILE=config.sepolia.json script/evidence/run-logged.sh "$OUTLOG" \
  forge script contracts/script/checks/CheckDefaultArtifacts.s.sol:CheckDefaultArtifacts --rpc-url http://127.0.0.1:$PORT
rc=$?
printf '# fork of Sepolia (chain 11155111) at block %s (local anvil :%s); forge script exit %s\n' "$FB" "$PORT" "$rc" >> "$OUTLOG"
echo "fork block $FB rc=$rc"

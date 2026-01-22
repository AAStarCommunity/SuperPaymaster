#!/bin/bash
# ==============================================================================
# Phase 1: Core Infrastructure Deployment
# ==============================================================================

ENV=${1:-"anvil"}
ENV_FILE=".env.$ENV"

if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

# Determine RPC
if [ "$ENV" == "anvil" ]; then
    RPC_URL="http://127.0.0.1:8545"
else
    ENV_UPPER=$(echo $ENV | tr '[:lower:]' '[:upper:]')
    ENV_CLEAN=${ENV_UPPER//-/_}
    VAR_NAME="${ENV_CLEAN}_RPC_URL"
    RPC_URL=${!VAR_NAME:-$RPC_URL}
fi

export CONFIG_FILE="config.$ENV.json"
export ENV="$ENV"
SCRIPT_NAME=$([ "$ENV" == "anvil" ] && echo "DeployAnvil" || echo "DeployLive")

echo "🚀 Starting Phase 1: Core Infrastructure Deployment ($ENV)"

if [ "$ENV" == "anvil" ]; then
    forge script "contracts/script/v3/${SCRIPT_NAME}.s.sol:$SCRIPT_NAME" \
        --rpc-url "$RPC_URL" --broadcast --slow \
        --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 -vv
else
    forge script "contracts/script/v3/${SCRIPT_NAME}.s.sol:$SCRIPT_NAME" \
        --rpc-url "$RPC_URL" --broadcast --slow --timeout 300 -vv
fi

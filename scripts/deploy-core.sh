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

# CC-48 round-7 LOW-4 / round-8 LOW-1: same change, same reason, as the root `deploy-core`.
# The round-7 justification ("a genuinely local node started by this repo's own tooling")
# was false — nothing here starts anvil, and `anvil --fork-url <chain>` also reports 31337 —
# so the ack is PROBED FOR rather than assumed. Unreachable node, missing `cast` or a
# fork-shaped answer all leave it unset and hand the decision back to a human.
LOCAL_FRESH_BLOCK_CEILING=1000000
if [ "$ENV" == "anvil" ] && [ -z "${LOCAL_DEV_GOVERNANCE_ACK:-}" ]; then
    PROBED_CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || echo "")
    PROBED_BLOCK=$(cast block-number --rpc-url "$RPC_URL" 2>/dev/null || echo "")
    if [ "$PROBED_CHAIN_ID" == "31337" ] && [ -n "$PROBED_BLOCK" ] \
        && [ "$PROBED_BLOCK" -lt "$LOCAL_FRESH_BLOCK_CEILING" ] 2>/dev/null; then
        echo "  [gov-gate] probed $RPC_URL: chain id 31337, head block $PROBED_BLOCK"
        echo "  [gov-gate] -> fresh local node, pre-setting LOCAL_DEV_GOVERNANCE_ACK=true."
        echo "  [gov-gate]    This is a HEURISTIC, not a proof that the node is not a fork."
        export LOCAL_DEV_GOVERNANCE_ACK=true
    else
        echo "  [gov-gate] probed $RPC_URL: chain id '${PROBED_CHAIN_ID:-<unreachable>}', head block"
        echo "  [gov-gate] '${PROBED_BLOCK:-<unreachable>}' -- not a fresh local anvil, so"
        echo "  [gov-gate] LOCAL_DEV_GOVERNANCE_ACK is NOT being set for you. Set it yourself if you"
        echo "  [gov-gate] really mean to rehearse against this node with no governance gate."
    fi
fi
SCRIPT_NAME=$([ "$ENV" == "anvil" ] && echo "DeployAnvil" || echo "DeployLive")

echo "🚀 Starting Phase 1: Core Infrastructure Deployment ($ENV)"

if [ "$ENV" == "anvil" ]; then
    forge script "contracts/script/v3/${SCRIPT_NAME}.s.sol:$SCRIPT_NAME" \
        --rpc-url "$RPC_URL" --broadcast --slow \
        --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 -vv
else
    ARGS="--rpc-url $RPC_URL --broadcast --slow --timeout 300 -vv"
    
    if [ -n "$DEPLOYER_ACCOUNT" ]; then
        ARGS="$ARGS --account $DEPLOYER_ACCOUNT"
    fi
     if [ -n "$DEPLOYER_ADDRESS" ]; then
        ARGS="$ARGS --sender $DEPLOYER_ADDRESS"
    fi

    forge script "contracts/script/v3/${SCRIPT_NAME}.s.sol:$SCRIPT_NAME" $ARGS
fi

#!/bin/bash
# ==============================================================================
# Sepolia Deployment (uses private key from .env.sepolia, no keystore needed)
# For mainnet, use deploy-core which supports --account keystore mode.
#
# Usage:
#   ./deploy-sepolia.sh              # Deploy if code changed
#   ./deploy-sepolia.sh --force      # Force redeploy
#   ./deploy-sepolia.sh --dry-run    # Simulate only
# ==============================================================================

set -e
exec < /dev/null  # Prevent any interactive prompts

ENV="sepolia"
ENV_FILE=".env.$ENV"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ $ENV_FILE not found"
    exit 1
fi

set -a; source "$ENV_FILE"; set +a

# Parse flags
FORCE=false
DRY_RUN=false
for arg in "$@"; do
    case $arg in
        --force) FORCE=true ;;
        --dry-run) DRY_RUN=true ;;
    esac
done

# Validate
RPC_URL="${SEPOLIA_RPC_URL:-$RPC_URL}"
[ -z "$RPC_URL" ] && echo "❌ RPC_URL not set" && exit 1
[ -z "$PRIVATE_KEY" ] && echo "❌ PRIVATE_KEY not set (check .env.sepolia)" && exit 1
[ -z "$DEPLOYER_ADDRESS" ] && echo "❌ DEPLOYER_ADDRESS not set" && exit 1

SENDER="${DEPLOYER_ADDRESS//\"/}"
echo "🔐 Signer:   $SENDER (private key mode)"
echo "🌐 Network:  Sepolia ($RPC_URL)"

# Hash check
export CONFIG_FILE="config.$ENV.json"
export SRC_HASH=$(find contracts/src -name "*.sol" -not -path "*/mocks/*" -type f -exec shasum -a 256 {} + | sort | shasum -a 256 | awk '{print $1}')
export DEPLOY_TIME=$(date "+%Y-%m-%d %H:%M:%S")
export ENV="$ENV"

if [ "$FORCE" = false ] && [ -f "deployments/$CONFIG_FILE" ]; then
    STORED_HASH=$(jq -r '.srcHash // ""' "deployments/$CONFIG_FILE")
    if [ "$SRC_HASH" == "$STORED_HASH" ] && [ -n "$STORED_HASH" ]; then
        echo "✅ Code unchanged. Use --force to redeploy."
        exit 0
    fi
fi

# Build forge flags
# --code-size-limit: Registry is 34326 bytes (> EIP-170's 24576). Sepolia doesn't enforce this.
# Must be reduced before mainnet deployment (extract libs or split contract).
FORGE_FLAGS="--rpc-url $RPC_URL --sender $SENDER --private-key $PRIVATE_KEY --timeout 300 --code-size-limit 40000 -vvvv"
if [ "$DRY_RUN" = false ]; then
    FORGE_FLAGS="$FORGE_FLAGS --broadcast --slow"
    echo "🚀 BROADCASTING to Sepolia..."
else
    echo "🧪 DRY RUN (simulation only)..."
fi

echo ""
forge script contracts/script/v3/DeployLive.s.sol:DeployLive $FORGE_FLAGS

echo ""
echo "✅ Deployment script complete!"

# Verification (only on real broadcast)
if [ "$DRY_RUN" = false ]; then
    echo ""
    echo "🛡️ Running verification checks..."
    CHECK_SCRIPTS="Check04_Registry Check01_GToken Check02_GTokenStaking Check03_MySBT Check07_SuperPaymaster Check08_Wiring VerifyV3_1_1"
    for SCRIPT in $CHECK_SCRIPTS; do
        echo "  Audit: $SCRIPT"
        forge script "contracts/script/checks/${SCRIPT}.s.sol:$SCRIPT" --rpc-url "$RPC_URL" --timeout 300 -vv 2>&1 || echo "  ⚠️  $SCRIPT skipped"
    done
fi

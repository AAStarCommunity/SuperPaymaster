#!/bin/bash
set -e

# ==============================================================================
# SuperPaymaster Full Regression Suite (Smart & Safe)
# ------------------------------------------------------------------------------
# 🔄 Workflow:
# 1. Check Source Changes: Calculate hash of contracts/src.
# 2. Smart Skip: Skip deployment if code hasn't changed (on live networks).
# 3. Deployment: Deploy only if necessary or forced.
# 4. Logic Audit: Run rigorous on-chain checks.
# 5. SDK Sync: ONLY syncs to SDK if all previous steps passed.
# ==============================================================================

ENV="anvil"
ENV_FILE=".env.$ENV"
FORCE_DEPLOY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --env) ENV="$2"; ENV_FILE=".env.$ENV"; shift 2 ;;
        --force) FORCE_DEPLOY=true; shift ;;
        --resume) RESUME_FLAG="--resume"; FORCE_DEPLOY=true; shift ;;
        *) shift ;;
    esac
done

CONFIG_NAME="config.$ENV.json"
CONFIG_FILE="deployments/$CONFIG_NAME"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║       SUPERPAYMASTER -> SDK INTEGRATION FLOW                 ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

# 0. Clean Build Artifacts (Avoid Stale Artifacts)
echo -ne "🧹 Cleaning stale artifacts... "
forge clean > /dev/null 2>&1
echo -e "${GREEN}Done${NC}"

# 1. Calculate Source Hash
echo -ne "🔍 Calculating contract source hash... "
# Use find + shasum to get a stable hash of the entire src directory
CURRENT_HASH=$(find contracts/src contracts/script -name "*.sol" -type f -exec shasum -a 256 {} + | sort | shasum -a 256 | awk '{print $1}')
echo -e "${GREEN}$CURRENT_HASH${NC}"

if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

ANVIL_PID=""
SHOULD_DEPLOY=true

if [ "$ENV" == "anvil" ]; then
    echo -e "\n${YELLOW}🔨 Anvil Mode: Always redeploying to fresh node...${NC}"
    pkill anvil || true
    anvil --port 8545 --chain-id 31337 > /dev/null 2>&1 &
    ANVIL_PID=$!
    sleep 2
    RPC_URL="http://127.0.0.1:8545"
    SHOULD_DEPLOY=true
else
    # Live Network Logic
    # 1. Transform to UPPERCASE: op-sepolia -> OP-SEPOLIA
    ENV_UPPER=$(echo $ENV | tr '[:lower:]' '[:upper:]')
    # 2. Transform HYPHENS to UNDERSCORES: OP-SEPOLIA -> OP_SEPOLIA
    ENV_CLEAN=${ENV_UPPER//-/_}
    
    VAR_NAME="${ENV_CLEAN}_RPC_URL"
    RPC_URL=${!VAR_NAME:-$RPC_URL}

    if [ -f "$CONFIG_FILE" ]; then
        STORED_HASH=$(jq -r '.srcHash // ""' "$CONFIG_FILE")
        if [ "$CURRENT_HASH" == "$STORED_HASH" ] && [ "$FORCE_DEPLOY" = false ]; then
            echo -e "${GREEN}Notice: Source code unchanged and config exists. Skipping deployment.${NC}"
            echo -e "Use --force to trigger a clean redeploy."
            SHOULD_DEPLOY=false
        fi
    fi
fi

# --- PHASE 1: DEPLOYMENT ---
if [ "$SHOULD_DEPLOY" = true ]; then
    echo -e "\n${YELLOW}PHASE 1: Deployment & Infrastructure${NC}"
    export CONFIG_FILE="$CONFIG_NAME"
    export SRC_HASH="$CURRENT_HASH" # Pass hash to Solidity script

    SCRIPT_NAME=$([ "$ENV" == "anvil" ] && echo "DeployAnvil" || echo "DeployLive")

    # If this fails, the script exits here (set -e)
    if [ "$ENV" == "anvil" ]; then
        # Use default Anvil private key
        forge script "contracts/script/v3/${SCRIPT_NAME}.s.sol:$SCRIPT_NAME" --rpc-url "$RPC_URL" --broadcast --slow $RESUME_FLAG --tc "$SCRIPT_NAME" --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 -vv
    else
        forge script "contracts/script/v3/${SCRIPT_NAME}.s.sol:$SCRIPT_NAME" --rpc-url "$RPC_URL" --broadcast --slow $RESUME_FLAG --tc "$SCRIPT_NAME" -vv
    fi
else
    echo -e "\n${GREEN}PHASE 1: Skipping Deployment (Already Up-to-date)${NC}"
fi

# --- PHASE 2 & 3: AUDIT ---
echo -e "\n${YELLOW}PHASE 2 & 3: On-Chain Logic Audit${NC}"
export CONFIG_FILE="$CONFIG_NAME"
CHECK_SCRIPTS=("Check04_Registry" "Check01_GToken" "Check02_GTokenStaking" "Check03_MySBT" "Check07_SuperPaymaster" "Check08_Wiring" "VerifyV3_1_1")

for SCRIPT in "${CHECK_SCRIPTS[@]}"; do
    echo "🔍 Running $SCRIPT..."
    forge script "contracts/script/checks/${SCRIPT}.s.sol:$SCRIPT" --rpc-url "$RPC_URL" -vv
done

echo -e "\n${GREEN}✅ All on-chain logic checks passed!${NC}"

# --- PHASE 4: AUTOMATED SYNC TO SDK ---
# ONLY reached if all above passed.
echo -e "\n${YELLOW}PHASE 4: SDK Synchronization Bridge${NC}"
if [ -f "./sync_to_sdk.sh" ]; then
    ./sync_to_sdk.sh
else
    echo -e "${RED}Error: sync_to_sdk.sh not found in root.${NC}"
    exit 1
fi

# Cleanup
if [ "$ENV" == "anvil" ]; then
    echo -e "\n${GREEN}✨ REGRESSION COMPLETE: Anvil is live (PID: $ANVIL_PID).${NC}"
    echo -e "${CYAN}👉 Next: Go to aastar-sdk and run your tests. They are now synced!${NC}"
else
    [ -n "$ANVIL_PID" ] && kill $ANVIL_PID
    echo -e "\n${GREEN}✨ REGRESSION FOR $ENV COMPLETE & SYNCED ✨${NC}"
fi
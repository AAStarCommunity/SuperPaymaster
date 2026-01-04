#!/bin/bash
set -e

# ==============================================================================
# SuperPaymaster V3/V4 Full Regression Suite (Clean & Standardized)
# ------------------------------------------------------------------------------
# Usage: ./run_full_regression.sh --env [anvil|sepolia|...] [--force]
# ==============================================================================

ENV="anvil"
ENV_FILE=".env.$ENV"
FORCE_DEPLOY=false

# Simple argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --env)
            ENV="$2"
            ENV_FILE=".env.$ENV"
            shift 2
            ;;
        --force)
            FORCE_DEPLOY=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Standardized Config File Name
CONFIG_NAME="config.$ENV.json"
CONFIG_FILE="deployments/$CONFIG_NAME"

echo "🚀 SuperPaymaster Full Regression Suite"
echo "Target Environment: $ENV"
echo "Force Redeploy: $FORCE_DEPLOY"
echo "=================================================="

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 1. Source Environment
if [ -f "$ENV_FILE" ]; then
    echo "Sourcing $ENV_FILE..."
    set -a; source "$ENV_FILE"; set +a
fi

# 2. Start/Check Node & Determine Deployment Necessity
ANVIL_PID=""
SHOULD_DEPLOY=true

if [ "$ENV" == "anvil" ]; then
    echo -e "\n${YELLOW}🔨 Restarting Local Anvil Node...${NC}"
    pkill anvil || true
    anvil --port 8545 --chain-id 31337 > /dev/null 2>&1 &
    ANVIL_PID=$!
    sleep 2
    RPC_URL="http://127.0.0.1:8545"
    SHOULD_DEPLOY=true
else
    # Check RPC_URL
    ENV_UPPER=$(echo $ENV | tr '[:lower:]' '[:upper:]')
    VAR_NAME="${ENV_UPPER}_RPC_URL"
    RPC_URL=${!VAR_NAME:-$RPC_URL}
    if [ -z "$RPC_URL" ]; then echo -e "${RED}Error: RPC_URL for $ENV not set${NC}"; exit 1; fi

    # Skip logic
    if [ -f "$CONFIG_FILE" ] && [ "$FORCE_DEPLOY" = false ]; then
        echo -e "${GREEN}Notice: $CONFIG_FILE exists. Skipping deployment phase...${NC}"
        echo -e "${GREEN}Use --force to trigger a clean redeploy.${NC}"
        SHOULD_DEPLOY=false
    fi
fi

# --- PHASE 1: DEPLOYMENT ---
if [ "$SHOULD_DEPLOY" = true ]; then
    echo -e "\n${YELLOW}PHASE 1: Deployment & Infrastructure${NC}"
    
    # Crucial: Export for Forge Scripts
    export CONFIG_FILE="$CONFIG_NAME"
    
    if [ "$ENV" == "anvil" ]; then
        SCRIPT_NAME="DeployAnvil"
    else
        SCRIPT_NAME="DeployLive"
    fi

    forge script "contracts/script/v3/${SCRIPT_NAME}.s.sol:$SCRIPT_NAME" \
      --rpc-url "$RPC_URL" \
      --broadcast \
      --slow \
      --tc "$SCRIPT_NAME" \
      -vv
else
    echo -e "\n${GREEN}PHASE 1: Skipping Deployment${NC}"
fi

# --- PHASE 2: ARTIFACT EXTRACTION ---
echo -e "\n${YELLOW}PHASE 2: ABI & Metadata Extraction${NC}"
if [ -f "scripts/extract_v3_abis.sh" ]; then
    ./scripts/extract_v3_abis.sh
else
    echo -e "${RED}Missing scripts/extract_v3_abis.sh${NC}"; exit 1
fi

# --- PHASE 3: RIGOROUS VERIFICATION ---
echo -e "\n${YELLOW}PHASE 3: On-Chain Logic & Wiring Audit${NC}"

CHECK_SCRIPTS=(
    "Check04_Registry"
    "Check01_GToken"
    "Check02_GTokenStaking"
    "Check03_MySBT"
    "Check07_SuperPaymaster"
    "Check08_Wiring"
    "VerifyV3_1_1"
)

# Ensure Check scripts find the right config
export CONFIG_FILE="$CONFIG_NAME"

for SCRIPT in "${CHECK_SCRIPTS[@]}"; do
    echo "🔍 Running $SCRIPT..."
    forge script "contracts/script/checks/${SCRIPT}.s.sol:$SCRIPT" \
      --rpc-url "$RPC_URL" \
      -vv || (echo -e "${RED}$SCRIPT Failed!${NC}"; exit 1)
done

echo -e "${GREEN}✅ All contract logic checks passed!${NC}"

# --- PHASE 4: ENVIRONMENT SYNC ---
echo -e "\n${YELLOW}PHASE 4: SDK & Env Synchronization${NC}"
if [ -f "scripts/update_env_from_config.ts" ]; then
    # Standardize the sync call
    pnpm tsx scripts/update_env_from_config.ts --config "$CONFIG_NAME" --output "$ENV_FILE"
fi

if [ -f "scripts/setup_test_environment.ts" ] && [ "$SHOULD_DEPLOY" = true ]; then
    echo "🛠 Initializing SDK Test Environment Data..."
    pnpm tsx scripts/setup_test_environment.ts
fi

# ------------------------------------------------------------------------------
# Cleanup
if [ "$ENV" == "anvil" ]; then
    echo -e "${YELLOW}Notice: Anvil is running (PID: $ANVIL_PID). Access at http://127.0.0.1:8545${NC}"
else
    if [ -n "$ANVIL_PID" ]; then
        kill $ANVIL_PID
    fi
fi

echo -e "\n${GREEN}✨ REGRESSION FOR $ENV COMPLETE: SYSTEM IS STABLE ✨${NC}"

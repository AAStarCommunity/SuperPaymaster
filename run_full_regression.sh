#!/bin/bash
set -e

# ==============================================================================
# SuperPaymaster V3/V4 Full Regression Suite (Enhanced Verification)
# ------------------------------------------------------------------------------
# Usage: ./run_full_regression.sh --env [anvil|sepolia|optimism|mainnet|...]
# ==============================================================================

ENV="anvil"
ENV_FILE=".env.anvil"

if [ "$1" == "--env" ]; then
    ENV="$2"
    ENV_FILE=".env.$ENV"
fi

CONFIG_FILE="deployments/$ENV.json"

echo "🚀 SuperPaymaster V3/V4 - Full Regression Suite"
echo "Target Environment: $ENV"
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

# 2. Start/Check Node
ANVIL_PID=""
if [ "$ENV" == "anvil" ]; then
    echo -e "\n${YELLOW}🔨 Restarting Local Anvil Node...${NC}"
    pkill anvil || true
    anvil --port 8545 --chain-id 31337 > /dev/null 2>&1 &
    ANVIL_PID=$!
    sleep 2
    RPC_URL="http://127.0.0.1:8545"
else
    ENV_UPPER=$(echo $ENV | tr '[:lower:]' '[:upper:]')
    VAR_NAME="${ENV_UPPER}_RPC_URL"
    RPC_URL=${!VAR_NAME:-$RPC_URL}
    if [ -z "$RPC_URL" ]; then echo -e "${RED}Error: RPC_URL not set${NC}"; exit 1; fi
fi

# --- PHASE 1: DEPLOYMENT ---
echo -e "\n${YELLOW}PHASE 1: Deployment & Infrastructure${NC}"
export CONFIG_FILE="$ENV.json"
forge script contracts/script/v3/DeployStandardV3.s.sol:DeployStandardV3 \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --tc DeployStandardV3 \
  -vv

# --- PHASE 2: ARTIFACT EXTRACTION ---
echo -e "\n${YELLOW}PHASE 2: ABI & Metadata Extraction${NC}"
if [ -f "scripts/extract_v3_abis.sh" ]; then
    ./scripts/extract_v3_abis.sh
else
    echo -e "${RED}Missing scripts/extract_v3_abis.sh${NC}"; exit 1
fi

# --- PHASE 3: RIGOROUS VERIFICATION (NEW) ---
echo -e "\n${YELLOW}PHASE 3: On-Chain Logic & Wiring Audit${NC}"

# 运行逐个组件的 Check 脚本
CHECK_SCRIPTS=(
    "Check04_Registry"
    "Check01_GToken"
    "Check02_GTokenStaking"
    "Check03_MySBT"
    "Check07_SuperPaymaster"
    "Check08_Wiring"
)

for SCRIPT in "${CHECK_SCRIPTS[@]}"; do
    echo "🔍 Running $SCRIPT..."
    # 使用刚刚生成的 config 文件进行验证
    forge script "contracts/script/checks/${SCRIPT}.s.sol:$SCRIPT" \
      --rpc-url "$RPC_URL" \
      -vv || (echo -e "${RED}$SCRIPT Failed!${NC}"; exit 1)
done

echo -e "${GREEN}✅ All contract logic checks passed!${NC}"

# --- PHASE 4: ENVIRONMENT SYNC ---
echo -e "\n${YELLOW}PHASE 4: SDK & Env Synchronization${NC}"
if [ -f "scripts/update_env_from_config.ts" ]; then
    pnpm tsx scripts/update_env_from_config.ts --config "$CONFIG_FILE" --output "$ENV_FILE"
fi

# 如果存在测试环境初始化脚本，则运行它（用于准备 SDK 测试数据）
if [ -f "scripts/setup_test_environment.ts" ]; then
    echo "🛠 Initializing SDK Test Environment..."
    pnpm tsx scripts/setup_test_environment.ts
fi

# ------------------------------------------------------------------------------
# Cleanup
if [ -n "$ANVIL_PID" ]; then
    kill $ANVIL_PID
fi

echo -e "\n${GREEN}✨ REGRESSION COMPLETE: SYSTEM IS STABLE ✨${NC}"

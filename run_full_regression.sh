#!/bin/bash
set -e

# Usage: ./run_full_regression.sh --env [anvil|sepolia]

ENV="anvil"
if [ "$1" == "--env" ]; then
    ENV="$2"
fi

echo "🚀 SuperPaymaster V3 - Full Regression Suite"
echo "Target Environment: $ENV"
echo "=================================================="

# Colors
GREEN='\033[0.32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Source env
if [ -f .env ]; then
    source .env
fi

if [ "$ENV" == "sepolia" ]; then
    echo -e "\n${YELLOW}📡 Executing Sepolia Workflow...${NC}"
    
    # Config Separation Logic
    export CONFIG_FILE="config.sepolia.json"
    if [ ! -f "$CONFIG_FILE" ] && [ -f "config.json" ]; then
        echo "Migrating config.json to $CONFIG_FILE to preserve state..."
        cp config.json $CONFIG_FILE
    fi

    # 1. Deploy
    echo -e "\n${YELLOW}Step 1: Deploying to Sepolia...${NC}"
    # Ensure config.json is present (Deploy script handles partial checks)
    forge script contracts/script/DeployV3FullSepolia.s.sol:DeployV3FullSepolia \
      --rpc-url $SEPOLIA_RPC_URL \
      --broadcast \
      --slow \
      --verify \
      --etherscan-api-key $ETHERSCAN_API_KEY
      
    if [ $? -ne 0 ]; then echo -e "${RED}Deployment Failed${NC}"; exit 1; fi

    # 2. Sync Env
    echo -e "\n${YELLOW}Step 2: Syncing .env...${NC}"
    if [ -f "scripts/update_env_from_config.ts" ]; then
        pnpm tsx scripts/update_env_from_config.ts
    else
        echo -e "${RED}Missing scripts/update_env_from_config.ts${NC}"
        # Fallback: echo config
        cat $CONFIG_FILE
    fi

    # 3. Setup Test Env
    echo -e "\n${YELLOW}Step 3: Initializing Test Environment...${NC}"
    if [ -f "scripts/setup_test_environment.ts" ]; then
        pnpm tsx scripts/setup_test_environment.ts
    else
         echo -e "${RED}Missing scripts/setup_test_environment.ts${NC}"
    fi

    # 4. Audit
    echo -e "\n${YELLOW}Step 4: Running Full Spectrum Audit...${NC}"
    forge script contracts/script/checks/VerifyV3_1_1.s.sol:VerifyV3_1_1 \
      --rpc-url $SEPOLIA_RPC_URL \
      -vv
      
    echo -e "${GREEN}🎉 Sepolia Workflow Complete!${NC}"

elif [ "$ENV" == "anvil" ]; then
    echo -e "\n${YELLOW}🔨 Executing Anvil Regression...${NC}"
    export CONFIG_FILE="config.anvil.json"

    # 1. Build
    echo -e "\n${YELLOW}Step 1: Building contracts...${NC}"
    forge build
    if [ $? -ne 0 ]; then echo -e "${RED}Build failed${NC}"; exit 1; fi

    # 2. Start Anvil (Background)
    echo -e "\n${YELLOW}Step 2: Starting Anvil...${NC}"
    pkill anvil || true
    anvil --port 8545 --chain-id 31337 > /dev/null 2>&1 &
    ANVIL_PID=$!
    sleep 3

    # 3. Deploy
    echo -e "\n${YELLOW}Step 3: Deploying V3 Full to Anvil...${NC}"
    # Use the same script as Sepolia but with anvil profile/rpc
    forge script contracts/script/DeployV3FullLocal.s.sol:DeployV3FullLocal \
      --rpc-url http://127.0.0.1:8545 \
      --broadcast \
      --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

    if [ $? -ne 0 ]; then
        echo -e "${RED}Deployment failed${NC}"
        kill $ANVIL_PID
        exit 1
    fi
    
    # 4. Extract ABIs (Integration Point)
    echo -e "\n${YELLOW}Step 4: Extracting ABIs for SDK...${NC}"
    if [ -f "scripts/extract_abis.sh" ]; then
        ./scripts/extract_abis.sh
    elif [ -f "extract_abis.sh" ]; then # Support root location
        ./extract_abis.sh
    fi

    # 5. Run Verification (Solidity)
    echo -e "\n${YELLOW}Step 5: Solidity Verification...${NC}"
    forge script contracts/script/checks/VerifyV3_1_1.s.sol:VerifyV3_1_1 \
      --rpc-url http://127.0.0.1:8545 \
      -vv

    # 6. Trigger SDK Regression (Optional but requested to link)
    echo -e "\n${YELLOW}Step 6: Triggering SDK Regression...${NC}"
    if [ -d "../aastar-sdk" ]; then
        cd ../aastar-sdk
        # We use run_sdk_regression.sh but skip anvil start since we managed it?
        # run_sdk_regression.sh checks anvil.
        # But it might restart it.
        # Let's just run specific integration tests or rely on user to run SDK suite separately?
        # User said "SDK regression stay I SDK". 
        # So here we just ensure Contracts side is good.
        echo "SDK tests should be run via 'cd ../aastar-sdk && ./run_sdk_regression.sh'"
        cd ../SuperPaymaster
    fi

    kill $ANVIL_PID
    echo -e "${GREEN}🎉 Anvil Regression Complete!${NC}"

else
    echo "Unknown Environment: $ENV"
    exit 1
fi

#!/bin/bash

# ============================================================
# Sepolia Testnet Deployment Script
# Unified xPNTs Architecture
# ============================================================

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Sepolia Deployment - Unified xPNTs Architecture${NC}"
echo -e "${GREEN}============================================================${NC}"

# Check if .env exists
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    echo -e "${YELLOW}Please copy .env.sepolia.example to .env and fill in your values:${NC}"
    echo -e "  cp .env.sepolia.example .env"
    exit 1
fi

# Load environment variables
source .env

# Validate required variables
if [ -z "$SEPOLIA_RPC_URL" ]; then
    echo -e "${RED}Error: SEPOLIA_RPC_URL not set in .env${NC}"
    exit 1
fi

if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}Error: PRIVATE_KEY not set in .env${NC}"
    exit 1
fi

echo -e "\n${YELLOW}Deployment Configuration:${NC}"
echo -e "  Network: ${NETWORK:-sepolia}"
echo -e "  RPC URL: ${SEPOLIA_RPC_URL:0:30}..."
echo -e "  Owner: ${OWNER_ADDRESS}"
echo -e "  Treasury: ${TREASURY_ADDRESS}"
echo -e ""

# ============================================================
# Step 1: Deploy SuperPaymaster V2 System
# ============================================================
echo -e "${GREEN}[Step 1/4] Deploying SuperPaymaster V2 System...${NC}"

if [ -z "$XPNTS_FACTORY_ADDRESS" ] || [ "$XPNTS_FACTORY_ADDRESS" == "0xYOUR_XPNTS_FACTORY_ADDRESS" ]; then
    echo -e "${YELLOW}Deploying SuperPaymaster V2 components...${NC}"

    forge script script/v2/DeploySuperPaymasterV2.s.sol:DeploySuperPaymasterV2 \
        --rpc-url $SEPOLIA_RPC_URL \
        --private-key $PRIVATE_KEY \
        --broadcast \
        --verify \
        --etherscan-api-key $ETHERSCAN_API_KEY \
        -vvvv

    echo -e "${GREEN}✅ SuperPaymaster V2 deployed!${NC}"
    echo -e "${YELLOW}Please update .env with deployed addresses:${NC}"
    echo -e "  - XPNTS_FACTORY_ADDRESS"
    echo -e "  - SUPERPAYMASTER_V2_ADDRESS"
    echo -e "  - REGISTRY_ADDRESS"
    echo -e "  - MYSBT_ADDRESS"
    echo -e ""
    read -p "Press Enter after updating .env..."
    source .env
else
    echo -e "${GREEN}✅ Using existing SuperPaymaster V2 at: ${XPNTS_FACTORY_ADDRESS}${NC}"
fi

# ============================================================
# Step 2: Deploy PaymasterV4_1 (Optional - AOA Mode)
# ============================================================
echo -e "\n${GREEN}[Step 2/4] PaymasterV4_1 Deployment (AOA Mode)${NC}"

AOA_MODE=${AOA_MODE:-aoa_plus}

if [ "$AOA_MODE" == "aoa" ]; then
    echo -e "${YELLOW}Deploying PaymasterV4_1 for AOA mode...${NC}"

    forge script script/DeployPaymasterV4_1_Unified.s.sol:DeployPaymasterV4_1_Unified \
        --rpc-url $SEPOLIA_RPC_URL \
        --private-key $PRIVATE_KEY \
        --broadcast \
        --verify \
        --etherscan-api-key $ETHERSCAN_API_KEY \
        -vvvv

    echo -e "${GREEN}✅ PaymasterV4_1 deployed!${NC}"
    echo -e "${YELLOW}Please update .env with:${NC}"
    echo -e "  - PAYMASTER_V4_1_ADDRESS"
    echo -e ""
    read -p "Press Enter after updating .env..."
    source .env
else
    echo -e "${GREEN}✅ Using AOA+ mode (SuperPaymaster V2)${NC}"
    PAYMASTER_V4_1_ADDRESS="0x0000000000000000000000000000000000000000"
fi

# ============================================================
# Step 3: Deploy xPNTs Token (Example)
# ============================================================
echo -e "\n${GREEN}[Step 3/4] xPNTs Token Deployment${NC}"
echo -e "${YELLOW}Options for deploying xPNTs tokens:${NC}"
echo -e "  1. Via Frontend: Navigate to /get-xpnts page"
echo -e "  2. Via Script: Use forge script with xpntsFactory.deployxPNTsToken()"
echo -e "  3. Skip (deploy later)"
echo -e ""
read -p "Choose option [1/2/3]: " XPNTS_OPTION

if [ "$XPNTS_OPTION" == "2" ]; then
    echo -e "${YELLOW}Deploying example xPNTs token...${NC}"

    # Create a temporary deployment script
    cat > script/temp_deploy_xpnts.s.sol << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/paymasters/v2/tokens/xPNTsFactory.sol";

contract DeployExampleXPNTs is Script {
    function run() external {
        address factory = vm.envAddress("XPNTS_FACTORY_ADDRESS");
        address paymasterAOA = vm.envOr("PAYMASTER_V4_1_ADDRESS", address(0));

        vm.startBroadcast();

        address token = xPNTsFactory(factory).deployxPNTsToken(
            "Example Community Points",
            "xECP",
            "Example Community",
            "example.eth",
            1 ether,  // 1:1 exchangeRate
            paymasterAOA
        );

        console.log("xPNTs Token deployed at:", token);

        vm.stopBroadcast();
    }
}
EOF

    forge script script/temp_deploy_xpnts.s.sol:DeployExampleXPNTs \
        --rpc-url $SEPOLIA_RPC_URL \
        --private-key $PRIVATE_KEY \
        --broadcast \
        -vvvv

    rm script/temp_deploy_xpnts.s.sol

    echo -e "${GREEN}✅ Example xPNTs token deployed!${NC}"
else
    echo -e "${YELLOW}⏭  Skipping xPNTs deployment (can be done via frontend)${NC}"
fi

# ============================================================
# Step 4: Post-Deployment Configuration
# ============================================================
echo -e "\n${GREEN}[Step 4/4] Post-Deployment Configuration${NC}"

if [ "$AOA_MODE" == "aoa" ] && [ -n "$PAYMASTER_V4_1_ADDRESS" ]; then
    echo -e "${YELLOW}PaymasterV4_1 configuration required:${NC}"
    echo -e "  1. Add deposit to EntryPoint:"
    echo -e "     cast send $PAYMASTER_V4_1_ADDRESS \"addDeposit()\" \\"
    echo -e "       --value 0.1ether \\"
    echo -e "       --rpc-url $SEPOLIA_RPC_URL \\"
    echo -e "       --private-key $PRIVATE_KEY"
    echo -e ""
    echo -e "  2. Add stake to EntryPoint:"
    echo -e "     cast send $PAYMASTER_V4_1_ADDRESS \"addStake(uint32)\" 86400 \\"
    echo -e "       --value 0.1ether \\"
    echo -e "       --rpc-url $SEPOLIA_RPC_URL \\"
    echo -e "       --private-key $PRIVATE_KEY"
    echo -e ""
    echo -e "  3. Register to SuperPaymasterRegistry:"
    echo -e "     (This should be done via frontend or specific script)"
fi

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${GREEN}============================================================${NC}"

echo -e "\n${YELLOW}Deployed Addresses:${NC}"
echo -e "  xPNTsFactory:       ${XPNTS_FACTORY_ADDRESS}"
echo -e "  SuperPaymaster V2:  ${SUPERPAYMASTER_V2_ADDRESS}"
echo -e "  Registry:           ${REGISTRY_ADDRESS}"
echo -e "  MySBT:              ${MYSBT_ADDRESS}"
if [ "$AOA_MODE" == "aoa" ]; then
    echo -e "  PaymasterV4_1:      ${PAYMASTER_V4_1_ADDRESS}"
fi

echo -e "\n${YELLOW}Next Steps:${NC}"
echo -e "  1. Open Registry frontend and verify deployment"
echo -e "  2. Deploy xPNTs tokens via /get-xpnts page"
echo -e "  3. Test UserOp execution with xPNTs"
echo -e "  4. Update aPNTs price if needed: factory.updateAPNTsPrice()"
echo -e ""

echo -e "${GREEN}Deployment script completed successfully! 🎉${NC}"

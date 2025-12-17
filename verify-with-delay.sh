#!/bin/bash

# ==============================================================================
# Improved Contract Verification Script with Rate Limiting
#
# Usage:
# 1. Ensure ETHERSCAN_API_KEY is set:
#    export ETHERSCAN_API_KEY=...
#
# 2. Run this script with all deployed contract addresses as arguments in order.
#
# ./verify-with-delay.sh <GTOKEN_ADDR> <GTOKEN_STAKING_ADDR> <MYSBT_ADDR> <REGISTRY_ADDR> <FACTORY_ADDR> <APNTS_ADDR> <SP_ADDR> <DEPLOYER_ADDR>
#
# ==============================================================================

# --- Arguments ---
GTOKEN_ADDR=$1
GTOKEN_STAKING_ADDR=$2
MYSBT_ADDR=$3
REGISTRY_ADDR=$4
FACTORY_ADDR=$5
APNTS_ADDR=$6
BPNTS_ADDR=$7
SP_ADDR=$8
JASON_DEPLOYER=$9
ANNI_DEPLOYER=${10}

# --- Configuration ---
DELAY_BETWEEN_VERIFICATIONS=30  # seconds between verifications
RETRY_ATTEMPTS=3
RETRY_DELAY=60  # seconds between retries

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Pre-flight Checks ---
if [ -z "$ETHERSCAN_API_KEY" ]; then
    echo -e "${RED}❌ Error: ETHERSCAN_API_KEY environment variable is not set.${NC}"
    exit 1
fi

if [ "$#" -ne 10 ]; then
    echo -e "${RED}❌ Error: Invalid number of arguments. Expected 10 contract addresses.${NC}"
    echo -e "${YELLOW}Usage: ./verify-with-delay.sh <GTOKEN_ADDR> <GTOKEN_STAKING_ADDR> <MYSBT_ADDR> <REGISTRY_ADDR> <FACTORY_ADDR> <APNTS_ADDR> <BPNTS_ADDR> <SP_ADDR> <JASON_DEPLOYER> <ANNI_DEPLOYER>${NC}"
    exit 1
fi

echo -e "${BLUE}🚀 Starting verification for all contracts with ${DELAY_BETWEEN_VERIFICATIONS}s delays between submissions...${NC}"

# --- Function to verify contract with retries ---
verify_contract() {
    local contract_name=$1
    local contract_address=$2
    local contract_path=$3
    local constructor_args=$4
    local attempt=1

    while [ $attempt -le $RETRY_ATTEMPTS ]; do
        echo -e "${BLUE}----------------------------------${NC}"
        echo -e "${YELLOW}Attempt $attempt: Verifying $contract_name at $contract_address${NC}"

        # Run forge verify command
        if forge verify-contract $contract_address $contract_path --chain-id 11155111 --constructor-args $constructor_args --etherscan-api-key $ETHERSCAN_API_KEY; then
            echo -e "${GREEN}✅ Successfully submitted verification for $contract_name${NC}"
            return 0
        else
            echo -e "${RED}❌ Failed to verify $contract_name (attempt $attempt/$RETRY_ATTEMPTS)${NC}"
            if [ $attempt -lt $RETRY_ATTEMPTS ]; then
                echo -e "${YELLOW}Waiting ${RETRY_DELAY}s before retry...${NC}"
                sleep $RETRY_DELAY
            fi
        fi
        ((attempt++))
    done

    echo -e "${RED}❌ All retry attempts failed for $contract_name${NC}"
    return 1
}

# --- Verification Commands with Delays ---

# 1. GToken
GTOKEN_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(uint256)" 21000000000000000000000000)
verify_contract "GToken" $GTOKEN_ADDR "contracts/src/tokens/GToken.sol:GToken" "$GTOKEN_CONSTRUCTOR_ARGS"
echo -e "${YELLOW}Waiting ${DELAY_BETWEEN_VERIFICATIONS}s before next verification...${NC}"
sleep $DELAY_BETWEEN_VERIFICATIONS

# 2. GTokenStaking
GTOKEN_STAKING_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address)" $GTOKEN_ADDR $JASON_DEPLOYER)
verify_contract "GTokenStaking" $GTOKEN_STAKING_ADDR "contracts/src/core/GTokenStaking.sol:GTokenStaking" "$GTOKEN_STAKING_CONSTRUCTOR_ARGS"
echo -e "${YELLOW}Waiting ${DELAY_BETWEEN_VERIFICATIONS}s before next verification...${NC}"
sleep $DELAY_BETWEEN_VERIFICATIONS

# 3. MySBT
MYSBT_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address,address,address)" $GTOKEN_ADDR $GTOKEN_STAKING_ADDR "0x0000000000000000000000000000000000000000" $JASON_DEPLOYER)
verify_contract "MySBT" $MYSBT_ADDR "contracts/src/tokens/MySBT.sol:MySBT" "$MYSBT_CONSTRUCTOR_ARGS"
echo -e "${YELLOW}Waiting ${DELAY_BETWEEN_VERIFICATIONS}s before next verification...${NC}"
sleep $DELAY_BETWEEN_VERIFICATIONS

# 4. Registry
REGISTRY_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address,address)" $GTOKEN_ADDR $GTOKEN_STAKING_ADDR $MYSBT_ADDR)
verify_contract "Registry" $REGISTRY_ADDR "contracts/src/core/Registry.sol:Registry" "$REGISTRY_CONSTRUCTOR_ARGS"
echo -e "${YELLOW}Waiting ${DELAY_BETWEEN_VERIFICATIONS}s before next verification...${NC}"
sleep $DELAY_BETWEEN_VERIFICATIONS

# 5. xPNTsFactory
FACTORY_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address)" "0x0000000000000000000000000000000000000000" $REGISTRY_ADDR)
verify_contract "xPNTsFactory" $FACTORY_ADDR "contracts/src/tokens/xPNTsFactory.sol:xPNTsFactory" "$FACTORY_CONSTRUCTOR_ARGS"
echo -e "${YELLOW}Waiting ${DELAY_BETWEEN_VERIFICATIONS}s before next verification...${NC}"
sleep $DELAY_BETWEEN_VERIFICATIONS

# 6. Mock aPNTs (xPNTsToken)
APNTS_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(string,string,address,string,string,uint256)" "AAStar PNT" "aPNTs" $JASON_DEPLOYER "AAStar Community" "aastar.eth" 1000000000000000000)
verify_contract "Mock aPNTs" $APNTS_ADDR "contracts/src/tokens/xPNTsToken.sol:xPNTsToken" "$APNTS_CONSTRUCTOR_ARGS"
echo -e "${YELLOW}Waiting ${DELAY_BETWEEN_VERIFICATIONS}s before next verification...${NC}"
sleep $DELAY_BETWEEN_VERIFICATIONS

# 7. Mock bPNTs (xPNTsToken) - Deployed by Anni
BPNTS_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(string,string,address,string,string,uint256)" "Bread PNT" "bPNTs" $ANNI_DEPLOYER "Bread Community" "bread.eth" 1000000000000000000)
verify_contract "Mock bPNTs" $BPNTS_ADDR "contracts/src/tokens/xPNTsToken.sol:xPNTsToken" "$BPNTS_CONSTRUCTOR_ARGS"
echo -e "${YELLOW}Waiting ${DELAY_BETWEEN_VERIFICATIONS}s before next verification...${NC}"
sleep $DELAY_BETWEEN_VERIFICATIONS

# 8. SuperPaymasterV3
ENTRYPOINT="0x0000000071727De22E5E9d8BAf0edAc6f37da032"
ETH_USD_FEED="0x694AA1769357215DE4FAC081bf1f309aDC325306"
SP_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address,address,address,address,address)" $ENTRYPOINT $JASON_DEPLOYER $REGISTRY_ADDR $APNTS_ADDR $ETH_USD_FEED $JASON_DEPLOYER)
verify_contract "SuperPaymasterV3" $SP_ADDR "contracts/src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol:SuperPaymasterV3" "$SP_CONSTRUCTOR_ARGS"

echo -e "${GREEN}🎉 All verification commands submitted.${NC}"
echo -e "${YELLOW}Note: Verification may take several minutes to complete on Etherscan.${NC}"
echo -e "${YELLOW}You can check the status on Sepolia Etherscan for each contract address.${NC}"
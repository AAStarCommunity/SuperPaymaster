#!/bin/bash
# Deactivate Inactive Paymasters Script
#
# Purpose: Deactivate Paymasters with 0 transactions from Registry v1.2
# Usage: ./deactivate-paymasters.sh

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load environment variables
ENV_FILE="../env/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Environment file not found: $ENV_FILE${NC}"
    exit 1
fi

source "$ENV_FILE"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           Deactivate Inactive Paymasters Script                   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Configuration
REGISTRY_ADDRESS="$SuperPaymasterRegistryV1_2"
RPC_URL="$SEPOLIA_RPC_URL"

echo -e "${GREEN}📍 Registry:${NC} $REGISTRY_ADDRESS"
echo -e "${GREEN}🌐 RPC:${NC} $RPC_URL"
echo ""

# Paymasters to deactivate (0 transactions)
PAYMASTERS=(
    "0x9091a98e43966cDa2677350CCc41efF9cedeff4c"
    "0x19afE5Ad8E5C6A1b16e3aCb545193041f61aB648"
    "0x798Dfe9E38a75D3c5fdE53FFf29f966C7635f88F"
    "0xC0C85a8B3703ad24DeD8207dcBca0104B9B27F02"
    "0x11bfab68f8eAB4Cd3dAa598955782b01cf9dC875"
    "0x17fe4D317D780b0d257a1a62E848Badea094ed97"
)

# Private keys to try
PRIVATE_KEYS=(
    "$OWNER_PRIVATE_KEY"
    "$DEPLOYER_PRIVATE_KEY"
    "$OWNER2_PRIVATE_KEY"
)

SUCCESS_COUNT=0
FAIL_COUNT=0

# Check each Paymaster's deployer and deactivate
for PAYMASTER in "${PAYMASTERS[@]}"; do
    echo -e "\n${BLUE}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}📍 Processing Paymaster:${NC} $PAYMASTER"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════${NC}"

    # Get Paymaster info
    echo -e "\n${GREEN}📋 Fetching Paymaster info...${NC}"
    INFO=$(cast call $REGISTRY_ADDRESS "paymasters(address)(address,uint256,bool,uint256,uint256)" $PAYMASTER --rpc-url $RPC_URL)

    # Parse info
    IS_ACTIVE=$(echo $INFO | cut -d' ' -f3)

    if [ "$IS_ACTIVE" = "false" ]; then
        echo -e "${GREEN}✅ Already inactive, skipping${NC}"
        ((SUCCESS_COUNT++))
        continue
    fi

    echo -e "${YELLOW}⚠️  Status: Active, attempting to deactivate...${NC}"

    # Get deployment transaction to find deployer
    echo -e "\n${GREEN}🔍 Finding deployer address...${NC}"

    # Get contract creation transaction
    CREATION_TX=$(cast creation $PAYMASTER --rpc-url $RPC_URL 2>/dev/null || echo "")

    if [ -n "$CREATION_TX" ]; then
        DEPLOYER=$(echo "$CREATION_TX" | grep "Deployer:" | awk '{print $2}')
        echo -e "${GREEN}   Deployer found:${NC} $DEPLOYER"
    else
        echo -e "${YELLOW}   ⚠️  Could not find deployer, will try all private keys${NC}"
        DEPLOYER=""
    fi

    # Try to deactivate with matching private key
    DEACTIVATED=false

    for i in "${!PRIVATE_KEYS[@]}"; do
        PRIVATE_KEY="${PRIVATE_KEYS[$i]}"

        if [ -z "$PRIVATE_KEY" ] || [ "$PRIVATE_KEY" = "undefined" ]; then
            continue
        fi

        # Get address from private key
        SIGNER_ADDRESS=$(cast wallet address $PRIVATE_KEY 2>/dev/null || echo "")

        if [ -z "$SIGNER_ADDRESS" ]; then
            continue
        fi

        echo -e "\n${BLUE}🔑 Trying key #$((i+1)):${NC} $SIGNER_ADDRESS"

        # Check if signer is the paymaster deployer
        if [ -n "$DEPLOYER" ] && [ "${SIGNER_ADDRESS,,}" != "${DEPLOYER,,}" ]; then
            echo -e "${YELLOW}   ⚠️  Not the deployer, skipping${NC}"
            continue
        fi

        # Check if signer is the paymaster address itself
        if [ "${SIGNER_ADDRESS,,}" != "${PAYMASTER,,}" ]; then
            echo -e "${YELLOW}   ⚠️  Not the paymaster address, skipping${NC}"
            continue
        fi

        # Execute deactivate transaction
        echo -e "${GREEN}   📤 Sending deactivate() transaction...${NC}"

        # Build the calldata for deactivate() - it's a simple function call from the Paymaster contract
        TX_HASH=$(cast send $REGISTRY_ADDRESS "deactivate()" \
            --private-key $PRIVATE_KEY \
            --rpc-url $RPC_URL \
            --json 2>/dev/null | jq -r '.transactionHash' || echo "")

        if [ -n "$TX_HASH" ] && [ "$TX_HASH" != "null" ]; then
            echo -e "${GREEN}   ✅ Transaction sent!${NC}"
            echo -e "${GREEN}   📝 TX Hash:${NC} $TX_HASH"
            echo -e "${GREEN}   🔗 Etherscan:${NC} https://sepolia.etherscan.io/tx/$TX_HASH"

            # Wait for confirmation
            echo -e "${YELLOW}   ⏳ Waiting for confirmation...${NC}"
            cast receipt $TX_HASH --rpc-url $RPC_URL > /dev/null 2>&1

            echo -e "${GREEN}   ✅ Transaction confirmed!${NC}"
            ((SUCCESS_COUNT++))
            DEACTIVATED=true
            break
        else
            echo -e "${RED}   ❌ Transaction failed${NC}"
        fi
    done

    if [ "$DEACTIVATED" = false ]; then
        echo -e "\n${RED}❌ Failed to deactivate with any private key${NC}"
        ((FAIL_COUNT++))
    fi
done

# Summary
echo -e "\n\n${BLUE}════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                           📊 SUMMARY                                ${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Total Paymasters:${NC} ${#PAYMASTERS[@]}"
echo -e "${GREEN}✅ Success:${NC} $SUCCESS_COUNT"
echo -e "${RED}❌ Failed:${NC} $FAIL_COUNT"
echo -e "${BLUE}════════════════════════════════════════════════════════════════════${NC}\n"

if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "${GREEN}✅ All paymasters processed successfully!${NC}\n"
    exit 0
else
    echo -e "${YELLOW}⚠️  Some paymasters could not be deactivated${NC}\n"
    exit 1
fi

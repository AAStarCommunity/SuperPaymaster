#!/bin/bash
# Simple Deactivate Script - Call Registry.deactivate() from each Paymaster
#
# Note: deactivate() uses msg.sender, so we need to call it FROM the Paymaster contract
# Strategy: Use owner's private key to make Paymaster contract call Registry.deactivate()

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Load env
source ../env/.env

echo -e "${BLUE}════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}         Deactivate Paymasters via Owner Call                      ${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════════${NC}\n"

REGISTRY="$SuperPaymasterRegistryV1_2"
RPC="$SEPOLIA_RPC_URL"
OWNER_KEY="$OWNER2_PRIVATE_KEY"  # Owner of the Paymaster contracts
OWNER_ADDR="$OWNER2_ADDRESS"

echo -e "${GREEN}📍 Registry:${NC} $REGISTRY"
echo -e "${GREEN}🔑 Owner:${NC} $OWNER_ADDR"
echo -e "${GREEN}🌐 RPC:${NC} $RPC\n"

# Inactive Paymasters (0 transactions)
PAYMASTERS=(
    "0x9091a98e43966cDa2677350CCc41efF9cedeff4c"
    "0x19afE5Ad8E5C6A1b16e3aCb545193041f61aB648"
    "0x798Dfe9E38a75D3c5fdE53FFf29f966C7635f88F"
    "0xC0C85a8B3703ad24DeD8207dcBca0104B9B27F02"
    "0x11bfab68f8eAB4Cd3dAa598955782b01cf9dC875"
    "0x17fe4D317D780b0d257a1a62E848Badea094ed97"
)

SUCCESS=0
FAILED=0

# deactivate() function selector
DEACTIVATE_SIG="0x51b42b00"  # cast sig "deactivate()"

for PM in "${PAYMASTERS[@]}"; do
    echo -e "\n${BLUE}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Processing:${NC} $PM"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════${NC}"

    # Check owner
    PM_OWNER=$(cast call $PM "owner()(address)" --rpc-url $RPC 2>/dev/null || echo "0x0")

    if [ "$PM_OWNER" != "$OWNER_ADDR" ]; then
        echo -e "${RED}❌ Owner mismatch!${NC}"
        echo -e "   Expected: $OWNER_ADDR"
        echo -e "   Got:      $PM_OWNER"
        ((FAILED++))
        continue
    fi

    echo -e "${GREEN}✅ Owner verified${NC}"

    # Strategy: Call a generic execute/call function from Paymaster to Registry
    # Let's try common patterns:

    # Pattern 1: Try execute(address,uint256,bytes)
    echo -e "\n${YELLOW}Attempting deactivate via Paymaster owner...${NC}"

    # Since Paymaster needs to call Registry.deactivate() and deactivate() checks msg.sender
    # We need Paymaster to make the call, not us directly

    # Check if Paymaster has execute function
    HAS_EXECUTE=$(cast call $PM "execute(address,uint256,bytes)" $REGISTRY 0 $DEACTIVATE_SIG --rpc-url $RPC 2>&1 | grep -i "error\|reverted" || echo "ok")

    if [ "$HAS_EXECUTE" = "ok" ]; then
        echo -e "${GREEN}Found execute() function${NC}"

        # Execute via owner
        TX=$(cast send $PM "execute(address,uint256,bytes)" $REGISTRY 0 $DEACTIVATE_SIG \
            --private-key $OWNER_KEY \
            --rpc-url $RPC \
            --json 2>/dev/null | jq -r '.transactionHash' || echo "")

        if [ -n "$TX" ] && [ "$TX" != "null" ]; then
            echo -e "${GREEN}✅ Transaction sent: $TX${NC}"
            echo -e "${BLUE}🔗 https://sepolia.etherscan.io/tx/$TX${NC}"
            ((SUCCESS++))
            continue
        fi
    fi

    # Pattern 2: Check if there's a registry management function
    echo -e "\n${YELLOW}Trying alternative methods...${NC}"

    # Since we can't find a way to make Paymaster call Registry,
    # let's check if Paymaster has any registry-related functions

    echo -e "${RED}❌ No suitable method found to deactivate${NC}"
    echo -e "${YELLOW}ℹ️  Paymaster contract doesn't expose a function to call Registry.deactivate()${NC}"
    ((FAILED++))
done

echo -e "\n\n${BLUE}════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                           SUMMARY                                  ${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Total:${NC} ${#PAYMASTERS[@]}"
echo -e "${GREEN}✅ Success:${NC} $SUCCESS"
echo -e "${RED}❌ Failed:${NC} $FAILED"
echo -e "${BLUE}════════════════════════════════════════════════════════════════════${NC}\n"

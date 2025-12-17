#!/bin/bash

# ==============================================================================
# Contract Verification Status Checker
#
# Usage: ./check-verification-status.sh
#
# ==============================================================================

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Contract addresses
GTOKEN_ADDR="0x4eEF13E130fA5f2aA17089aEf2754234f49f1D49"
GTOKEN_STAKING_ADDR="0x462037Cf25dBCD414EcEe8f93475fE6cdD8b23c2"
MYSBT_ADDR="0xe05aef70F9d31d662aa56ee512136815EdC0cd57"
REGISTRY_ADDR="0xDc06127A0289AA37b7Ff82a68747d6e708cC7774"
FACTORY_ADDR="0x62b1b3B2A95c766FF7b1c633F83d3DeebBe6323b"
APNTS_ADDR="0xD47455C48B379920c3649E8c531c7d16eBA4657D"
BPNTS_ADDR="0x6800Dd9ad44dF86A5F2F9FdF6c135A3FE8dF53c7"
SP_ADDR="0x181b5249375cd113948627a4d78d954BB3dE89E0"

echo -e "${BLUE}🔍 Checking verification status for all contracts...${NC}"
echo -e "${BLUE}================================================${NC}"

# Function to check contract verification status
check_verification() {
    local name=$1
    local address=$2

    echo -ne "${YELLOW}$name${NC} ($address): "

    # Use curl to check the API endpoint
    local result=$(curl -s "https://api-sepolia.etherscan.io/api?module=contract&action=getsourcecode&address=$address&apikey=YourApiKeyToken")

    # Parse the result to check if SourceCode is empty
    if echo "$result" | grep -q '"SourceCode":""'; then
        echo -e "${RED}❌ Not Verified${NC}"
        return 1
    elif echo "$result" | grep -q '"SourceCode":"'; then
        echo -e "${GREEN}✅ Verified${NC}"
        return 0
    else
        echo -e "${YELLOW}❓ Unknown Status${NC}"
        return 2
    fi
}

# Check all contracts
check_verification "GToken" $GTOKEN_ADDR
check_verification "GTokenStaking" $GTOKEN_STAKING_ADDR
check_verification "MySBT" $MYSBT_ADDR
check_verification "Registry" $REGISTRY_ADDR
check_verification "xPNTsFactory" $FACTORY_ADDR
check_verification "Mock aPNTs" $APNTS_ADDR
check_verification "Mock bPNTs" $BPNTS_ADDR
check_verification "SuperPaymasterV3" $SP_ADDR

echo -e "${BLUE}================================================${NC}"
echo -e "${YELLOW}💡 Tip: Run ./verify-only-unverified.sh to verify only unverified contracts${NC}"
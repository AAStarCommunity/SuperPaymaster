#!/bin/bash

# ==============================================================================
# Simple Contract Verification Script with Rate Limiting
#
# Usage: ./verify-all-simple.sh
#
# ==============================================================================

# --- Configuration ---
DELAY_BETWEEN_VERIFICATIONS=30  # seconds between verifications

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Addresses ---
GTOKEN_ADDR="0x4eEF13E130fA5f2aA17089aEf2754234f49f1D49"
GTOKEN_STAKING_ADDR="0x462037Cf25dBCD414EcEe8f93475fE6cdD8b23c2"
MYSBT_ADDR="0xe05aef70F9d31d662aa56ee512136815EdC0cd57"
REGISTRY_ADDR="0xDc06127A0289AA37b7Ff82a68747d6e708cC7774"
FACTORY_ADDR="0x62b1b3B2A95c766FF7b1c633F83d3DeebBe6323b"
APNTS_ADDR="0xD47455C48B379920c3649E8c531c7d16eBA4657D"
BPNTS_ADDR="0x6800Dd9ad44dF86A5F2F9FdF6c135A3FE8dF53c7"
SP_ADDR="0x181b5249375cd113948627a4d78d954BB3dE89E0"
JASON_DEPLOYER="0xb5600060e6de5E11D3636731964218E53caadf0E"
ANNI_DEPLOYER="0xEcAACb915f7D92e9916f449F7ad42BD0408733c9"

# --- Pre-flight Checks ---
if [ -z "$ETHERSCAN_API_KEY" ]; then
    echo -e "${RED}❌ Error: ETHERSCAN_API_KEY environment variable is not set.${NC}"
    exit 1
fi

echo -e "${BLUE}🚀 Starting verification for all contracts...${NC}"
echo -e "${YELLOW}Note: If a contract is already verified, forge will skip it automatically.${NC}"

# --- Constructor Args Pre-computation ---
echo -e "${YELLOW}Preparing constructor arguments...${NC}"
GTOKEN_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(uint256)" 21000000000000000000000000)
GTOKEN_STAKING_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address)" $GTOKEN_ADDR $JASON_DEPLOYER)
MYSBT_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address,address,address)" $GTOKEN_ADDR $GTOKEN_STAKING_ADDR "0x0000000000000000000000000000000000000000" $JASON_DEPLOYER)
REGISTRY_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address,address)" $GTOKEN_ADDR $GTOKEN_STAKING_ADDR $MYSBT_ADDR)
FACTORY_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address)" "0x0000000000000000000000000000000000000000" $REGISTRY_ADDR)
APNTS_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(string,string,address,string,string,uint256)" "AAStar PNT" "aPNTs" $JASON_DEPLOYER "AAStar Community" "aastar.eth" 1000000000000000000)
BPNTS_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(string,string,address,string,string,uint256)" "Bread PNT" "bPNTs" $ANNI_DEPLOYER "Bread Community" "bread.eth" 1000000000000000000)
ENTRYPOINT="0x0000000071727De22E5E9d8BAf0edAc6f37da032"
ETH_USD_FEED="0x694AA1769357215DE4FAC081bf1f309aDC325306"
SP_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address,address,address,address,address)" $ENTRYPOINT $JASON_DEPLOYER $REGISTRY_ADDR $APNTS_ADDR $ETH_USD_FEED $JASON_DEPLOYER)

# --- Function to verify contract ---
verify_contract() {
    local contract_name=$1
    local contract_address=$2
    local contract_path=$3
    local constructor_args=$4

    echo -e "${BLUE}----------------------------------${NC}"
    echo -e "${YELLOW}Verifying $contract_name at $contract_address${NC}"
    echo -e "${BLUE}Contract path: $contract_path${NC}"
    echo -e "${BLUE}Constructor args: $constructor_args${NC}"

    # Run forge verify command
    if forge verify-contract $contract_address $contract_path --chain-id 11155111 --constructor-args $constructor_args --etherscan-api-key $ETHERSCAN_API_KEY; then
        echo -e "${GREEN}✅ Successfully submitted verification for $contract_name${NC}"
        return 0
    else
        echo -e "${RED}❌ Failed to verify $contract_name${NC}"
        return 1
    fi
}

# --- Verification Process ---
echo -e "${YELLOW}Starting contract verification process...${NC}"

# 1. GToken
verify_contract "GToken" $GTOKEN_ADDR "contracts/src/tokens/GToken.sol:GToken" "$GTOKEN_CONSTRUCTOR_ARGS"
echo -e "${YELLOW}Waiting ${DELAY_BETWEEN_VERIFICATIONS}s before next verification...${NC}"
sleep $DELAY_BETWEEN_VERIFICATIONS

# 2. GTokenStaking
verify_contract "GTokenStaking" $GTOKEN_STAKING_ADDR "contracts/src/core/GTokenStaking.sol:GTokenStaking" "$GTOKEN_STAKING_CONSTRUCTOR_ARGS"
echo -e "${YELLOW}Waiting ${DELAY_BETWEEN_VERIFICATIONS}s before next verification...${NC}"
sleep $DELAY_BETWEEN_VERIFICATIONS

# 3. MySBT
verify_contract "MySBT" $MYSBT_ADDR "contracts/src/tokens/MySBT.sol:MySBT" "$MYSBT_CONSTRUCTOR_ARGS"
echo -e "${YELLOW}Waiting ${DELAY_BETWEEN_VERIFICATIONS}s before next verification...${NC}"
sleep $DELAY_BETWEEN_VERIFICATIONS

# 4. Registry
verify_contract "Registry" $REGISTRY_ADDR "contracts/src/core/Registry.sol:Registry" "$REGISTRY_CONSTRUCTOR_ARGS"
echo -e "${YELLOW}Waiting ${DELAY_BETWEEN_VERIFICATIONS}s before next verification...${NC}"
sleep $DELAY_BETWEEN_VERIFICATIONS

# 5. xPNTsFactory
verify_contract "xPNTsFactory" $FACTORY_ADDR "contracts/src/tokens/xPNTsFactory.sol:xPNTsFactory" "$FACTORY_CONSTRUCTOR_ARGS"
echo -e "${YELLOW}Waiting ${DELAY_BETWEEN_VERIFICATIONS}s before next verification...${NC}"
sleep $DELAY_BETWEEN_VERIFICATIONS

# 6. Mock aPNTs (xPNTsToken)
verify_contract "Mock aPNTs" $APNTS_ADDR "contracts/src/tokens/xPNTsToken.sol:xPNTsToken" "$APNTS_CONSTRUCTOR_ARGS"
echo -e "${YELLOW}Waiting ${DELAY_BETWEEN_VERIFICATIONS}s before next verification...${NC}"
sleep $DELAY_BETWEEN_VERIFICATIONS

# 7. Mock bPNTs (xPNTsToken) - Deployed by Anni
verify_contract "Mock bPNTs" $BPNTS_ADDR "contracts/src/tokens/xPNTsToken.sol:xPNTsToken" "$BPNTS_CONSTRUCTOR_ARGS"
echo -e "${YELLOW}Waiting ${DELAY_BETWEEN_VERIFICATIONS}s before next verification...${NC}"
sleep $DELAY_BETWEEN_VERIFICATIONS

# 8. SuperPaymasterV3
verify_contract "SuperPaymasterV3" $SP_ADDR "contracts/src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol:SuperPaymasterV3" "$SP_CONSTRUCTOR_ARGS"

echo -e "${GREEN}🎉 All verification attempts completed.${NC}"
echo -e "${YELLOW}Note: Check the status on Sepolia Etherscan for each contract address.${NC}"
echo -e "${YELLOW}Already verified contracts will show 'Contract source code verified' on Etherscan.${NC}"
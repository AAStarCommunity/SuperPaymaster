#!/bin/bash

# ==============================================================================
# Unified Contract Verification Script
#
# Usage:
# 1. Ensure ETHERSCAN_API_KEY is set:
#    export ETHERSCAN_API_KEY=...
#
# 2. Run this script with all deployed contract addresses as arguments in order.
#
# ./verify-all.sh <GTOKEN_ADDR> <GTOKEN_STAKING_ADDR> <MYSBT_ADDR> <REGISTRY_ADDR> <FACTORY_ADDR> <APNTS_ADDR> <SP_ADDR> <DEPLOYER_ADDR>
#
# ==============================================================================

# --- Arguments ---
GTOKEN_ADDR=$1
GTOKEN_STAKING_ADDR=$2
MYSBT_ADDR=$3
REGISTRY_ADDR=$4
FACTORY_ADDR=$5
APNTS_ADDR=$6
SP_ADDR=$7
DEPLOYER_ADDR=$8

# --- Pre-flight Checks ---
if [ -z "$ETHERSCAN_API_KEY" ]; then
    echo "❌ Error: ETHERSCAN_API_KEY environment variable is not set."
    exit 1
fi

if [ "$#" -ne 8 ]; then
    echo "❌ Error: Invalid number of arguments. Expected 8 contract addresses."
    echo "Usage: ./verify-all.sh <GTOKEN_ADDR> <GTOKEN_STAKING_ADDR> <MYSBT_ADDR> <REGISTRY_ADDR> <FACTORY_ADDR> <APNTS_ADDR> <SP_ADDR> <DEPLOYER_ADDR>"
    exit 1
fi

echo "🚀 Starting verification for all contracts..."

# --- Verification Commands ---

echo "----------------------------------"
echo "1. Verifying GToken..."
forge verify-contract $GTOKEN_ADDR src/tokens/GToken.sol:GToken --chain sepolia -e $ETHERSCAN_API_KEY --constructor-args $(cast abi-encode "constructor(uint256)" 21000000000000000000000000)

echo "----------------------------------"
echo "2. Verifying GTokenStaking..."
forge verify-contract $GTOKEN_STAKING_ADDR src/core/GTokenStaking.sol:GTokenStaking --chain sepolia -e $ETHERSCAN_API_KEY --constructor-args $(cast abi-encode "constructor(address,address)" $GTOKEN_ADDR $DEPLOYER_ADDR)

echo "----------------------------------"
echo "3. Verifying MySBT..."
forge verify-contract $MYSBT_ADDR src/tokens/MySBT.sol:MySBT --chain sepolia -e $ETHERSCAN_API_KEY --constructor-args $(cast abi-encode "constructor(address,address,address,address)" $GTOKEN_ADDR $GTOKEN_STAKING_ADDR "0x0000000000000000000000000000000000000000" $DEPLOYER_ADDR)

echo "----------------------------------"
echo "4. Verifying Registry..."
forge verify-contract $REGISTRY_ADDR src/core/Registry.sol:Registry --chain sepolia -e $ETHERSCAN_API_KEY --constructor-args $(cast abi-encode "constructor(address,address,address)" $GTOKEN_ADDR $GTOKEN_STAKING_ADDR $MYSBT_ADDR)

echo "----------------------------------"
echo "5. Verifying xPNTsFactory..."
forge verify-contract $FACTORY_ADDR src/tokens/xPNTsFactory.sol:xPNTsFactory --chain sepolia -e $ETHERSCAN_API_KEY --constructor-args $(cast abi-encode "constructor(address,address)" "0x0000000000000000000000000000000000000000" $REGISTRY_ADDR)

echo "----------------------------------"
echo "6. Verifying Mock aPNTs (xPNTsToken)..."
forge verify-contract $APNTS_ADDR src/tokens/xPNTsToken.sol:xPNTsToken --chain sepolia -e $ETHERSCAN_API_KEY --constructor-args $(cast abi-encode "constructor(string,string,address,string,string,uint256)" "AAStar PNT" "aPNTs" $DEPLOYER_ADDR "AAStar Community" "aastar.eth" 1e18)

echo "----------------------------------"
echo "7. Verifying SuperPaymasterV3..."
# Note: SuperPaymaster constructor args are complex. This is a best-effort attempt.
# It requires the addresses of EntryPoint and the ETH/USD price feed.
ENTRYPOINT="0x0000000071727De22E5E9d8BAf0edAc6f37da032"
ETH_USD_FEED="0x694AA1769357215DE4FAC081bf1f309aDC325306"
forge verify-contract $SP_ADDR src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol:SuperPaymasterV3 --chain sepolia -e $ETHERSCAN_API_KEY --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,address)" $ENTRYPOINT $DEPLOYER_ADDR $REGISTRY_ADDR $APNTS_ADDR $ETH_USD_FEED $DEPLOYER_ADDR)


echo "🎉 All verification commands submitted."
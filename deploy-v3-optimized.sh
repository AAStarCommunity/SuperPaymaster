#!/bin/bash

# ==============================================================================
# SuperPaymaster V3 Optimized Deployment Script
#
# Usage:
# 1. Make sure PRIVATE_KEY and ETHERSCAN_API_KEY are set as environment variables
#    export PRIVATE_KEY=0x...
#    export ETHERSCAN_API_KEY=...
# 2. Run the script: ./deploy-v3-optimized.sh
# ==============================================================================

# --- Configuration ---
RPC_URL="https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N"
SCRIPT_PATH="contracts/script/DeployAllV3_Optimized.s.sol"
DELAY_SECONDS=15 # Delay between transactions to avoid RPC rate limiting

# --- Helper Functions ---
# Function to execute a forge script command, log output, and extract deployed address
execute_and_extract() {
    local func_sig=$1
    shift # Remove function signature from arguments
    local args="$@"
    
    echo "----------------------------------------------------------------"
    echo "Executing: $func_sig"
    echo "----------------------------------------------------------------"
    
    # Run the forge script command, tee output to a log file and stdout
    local output
    output=$(forge script $SCRIPT_PATH --tc DeployAllV3_Optimized --rpc-url $RPC_URL --sig "$func_sig" $args --broadcast --verify -vvvv 2>&1 | tee /tmp/deployment_output.log)
    
    # Check for forge script errors
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        echo "❌ Forge script execution failed for $func_sig"
        exit 1
    fi

    # Extract the deployed address from the log
    local deployed_address
    deployed_address=$(echo "$output" | grep "deployed to:" | awk '{print $NF}')

    if [ -z "$deployed_address" ]; then
        echo "⚠️ Could not extract deployed address for $func_sig. Manual check required."
    else
        echo "✅ Deployed Address: $deployed_address"
    fi
    
    # Return the address
    echo "$deployed_address"
}

# Function to execute a transaction without expecting a return address
execute_tx() {
    local func_sig=$1
    shift
    local args="$@"

    echo "----------------------------------------------------------------"
    echo "Executing: $func_sig"
    echo "----------------------------------------------------------------"

    forge script $SCRIPT_PATH --tc DeployAllV3_Optimized --rpc-url $RPC_URL --sig "$func_sig" $args --broadcast -vvvv
    
    if [ $? -ne 0 ]; then
        echo "❌ Forge script execution failed for $func_sig"
        exit 1
    fi
    echo "✅ Transaction sent for $func_sig"
}


# --- Pre-flight Checks ---
if [ -z "$PRIVATE_KEY" ]; then
    echo "❌ Error: PRIVATE_KEY environment variable is not set."
    exit 1
fi

if [ -z "$ETHERSCAN_API_KEY" ]; then
    echo "❌ Error: ETHERSCAN_API_KEY environment variable is not set. Verification will fail."
    exit 1
fi

echo "🚀 Starting SuperPaymaster V3 Optimized Deployment..."


# --- Deployment Steps ---

GTOKEN_ADDR=$(execute_and_extract "deployGToken()")
if [ -z "$GTOKEN_ADDR" ]; then exit 1; fi
sleep $DELAY_SECONDS

GTOKEN_STAKING_ADDR=$(execute_and_extract "deployGTokenStaking(address)" "$GTOKEN_ADDR")
if [ -z "$GTOKEN_STAKING_ADDR" ]; then exit 1; fi
sleep $DELAY_SECONDS

MYSBT_ADDR=$(execute_and_extract "deployMySBT(address,address)" "$GTOKEN_ADDR" "$GTOKEN_STAKING_ADDR")
if [ -z "$MYSBT_ADDR" ]; then exit 1; fi
sleep $DELAY_SECONDS

REGISTRY_ADDR=$(execute_and_extract "deployRegistry(address,address,address)" "$GTOKEN_ADDR" "$GTOKEN_STAKING_ADDR" "$MYSBT_ADDR")
if [ -z "$REGISTRY_ADDR" ]; then exit 1; fi
sleep $DELAY_SECONDS

APNTS_ADDR=$(execute_and_extract "deployMockAPNTs()")
if [ -z "$APNTS_ADDR" ]; then exit 1; fi
sleep $DELAY_SECONDS

SUPER_PAYMASTER_ADDR=$(execute_and_extract "deploySuperPaymaster(address,address)" "$REGISTRY_ADDR" "$APNTS_ADDR")
if [ -z "$SUPER_PAYMASTER_ADDR" ]; then exit 1; fi
sleep $DELAY_SECONDS


# --- Wiring and Minting ---

execute_tx "wireUpContracts(address,address,address)" "$MYSBT_ADDR" "$GTOKEN_STAKING_ADDR" "$REGISTRY_ADDR"
sleep $DELAY_SECONDS

execute_tx "mintInitialTokens(address,address)" "$GTOKEN_ADDR" "$APNTS_ADDR"


echo "🎉 Deployment complete!"
echo "========================================"
echo "Deployed Contract Addresses:"
echo "GToken:             $GTOKEN_ADDR"
echo "GTokenStaking:      $GTOKEN_STAKING_ADDR"
echo "MySBT:              $MYSBT_ADDR"
echo "Registry:           $REGISTRY_ADDR"
echo "aPNTs (Mock):       $APNTS_ADDR"
echo "SuperPaymasterV3:   $SUPER_PAYMASTER_ADDR"
echo "========================================"

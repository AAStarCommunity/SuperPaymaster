#!/bin/bash
# Usage: ./check-onchain-version.sh <RPC_URL>
# Example: ./check-onchain-version.sh https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY

if [ -z "$1" ]; then
    echo "Error: RPC URL is required"
    echo "Usage: ./check-onchain-version.sh <RPC_URL>"
    echo "Example: ./check-onchain-version.sh https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY"
    exit 1
fi

RPC_URL="$1"
echo "Checking on-chain contract versions..."
echo "RPC URL: $RPC_URL"
echo ""

forge script contracts/script/check/CheckVersions.s.sol --rpc-url "$RPC_URL" -vvv

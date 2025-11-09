#!/bin/bash
# Test V3 contracts on local Anvil

set -e

echo "Starting Anvil fork of Sepolia..."
anvil --fork-url "$SEPOLIA_RPC_URL" --fork-block-number 9355570 &
ANVIL_PID=$!
sleep 3

echo "Anvil started with PID: $ANVIL_PID"
echo "RPC: http://localhost:8545"
echo ""
echo "Running test..."

# Use local RPC
export LOCAL_RPC="http://localhost:8545"
export SEPOLIA_RPC_URL="$LOCAL_RPC"

# Run test
node scripts/submit-via-entrypoint.js

echo ""
echo "Stopping Anvil..."
kill $ANVIL_PID

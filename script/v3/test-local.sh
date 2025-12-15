#!/bin/bash
# Start Anvil in background
mkdir -p script/v3/logs
echo "Starting Anvil..."
anvil --port 8545 --chain-id 31337 > script/v3/logs/anvil.log 2>&1 &
ANVIL_PID=$!
echo "Anvil started with PID $ANVIL_PID"

# Wait for Anvil to be ready
sleep 3

# Define Local Keys (Anvil Defaults)
# Account 0 (Admin/Deployer)
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
# Account 1 (User)
export PRIVATE_KEY_ANNI=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
# Map Admin Key for scripts
export PRIVATE_KEY_JASON=$PRIVATE_KEY
export SEPOLIA_RPC_URL=http://127.0.0.1:8545

# Deploy
echo "Deploying Contracts locally..."
forge script script/v3/SetupV3.s.sol --tc SetupV3 --rpc-url $SEPOLIA_RPC_URL --broadcast --private-key $PRIVATE_KEY -vvvv > script/v3/logs/deploy.log 2>&1

if [ $? -eq 0 ]; then
    echo "Deployment Successful! Config generated."
    echo "Running E2E tests..."
    node script/v3/test-e2e.js
else
    echo "❌ Deployment Failed. Check script/v3/logs/deploy.log"
    cat script/v3/logs/deploy.log
fi

# Cleanup
echo "Stopping Anvil..."
kill $ANVIL_PID

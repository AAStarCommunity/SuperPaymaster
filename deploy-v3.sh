#!/bin/bash

# V3 Deployment Script

# Load env variables from project env
if [ -f "../env/.env.v3" ]; then
    echo "Loading .env.v3..."
    source "../env/.env.v3"
elif [ -f "../env/.env" ]; then
    echo "Loading ../env/.env..."
    source "../env/.env"
elif [ -f ".env" ]; then
    source .env
else
    echo "Error: .env file not found"
    exit 1
fi

echo "Deploying SuperPaymaster V3 to Sepolia..."
echo "RPC URL: $SEPOLIA_RPC_URL"

# Run Forge Script
forge script script/DeployV3.s.sol:DeploySuperPaymasterV3 \
    --rpc-url "$SEPOLIA_RPC_URL" \
    --broadcast \
    --verify \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    -vvvv

# Check if successful
if [ $? -eq 0 ]; then
    echo "✅ Deployment Successful!"
    echo "Addresses saved to deployment_v3.env"
    cat deployment_v3.env
else
    echo "❌ Deployment Failed"
    exit 1
fi

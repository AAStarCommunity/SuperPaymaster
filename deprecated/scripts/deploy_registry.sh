#!/bin/bash

# Load environment variables
set -a
source env/.env
set +a

# Set GTokenStaking address from shared-config
export GTOKEN_STAKING="0x60Bd54645b0fDabA1114B701Df6f33C4ecE87fEa"

echo "Deploying Registry v2.1.4..."
echo "GTokenStaking: $GTOKEN_STAKING"
echo ""

# Deploy contract
forge script script/DeployRegistry_v2_1_4.s.sol:DeployRegistry_v2_1_4 \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast \
  --legacy \
  -vvv

echo ""
echo "Deployment completed!"

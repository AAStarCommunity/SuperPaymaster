#!/bin/bash
# Deploy SuperPaymasterV7 Registry

set -e

cd "$(dirname "$0")/.."
source .env.v3

export PRIVATE_KEY="0x${SuperPaymaster_Owner_Private_Key}"
export ENTRY_POINT="$ENTRYPOINT_V07"
export SuperPaymaster_Owner="$SuperPaymaster_Owner"

echo "Deploying SuperPaymasterV7 Registry..."
forge script script/DeployV7.s.sol:DeployV7 \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast \
  --via-ir \
  -vvv

echo "Done! Check deployments/v7-sepolia-latest.json for deployed address"

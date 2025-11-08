#!/bin/bash
# Deploy Settlement and PaymasterV3 contracts

set -e

cd "$(dirname "$0")/.."
source .env.v3

export PRIVATE_KEY="0x${SuperPaymaster_Owner_Private_Key}"
export GAS_TOKEN_ADDRESS="$PNTS_TOKEN"
export SBT_CONTRACT_ADDRESS="$SBT_CONTRACT"
export MIN_TOKEN_BALANCE="$MIN_TOKEN_BALANCE"
export SETTLEMENT_THRESHOLD="$SETTLEMENT_THRESHOLD"
export SUPER_PAYMASTER="$SUPER_PAYMASTER"

echo "Deploying Settlement and PaymasterV3..."
forge script script/v3-deploy-simple.s.sol:V3DeploySimple \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast

echo "Done! Check deployments/v3-sepolia-latest.json for deployed addresses"

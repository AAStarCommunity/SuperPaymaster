#!/bin/bash
set -e

# Read from .env
export $(grep -v '^#' .env | grep -E '^(SEPOLIA_RPC_URL|PRIVATE_KEY|ETHERSCAN_API_KEY)=' | xargs)

echo "=== Deploying Registry v2.1 to Sepolia ==="
echo "RPC URL: ${SEPOLIA_RPC_URL:0:50}..."
echo ""

forge script script/DeployRegistryV2_1.s.sol:DeployRegistryV2_1 \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  -vvv

#!/bin/bash
SEPOLIA_RPC=$(grep "^SEPOLIA_RPC_URL=" .env | cut -d'=' -f2 | tr -d '"')
REGISTRY_V2_1="0x3F7E822C7FD54dBF8df29C6EC48E08Ce8AcEBeb3"

echo "=== Testing Registry v2.1 Communities ==="
echo "Registry v2.1: $REGISTRY_V2_1"
echo ""

echo "1. Testing getCommunityCount():"
cast call $REGISTRY_V2_1 \
  "getCommunityCount()(uint256)" \
  --rpc-url "$SEPOLIA_RPC"

echo ""
echo "2. Testing getAllCommunities():"
cast call $REGISTRY_V2_1 \
  "getAllCommunities()(address[])" \
  --rpc-url "$SEPOLIA_RPC"

echo ""
echo "3. Testing getPaymasterCount():"
cast call $REGISTRY_V2_1 \
  "getPaymasterCount()(uint256)" \
  --rpc-url "$SEPOLIA_RPC"

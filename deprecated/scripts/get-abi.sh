#!/bin/bash
SEPOLIA_RPC=$(grep "^SEPOLIA_RPC_URL=" .env | cut -d'=' -f2 | tr -d '"')
REGISTRY_V2_1="0x3F7E822C7FD54dBF8df29C6EC48E08Ce8AcEBeb3"

echo "=== Getting Registry v2.1 Interface ==="
echo ""

# Get contract interface
cast interface $REGISTRY_V2_1 --rpc-url "$SEPOLIA_RPC" | grep -E "(getCommunity|getAllCommunity)" || echo "No matching functions found"

echo ""
echo "=== Testing specific functions ==="
echo ""

# Test getCommunityCount
echo "1. getCommunityCount():"
cast call $REGISTRY_V2_1 \
  "getCommunityCount()" \
  --rpc-url "$SEPOLIA_RPC" 2>&1

echo ""

# Test if getAllCommunities exists
echo "2. getAllCommunities() (should fail if not exists):"
cast call $REGISTRY_V2_1 \
  "getAllCommunities()" \
  --rpc-url "$SEPOLIA_RPC" 2>&1

echo ""

# Test getCommunities paginated
echo "3. getCommunities(0, 10):"
cast call $REGISTRY_V2_1 \
  "getCommunities(uint256,uint256)(address[])" \
  0 10 \
  --rpc-url "$SEPOLIA_RPC" 2>&1

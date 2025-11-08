#!/bin/bash
set -e

# Read from .env
export $(grep -v '^#' .env | grep -E '^(SEPOLIA_RPC_URL|PRIVATE_KEY)=' | xargs)

REGISTRY_V2_1="0x3F7E822C7FD54dBF8df29C6EC48E08Ce8AcEBeb3"
GTOKEN_STAKING="0xD8235F8920815175BD46f76a2cb99e15E02cED68"

echo "=== Adding Registry v2.1 as Locker ==="
echo "GTokenStaking: $GTOKEN_STAKING"
echo "Registry v2.1: $REGISTRY_V2_1"
echo ""

cast send $GTOKEN_STAKING \
  "addLocker(address)" \
  $REGISTRY_V2_1 \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY"

echo ""
echo "=== Verifying ==="
cast call $GTOKEN_STAKING \
  "isLocker(address)(bool)" \
  $REGISTRY_V2_1 \
  --rpc-url "$SEPOLIA_RPC_URL"

#!/bin/bash
set -e

# Read from .env
export $(grep -v '^#' .env | grep -E '^(SEPOLIA_RPC_URL|PRIVATE_KEY)=' | xargs)

REGISTRY_V2_1="0x3F7E822C7FD54dBF8df29C6EC48E08Ce8AcEBeb3"
GTOKEN_STAKING="0xD8235F8920815175BD46f76a2cb99e15E02cED68"

echo "=== Configuring Registry v2.1 as Locker ==="
echo "GTokenStaking: $GTOKEN_STAKING"
echo "Registry v2.1: $REGISTRY_V2_1"
echo ""

# configureLocker(address locker, bool authorized, uint256 baseExitFee, uint256[] timeTiers, uint256[] tierFees, address feeRecipient)
# Use simple config: authorized=true, baseExitFee=0, empty tiers, feeRecipient=address(0)

cast send $GTOKEN_STAKING \
  "configureLocker(address,bool,uint256,uint256[],uint256[],address)" \
  $REGISTRY_V2_1 \
  true \
  0 \
  "[]" \
  "[]" \
  "0x0000000000000000000000000000000000000000" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY"

echo ""
echo "=== Verifying ==="
cast call $GTOKEN_STAKING \
  "getLockerConfig(address)(bool,uint256,uint256[],uint256[],address)" \
  $REGISTRY_V2_1 \
  --rpc-url "$SEPOLIA_RPC_URL"

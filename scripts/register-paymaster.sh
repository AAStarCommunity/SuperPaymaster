#!/bin/bash
# Register PaymasterV3 in SuperPaymaster Registry

set -e

cd "$(dirname "$0")/.."
source .env.v3

if [ -z "$1" ]; then
    echo "Usage: $0 <paymaster_address>"
    exit 1
fi

PAYMASTER_ADDRESS=$1
FEE_RATE=${2:-100}  # Default 1% (100/10000)
PAYMASTER_NAME=${3:-"SuperPaymasterV3"}

export PRIVATE_KEY="0x${SuperPaymaster_Owner_Private_Key}"

echo "Registering PaymasterV3..."
echo "  Registry: $SUPER_PAYMASTER"
echo "  Paymaster: $PAYMASTER_ADDRESS"
echo "  Fee Rate: $FEE_RATE ($(echo "scale=2; $FEE_RATE/100" | bc)%)"
echo "  Name: $PAYMASTER_NAME"

cast send "$SUPER_PAYMASTER" \
  "registerPaymaster(address,uint256,string)" \
  "$PAYMASTER_ADDRESS" \
  "$FEE_RATE" \
  "$PAYMASTER_NAME" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY"

echo "Done!"

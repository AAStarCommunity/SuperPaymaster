#!/bin/bash

# Verify PaymasterV4 token registration
# This script checks if SBT and PNT tokens are registered in PaymasterV4

set -e

source .env.v3

PAYMASTER_V4="0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445"
PNT_TOKEN="0x090E34709a592210158aA49A969e4A04e3a29ebd"
SBT_TOKEN="0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f"

echo "=== PaymasterV4 Token Registration Verification ==="
echo ""
echo "PaymasterV4: $PAYMASTER_V4"
echo "Network: Sepolia"
echo ""

# Check PNT Token
echo "1. Checking PNT Token Registration..."
echo "   Address: $PNT_TOKEN"
PNT_SUPPORTED=$(cast call $PAYMASTER_V4 \
  "isGasTokenSupported(address)(bool)" \
  $PNT_TOKEN \
  --rpc-url "$SEPOLIA_RPC_URL")

if [ "$PNT_SUPPORTED" = "true" ]; then
    echo "   ✅ PNT Token is registered as GasToken"
else
    echo "   ❌ PNT Token is NOT registered"
    echo ""
    echo "To register PNT Token, run:"
    echo "cast send $PAYMASTER_V4 \\"
    echo "  \"addGasToken(address)\" \\"
    echo "  $PNT_TOKEN \\"
    echo "  --rpc-url \$SEPOLIA_RPC_URL \\"
    echo "  --private-key \$PRIVATE_KEY"
    exit 1
fi

echo ""

# Check SBT Token
echo "2. Checking SBT Token Registration..."
echo "   Address: $SBT_TOKEN"
SBT_SUPPORTED=$(cast call $PAYMASTER_V4 \
  "isSBTSupported(address)(bool)" \
  $SBT_TOKEN \
  --rpc-url "$SEPOLIA_RPC_URL")

if [ "$SBT_SUPPORTED" = "true" ]; then
    echo "   ✅ SBT Token is registered"
else
    echo "   ❌ SBT Token is NOT registered"
    echo ""
    echo "To register SBT Token, run:"
    echo "cast send $PAYMASTER_V4 \\"
    echo "  \"addSBT(address)\" \\"
    echo "  $SBT_TOKEN \\"
    echo "  --rpc-url \$SEPOLIA_RPC_URL \\"
    echo "  --private-key \$PRIVATE_KEY"
    exit 1
fi

echo ""
echo "=== All Tokens Registered Successfully ✅ ==="
echo ""
echo "You can now use PaymasterV4 with:"
echo "- GasToken: PNT ($PNT_TOKEN)"
echo "- SBT: MySBT ($SBT_TOKEN)"
echo ""
echo "View on Etherscan:"
echo "- PaymasterV4: https://sepolia.etherscan.io/address/$PAYMASTER_V4"
echo "- PNT Token: https://sepolia.etherscan.io/address/$PNT_TOKEN"
echo "- SBT Token: https://sepolia.etherscan.io/address/$SBT_TOKEN"

#!/bin/bash
# Register and fund existing PaymasterV4

set -e

cd "$(dirname "$0")/.."
source .env.v3

if [ -z "$1" ]; then
    echo "Usage: $0 <paymaster_v4_address> [stake_amount_eth] [deposit_amount_eth]"
    echo ""
    echo "Example:"
    echo "  $0 0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445 0.05 0.05"
    exit 1
fi

PAYMASTER_V4_ADDRESS=$1
STAKE_AMOUNT=${2:-0.05}
DEPOSIT_AMOUNT=${3:-0.05}
FEE_RATE=200  # 2%

echo "==================================="
echo "PaymasterV4 Registration & Funding"
echo "==================================="
echo ""
echo "PaymasterV4: $PAYMASTER_V4_ADDRESS"
echo "Registry: $SUPER_PAYMASTER"
echo "Fee Rate: $FEE_RATE bps (2%)"
echo "Stake: $STAKE_AMOUNT ETH"
echo "Deposit: $DEPOSIT_AMOUNT ETH"
echo ""

# Step 1: Register in Registry
echo "Step 1: Registering in Registry..."
export REGISTER_PRIVATE_KEY="0x${SuperPaymaster_Owner_Private_Key}"

cast send "$SUPER_PAYMASTER" \
  "registerPaymaster(address,uint256,string)" \
  "$PAYMASTER_V4_ADDRESS" \
  "$FEE_RATE" \
  "PaymasterV4-Direct" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$REGISTER_PRIVATE_KEY" \
  --legacy

echo "✓ Registered"
echo ""

# Step 2: Add Stake
echo "Step 2: Adding stake..."
cast send "$PAYMASTER_V4_ADDRESS" \
  "addStake(uint32)" \
  86400 \
  --value "${STAKE_AMOUNT}ether" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --legacy

echo "✓ Added $STAKE_AMOUNT ETH stake"
echo ""

# Step 3: Add Deposit
echo "Step 3: Adding deposit to EntryPoint..."
cast send "$ENTRYPOINT_V07" \
  "depositTo(address)" \
  "$PAYMASTER_V4_ADDRESS" \
  --value "${DEPOSIT_AMOUNT}ether" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --legacy

echo "✓ Added $DEPOSIT_AMOUNT ETH deposit"
echo ""

# Verify
echo "Verification:"
echo "  EntryPoint balance:"
cast call "$ENTRYPOINT_V07" "balanceOf(address)(uint256)" "$PAYMASTER_V4_ADDRESS" --rpc-url "$SEPOLIA_RPC_URL"

echo ""
echo "✓ Complete!"

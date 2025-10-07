#!/bin/bash
# Fund PaymasterV3 with stake and deposit

set -e

cd "$(dirname "$0")/.."
source .env.v3

if [ -z "$1" ]; then
    echo "Usage: $0 <paymaster_address> [stake_amount_eth] [deposit_amount_eth]"
    exit 1
fi

PAYMASTER_ADDRESS=$1
STAKE_AMOUNT=${2:-0.02}    # Default 0.02 ETH
DEPOSIT_AMOUNT=${3:-0.02}  # Default 0.02 ETH

export PRIVATE_KEY="0x${SuperPaymaster_Owner_Private_Key}"

echo "Funding PaymasterV3..."
echo "  Paymaster: $PAYMASTER_ADDRESS"
echo "  Stake: $STAKE_AMOUNT ETH"
echo "  Deposit: $DEPOSIT_AMOUNT ETH"

# Add stake
echo "Adding stake..."
cast send "$PAYMASTER_ADDRESS" \
  "addStake(uint32)" \
  86400 \
  --value "${STAKE_AMOUNT}ether" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY"

# Add deposit to EntryPoint
echo "Adding deposit to EntryPoint..."
cast send "$ENTRYPOINT_V07" \
  "depositTo(address)" \
  "$PAYMASTER_ADDRESS" \
  --value "${DEPOSIT_AMOUNT}ether" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY"

echo "Done!"

#!/bin/bash
# Quick SBT setup for testing
set -e
source .env

echo "Deploying TestSBT..."
SBT_ADDR=$(forge create contracts/src/mocks/TestSBT.sol:TestSBT \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy 2>&1 | grep "Deployed to:" | awk '{print $3}')

echo "✅ TestSBT deployed: $SBT_ADDR"

echo "Minting SBT to AA account..."
cast send $SBT_ADDR "mint(address)" 0x57b2e6f08399c276b2c1595825219d29990d0921 \
  --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL --legacy

echo "✅ SBT minted"

echo "Updating operator supported SBTs..."
cast send 0x34671Bf95159bbDAb12Ac1DA8dbdfEc5D5dC1c24 "updateSupportedSBTs(address[])" "[$SBT_ADDR]" \
  --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL --legacy

echo "✅ Supported SBTs updated"
echo "TestSBT Address: $SBT_ADDR"

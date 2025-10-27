#!/bin/bash
PRIVATE_KEY=$(grep "^PRIVATE_KEY=" .env | cut -d'=' -f2 | tr -d '"')
SEPOLIA_RPC=$(grep "^SEPOLIA_RPC_URL=" .env | cut -d'=' -f2 | tr -d '"')

echo "=== Checking Deployer Address ==="
echo "Address from private key:"
cast wallet address --private-key "$PRIVATE_KEY"

echo ""
echo "GTokenStaking owner:"
cast call 0xD8235F8920815175BD46f76a2cb99e15E02cED68 \
  "owner()(address)" \
  --rpc-url "$SEPOLIA_RPC"

#!/bin/bash
SEPOLIA_RPC=$(grep "^SEPOLIA_RPC_URL=" .env | cut -d'=' -f2 | tr -d '"')
cast call 0xD8235F8920815175BD46f76a2cb99e15E02cED68 \
  "owner()(address)" \
  --rpc-url "$SEPOLIA_RPC"

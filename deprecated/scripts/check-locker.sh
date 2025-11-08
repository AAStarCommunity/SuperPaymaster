#!/bin/bash
SEPOLIA_RPC=$(grep "^SEPOLIA_RPC_URL=" .env | cut -d'=' -f2 | tr -d '"')
echo "Checking if 0x3F7E822C7FD54dBF8df29C6EC48E08Ce8AcEBeb3 is locker..."
cast call 0xD8235F8920815175BD46f76a2cb99e15E02cED68 \
  "isLocker(address)(bool)" \
  0x3F7E822C7FD54dBF8df29C6EC48E08Ce8AcEBeb3 \
  --rpc-url "$SEPOLIA_RPC"

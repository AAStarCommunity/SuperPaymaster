#!/bin/bash
# 给 PaymasterV3 充值 ETH

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# 加载环境变量
if [ -f .env.v3 ]; then
    source .env.v3
else
    echo -e "${RED}Error: .env.v3 file not found${NC}"
    exit 1
fi

# 获取 PaymasterV3 地址
PAYMASTER_ADDRESS=${1:-$PAYMASTER_V3_ADDRESS}

if [ -z "$PAYMASTER_ADDRESS" ]; then
    echo -e "${RED}Error: PaymasterV3 address not provided${NC}"
    echo "Usage: $0 <paymaster_address>"
    exit 1
fi

AMOUNT=${2:-0.1ether}

echo -e "${YELLOW}Depositing ${AMOUNT} to PaymasterV3...${NC}"
echo -e "Address: ${PAYMASTER_ADDRESS}"

# 执行充值
TX_HASH=$(cast send $PAYMASTER_ADDRESS \
  --value $AMOUNT \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --legacy \
  --json | jq -r '.transactionHash')

echo -e "${GREEN}✅ Deposit successful!${NC}"
echo -e "Transaction: https://sepolia.etherscan.io/tx/${TX_HASH}"

# 查询余额
BALANCE=$(cast balance $PAYMASTER_ADDRESS --rpc-url "$SEPOLIA_RPC_URL")
echo -e "Current balance: ${BALANCE} wei ($(cast --from-wei $BALANCE) ETH)"

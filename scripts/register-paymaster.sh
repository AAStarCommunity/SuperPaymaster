#!/bin/bash
# 注册 PaymasterV3 到 SuperPaymaster Registry

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Register PaymasterV3 to Registry${NC}"
echo -e "${GREEN}========================================${NC}"

# 加载环境变量
if [ -f .env.v3 ]; then
    source .env.v3
else
    echo -e "${RED}Error: .env.v3 file not found${NC}"
    exit 1
fi

# Registry 地址
REGISTRY_ADDRESS="0x4e67678AF714f6B5A8882C2e5a78B15B08a79575"

# 获取 PaymasterV3 地址
PAYMASTER_ADDRESS=${1:-$PAYMASTER_V3_ADDRESS}

if [ -z "$PAYMASTER_ADDRESS" ]; then
    echo -e "${RED}Error: PaymasterV3 address not provided${NC}"
    echo "Usage: $0 <paymaster_address>"
    exit 1
fi

echo -e "\n${YELLOW}Registry:${NC} ${REGISTRY_ADDRESS}"
echo -e "${YELLOW}Paymaster:${NC} ${PAYMASTER_ADDRESS}"

# 检查是否已注册
echo -e "\n${YELLOW}Checking registration status...${NC}"
INFO=$(cast call $REGISTRY_ADDRESS \
  "getPaymasterInfo(address)(uint256,bool)" \
  $PAYMASTER_ADDRESS \
  --rpc-url "$SEPOLIA_RPC_URL" 2>&1) || true

# 解析结果 (格式: "feeRate\ntrue/false")
IS_ACTIVE=$(echo "$INFO" | tail -1)

if [ "$IS_ACTIVE" = "true" ]; then
    FEE_RATE=$(echo "$INFO" | head -1)
    echo -e "${GREEN}✅ Paymaster is already registered and active!${NC}"
    echo -e "Fee Rate: ${FEE_RATE} ($(echo "scale=2; ${FEE_RATE}/100" | bc)%)"
    exit 0
fi

# 执行注册 (需要3个参数: address, feeRate, name)
FEE_RATE=${2:-100}  # 默认 1% = 100 basis points
NAME=${3:-"PaymasterV3"}

echo -e "\n${YELLOW}Registering PaymasterV3 to Registry...${NC}"
echo -e "Fee Rate: ${FEE_RATE} ($(echo "scale=2; ${FEE_RATE}/100" | bc)%)"
echo -e "Name: ${NAME}"

RESULT=$(cast send $REGISTRY_ADDRESS \
  "registerPaymaster(address,uint256,string)" \
  $PAYMASTER_ADDRESS \
  $FEE_RATE \
  "$NAME" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --legacy \
  --json)

TX_HASH=$(echo $RESULT | jq -r '.transactionHash')
STATUS=$(echo $RESULT | jq -r '.status')

if [ "$STATUS" = "0x1" ]; then
    echo -e "${GREEN}✅ Registration successful!${NC}"
    echo -e "Transaction: https://sepolia.etherscan.io/tx/${TX_HASH}"

    # 再次验证
    INFO=$(cast call $REGISTRY_ADDRESS \
      "getPaymasterInfo(address)(uint256,bool)" \
      $PAYMASTER_ADDRESS \
      --rpc-url "$SEPOLIA_RPC_URL")

    FINAL_FEE=$(echo "$INFO" | head -1)
    FINAL_ACTIVE=$(echo "$INFO" | tail -1)

    echo -e "Active status: ${FINAL_ACTIVE}"
    echo -e "Fee Rate: ${FINAL_FEE} ($(echo "scale=2; ${FINAL_FEE}/100" | bc)%)"
else
    echo -e "${RED}❌ Registration failed!${NC}"
    echo $RESULT | jq '.'
    exit 1
fi

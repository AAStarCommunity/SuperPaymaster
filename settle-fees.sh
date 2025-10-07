#!/bin/bash
# 执行批量结算

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

source .env.v3

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Batch Settlement${NC}"
echo -e "${GREEN}========================================${NC}"

echo -e "\n${YELLOW}Getting pending records for User1...${NC}"
RECORDS=$(cast call $SETTLEMENT_ADDRESS \
  "getUserPendingRecords(address,address)(bytes32[])" \
  $TEST_USER_ADDRESS \
  $GAS_TOKEN_ADDRESS \
  --rpc-url "$SEPOLIA_RPC_URL")

echo "Pending records: ${RECORDS}"

# 检查是否有记录
if [ -z "$RECORDS" ] || [ "$RECORDS" = "[]" ] || [ "$RECORDS" = "" ]; then
    echo -e "${YELLOW}No pending records to settle${NC}"
    exit 0
fi

echo -e "\n${YELLOW}Executing batch settlement...${NC}"

# 生成 settlement hash
SETTLEMENT_HASH="0x$(date +%s | sha256sum | head -c 64)"
echo "Settlement hash: ${SETTLEMENT_HASH}"

# 执行结算 (需要 owner 调用)
TX=$(cast send $SETTLEMENT_ADDRESS \
  "settleFees(bytes32[],bytes32)" \
  "$RECORDS" \
  "$SETTLEMENT_HASH" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --legacy \
  --json)

TX_HASH=$(echo $TX | jq -r '.transactionHash')
STATUS=$(echo $TX | jq -r '.status')

if [ "$STATUS" = "0x1" ]; then
    echo -e "${GREEN}✅ Settlement completed!${NC}"
    echo -e "Transaction: https://sepolia.etherscan.io/tx/${TX_HASH}"

    # 验证 pending 余额已清零
    echo -e "\n${YELLOW}Verifying final state...${NC}"
    FINAL_PENDING=$(cast call $SETTLEMENT_ADDRESS \
      "pendingAmounts(address,address)(uint256)" \
      $TEST_USER_ADDRESS \
      $GAS_TOKEN_ADDRESS \
      --rpc-url "$SEPOLIA_RPC_URL")

    echo -e "Final pending balance: ${FINAL_PENDING} wei"

    if [ "$FINAL_PENDING" = "0" ]; then
        echo -e "${GREEN}✅ All fees settled successfully!${NC}"
    else
        echo -e "${YELLOW}⚠️  Still has pending balance${NC}"
    fi
else
    echo -e "${RED}❌ Settlement failed!${NC}"
    echo "$TX" | jq '.'
    exit 1
fi

echo -e "\n${GREEN}========================================${NC}"

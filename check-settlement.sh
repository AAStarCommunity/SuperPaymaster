#!/bin/bash
# 检查 Settlement 记账状态

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

source .env.v3

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Check Settlement Records${NC}"
echo -e "${GREEN}========================================${NC}"

echo -e "\n${YELLOW}Checking pending balance for User1...${NC}"
PENDING=$(cast call $SETTLEMENT_ADDRESS \
  "pendingAmounts(address,address)(uint256)" \
  $TEST_USER_ADDRESS \
  $GAS_TOKEN_ADDRESS \
  --rpc-url "$SEPOLIA_RPC_URL")

echo -e "Pending amount: ${PENDING} wei"

if [ "$PENDING" != "0" ] && [ -n "$PENDING" ]; then
    echo -e "${GREEN}✅ Fee recorded successfully!${NC}"
    echo -e ""
    echo -e "${YELLOW}Getting pending records...${NC}"

    # 获取 pending 记录
    RECORDS=$(cast call $SETTLEMENT_ADDRESS \
      "getUserPendingRecords(address,address)(bytes32[])" \
      $TEST_USER_ADDRESS \
      $GAS_TOKEN_ADDRESS \
      --rpc-url "$SEPOLIA_RPC_URL")

    echo -e "Pending records:"
    echo "$RECORDS"

    # 解析记录数量
    RECORD_COUNT=$(echo "$RECORDS" | grep -o "0x" | wc -l)
    echo -e "\nTotal pending records: ${RECORD_COUNT}"
else
    echo -e "${YELLOW}⚠️  No pending fees recorded yet${NC}"
    echo -e ""
    echo -e "Possible reasons:"
    echo -e "1. UserOperation hasn't been executed yet"
    echo -e "2. postOp() wasn't called"
    echo -e "3. recordGasFee() failed"
fi

echo -e "\n${GREEN}========================================${NC}"

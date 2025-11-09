#!/bin/bash
# 运行 V3 集成测试

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}SuperPaymaster V3 Integration Test${NC}"
echo -e "${GREEN}========================================${NC}"

# 加载环境变量
if [ -f .env.v3 ]; then
    source .env.v3
else
    echo -e "${RED}Error: .env.v3 file not found${NC}"
    exit 1
fi

# 检查必要的环境变量
if [ -z "$SETTLEMENT_ADDRESS" ] || [ -z "$PAYMASTER_V3_ADDRESS" ]; then
    echo -e "${RED}Error: Missing contract addresses in .env.v3${NC}"
    exit 1
fi

echo -e "\n${YELLOW}Contract Addresses:${NC}"
echo -e "Settlement:  ${SETTLEMENT_ADDRESS}"
echo -e "PaymasterV3: ${PAYMASTER_V3_ADDRESS}"
echo -e "SBT:         ${SBT_CONTRACT_ADDRESS}"
echo -e "Gas Token:   ${GAS_TOKEN_ADDRESS}"

# 导出环境变量供 forge script 使用
export SETTLEMENT_ADDRESS
export PAYMASTER_V3_ADDRESS
export SBT_CONTRACT_ADDRESS
export GAS_TOKEN_ADDRESS
export TREASURY_ADDRESS
export TEST_USER_ADDRESS
export PRIVATE_KEY

# 运行集成测试
echo -e "\n${YELLOW}Running integration test script...${NC}"
forge script script/v3-integration-test.s.sol \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast --legacy -vv

echo -e "\n${GREEN}Integration test completed!${NC}"

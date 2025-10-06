#!/bin/bash
# 在 Etherscan 上验证合约

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Verify Contracts on Etherscan${NC}"
echo -e "${GREEN}========================================${NC}"

# 加载环境变量
if [ -f .env.v3 ]; then
    source .env.v3
else
    echo -e "${RED}Error: .env.v3 file not found${NC}"
    exit 1
fi

# 验证 Settlement
echo -e "\n${YELLOW}[1/2] Verifying Settlement contract...${NC}"
echo -e "Address: ${SETTLEMENT_ADDRESS}"

forge verify-contract \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --compiler-version "0.8.28" \
  --optimizer-runs 1000000 \
  --watch \
  --constructor-args $(cast abi-encode "constructor(address,address,uint256)" \
    "0x411BD567E46C0781248dbB6a9211891C032885e5" \
    "0x4e6748C62d8EBE8a8b71736EAABBB79575A79575" \
    "100000000000000000000") \
  $SETTLEMENT_ADDRESS \
  src/v3/Settlement.sol:Settlement

# 验证 PaymasterV3
echo -e "\n${YELLOW}[2/2] Verifying PaymasterV3 contract...${NC}"
echo -e "Address: ${PAYMASTER_V3_ADDRESS}"

forge verify-contract \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --compiler-version "0.8.28" \
  --optimizer-runs 1000000 \
  --watch \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,uint256)" \
    "0x0000000071727De22E5E9d8BAf0edAc6f37da032" \
    "0x411BD567E46C0781248dbB6a9211891C032885e5" \
    "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f" \
    "0x3e7B771d4541eC85c8137e950598Ac97553a337a" \
    "$SETTLEMENT_ADDRESS" \
    "10000000000000000000") \
  $PAYMASTER_V3_ADDRESS \
  src/v3/PaymasterV3.sol:PaymasterV3

echo -e "\n${GREEN}✅ Verification complete!${NC}"

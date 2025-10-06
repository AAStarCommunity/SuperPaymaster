#!/bin/bash
# SuperPaymaster V3 部署脚本
# 使用 cast 直接部署合约到 Sepolia

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}SuperPaymaster V3 Deployment Script${NC}"
echo -e "${GREEN}========================================${NC}"

# 加载环境变量
if [ -f .env.v3 ]; then
    source .env.v3
else
    echo -e "${RED}Error: .env.v3 file not found${NC}"
    exit 1
fi

# 检查必要的环境变量
if [ -z "$PRIVATE_KEY" ] || [ -z "$SEPOLIA_RPC_URL" ]; then
    echo -e "${RED}Error: Missing required environment variables${NC}"
    exit 1
fi

# 编译合约
echo -e "\n${YELLOW}[1/3] Compiling contracts...${NC}"
forge build

# 部署 Settlement
echo -e "\n${YELLOW}[2/3] Deploying Settlement contract...${NC}"
SETTLEMENT_BYTECODE=$(cat out/Settlement.sol/Settlement.json | jq -r '.bytecode.object')
SETTLEMENT_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address,uint256)" \
  "0x411BD567E46C0781248dbB6a9211891C032885e5" \
  "0x4e6748C62d8EBE8a8b71736EAABBB79575A79575" \
  "100000000000000000000")

SETTLEMENT_RESULT=$(cast send --legacy \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --create "${SETTLEMENT_BYTECODE}${SETTLEMENT_CONSTRUCTOR_ARGS:2}" \
  --json)

SETTLEMENT_ADDRESS=$(echo $SETTLEMENT_RESULT | jq -r '.contractAddress')
SETTLEMENT_TX=$(echo $SETTLEMENT_RESULT | jq -r '.transactionHash')

echo -e "${GREEN}✅ Settlement deployed!${NC}"
echo -e "   Address: ${SETTLEMENT_ADDRESS}"
echo -e "   TX: ${SETTLEMENT_TX}"

# 部署 PaymasterV3
echo -e "\n${YELLOW}[3/3] Deploying PaymasterV3 contract...${NC}"
PAYMASTER_BYTECODE=$(cat out/PaymasterV3.sol/PaymasterV3.json | jq -r '.bytecode.object')
PAYMASTER_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address,address,address,address,uint256)" \
  "0x0000000071727De22E5E9d8BAf0edAc6f37da032" \
  "0x411BD567E46C0781248dbB6a9211891C032885e5" \
  "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f" \
  "0x3e7B771d4541eC85c8137e950598Ac97553a337a" \
  "${SETTLEMENT_ADDRESS}" \
  "10000000000000000000")

PAYMASTER_RESULT=$(cast send --legacy \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --create "${PAYMASTER_BYTECODE}${PAYMASTER_CONSTRUCTOR_ARGS:2}" \
  --json)

PAYMASTER_ADDRESS=$(echo $PAYMASTER_RESULT | jq -r '.contractAddress')
PAYMASTER_TX=$(echo $PAYMASTER_RESULT | jq -r '.transactionHash')

echo -e "${GREEN}✅ PaymasterV3 deployed!${NC}"
echo -e "   Address: ${PAYMASTER_ADDRESS}"
echo -e "   TX: ${PAYMASTER_TX}"

# 验证部署
echo -e "\n${YELLOW}Verifying deployments...${NC}"
SETTLEMENT_OWNER=$(cast call $SETTLEMENT_ADDRESS "owner()(address)" --rpc-url "$SEPOLIA_RPC_URL")
PAYMASTER_OWNER=$(cast call $PAYMASTER_ADDRESS "owner()(address)" --rpc-url "$SEPOLIA_RPC_URL")

echo -e "Settlement Owner: ${SETTLEMENT_OWNER}"
echo -e "PaymasterV3 Owner: ${PAYMASTER_OWNER}"

# 保存部署信息
DEPLOYMENT_FILE="deployments/v3-sepolia-$(date +%Y%m%d-%H%M%S).json"
mkdir -p deployments
cat > $DEPLOYMENT_FILE << EOF
{
  "network": "sepolia",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "contracts": {
    "Settlement": {
      "address": "${SETTLEMENT_ADDRESS}",
      "transactionHash": "${SETTLEMENT_TX}"
    },
    "PaymasterV3": {
      "address": "${PAYMASTER_ADDRESS}",
      "transactionHash": "${PAYMASTER_TX}"
    }
  },
  "constructor_args": {
    "Settlement": {
      "initialOwner": "0x411BD567E46C0781248dbB6a9211891C032885e5",
      "registryAddress": "0x4e6748C62d8EBE8a8b71736EAABBB79575A79575",
      "initialThreshold": "100000000000000000000"
    },
    "PaymasterV3": {
      "entryPoint": "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
      "owner": "0x411BD567E46C0781248dbB6a9211891C032885e5",
      "sbtContract": "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f",
      "gasToken": "0x3e7B771d4541eC85c8137e950598Ac97553a337a",
      "settlement": "${SETTLEMENT_ADDRESS}",
      "minTokenBalance": "10000000000000000000"
    }
  }
}
EOF

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "\nDeployment info saved to: ${DEPLOYMENT_FILE}"
echo -e "\n${YELLOW}Next steps:${NC}"
echo -e "1. Deposit ETH: ./scripts/deposit-eth.sh ${PAYMASTER_ADDRESS}"
echo -e "2. Register to Registry: ./scripts/register-paymaster.sh ${PAYMASTER_ADDRESS}"
echo -e "3. Run integration tests: ./scripts/integration-test.sh"

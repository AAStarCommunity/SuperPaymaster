#!/bin/bash
# scripts/verify-all.sh
# 自动化验证 SuperPaymaster 所有核心合约

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Default values
ENV="sepolia"
CHAIN_NAME="$ENV"

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --env) 
            ENV="$2"
            if [ "$ENV" == "op-sepolia" ]; then
                CHAIN_NAME="optimism-sepolia"
            elif [ "$ENV" == "op-mainnet" ]; then
                CHAIN_NAME="optimism" 
            else
                CHAIN_NAME="$ENV"
            fi
            shift 
            ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Verifying SuperPaymaster on Network: ${ENV}${NC}"
echo -e "${GREEN}========================================${NC}"

# 1. 加载环境变量
ENV_FILE=".env.${ENV}"
if [ -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}Loading environment from ${ENV_FILE}...${NC}"
    # Use export to ensure forge sees them
    set -a
    source "$ENV_FILE"
    set +a
else
    echo -e "${RED}Error: ${ENV_FILE} file not found${NC}"
    exit 1
fi

# 动态获取 RPC URL
# 将 ENV 转换为大写并替换 - 为 _ (例如 op-sepolia -> OP_SEPOLIA)
ENV_UPPER=$(echo "$ENV" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
RPC_VAR_NAME="${ENV_UPPER}_RPC_URL"
RPC_URL="${!RPC_VAR_NAME}"

# 如果特定网络的 RPC 变量不存在，尝试回退到通用的 RPC_URL
if [ -z "$RPC_URL" ]; then
    RPC_URL="$RPC_URL"
fi

# 如果仍然没有找到 RPC URL，报错
if [ -z "$RPC_URL" ]; then
    echo -e "${RED}Error: Could not find RPC URL. Checked ${RPC_VAR_NAME} and RPC_URL.${NC}"
    exit 1
fi

echo -e "Using RPC URL: ${RPC_URL}"

# 确保必要的变量存在
if [ -z "$ETHERSCAN_API_KEY" ]; then
    echo -e "${RED}Error: ETHERSCAN_API_KEY not set in ${ENV_FILE}${NC}"
    exit 1
fi

# 2. 加载部署配置
CONFIG_FILE="deployments/config.${ENV}.json"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: ${CONFIG_FILE} not found${NC}"
    exit 1
fi

echo -e "${YELLOW}Loading addresses from ${CONFIG_FILE}...${NC}"

# 使用 jq 提取地址
REGISTRY=$(jq -r '.registry' "$CONFIG_FILE")
GTOKEN=$(jq -r '.gToken' "$CONFIG_FILE")
STAKING=$(jq -r '.staking' "$CONFIG_FILE")
SBT=$(jq -r '.sbt' "$CONFIG_FILE")
SUPER_PAYMASTER=$(jq -r '.superPaymaster' "$CONFIG_FILE")
APNTS=$(jq -r '.aPNTs' "$CONFIG_FILE")
XPNTS_FACTORY=$(jq -r '.xPNTsFactory' "$CONFIG_FILE")
PM_FACTORY=$(jq -r '.paymasterFactory' "$CONFIG_FILE")
PM_V4_IMPL=$(jq -r '.paymasterV4Impl' "$CONFIG_FILE")
REP_SYSTEM=$(jq -r '.reputationSystem' "$CONFIG_FILE")
BLS_AGGREGATOR=$(jq -r '.blsAggregator' "$CONFIG_FILE")
BLS_VALIDATOR=$(jq -r '.blsValidator' "$CONFIG_FILE")
DVT_VALIDATOR=$(jq -r '.dvtValidator' "$CONFIG_FILE")
ENTRY_POINT=$(jq -r '.entryPoint' "$CONFIG_FILE")
PRICE_FEED=$(jq -r '.priceFeed' "$CONFIG_FILE")


# 获取 Deployer 地址 (用于构造参数)
DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
echo -e "Deployer detected: ${DEPLOYER}"

# 3. 执行验证函数
verify() {
    local addr=$1
    local name=$2
    local contract_path=$3
    local args=$4

    echo -e "\n${YELLOW}>>> Verifying ${name} at ${addr}...${NC}"
    
    # 简单的代码存在性检查
    code=$(cast code "$addr" --rpc-url "$RPC_URL")
    if [ "$code" == "0x" ]; then
        echo -e "${RED}Skip: No code at ${addr}${NC}"
        return
    fi

    echo -e "Path: ${contract_path}"
    
    if [ -n "$args" ]; then
        echo -e "Args: ${args}"
        forge verify-contract "$addr" "$contract_path" \
            --chain "$CHAIN_NAME" \
            --etherscan-api-key "$ETHERSCAN_API_KEY" \
            --watch \
            --constructor-args "$args" \
            --compiler-version "0.8.33" \
            --optimizer-runs 10000 \
            --via-ir
    else
        forge verify-contract "$addr" "$contract_path" \
            --chain "$CHAIN_NAME" \
            --etherscan-api-key "$ETHERSCAN_API_KEY" \
            --watch \
            --compiler-version "0.8.33" \
            --optimizer-runs 10000 \
            --via-ir
    fi
}

# 4. 依次验证 (按照 DeployLive.s.sol 的构造逻辑)

# GToken(uint256 totalSupply)
verify "$GTOKEN" "GToken" "contracts/src/tokens/GToken.sol:GToken" "$(cast abi-encode "constructor(uint256)" "21000000000000000000000000")"

# GTokenStaking(address gtoken, address initialOwner)
verify "$STAKING" "GTokenStaking" "contracts/src/core/GTokenStaking.sol:GTokenStaking" "$(cast abi-encode "constructor(address,address)" "$GTOKEN" "$DEPLOYER")"

# MySBT(address token, address staking, address registry, address initialOwner)
verify "$SBT" "MySBT" "contracts/src/tokens/MySBT.sol:MySBT" "$(cast abi-encode "constructor(address,address,address,address)" "$GTOKEN" "$STAKING" "$REGISTRY" "$DEPLOYER")"

# Registry(address token, address staking, address sbt)
verify "$REGISTRY" "Registry" "contracts/src/core/Registry.sol:Registry" "$(cast abi-encode "constructor(address,address,address)" "$GTOKEN" "$STAKING" "$SBT")"

# SuperPaymaster(IEntryPoint entryPoint, address initialOwner, address registry, address supervisor, address priceFeed, address treasury, uint256 buffer)
# Buffer according to DeployLive.s.sol is 4200
verify "$SUPER_PAYMASTER" "SuperPaymaster" "contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:SuperPaymaster" \
    "$(cast abi-encode "constructor(address,address,address,address,address,address,uint256)" "$ENTRY_POINT" "$DEPLOYER" "$REGISTRY" "0x0000000000000000000000000000000000000000" "$PRICE_FEED" "$DEPLOYER" "4200")"

# ReputationSystem(address registry)
verify "$REP_SYSTEM" "ReputationSystem" "contracts/src/modules/reputation/ReputationSystem.sol:ReputationSystem" "$(cast abi-encode "constructor(address)" "$REGISTRY")"

# BLSAggregator(address registry, address paymaster, address validator)
verify "$BLS_AGGREGATOR" "BLSAggregator" "contracts/src/modules/monitoring/BLSAggregator.sol:BLSAggregator" "$(cast abi-encode "constructor(address,address,address)" "$REGISTRY" "$SUPER_PAYMASTER" "0x0000000000000000000000000000000000000000")"

# DVTValidator(address registry)
verify "$DVT_VALIDATOR" "DVTValidator" "contracts/src/modules/monitoring/DVTValidator.sol:DVTValidator" "$(cast abi-encode "constructor(address)" "$REGISTRY")"

# BLSValidator()
verify "$BLS_VALIDATOR" "BLSValidator" "contracts/src/modules/validators/BLSValidator.sol:BLSValidator" ""

# xPNTsFactory(address sp, address registry)
verify "$XPNTS_FACTORY" "xPNTsFactory" "contracts/src/tokens/xPNTsFactory.sol:xPNTsFactory" "$(cast abi-encode "constructor(address,address)" "$SUPER_PAYMASTER" "$REGISTRY")"

# 🚀 验证 xPNTsToken 实现合约 (Clone Pattern)
echo -e "${YELLOW}Detecting xPNTsToken implementation...${NC}"
XPNTS_IMPL=$(cast call "$XPNTS_FACTORY" "implementation()(address)" --rpc-url "$RPC_URL")
if [ -n "$XPNTS_IMPL" ] && [ "$XPNTS_IMPL" != "0x0000000000000000000000000000000000000000" ]; then
    verify "$XPNTS_IMPL" "xPNTsTokenImpl" "contracts/src/tokens/xPNTsToken.sol:xPNTsToken" ""
else
    echo -e "${RED}Failed to detect xPNTsToken implementation address from factory.${NC}"
fi

# PaymasterFactory()
verify "$PM_FACTORY" "PaymasterFactory" "contracts/src/paymasters/v4/core/PaymasterFactory.sol:PaymasterFactory" ""

# Paymaster(address registry)
verify "$PM_V4_IMPL" "PaymasterV4Impl" "contracts/src/paymasters/v4/Paymaster.sol:Paymaster" "$(cast abi-encode "constructor(address)" "$REGISTRY")"


echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Verification Process Complete!${NC}"
echo -e "${GREEN}========================================${NC}"

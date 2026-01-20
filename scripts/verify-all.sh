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

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --env) ENV="$2"; shift ;;
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
DVT_VALIDATOR=$(jq -r '.dvtValidator' "$CONFIG_FILE")
ENTRY_POINT=$(jq -r '.entryPoint' "$CONFIG_FILE")

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
    code=$(cast code "$addr" --rpc-url "$SEPOLIA_RPC_URL")
    if [ "$code" == "0x" ]; then
        echo -e "${RED}Skip: No code at ${addr}${NC}"
        return
    fi

    echo -e "Path: ${contract_path}"
    
    if [ -n "$args" ]; then
        echo -e "Args: ${args}"
        forge verify-contract "$addr" "$contract_path" \
            --chain "$ENV" \
            --etherscan-api-key "$ETHERSCAN_API_KEY" \
            --watch \
            --constructor-args "$args" \
            --compiler-version "0.8.28" \
            --optimizer-runs 1 \
            --via-ir
    else
        forge verify-contract "$addr" "$contract_path" \
            --chain "$ENV" \
            --etherscan-api-key "$ETHERSCAN_API_KEY" \
            --watch \
            --compiler-version "0.8.28" \
            --optimizer-runs 1 \
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
    "$(cast abi-encode "constructor(address,address,address,address,address,address,uint256)" "$ENTRY_POINT" "$DEPLOYER" "$REGISTRY" "0x0000000000000000000000000000000000000000" "$ETH_USD_FEED" "$DEPLOYER" "4200")"

# ReputationSystem(address registry)
verify "$REP_SYSTEM" "ReputationSystem" "contracts/src/modules/reputation/ReputationSystem.sol:ReputationSystem" "$(cast abi-encode "constructor(address)" "$REGISTRY")"

# BLSAggregator(address registry, address paymaster, address validator)
verify "$BLS_AGGREGATOR" "BLSAggregator" "contracts/src/modules/monitoring/BLSAggregator.sol:BLSAggregator" "$(cast abi-encode "constructor(address,address,address)" "$REGISTRY" "$SUPER_PAYMASTER" "0x0000000000000000000000000000000000000000")"

# DVTValidator(address registry)
verify "$DVT_VALIDATOR" "DVTValidator" "contracts/src/modules/monitoring/DVTValidator.sol:DVTValidator" "$(cast abi-encode "constructor(address)" "$REGISTRY")"

# xPNTsFactory(address sp, address registry)
verify "$XPNTS_FACTORY" "xPNTsFactory" "contracts/src/tokens/xPNTsFactory.sol:xPNTsFactory" "$(cast abi-encode "constructor(address,address)" "$SUPER_PAYMASTER" "$REGISTRY")"

# PaymasterFactory()
verify "$PM_FACTORY" "PaymasterFactory" "contracts/src/paymasters/v4/core/PaymasterFactory.sol:PaymasterFactory" ""

# Paymaster(address registry)
verify "$PM_V4_IMPL" "PaymasterV4Impl" "contracts/src/paymasters/v4/Paymaster.sol:Paymaster" "$(cast abi-encode "constructor(address)" "$REGISTRY")"

# aPNTs (xPNTsToken)
# deployxPNTsToken("AAStar PNTs", "aPNTs", "AAStar", "aastar.eth", 1e18, address(0))
# Constructed via: xPNTsToken(name, symbol, communityOwner, communityName, communityENS, exchangeRate)
verify "$APNTS" "aPNTs" "contracts/src/tokens/xPNTsToken.sol:xPNTsToken" \
    "$(cast abi-encode "constructor(string,string,address,string,string,uint256)" "AAStar PNTs" "aPNTs" "$DEPLOYER" "AAStar" "aastar.eth" "1000000000000000000")"

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Verification Process Complete!${NC}"
echo -e "${GREEN}========================================${NC}"

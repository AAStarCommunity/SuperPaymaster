#!/bin/bash
# scripts/verify-all.sh
# 自动化验证 SuperPaymaster 所有核心合约
#
# Idempotent: contracts already verified return success quickly.
# Non-fatal per-contract: one bad address (e.g. deprecated `blsValidator`
# missing from config.<env>.json → jq returns "null") does NOT abort the
# whole run. The function tracks failures and prints a summary at the end.

# NOTE: `set -e` intentionally NOT used here. A single forge timeout shouldn't
#       kill verification of the other contracts. Use FAILED_CONTRACTS to
#       surface problems at the end.
set -uo pipefail

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
            if [ -z "${2:-}" ]; then
                echo "Missing value for --env"
                exit 1
            fi
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
GENERIC_RPC_URL="${RPC_URL:-}"
ENV_UPPER=$(echo "$ENV" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
RPC_VAR_NAME="${ENV_UPPER}_RPC_URL"
RPC_URL="${!RPC_VAR_NAME:-}"

# 如果特定网络的 RPC 变量不存在，尝试回退到通用的 RPC_URL
if [ -z "$RPC_URL" ]; then
    RPC_URL="$GENERIC_RPC_URL"
fi

# 如果仍然没有找到 RPC URL，报错
if [ -z "$RPC_URL" ]; then
    echo -e "${RED}Error: Could not find RPC URL. Checked ${RPC_VAR_NAME} and RPC_URL.${NC}"
    exit 1
fi

echo -e "Using RPC URL: ${RPC_URL}"

# 确保必要的变量存在
if [ -z "${ETHERSCAN_API_KEY:-}" ]; then
    echo -e "${RED}Error: ETHERSCAN_API_KEY not set in ${ENV_FILE}${NC}"
    exit 1
fi

# 2. 加载部署配置
CONFIG_FILE="deployments/config.${ENV}.json"
if [ ! -f "$CONFIG_FILE" ]; then
    # Try alternate path
    CONFIG_FILE="contracts/deployments/config.${ENV}.json"
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: config.${ENV}.json not found in assignments/ or contracts/deployments/${NC}"
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
if [ -n "${DEPLOYER_ADDRESS:-}" ]; then
    DEPLOYER="$DEPLOYER_ADDRESS"
elif [ -n "${DEPLOYER_ACCOUNT:-}" ]; then
    # 如果只有 Account Name，尝试解析（可能需要密码，但 verify 不需要签名，只需地址）
    # 但 verify 脚本无法交互输入密码，所以最好是在 env 里配好 DEPLOYER_ADDRESS
    echo -e "${YELLOW}Warning: DEPLOYER_ADDRESS not set. Trying to resolve from Keystore (might fail if requires password)...${NC}"
    DEPLOYER=$(cast wallet address --account "$DEPLOYER_ACCOUNT" 2>/dev/null || echo "")
else
    DEPLOYER=$(cast wallet address --private-key "${PRIVATE_KEY:-}" 2>/dev/null || echo "")
fi

if [ -z "$DEPLOYER" ]; then
     echo -e "${RED}Error: Could not determine DEPLOYER address for constructor args verification.${NC}"
     echo "Please set DEPLOYER_ADDRESS in .env.${ENV}"
     exit 1
fi

echo -e "Deployer detected: ${DEPLOYER}"

# 3. 执行验证函数
FAILED_CONTRACTS=()
VERIFIED_CONTRACTS=()

verify() {
    local addr=$1
    local name=$2
    local contract_path=$3
    local args=$4
    local optional=${5:-false}

    echo -e "\n${YELLOW}>>> Verifying ${name} at ${addr}...${NC}"

    # Skip when jq returned "null" (field missing from config) or empty
    if [ -z "$addr" ] || [ "$addr" == "null" ] || [ "$addr" == "0x0000000000000000000000000000000000000000" ]; then
        if [ "$optional" = true ]; then
            echo -e "${YELLOW}Skip: ${name} address is null/zero/missing from config (optional/deprecated)${NC}"
        else
            echo -e "${RED}Failed: ${name} address is null/zero/missing from config${NC}"
            FAILED_CONTRACTS+=("$name (missing address)")
        fi
        return 0
    fi

    # 简单的代码存在性检查
    code=$(cast code "$addr" --rpc-url "$RPC_URL" 2>/dev/null || echo "0x")
    if [ "$code" == "0x" ]; then
        echo -e "${RED}Skip: No code at ${addr}${NC}"
        FAILED_CONTRACTS+=("$name @ $addr (no code)")
        return 0
    fi

    echo -e "Path: ${contract_path}"

    # Capture both exit code AND stdout/stderr so we can recognize the
    # "is already verified" idempotent case even when forge returns non-zero
    # (observed behaviour with forge 1.7.x on Etherscan API V2 — already-
    # verified contracts sometimes exit 1 despite the verification being
    # confirmed on the explorer).
    local exit_code=0
    local output
    if [ -n "$args" ]; then
        echo -e "Args: ${args}"
        output=$(forge verify-contract "$addr" "$contract_path" \
            --chain "$CHAIN_NAME" \
            --etherscan-api-key "$ETHERSCAN_API_KEY" \
            --watch \
            --constructor-args "$args" \
            --compiler-version "0.8.33" \
            --optimizer-runs 10000 \
            --via-ir 2>&1) || exit_code=$?
    else
        output=$(forge verify-contract "$addr" "$contract_path" \
            --chain "$CHAIN_NAME" \
            --etherscan-api-key "$ETHERSCAN_API_KEY" \
            --watch \
            --compiler-version "0.8.33" \
            --optimizer-runs 10000 \
            --via-ir 2>&1) || exit_code=$?
    fi

    # Echo forge output so logs still show what happened
    echo "$output"

    if [ "$exit_code" -eq 0 ]; then
        VERIFIED_CONTRACTS+=("$name")
    elif echo "$output" | grep -q -i "already verified"; then
        # Forge exited non-zero but Etherscan already has this contract.
        # Treat as success — re-verification is a no-op.
        echo -e "${YELLOW}  (forge exit ${exit_code} but Etherscan reports already-verified — treating as success)${NC}"
        VERIFIED_CONTRACTS+=("$name (already verified)")
    else
        FAILED_CONTRACTS+=("$name @ $addr (exit $exit_code)")
    fi
}

# 4. 依次验证 (按照 DeployLive.s.sol 的构造逻辑)

# GTokenAuthorization(uint256 cap_, address factory_)
verify "$GTOKEN" "GTokenAuthorization" "contracts/src/tokens/GTokenAuthorization.sol:GTokenAuthorization" "$(cast abi-encode "constructor(uint256,address)" "21000000000000000000000000" "$XPNTS_FACTORY")"

# GTokenStaking(address _gtoken, address _treasury, address _registry)
verify "$STAKING" "GTokenStaking" "contracts/src/core/GTokenStaking.sol:GTokenStaking" "$(cast abi-encode "constructor(address,address,address)" "$GTOKEN" "$DEPLOYER" "$REGISTRY")"

# MySBT(address _g, address _s, address _r, address _d) — d is DAO/multisig (same as deployer on Sepolia)
verify "$SBT" "MySBT" "contracts/src/tokens/MySBT.sol:MySBT" "$(cast abi-encode "constructor(address,address,address,address)" "$GTOKEN" "$STAKING" "$REGISTRY" "$DEPLOYER")"

# Registry — UUPS implementation, no constructor args.
# (The proxy stores `initialize(...)` data; the impl contract has no args.)
# Note: $REGISTRY in config is the PROXY address. To verify the IMPL,
# we read the ERC-1967 implementation slot.
REGISTRY_IMPL=$(cast storage "$REGISTRY" 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url "$RPC_URL" 2>/dev/null | sed 's/0x000000000000000000000000/0x/')
echo -e "${YELLOW}Registry implementation (UUPS): ${REGISTRY_IMPL}${NC}"
verify "$REGISTRY_IMPL" "Registry (impl)" "contracts/src/core/Registry.sol:Registry" ""

# SuperPaymaster(IEntryPoint _entryPoint, IRegistry _registry, address _ethUsdPriceFeed) — UUPS impl
# Note: $SUPER_PAYMASTER in config is the PROXY address. Resolve impl via ERC-1967 slot.
SP_IMPL=$(cast storage "$SUPER_PAYMASTER" 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url "$RPC_URL" 2>/dev/null | sed 's/0x000000000000000000000000/0x/')
echo -e "${YELLOW}SuperPaymaster implementation (UUPS): ${SP_IMPL}${NC}"
verify "$SP_IMPL" "SuperPaymaster (impl)" "contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:SuperPaymaster" \
    "$(cast abi-encode "constructor(address,address,address)" "$ENTRY_POINT" "$REGISTRY" "$PRICE_FEED")"

# ReputationSystem(address registry)
verify "$REP_SYSTEM" "ReputationSystem" "contracts/src/modules/reputation/ReputationSystem.sol:ReputationSystem" "$(cast abi-encode "constructor(address)" "$REGISTRY")"

# BLSAggregator(address registry, address paymaster, address validator)
verify "$BLS_AGGREGATOR" "BLSAggregator" "contracts/src/modules/monitoring/BLSAggregator.sol:BLSAggregator" "$(cast abi-encode "constructor(address,address,address)" "$REGISTRY" "$SUPER_PAYMASTER" "0x0000000000000000000000000000000000000000")"

# DVTValidator(address registry)
verify "$DVT_VALIDATOR" "DVTValidator" "contracts/src/modules/monitoring/DVTValidator.sol:DVTValidator" "$(cast abi-encode "constructor(address)" "$REGISTRY")"

# BLSValidator()
verify "$BLS_VALIDATOR" "BLSValidator" "contracts/src/modules/validators/BLSValidator.sol:BLSValidator" "" true

# xPNTsFactory(address sp, address registry)
verify "$XPNTS_FACTORY" "xPNTsFactory" "contracts/src/tokens/xPNTsFactory.sol:xPNTsFactory" "$(cast abi-encode "constructor(address,address)" "$SUPER_PAYMASTER" "$REGISTRY")"

# 🚀 验证 xPNTsToken 实现合约 (Clone Pattern)
echo -e "${YELLOW}Detecting xPNTsToken implementation...${NC}"
XPNTS_IMPL=$(cast call "$XPNTS_FACTORY" "implementation()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
if [ -n "$XPNTS_IMPL" ] && [ "$XPNTS_IMPL" != "0x0000000000000000000000000000000000000000" ]; then
    verify "$XPNTS_IMPL" "xPNTsTokenImpl" "contracts/src/tokens/xPNTsToken.sol:xPNTsToken" ""
else
    echo -e "${RED}Failed to detect xPNTsToken implementation address from factory.${NC}"
    FAILED_CONTRACTS+=("xPNTsTokenImpl (implementation lookup failed)")
fi

# PaymasterFactory()
verify "$PM_FACTORY" "PaymasterFactory" "contracts/src/paymasters/v4/core/PaymasterFactory.sol:PaymasterFactory" ""

# Paymaster(address registry)
verify "$PM_V4_IMPL" "PaymasterV4Impl" "contracts/src/paymasters/v4/Paymaster.sol:Paymaster" "$(cast abi-encode "constructor(address)" "$REGISTRY")"



# 5. Generate Verification Report
echo -e "\n${YELLOW}Generating verification report...${NC}"
# Use npx tsx to execute the typescript script (non-fatal)
npx tsx scripts/generate-verification-report.ts "$ENV" || echo -e "${YELLOW}  (report generation skipped — non-fatal)${NC}"

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Per-contract summary:${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Verified or already-verified (${#VERIFIED_CONTRACTS[@]}):${NC}"
for c in "${VERIFIED_CONTRACTS[@]}"; do echo -e "  ${GREEN}✅${NC} $c"; done
if [ "${#FAILED_CONTRACTS[@]}" -gt 0 ]; then
    echo -e "\n${RED}Failed or skipped (${#FAILED_CONTRACTS[@]}):${NC}"
    for c in "${FAILED_CONTRACTS[@]}"; do echo -e "  ${RED}❌${NC} $c"; done
    echo -e "\n${YELLOW}Hint: re-run verify-all after fixing constructor args / config. Re-runs are idempotent.${NC}"
    exit 1
fi

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Verification Process Complete!${NC}"
echo -e "${GREEN}========================================${NC}"

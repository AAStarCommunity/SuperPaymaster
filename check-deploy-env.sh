#!/bin/bash

# SuperPaymaster v2.0.1 和 Registry v2.2.0 部署环境检查脚本

echo "========================================"
echo "部署环境变量检查"
echo "========================================"
echo ""

# 加载 .env 文件
if [ -f .env ]; then
    source .env
else
    echo "❌ 错误: .env 文件不存在"
    exit 1
fi

# 检查必需的环境变量
MISSING=0

echo "1. 检查网络配置..."
if [ -z "$SEPOLIA_RPC_URL" ]; then
    echo "   ❌ SEPOLIA_RPC_URL 未设置"
    MISSING=$((MISSING + 1))
else
    echo "   ✅ SEPOLIA_RPC_URL: ${SEPOLIA_RPC_URL:0:40}..."
fi

if [ -z "$PRIVATE_KEY" ]; then
    echo "   ❌ PRIVATE_KEY 未设置"
    MISSING=$((MISSING + 1))
else
    echo "   ✅ PRIVATE_KEY: ${PRIVATE_KEY:0:10}... (已设置)"
fi

echo ""
echo "2. 检查依赖合约地址..."

# 使用现有的变量名或新的变量名
GTOKEN_STAKING=${GTOKEN_STAKING:-$GTOKEN_STAKING_ADDRESS}
REGISTRY=${REGISTRY:-$REGISTRY_ADDRESS}

if [ -z "$GTOKEN_STAKING" ]; then
    echo "   ❌ GTOKEN_STAKING 或 GTOKEN_STAKING_ADDRESS 未设置"
    MISSING=$((MISSING + 1))
else
    echo "   ✅ GTOKEN_STAKING: $GTOKEN_STAKING"
fi

if [ -z "$REGISTRY" ]; then
    echo "   ❌ REGISTRY 或 REGISTRY_ADDRESS 未设置"
    MISSING=$((MISSING + 1))
else
    echo "   ✅ REGISTRY: $REGISTRY"
fi

if [ -z "$ETH_USD_PRICE_FEED" ]; then
    echo "   ⚠️  ETH_USD_PRICE_FEED 未设置"
    echo "      Sepolia 推荐值: 0x694AA1769357215DE4FAC081bf1f309aDC325306"
    MISSING=$((MISSING + 1))
else
    echo "   ✅ ETH_USD_PRICE_FEED: $ETH_USD_PRICE_FEED"
fi

if [ -z "$ENTRYPOINT_V07" ]; then
    echo "   ❌ ENTRYPOINT_V07 未设置"
    MISSING=$((MISSING + 1))
else
    echo "   ✅ ENTRYPOINT_V07: $ENTRYPOINT_V07"
fi

echo ""
echo "========================================"
if [ $MISSING -eq 0 ]; then
    echo "✅ 所有环境变量已配置，可以开始部署"
    echo ""
    echo "部署步骤:"
    echo "1. 部署 SuperPaymasterV2 v2.0.1"
    echo "   forge script script/DeploySuperPaymasterV2_0_1.s.sol:DeploySuperPaymasterV2_0_1 \\"
    echo "     --rpc-url \$SEPOLIA_RPC_URL --broadcast --verify -vvvv"
    echo ""
    echo "2. 部署 Registry v2.2.0"
    echo "   forge script script/DeployRegistry_v2_2_0.s.sol:DeployRegistry_v2_2_0 \\"
    echo "     --rpc-url \$SEPOLIA_RPC_URL --broadcast --verify -vvvv"
    echo ""
    echo "3. 配置 Locker"
    echo "   forge script script/ConfigureLockers_v2.s.sol:ConfigureLockers_v2 \\"
    echo "     --sig 'run(address,address)' <superpaymaster_addr> <registry_addr> \\"
    echo "     --rpc-url \$SEPOLIA_RPC_URL --broadcast -vvvv"
else
    echo "❌ 缺失 $MISSING 个环境变量，请先配置"
    echo ""
    echo "建议添加到 .env 文件:"
    [ -z "$ETH_USD_PRICE_FEED" ] && echo "ETH_USD_PRICE_FEED=0x694AA1769357215DE4FAC081bf1f309aDC325306"
    [ -z "$GTOKEN_STAKING" ] && [ -n "$GTOKEN_STAKING_ADDRESS" ] && echo "GTOKEN_STAKING=\$GTOKEN_STAKING_ADDRESS"
    [ -z "$REGISTRY" ] && [ -n "$REGISTRY_ADDRESS" ] && echo "REGISTRY=\$REGISTRY_ADDRESS"
fi
echo "========================================"

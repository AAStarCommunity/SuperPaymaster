#!/bin/bash
# SuperPaymaster V2.3 部署脚本
# 运行: bash scripts/deploy/deploy-v2.3.sh

set -e

echo "========================================="
echo "SuperPaymaster V2.3 部署到Sepolia"
echo "========================================="
echo ""

# 加载环境变量
if [ -f "/Volumes/UltraDisk/Dev2/aastar/env/.env" ]; then
    source /Volumes/UltraDisk/Dev2/aastar/env/.env
    echo "✅ 环境变量已加载"
else
    echo "❌ 找不到.env文件"
    exit 1
fi

# 检查必要的环境变量
if [ -z "$SEPOLIA_RPC_URL" ] || [ -z "$PRIVATE_KEY" ]; then
    echo "❌ 缺少必要的环境变量"
    echo "需要: SEPOLIA_RPC_URL, PRIVATE_KEY"
    exit 1
fi

echo "RPC: ${SEPOLIA_RPC_URL:0:40}..."
echo ""

# 编译合约
echo "📦 编译合约..."
forge build
echo "✅ 编译完成"
echo ""

# 部署参数
GTOKEN="0x36b699a921fc792119D84f1429e2c00a38c09f7f"
GTOKEN_STAKING="0x83f9554641b2Eb8984C4dD03D27f1f75EC537d36"
REGISTRY="0xfc1d62e41a86b11cF19Ce2C0B610bE8D58A5aa4F"
ETH_USD_FEED="0x694AA1769357215DE4FAC081bf1f309aDC325306"
DEFAULT_SBT="0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C"

echo "📋 部署参数:"
echo "  GTOKEN: $GTOKEN"
echo "  GTOKEN_STAKING: $GTOKEN_STAKING"
echo "  REGISTRY: $REGISTRY"
echo "  ETH_USD_FEED: $ETH_USD_FEED"
echo "  DEFAULT_SBT: $DEFAULT_SBT"
echo ""

# 部署合约
echo "🚀 部署SuperPaymasterV2_3..."
DEPLOY_OUTPUT=$(forge create contracts/src/paymasters/v2/core/SuperPaymasterV2_3.sol:SuperPaymasterV2_3 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args $GTOKEN $GTOKEN_STAKING $REGISTRY $ETH_USD_FEED $DEFAULT_SBT \
  --legacy \
  2>&1)

echo "$DEPLOY_OUTPUT"

# 提取部署地址
PAYMASTER_V2_3=$(echo "$DEPLOY_OUTPUT" | grep "Deployed to:" | awk '{print $3}')

if [ -z "$PAYMASTER_V2_3" ]; then
    echo "❌ 部署失败，无法获取合约地址"
    exit 1
fi

echo ""
echo "✅ 部署成功!"
echo "📍 SuperPaymasterV2_3: $PAYMASTER_V2_3"
echo ""

# 保存部署地址
echo "export PAYMASTER_V2_3=$PAYMASTER_V2_3" > .env.v2.3
echo "✅ 地址已保存到 .env.v2.3"
echo ""

# 验证部署
echo "🔍 验证部署..."
VERSION=$(cast call $PAYMASTER_V2_3 "VERSION()(string)" --rpc-url $SEPOLIA_RPC_URL)
DEFAULT_SBT_CHECK=$(cast call $PAYMASTER_V2_3 "DEFAULT_SBT()(address)" --rpc-url $SEPOLIA_RPC_URL)

echo "  VERSION: $VERSION"
echo "  DEFAULT_SBT: $DEFAULT_SBT_CHECK"
echo ""

if [ "$DEFAULT_SBT_CHECK" = "$DEFAULT_SBT" ]; then
    echo "✅ DEFAULT_SBT配置正确"
else
    echo "⚠️  DEFAULT_SBT配置不匹配"
fi

echo ""
echo "========================================="
echo "下一步操作："
echo "========================================="
echo "1. 配置EntryPoint:"
echo "   bash scripts/deploy/configure-v2.3.sh"
echo ""
echo "2. 注册Operator:"
echo "   bash scripts/deploy/register-operator-v2.3.sh"
echo ""
echo "3. 测试Gasless交易:"
echo "   cd scripts/gasless-test"
echo "   node test-v2.3-gasless.js"
echo ""
echo "========================================="

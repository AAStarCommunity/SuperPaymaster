#!/bin/bash

# SuperPaymaster v2 部署脚本
# 自动部署 SuperPaymasterV2 v2.0.1 和 Registry v2.2.0

set -e  # 遇到错误立即退出

# 加载环境变量
source .env

echo "============================================"
echo "🚀 开始部署 SuperPaymaster v2 合约"
echo "============================================"
echo ""
echo "目标网络: Sepolia (Chain ID: 11155111)"
echo "部署账户: $(cast wallet address --private-key "$PRIVATE_KEY")"
echo ""

# 检查余额
BALANCE=$(cast balance $(cast wallet address --private-key "$PRIVATE_KEY") --rpc-url "$SEPOLIA_RPC_URL")
echo "账户余额: $(cast --to-unit "$BALANCE" ether) ETH"
echo ""

if [ "$BALANCE" = "0" ]; then
    echo "❌ 错误: 账户余额为 0，无法支付 gas"
    exit 1
fi

# 部署 SuperPaymasterV2 v2.0.1
echo "============================================"
echo "📝 步骤 1/2: 部署 SuperPaymasterV2 v2.0.1"
echo "============================================"
echo ""

forge script script/DeploySuperPaymasterV2_0_1.s.sol:DeploySuperPaymasterV2_0_1 \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast \
  --verify \
  --etherscan-api-key "${ETHERSCAN_API_KEY:-}" \
  -vvv

# 提取部署地址
SUPERPAYMASTER_ADDR=$(cat broadcast/DeploySuperPaymasterV2_0_1.s.sol/11155111/run-latest.json 2>/dev/null | jq -r '.transactions[0].contractAddress' || echo "")

if [ -n "$SUPERPAYMASTER_ADDR" ] && [ "$SUPERPAYMASTER_ADDR" != "null" ]; then
    echo ""
    echo "✅ SuperPaymasterV2 部署成功: $SUPERPAYMASTER_ADDR"
    echo "SUPERPAYMASTER_V2_ADDRESS=$SUPERPAYMASTER_ADDR" >> /tmp/deployed_addresses.env
    echo ""
else
    echo "⚠️  无法自动提取 SuperPaymaster 地址，请手动查看部署日志"
    echo ""
fi

# 部署 Registry v2.2.0
echo "============================================"
echo "📝 步骤 2/2: 部署 Registry v2.2.0"
echo "============================================"
echo ""

forge script script/DeployRegistry.s.sol:DeployRegistry \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast \
  --verify \
  --etherscan-api-key "${ETHERSCAN_API_KEY:-}" \
  -vvv

# 提取部署地址
REGISTRY_ADDR=$(cat broadcast/DeployRegistry.s.sol/11155111/run-latest.json 2>/dev/null | jq -r '.transactions[0].contractAddress' || echo "")

if [ -n "$REGISTRY_ADDR" ] && [ "$REGISTRY_ADDR" != "null" ]; then
    echo ""
    echo "✅ Registry 部署成功: $REGISTRY_ADDR"
    echo "REGISTRY_V2_2_0_ADDRESS=$REGISTRY_ADDR" >> /tmp/deployed_addresses.env
    echo ""
else
    echo "⚠️  无法自动提取 Registry 地址，请手动查看部署日志"
    echo ""
fi

echo ""
echo "============================================"
echo "🎉 部署完成！"
echo "============================================"
echo ""
echo "部署的合约地址:"
cat /tmp/deployed_addresses.env 2>/dev/null || echo "  (请手动查看 broadcast/ 目录)"
echo ""
echo "下一步:"
echo "1. 配置 Locker"
echo "2. 更新 shared-config"
echo "3. 更新 registry 前端"
echo ""

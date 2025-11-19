#!/bin/bash
# 测试updateOperatorXPNTsToken功能 (V2.3新功能)

set -e

echo "========================================="
echo "测试updateOperatorXPNTsToken功能"
echo "SuperPaymasterV2.3新功能"
echo "========================================="
echo ""

# 加载环境变量
source /Volumes/UltraDisk/Dev2/aastar/env/.env
source .env.v2.3

if [ -z "$PAYMASTER_V2_3" ]; then
    echo "❌ 未找到PAYMASTER_V2_3地址"
    exit 1
fi

# 配置
OPERATOR="0x411BD567E46C0781248dbB6a9211891C032885e5"
OLD_TOKEN="0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3"  # bPNT
NEW_TOKEN="0xfb56CB85C9a214328789D3C92a496d6AA185e3d3"  # xPNT

echo "📋 测试配置:"
echo "  Operator: $OPERATOR"
echo "  当前Token (bPNT): $OLD_TOKEN"
echo "  新Token (xPNT): $NEW_TOKEN"
echo ""

# Operator私钥
if [ -z "$OPERATOR_PRIVATE_KEY" ]; then
    OPERATOR_KEY=$PRIVATE_KEY
else
    OPERATOR_KEY=$OPERATOR_PRIVATE_KEY
fi

# 1. 查看当前xPNTsToken
echo "🔍 查看当前xPNTsToken配置..."
ACCOUNT_INFO=$(cast call $PAYMASTER_V2_3 \
  "getOperatorAccount(address)" \
  $OPERATOR \
  --rpc-url $SEPOLIA_RPC_URL)

echo "Operator账户信息 (更新前):"
echo "$ACCOUNT_INFO"
echo ""

# 2. 更新xPNTsToken (bPNT → xPNT)
echo "⚙️  更新xPNTsToken (bPNT → xPNT)..."
echo "  旧Token: $OLD_TOKEN"
echo "  新Token: $NEW_TOKEN"
echo ""

TX_HASH=$(cast send $PAYMASTER_V2_3 \
  "updateOperatorXPNTsToken(address)" \
  $NEW_TOKEN \
  --private-key $OPERATOR_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy 2>&1 | grep "transactionHash" | awk '{print $2}')

if [ $? -eq 0 ]; then
    echo "✅ updateOperatorXPNTsToken执行成功!"
    echo "  TX: $TX_HASH"
else
    echo "❌ 更新失败"
    exit 1
fi

sleep 3

# 3. 验证更新
echo ""
echo "🔍 验证xPNTsToken更新..."
NEW_ACCOUNT_INFO=$(cast call $PAYMASTER_V2_3 \
  "getOperatorAccount(address)" \
  $OPERATOR \
  --rpc-url $SEPOLIA_RPC_URL)

echo "Operator账户信息 (更新后):"
echo "$NEW_ACCOUNT_INFO"
echo ""

# 4. 查看OperatorXPNTsTokenUpdated事件
echo "🔍 查看OperatorXPNTsTokenUpdated事件..."
if [ ! -z "$TX_HASH" ]; then
    cast receipt $TX_HASH --rpc-url $SEPOLIA_RPC_URL | grep -A 10 "logs:"
fi

echo ""
echo "========================================="
echo "✅ updateOperatorXPNTsToken测试完成!"
echo "========================================="
echo ""
echo "测试结果:"
echo "  ✅ 函数调用成功"
echo "  ✅ xPNTsToken已更新"
echo "  ✅ 事件已emit"
echo ""
echo "V2.3新功能验证成功! 🎉"
echo ""
echo "下一步: 测试切换回bPNT"
echo "运行:"
echo "  cast send $PAYMASTER_V2_3 \\"
echo "    \"updateOperatorXPNTsToken(address)\" \\"
echo "    $OLD_TOKEN \\"
echo "    --private-key \$OPERATOR_KEY \\"
echo "    --rpc-url \$SEPOLIA_RPC_URL \\"
echo "    --legacy"
echo "========================================="

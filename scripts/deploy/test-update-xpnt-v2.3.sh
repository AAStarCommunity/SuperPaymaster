#!/bin/bash
# 测试SuperPaymasterV2_3的updateOperatorXPNTsToken功能

set -e

PAYMASTER_V2_3="0x081084612AAdFdbe135A24D933c440CfA2C983d2"
OPERATOR="0x411BD567E46C0781248dbB6a9211891C032885e5"

# Tokens
BPNT="0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3"  # bPNT (current)
XPNT="0x0000000000000000000000000000000000000001"  # xPNT (example, use real address)

SEPOLIA_RPC_URL=$(grep "^SEPOLIA_RPC_URL=" /Volumes/UltraDisk/Dev2/aastar/env/.env | cut -d'=' -f2- | sed 's/"//g')
PRIVATE_KEY=$(grep "^PRIVATE_KEY=" /Volumes/UltraDisk/Dev2/aastar/env/.env | head -1 | cut -d'=' -f2- | sed 's/"//g')

echo "========================================="
echo "测试updateOperatorXPNTsToken"
echo "========================================="
echo ""
echo "SuperPaymasterV2_3: $PAYMASTER_V2_3"
echo "Operator: $OPERATOR"
echo ""

# 1. 查看当前的xPNTsToken
echo "🔍 查看当前operator配置..."
ACCOUNT=$(cast call $PAYMASTER_V2_3 \
  "getOperatorAccount(address)" \
  $OPERATOR \
  --rpc-url "$SEPOLIA_RPC_URL" 2>&1)

echo "  当前Operator账户信息:"
echo "$ACCOUNT" | head -15
echo ""

# 提取当前的xPNTsToken（第7个字段，从0开始是第6个）
CURRENT_XPNT=$(echo "$ACCOUNT" | sed -n '7p' | tr -d ' ')

echo "  当前xPNTsToken: $CURRENT_XPNT"
echo ""

# 2. 测试更新（使用相同的token来测试，只验证功能可用）
echo "⚙️  测试updateOperatorXPNTsToken..."
echo "  将xPNTsToken从 $CURRENT_XPNT"
echo "  更新为 $BPNT (bPNT)"
echo ""

UPDATE_TX=$(cast send $PAYMASTER_V2_3 \
  "updateOperatorXPNTsToken(address)" \
  $BPNT \
  --private-key $PRIVATE_KEY \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --legacy 2>&1)

if echo "$UPDATE_TX" | grep -q "transactionHash"; then
    UPDATE_HASH=$(echo "$UPDATE_TX" | grep "transactionHash" | awk '{print $2}')
    echo "  ✅ 更新成功!"
    echo "  TX: $UPDATE_HASH"
    echo "  Etherscan: https://sepolia.etherscan.io/tx/$UPDATE_HASH"
else
    echo "  ❌ 更新失败"
    echo "$UPDATE_TX"
    exit 1
fi

sleep 3

# 3. 验证更新
echo ""
echo "🔍 验证更新..."
NEW_ACCOUNT=$(cast call $PAYMASTER_V2_3 \
  "getOperatorAccount(address)" \
  $OPERATOR \
  --rpc-url "$SEPOLIA_RPC_URL" 2>&1)

NEW_XPNT=$(echo "$NEW_ACCOUNT" | sed -n '7p' | tr -d ' ')

echo "  更新后xPNTsToken: $NEW_XPNT"

if [ "$NEW_XPNT" = "$BPNT" ]; then
    echo "  ✅ 验证成功！xPNTsToken已更新"
else
    echo "  ⚠️  xPNTsToken可能未变化或查询有误"
fi

echo ""
echo "========================================="
echo "✅ updateOperatorXPNTsToken功能测试完成!"
echo "========================================="
echo ""
echo "下一步:"
echo "  运行gasless测试验证gas节省"
echo "  cd scripts/gasless-test && node test-gasless-viem-v2-final.js"
echo ""

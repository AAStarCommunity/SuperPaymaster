#!/bin/bash
# SuperPaymaster V2.3 配置脚本

set -e

echo "========================================="
echo "配置SuperPaymasterV2.3"
echo "========================================="
echo ""

# 加载环境变量
source /Volumes/UltraDisk/Dev2/aastar/env/.env
source .env.v2.3

if [ -z "$PAYMASTER_V2_3" ]; then
    echo "❌ 未找到PAYMASTER_V2_3地址"
    echo "请先运行: bash scripts/deploy/deploy-v2.3.sh"
    exit 1
fi

echo "📍 Paymaster: $PAYMASTER_V2_3"
echo ""

# 配置参数
ENTRYPOINT="0x0000000071727De22E5E9d8BAf0edAc6f37da032"
APNTS_TOKEN="0xBD0710596010a157B88cd141d797E8Ad4bb2306b"
TREASURY="0x411BD567E46C0781248dbB6a9211891C032885e5"

echo "📋 配置参数:"
echo "  ENTRYPOINT: $ENTRYPOINT"
echo "  APNTS_TOKEN: $APNTS_TOKEN"
echo "  TREASURY: $TREASURY"
echo ""

# 1. 设置EntryPoint
echo "⚙️  设置EntryPoint..."
cast send $PAYMASTER_V2_3 \
  "setEntryPoint(address)" \
  $ENTRYPOINT \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy

if [ $? -eq 0 ]; then
    echo "✅ EntryPoint设置成功"
else
    echo "❌ EntryPoint设置失败"
    exit 1
fi

sleep 2

# 2. 设置aPNTsToken
echo "⚙️  设置aPNTsToken..."
cast send $PAYMASTER_V2_3 \
  "setAPNTsToken(address)" \
  $APNTS_TOKEN \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy

if [ $? -eq 0 ]; then
    echo "✅ aPNTsToken设置成功"
else
    echo "❌ aPNTsToken设置失败"
    exit 1
fi

sleep 2

# 3. 设置Treasury
echo "⚙️  设置Treasury..."
cast send $PAYMASTER_V2_3 \
  "setSuperPaymasterTreasury(address)" \
  $TREASURY \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy

if [ $? -eq 0 ]; then
    echo "✅ Treasury设置成功"
else
    echo "❌ Treasury设置失败"
    exit 1
fi

sleep 2

# 验证配置
echo ""
echo "🔍 验证配置..."
ENTRY_CHECK=$(cast call $PAYMASTER_V2_3 "ENTRY_POINT()(address)" --rpc-url $SEPOLIA_RPC_URL)
APNTS_CHECK=$(cast call $PAYMASTER_V2_3 "aPNTsToken()(address)" --rpc-url $SEPOLIA_RPC_URL)
TREASURY_CHECK=$(cast call $PAYMASTER_V2_3 "superPaymasterTreasury()(address)" --rpc-url $SEPOLIA_RPC_URL)

echo "  ENTRY_POINT: $ENTRY_CHECK"
echo "  aPNTsToken: $APNTS_CHECK"
echo "  Treasury: $TREASURY_CHECK"
echo ""

# 检查配置是否正确
ERRORS=0
if [ "$ENTRY_CHECK" != "$ENTRYPOINT" ]; then
    echo "❌ EntryPoint配置不匹配"
    ERRORS=$((ERRORS + 1))
fi

if [ "$APNTS_CHECK" != "$APNTS_TOKEN" ]; then
    echo "❌ aPNTsToken配置不匹配"
    ERRORS=$((ERRORS + 1))
fi

if [ "$TREASURY_CHECK" != "$TREASURY" ]; then
    echo "❌ Treasury配置不匹配"
    ERRORS=$((ERRORS + 1))
fi

if [ $ERRORS -eq 0 ]; then
    echo "✅ 所有配置验证成功!"
else
    echo "⚠️  发现 $ERRORS 个配置错误"
    exit 1
fi

echo ""
echo "========================================="
echo "✅ 配置完成!"
echo "========================================="
echo "下一步: 注册Operator"
echo "运行: bash scripts/deploy/register-operator-v2.3.sh"
echo "========================================="

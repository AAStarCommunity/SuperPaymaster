#!/bin/bash
# 检查Operator状态

PAYMASTER_V2_3="0xb89011D7a86E5BBf816A66c9CB30d005D9243b1b"
OPERATOR="0x411BD567E46C0781248dbB6a9211891C032885e5"

SEPOLIA_RPC_URL=$(grep "^SEPOLIA_RPC_URL=" /Volumes/UltraDisk/Dev2/aastar/env/.env | cut -d'=' -f2- | sed 's/"//g')

echo "检查Operator状态..."
echo "Operator: $OPERATOR"
echo ""

# 检查operator是否已注册
ACCOUNT_INFO=$(cast call $PAYMASTER_V2_3 \
  "getOperatorAccount(address)" \
  $OPERATOR \
  --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null)

if [ $? -eq 0 ]; then
    echo "Operator账户信息:"
    echo "$ACCOUNT_INFO"
    echo ""

    # 检查stakedAt是否为0（未注册）
    STAKED_AT=$(cast call $PAYMASTER_V2_3 \
      "accounts(address)" \
      $OPERATOR \
      --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null | head -1)

    echo "StakedAt: $STAKED_AT"

    if [ "$STAKED_AT" = "0x0000000000000000000000000000000000000000000000000000000000000000" ]; then
        echo ""
        echo "❌ Operator未注册"
        echo ""
        echo "由于GTOKEN地址不正确，无法注册operator"
        echo "建议：使用已存在的operator或更新GTOKEN地址"
    else
        echo ""
        echo "✅ Operator已注册"
        echo ""
        echo "可以继续测试updateOperatorXPNTsToken功能"
    fi
else
    echo "❌ 查询失败"
fi

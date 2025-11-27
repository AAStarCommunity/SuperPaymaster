#!/bin/bash
# 注册operator到SuperPaymasterV2_3（使用shared-config v0.3.4地址）

set -e

# 新部署的SuperPaymasterV2_3
PAYMASTER_V2_3="0x081084612AAdFdbe135A24D933c440CfA2C983d2"

# Operator信息
OPERATOR="0x411BD567E46C0781248dbB6a9211891C032885e5"
BPNT="0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3"  # bPNT token
STAKE_AMOUNT="30000000000000000000"  # 30 GT

# shared-config v0.3.4地址
GTOKEN="0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc"
GTOKEN_STAKING="0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0"

SEPOLIA_RPC_URL=$(grep "^SEPOLIA_RPC_URL=" /Volumes/UltraDisk/Dev2/aastar/env/.env | cut -d'=' -f2- | sed 's/"//g')
PRIVATE_KEY=$(grep "^PRIVATE_KEY=" /Volumes/UltraDisk/Dev2/aastar/env/.env | head -1 | cut -d'=' -f2- | sed 's/"//g')

echo "========================================="
echo "注册Operator到SuperPaymasterV2_3"
echo "========================================="
echo ""
echo "SuperPaymasterV2_3: $PAYMASTER_V2_3"
echo "Operator: $OPERATOR"
echo "Stake: 30 GT"
echo "xPNTsToken: $BPNT (bPNT)"
echo ""

# 1. 检查operator在SuperPaymasterV2_3的状态
echo "🔍 检查operator注册状态..."
ACCOUNT=$(cast call $PAYMASTER_V2_3 \
  "accounts(address)" \
  $OPERATOR \
  --rpc-url "$SEPOLIA_RPC_URL" 2>&1 || echo "")

if [ ! -z "$ACCOUNT" ]; then
    STAKED_AT=$(echo "$ACCOUNT" | head -1)
    if [ "$STAKED_AT" != "0" ] && [ ! -z "$STAKED_AT" ]; then
        echo "  ✅ Operator已注册"
        echo ""
        echo "========================================="
        echo "✅ Operator已存在，无需重复注册"
        echo "========================================="
        exit 0
    fi
fi

echo "  ⚠️  Operator未注册，开始注册流程..."
echo ""

# 2. 检查GT余额
echo "🔍 检查GT余额..."
GT_BALANCE=$(cast call $GTOKEN \
  "balanceOf(address)(uint256)" \
  $OPERATOR \
  --rpc-url "$SEPOLIA_RPC_URL" 2>&1)

GT_DEC=$(cast --to-dec "$GT_BALANCE" 2>/dev/null || echo "0")
GT_ETHER=$(echo "scale=2; $GT_DEC / 1000000000000000000" | bc 2>/dev/null || echo "0")

echo "  GT余额: $GT_ETHER GT"

if [ "$GT_DEC" -lt "$STAKE_AMOUNT" ]; then
    echo "  ❌ GT余额不足，需要至少30 GT"
    exit 1
fi

echo "  ✅ GT余额充足"
echo ""

# 3-5. 执行注册流程
echo "⚙️  Approve GT..."
cast send $GTOKEN \
  "approve(address,uint256)" \
  $GTOKEN_STAKING \
  $STAKE_AMOUNT \
  --private-key $PRIVATE_KEY \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --legacy > /dev/null

echo "  ✅ Approve成功"
sleep 2

echo ""
echo "⚙️  Stake GT..."
cast send $GTOKEN_STAKING \
  "stake(uint256)" \
  $STAKE_AMOUNT \
  --private-key $PRIVATE_KEY \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --legacy > /dev/null

echo "  ✅ Stake成功"
sleep 2

echo ""
echo "⚙️  注册Operator..."
REGISTER_TX=$(cast send $PAYMASTER_V2_3 \
  "registerOperator(uint256,address,address)" \
  $STAKE_AMOUNT \
  $BPNT \
  $OPERATOR \
  --private-key $PRIVATE_KEY \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --legacy 2>&1)

if echo "$REGISTER_TX" | grep -q "transactionHash"; then
    REGISTER_HASH=$(echo "$REGISTER_TX" | grep "transactionHash" | awk '{print $2}')
    echo "  ✅ Operator注册成功!"
    echo "  TX: $REGISTER_HASH"
    echo ""
    echo "========================================="
    echo "✅ 注册完成!"
    echo "========================================="
else
    echo "  ❌ 注册失败"
    echo "$REGISTER_TX"
    exit 1
fi

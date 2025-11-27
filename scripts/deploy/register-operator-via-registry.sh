#!/bin/bash
# Operator注册脚本 - 通过Registry的registerCommunityWithAutoStake
#
# 使用说明：
# 1. 用户先给operator地址打GT
# 2. Operator approve Registry合约
# 3. 调用registerCommunityWithAutoStake一步完成stake+register

set -e

echo "========================================="
echo "Operator注册 - Via Registry Auto Stake"
echo "========================================="
echo ""

# 配置
REGISTRY="0xfc1d62e41a86b11cF19Ce2C0B610bE8D58A5aa4F"
OPERATOR="0x411BD567E46C0781248dbB6a9211891C032885e5"
PAYMASTER_V2_3="0xb89011D7a86E5BBf816A66c9CB30d005D9243b1b"

# NodeType: 1 = PAYMASTER_SUPER (需要50 GT)
NODE_TYPE=1
STAKE_AMOUNT="50000000000000000000"  # 50 GT

# Community Profile参数
COMMUNITY_NAME="SuperPaymaster V2.3 Operator"
ENS_NAME=""  # 可选
XPNTS_TOKEN="0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3"  # bPNT
DEFAULT_SBT="0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C"

# 从.env提取RPC和私钥
SEPOLIA_RPC_URL=$(grep "^SEPOLIA_RPC_URL=" /Volumes/UltraDisk/Dev2/aastar/env/.env | cut -d'=' -f2- | sed 's/"//g')
PRIVATE_KEY=$(grep "^PRIVATE_KEY=" /Volumes/UltraDisk/Dev2/aastar/env/.env | head -1 | cut -d'=' -f2- | sed 's/"//g')

echo "📋 注册配置:"
echo "  Operator: $OPERATOR"
echo "  Registry: $REGISTRY"
echo "  Paymaster: $PAYMASTER_V2_3"
echo "  NodeType: $NODE_TYPE (PAYMASTER_SUPER)"
echo "  Stake Amount: 50 GT"
echo "  Community Name: $COMMUNITY_NAME"
echo "  xPNTs Token: $XPNTS_TOKEN (bPNT)"
echo "  Supported SBT: $DEFAULT_SBT"
echo ""

echo "⚠️  重要提示:"
echo "  在运行此脚本前，请确保:"
echo "  1. Operator地址已收到足够的GT (≥50 GT)"
echo "  2. 准备好approve Registry合约"
echo ""

read -p "按Enter继续，或Ctrl+C取消..."
echo ""

# 检查Registry合约的GTOKEN地址
echo "🔍 检查Registry配置..."
GTOKEN=$(cast call $REGISTRY "GTOKEN()(address)" --rpc-url "$SEPOLIA_RPC_URL")
GTOKEN_STAKING=$(cast call $REGISTRY "GTOKEN_STAKING()(address)" --rpc-url "$SEPOLIA_RPC_URL")

echo "  GTOKEN: $GTOKEN"
echo "  GTOKEN_STAKING: $GTOKEN_STAKING"
echo ""

# 检查GT余额
echo "🔍 检查Operator GT余额..."
GT_BALANCE=$(cast call $GTOKEN "balanceOf(address)(uint256)" $OPERATOR --rpc-url "$SEPOLIA_RPC_URL")
GT_BALANCE_DEC=$(cast --to-dec $GT_BALANCE)

echo "  GT余额: $GT_BALANCE_DEC wei"
echo "  需要: $STAKE_AMOUNT wei (50 GT)"

if [ "$GT_BALANCE_DEC" -lt "$STAKE_AMOUNT" ]; then
    echo ""
    echo "❌ GT余额不足!"
    echo ""
    echo "请向以下地址打GT:"
    echo "  地址: $OPERATOR"
    echo "  需要数量: 50 GT"
    echo "  当前余额: $(echo "scale=18; $GT_BALANCE_DEC / 1000000000000000000" | bc) GT"
    echo ""
    exit 1
fi

echo "  ✅ GT余额充足"
echo ""

# 步骤1: Approve GTOKEN给Registry
echo "⚙️  步骤1: Approve GT给Registry..."
APPROVE_TX=$(cast send $GTOKEN \
  "approve(address,uint256)" \
  $REGISTRY \
  $STAKE_AMOUNT \
  --private-key $PRIVATE_KEY \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --legacy 2>&1 | grep "transactionHash" | awk '{print $2}')

if [ $? -eq 0 ]; then
    echo "  ✅ Approve成功: $APPROVE_TX"
else
    echo "  ❌ Approve失败"
    exit 1
fi

sleep 3

# 步骤2: 调用registerCommunityWithAutoStake
echo ""
echo "⚙️  步骤2: 调用registerCommunityWithAutoStake..."
echo ""
echo "  构造CommunityProfile参数:"
echo "    name: $COMMUNITY_NAME"
echo "    ensName: (empty)"
echo "    xPNTsToken: $XPNTS_TOKEN"
echo "    supportedSBTs: [$DEFAULT_SBT]"
echo "    nodeType: $NODE_TYPE"
echo "    paymasterAddress: $PAYMASTER_V2_3"
echo ""

# 使用cast发送交易
# CommunityProfile结构:
# (string name, string ensName, address xPNTsToken, address[] supportedSBTs,
#  uint8 nodeType, address paymasterAddress, address community,
#  uint256 registeredAt, uint256 lastUpdatedAt, bool isActive, bool allowPermissionlessMint)

REGISTER_TX=$(cast send $REGISTRY \
  'registerCommunityWithAutoStake((string,string,address,address[],uint8,address,address,uint256,uint256,bool,bool),uint256)' \
  "($COMMUNITY_NAME,,${XPNTS_TOKEN},[${DEFAULT_SBT}],${NODE_TYPE},${PAYMASTER_V2_3},0x0000000000000000000000000000000000000000,0,0,false,false)" \
  $STAKE_AMOUNT \
  --private-key $PRIVATE_KEY \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --legacy 2>&1)

echo "$REGISTER_TX"
echo ""

REGISTER_TX_HASH=$(echo "$REGISTER_TX" | grep "transactionHash" | awk '{print $2}')

if [ ! -z "$REGISTER_TX_HASH" ]; then
    echo "✅ Operator注册成功!"
    echo "  TX: $REGISTER_TX_HASH"
    sleep 5

    # 验证注册
    echo ""
    echo "🔍 验证Operator注册..."
    IS_REGISTERED=$(cast call $REGISTRY \
      "isRegistered(address)(bool)" \
      $OPERATOR \
      --rpc-url "$SEPOLIA_RPC_URL")

    COMMUNITY_INFO=$(cast call $REGISTRY \
      "communities(address)" \
      $OPERATOR \
      --rpc-url "$SEPOLIA_RPC_URL")

    echo "  isRegistered: $IS_REGISTERED"
    echo "  Community Info: $COMMUNITY_INFO"
    echo ""

    if [ "$IS_REGISTERED" = "true" ]; then
        echo "✅ 验证成功: Operator已在Registry注册"
        echo ""
        echo "========================================="
        echo "✅ Operator注册完成!"
        echo "========================================="
        echo ""
        echo "下一步:"
        echo "1. 在SuperPaymasterV2_3中注册operator:"
        echo "   bash scripts/deploy/register-operator-v2.3-final.sh"
        echo ""
        echo "2. 测试updateOperatorXPNTsToken:"
        echo "   bash scripts/deploy/test-update-xpnt.sh"
    else
        echo "❌ 验证失败: Operator未注册"
    fi
else
    echo "❌ Operator注册失败"
    exit 1
fi

#!/bin/bash
# 检查operator状态并注册到SuperPaymasterV2_3

set -e

REGISTRY="0xfc1d62e41a86b11cF19Ce2C0B610bE8D58A5aa4F"
OPERATOR="0x411BD567E46C0781248dbB6a9211891C032885e5"
PAYMASTER_V2_3="0xb89011D7a86E5BBf816A66c9CB30d005D9243b1b"
BPNT="0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3"
STAKE_AMOUNT="30000000000000000000"  # 30 GT

SEPOLIA_RPC_URL=$(grep "^SEPOLIA_RPC_URL=" /Volumes/UltraDisk/Dev2/aastar/env/.env | cut -d'=' -f2- | sed 's/"//g')
PRIVATE_KEY=$(grep "^PRIVATE_KEY=" /Volumes/UltraDisk/Dev2/aastar/env/.env | head -1 | cut -d'=' -f2- | sed 's/"//g')

echo "========================================="
echo "检查Operator状态并注册到V2.3"
echo "========================================="
echo ""
echo "Operator: $OPERATOR"
echo "SuperPaymasterV2_3: $PAYMASTER_V2_3"
echo ""

# 1. 检查Registry中的GTOKEN地址
echo "🔍 检查Registry配置..."
GTOKEN=$(cast call $REGISTRY "GTOKEN()(address)" --rpc-url "$SEPOLIA_RPC_URL")
GTOKEN_STAKING=$(cast call $REGISTRY "GTOKEN_STAKING()(address)" --rpc-url "$SEPOLIA_RPC_URL")

echo "  GTOKEN: $GTOKEN"
echo "  GTOKEN_STAKING: $GTOKEN_STAKING"
echo ""

# 2. 检查operator在Registry的注册状态
echo "🔍 检查Registry注册状态..."
IS_REGISTERED=$(cast call $REGISTRY "isRegistered(address)(bool)" $OPERATOR --rpc-url "$SEPOLIA_RPC_URL")
echo "  isRegistered: $IS_REGISTERED"

if [ "$IS_REGISTERED" = "true" ]; then
    echo "  ✅ Operator已在Registry注册"

    # 检查community信息
    echo ""
    echo "  Community信息:"
    cast call $REGISTRY "communities(address)" $OPERATOR --rpc-url "$SEPOLIA_RPC_URL" | head -5
else
    echo "  ⚠️  Operator未在Registry注册"
    echo "  可以继续，SuperPaymasterV2_3不强制要求Registry注册"
fi

# 3. 检查GT余额
echo ""
echo "🔍 检查GT余额..."
GT_BALANCE=$(cast call $GTOKEN "balanceOf(address)(uint256)" $OPERATOR --rpc-url "$SEPOLIA_RPC_URL")
GT_BALANCE_DEC=$(cast --to-dec $GT_BALANCE)
GT_BALANCE_ETHER=$(echo "scale=2; $GT_BALANCE_DEC / 1000000000000000000" | bc)

echo "  GT余额: $GT_BALANCE_ETHER GT"

if [ "$GT_BALANCE_DEC" -lt "$STAKE_AMOUNT" ]; then
    echo "  ❌ GT余额不足，需要至少30 GT"
    exit 1
fi
echo "  ✅ GT余额充足"

# 4. 检查GTokenStaking中的staked余额
echo ""
echo "🔍 检查Staking状态..."
STAKED=$(cast call $GTOKEN_STAKING "staked(address)(uint256)" $OPERATOR --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
STAKED_DEC=$(cast --to-dec $STAKED)
STAKED_ETHER=$(echo "scale=2; $STAKED_DEC / 1000000000000000000" | bc)

echo "  已Stake: $STAKED_ETHER GT"

# 5. 检查SuperPaymasterV2_3中的operator状态
echo ""
echo "🔍 检查SuperPaymasterV2_3中的operator状态..."
ACCOUNT_INFO=$(cast call $PAYMASTER_V2_3 "getOperatorAccount(address)" $OPERATOR --rpc-url "$SEPOLIA_RPC_URL")

# 检查stakedAt（第一个返回值）
if echo "$ACCOUNT_INFO" | grep -q "^0x0000000000000000000000000000000000000000000000000000000000000000"; then
    echo "  ⚠️  Operator未在SuperPaymasterV2_3注册"
    echo ""

    # 需要注册
    echo "========================================="
    echo "开始注册Operator到SuperPaymasterV2_3"
    echo "========================================="
    echo ""

    # 检查是否需要stake
    if [ "$STAKED_DEC" -lt "$STAKE_AMOUNT" ]; then
        NEED_STAKE=$((STAKE_AMOUNT - STAKED_DEC))
        NEED_STAKE_ETHER=$(echo "scale=2; $NEED_STAKE / 1000000000000000000" | bc)

        echo "📌 需要stake额外的 $NEED_STAKE_ETHER GT"
        echo ""

        # Approve
        echo "⚙️  Approve GT给GTokenStaking..."
        cast send $GTOKEN \
          "approve(address,uint256)" \
          $GTOKEN_STAKING \
          $NEED_STAKE \
          --private-key $PRIVATE_KEY \
          --rpc-url "$SEPOLIA_RPC_URL" \
          --legacy > /dev/null

        echo "  ✅ Approve成功"
        sleep 2

        # Stake
        echo "⚙️  Stake GT..."
        cast send $GTOKEN_STAKING \
          "stake(uint256)" \
          $NEED_STAKE \
          --private-key $PRIVATE_KEY \
          --rpc-url "$SEPOLIA_RPC_URL" \
          --legacy > /dev/null

        echo "  ✅ Stake成功"
        sleep 2
    else
        echo "  ✅ 已有足够的staked GT"
    fi

    # 注册operator
    echo ""
    echo "⚙️  注册Operator到SuperPaymasterV2_3..."
    echo "  参数:"
    echo "    stGTokenAmount: $STAKE_AMOUNT (30 GT)"
    echo "    xPNTsToken: $BPNT (bPNT)"
    echo "    treasury: $OPERATOR"
    echo ""

    REGISTER_TX=$(cast send $PAYMASTER_V2_3 \
      "registerOperator(uint256,address,address)" \
      $STAKE_AMOUNT \
      $BPNT \
      $OPERATOR \
      --private-key $PRIVATE_KEY \
      --rpc-url "$SEPOLIA_RPC_URL" \
      --legacy 2>&1)

    echo "$REGISTER_TX"

    REGISTER_TX_HASH=$(echo "$REGISTER_TX" | grep "transactionHash" | awk '{print $2}')

    if [ ! -z "$REGISTER_TX_HASH" ]; then
        echo ""
        echo "✅ Operator注册成功!"
        echo "  TX: $REGISTER_TX_HASH"
        sleep 5

        # 验证
        echo ""
        echo "🔍 验证注册..."
        NEW_ACCOUNT=$(cast call $PAYMASTER_V2_3 "getOperatorAccount(address)" $OPERATOR --rpc-url "$SEPOLIA_RPC_URL")
        echo "  Operator账户信息:"
        echo "$NEW_ACCOUNT" | head -10
        echo ""
        echo "✅ 注册验证完成!"
    else
        echo ""
        echo "❌ 注册失败"
        exit 1
    fi
else
    echo "  ✅ Operator已在SuperPaymasterV2_3注册"
    echo ""
    echo "  Operator账户信息:"
    echo "$ACCOUNT_INFO" | head -10
fi

echo ""
echo "========================================="
echo "✅ Operator状态检查完成"
echo "========================================="
echo ""
echo "下一步："
echo "1. 测试updateOperatorXPNTsToken:"
echo "   bash scripts/deploy/test-update-xpnt.sh"
echo ""
echo "2. 运行gasless测试:"
echo "   cd scripts/gasless-test && node test-gasless-viem-v2-final.js"

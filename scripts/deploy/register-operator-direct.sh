#!/bin/bash
# 直接注册operator到SuperPaymasterV2_3（跳过Registry）

set -e

OPERATOR="0x411BD567E46C0781248dbB6a9211891C032885e5"
PAYMASTER_V2_3="0xb89011D7a86E5BBf816A66c9CB30d005D9243b1b"
BPNT="0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3"
STAKE_AMOUNT="30000000000000000000"  # 30 GT

SEPOLIA_RPC_URL=$(grep "^SEPOLIA_RPC_URL=" /Volumes/UltraDisk/Dev2/aastar/env/.env | cut -d'=' -f2- | sed 's/"//g')
PRIVATE_KEY=$(grep "^PRIVATE_KEY=" /Volumes/UltraDisk/Dev2/aastar/env/.env | head -1 | cut -d'=' -f2- | sed 's/"//g')

echo "========================================="
echo "直接注册Operator到SuperPaymasterV2_3"
echo "========================================="
echo ""
echo "Operator: $OPERATOR"
echo "SuperPaymasterV2_3: $PAYMASTER_V2_3"
echo "Stake: 30 GT"
echo "xPNTsToken: $BPNT (bPNT)"
echo ""

# 获取部署时使用的地址
GTOKEN=$(cast call $PAYMASTER_V2_3 "gtoken()(address)" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null)
GTOKEN_STAKING=$(cast call $PAYMASTER_V2_3 "gtokenStaking()(address)" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null)

if [ -z "$GTOKEN" ]; then
    # 如果无法读取，使用部署参数中的地址
    GTOKEN="0x36b699a921fc792119D84f1429e2c00a38c09f7f"
    GTOKEN_STAKING="0x83f9554641b2Eb8984C4dD03D27f1f75EC537d36"
    echo "⚠️  使用部署参数中的地址"
fi

echo "GTOKEN: $GTOKEN"
echo "GTOKEN_STAKING: $GTOKEN_STAKING"
echo ""

# 检查合约是否有代码
echo "🔍 检查合约状态..."
GTOKEN_CODE=$(cast code $GTOKEN --rpc-url "$SEPOLIA_RPC_URL")

if [ "$GTOKEN_CODE" = "0x" ]; then
    echo ""
    echo "❌ GTOKEN合约在Sepolia无代码"
    echo ""
    echo "问题分析："
    echo "  部署时使用的GTOKEN地址可能是错误的或其他网络的地址"
    echo ""
    echo "解决方案："
    echo "  1. 查找Sepolia上正确的GTOKEN地址"
    echo "  2. 或者部署新的GTOKEN系统到Sepolia"
    echo "  3. 或者使用现有operator（如果在其他paymaster已注册）"
    echo ""
    echo "当前operator地址: $OPERATOR"
    echo "GT余额: 200 GT (用户提供)"
    echo ""
    exit 1
fi

echo "  ✅ GTOKEN合约存在"

# 检查operator状态
echo ""
echo "🔍 检查SuperPaymasterV2_3中的operator..."
ACCOUNT=$(cast call $PAYMASTER_V2_3 \
  "accounts(address)" \
  $OPERATOR \
  --rpc-url "$SEPOLIA_RPC_URL" 2>&1)

echo "$ACCOUNT" | head -5

# 提取stakedAt（tuple的第一个字段）
STAKED_AT=$(echo "$ACCOUNT" | head -1)

if [ "$STAKED_AT" = "0" ] || [ -z "$STAKED_AT" ]; then
    echo ""
    echo "⚠️  Operator未注册，准备注册..."
    echo ""

    # 检查GT余额
    echo "🔍 检查GT余额..."
    GT_BALANCE=$(cast call $GTOKEN \
      "balanceOf(address)(uint256)" \
      $OPERATOR \
      --rpc-url "$SEPOLIA_RPC_URL" 2>&1)

    if echo "$GT_BALANCE" | grep -q "Error"; then
        echo "  ❌ 无法查询GT余额（GTOKEN合约可能不可用）"
        exit 1
    fi

    GT_DEC=$(cast --to-dec $GT_BALANCE)
    GT_ETHER=$(echo "scale=2; $GT_DEC / 1000000000000000000" | bc)

    echo "  GT余额: $GT_ETHER GT"

    if [ "$GT_DEC" -lt "$STAKE_AMOUNT" ]; then
        echo "  ❌ GT余额不足，需要至少30 GT"
        exit 1
    fi

    echo "  ✅ GT余额充足"
    echo ""

    # Approve
    echo "⚙️  Approve GT给GTokenStaking..."
    APPROVE_TX=$(cast send $GTOKEN \
      "approve(address,uint256)" \
      $GTOKEN_STAKING \
      $STAKE_AMOUNT \
      --private-key $PRIVATE_KEY \
      --rpc-url "$SEPOLIA_RPC_URL" \
      --legacy 2>&1)

    if echo "$APPROVE_TX" | grep -q "transactionHash"; then
        APPROVE_HASH=$(echo "$APPROVE_TX" | grep "transactionHash" | awk '{print $2}')
        echo "  ✅ Approve成功: $APPROVE_HASH"
    else
        echo "  ❌ Approve失败"
        echo "$APPROVE_TX"
        exit 1
    fi

    sleep 3

    # Stake
    echo ""
    echo "⚙️  Stake GT..."
    STAKE_TX=$(cast send $GTOKEN_STAKING \
      "stake(uint256)" \
      $STAKE_AMOUNT \
      --private-key $PRIVATE_KEY \
      --rpc-url "$SEPOLIA_RPC_URL" \
      --legacy 2>&1)

    if echo "$STAKE_TX" | grep -q "transactionHash"; then
        STAKE_HASH=$(echo "$STAKE_TX" | grep "transactionHash" | awk '{print $2}')
        echo "  ✅ Stake成功: $STAKE_HASH"
    else
        echo "  ❌ Stake失败"
        echo "$STAKE_TX"
        exit 1
    fi

    sleep 3

    # 注册operator
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
        echo "  ✅ Operator注册成功: $REGISTER_HASH"
    else
        echo "  ❌ 注册失败"
        echo "$REGISTER_TX"
        exit 1
    fi

    sleep 5

    # 验证
    echo ""
    echo "🔍 验证注册..."
    NEW_ACCOUNT=$(cast call $PAYMASTER_V2_3 \
      "getOperatorAccount(address)" \
      $OPERATOR \
      --rpc-url "$SEPOLIA_RPC_URL")

    echo "  Operator账户:"
    echo "$NEW_ACCOUNT" | head -10

    echo ""
    echo "========================================="
    echo "✅ Operator注册完成!"
    echo "========================================="
else
    echo ""
    echo "  ✅ Operator已注册"
    echo ""
    echo "========================================="
    echo "✅ Operator已存在"
    echo "========================================="
fi

echo ""
echo "下一步："
echo "1. 测试updateOperatorXPNTsToken:"
echo "   bash scripts/deploy/test-update-xpnt.sh"
echo ""
echo "2. 生成Gas报告:"
echo "   bash scripts/deploy/gas-savings-report.sh"

#!/bin/bash
# Operator注册脚本 - 使用bPNT token

set -e

echo "========================================="
echo "注册Operator到SuperPaymasterV2.3"
echo "使用bPNT Token (Bread Points)"
echo "========================================="
echo ""

# 加载环境变量
source /Volumes/UltraDisk/Dev2/aastar/env/.env
source .env.v2.3

if [ -z "$PAYMASTER_V2_3" ]; then
    echo "❌ 未找到PAYMASTER_V2_3地址"
    exit 1
fi

# Operator配置
OPERATOR="0x411BD567E46C0781248dbB6a9211891C032885e5"
BPNT_TOKEN="0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3"  # Bread Points
TREASURY=$OPERATOR  # 使用同一地址作为treasury
STAKE_AMOUNT="30000000000000000000"  # 30 GT

GTOKEN="0x36b699a921fc792119D84f1429e2c00a38c09f7f"
GTOKEN_STAKING="0x83f9554641b2Eb8984C4dD03D27f1f75EC537d36"

echo "📋 Operator配置:"
echo "  Operator: $OPERATOR"
echo "  bPNT Token: $BPNT_TOKEN"
echo "  Treasury: $TREASURY"
echo "  Stake Amount: 30 GT"
echo ""

# 检查operator的私钥
if [ -z "$OPERATOR_PRIVATE_KEY" ]; then
    echo "⚠️  警告: 未找到OPERATOR_PRIVATE_KEY环境变量"
    echo "使用PRIVATE_KEY作为operator密钥"
    OPERATOR_KEY=$PRIVATE_KEY
else
    OPERATOR_KEY=$OPERATOR_PRIVATE_KEY
fi

# 1. 检查GT余额
echo "🔍 检查GT余额..."
GT_BALANCE=$(cast call $GTOKEN \
  "balanceOf(address)(uint256)" \
  $OPERATOR \
  --rpc-url $SEPOLIA_RPC_URL)

echo "  GT余额: $(cast --to-dec $GT_BALANCE) wei"

if [ "$(cast --to-dec $GT_BALANCE)" -lt "$STAKE_AMOUNT" ]; then
    echo "❌ GT余额不足，需要至少30 GT"
    exit 1
fi

# 2. Approve GT给GTokenStaking
echo "⚙️  Approve GT给GTokenStaking..."
cast send $GTOKEN \
  "approve(address,uint256)" \
  $GTOKEN_STAKING \
  $STAKE_AMOUNT \
  --private-key $OPERATOR_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy

echo "✅ Approve成功"
sleep 2

# 3. Stake GT
echo "⚙️  Stake 30 GT..."
cast send $GTOKEN_STAKING \
  "stake(uint256)" \
  $STAKE_AMOUNT \
  --private-key $OPERATOR_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy

echo "✅ Stake成功"
sleep 2

# 4. 注册Operator (⚡ V2.3: 无需supportedSBTs参数)
echo "⚙️  注册Operator (使用bPNT)..."
echo "  参数:"
echo "    - stGTokenAmount: $STAKE_AMOUNT"
echo "    - xPNTsToken: $BPNT_TOKEN (bPNT)"
echo "    - treasury: $TREASURY"
echo ""

cast send $PAYMASTER_V2_3 \
  "registerOperator(uint256,address,address)" \
  $STAKE_AMOUNT \
  $BPNT_TOKEN \
  $TREASURY \
  --private-key $OPERATOR_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy

if [ $? -eq 0 ]; then
    echo "✅ Operator注册成功!"
else
    echo "❌ Operator注册失败"
    exit 1
fi

sleep 3

# 5. 验证注册
echo ""
echo "🔍 验证Operator注册..."
ACCOUNT_INFO=$(cast call $PAYMASTER_V2_3 \
  "getOperatorAccount(address)" \
  $OPERATOR \
  --rpc-url $SEPOLIA_RPC_URL)

echo "Operator账户信息:"
echo "$ACCOUNT_INFO"
echo ""

# 检查xPNTsToken是否为bPNT
# 注意: getOperatorAccount返回的是tuple，需要解析
echo "验证xPNTsToken配置..."
XPNT_TOKEN=$(cast call $PAYMASTER_V2_3 \
  "accounts(address)" \
  $OPERATOR \
  --rpc-url $SEPOLIA_RPC_URL | grep -o "0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3" || echo "")

if [ ! -z "$XPNT_TOKEN" ]; then
    echo "✅ xPNTsToken配置正确 (bPNT)"
else
    echo "⚠️  无法验证xPNTsToken配置"
fi

echo ""
echo "========================================="
echo "✅ Operator注册完成!"
echo "========================================="
echo ""
echo "Operator信息:"
echo "  地址: $OPERATOR"
echo "  Token: bPNT (0x70Da2...)"
echo "  Stake: 30 GT"
echo ""
echo "下一步:"
echo "1. 测试updateOperatorXPNTsToken:"
echo "   bash scripts/deploy/test-update-xpnt.sh"
echo ""
echo "2. 运行Gasless测试:"
echo "   cd scripts/gasless-test"
echo "   node test-v2.3-gasless.js"
echo "========================================="

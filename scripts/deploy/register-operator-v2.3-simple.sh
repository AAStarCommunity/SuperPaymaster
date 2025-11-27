#!/bin/bash
# 简化版Operator注册脚本 - V2.3

set -e

PAYMASTER_V2_3="0xb89011D7a86E5BBf816A66c9CB30d005D9243b1b"
OPERATOR="0x411BD567E46C0781248dbB6a9211891C032885e5"
BPNT_TOKEN="0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3"
TREASURY="0x411BD567E46C0781248dbB6a9211891C032885e5"
STAKE_AMOUNT="30000000000000000000"

GTOKEN="0x36b699a921fc792119D84f1429e2c00a38c09f7f"
GTOKEN_STAKING="0x83f9554641b2Eb8984C4dD03D27f1f75EC537d36"

# 从.env提取RPC和私钥
SEPOLIA_RPC_URL=$(grep "^SEPOLIA_RPC_URL=" /Volumes/UltraDisk/Dev2/aastar/env/.env | cut -d'=' -f2- | sed 's/"//g')
PRIVATE_KEY=$(grep "^PRIVATE_KEY=" /Volumes/UltraDisk/Dev2/aastar/env/.env | head -1 | cut -d'=' -f2- | sed 's/"//g')

echo "========================================="
echo "注册Operator到SuperPaymasterV2.3"
echo "使用bPNT Token"
echo "========================================="
echo ""
echo "Operator: $OPERATOR"
echo "bPNT Token: $BPNT_TOKEN"
echo "Stake: 30 GT"
echo ""

# 1. 检查GT余额
echo "🔍 检查GT余额..."
GT_BALANCE=$(cast call $GTOKEN \
  "balanceOf(address)(uint256)" \
  $OPERATOR \
  --rpc-url "$SEPOLIA_RPC_URL")

echo "  GT余额: $GT_BALANCE wei"

# 2. Approve GT
echo "⚙️  Approve GT给GTokenStaking..."
cast send $GTOKEN \
  "approve(address,uint256)" \
  $GTOKEN_STAKING \
  $STAKE_AMOUNT \
  --private-key $PRIVATE_KEY \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --legacy > /dev/null

echo "✅ Approve成功"
sleep 2

# 3. Stake GT
echo "⚙️  Stake 30 GT..."
cast send $GTOKEN_STAKING \
  "stake(uint256)" \
  $STAKE_AMOUNT \
  --private-key $PRIVATE_KEY \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --legacy > /dev/null

echo "✅ Stake成功"
sleep 2

# 4. 注册Operator (V2.3: 无需supportedSBTs参数)
echo "⚙️  注册Operator (使用bPNT)..."
cast send $PAYMASTER_V2_3 \
  "registerOperator(uint256,address,address)" \
  $STAKE_AMOUNT \
  $BPNT_TOKEN \
  $TREASURY \
  --private-key $PRIVATE_KEY \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --legacy

echo "✅ Operator注册成功!"
sleep 3

# 5. 验证注册
echo ""
echo "🔍 验证Operator注册..."
ACCOUNT_INFO=$(cast call $PAYMASTER_V2_3 \
  "getOperatorAccount(address)" \
  $OPERATOR \
  --rpc-url "$SEPOLIA_RPC_URL")

echo "Operator账户信息:"
echo "$ACCOUNT_INFO"
echo ""
echo "========================================="
echo "✅ Operator注册完成!"
echo "========================================="

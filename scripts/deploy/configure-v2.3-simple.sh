#!/bin/bash
# 简化版配置脚本 - V2.3

set -e

PAYMASTER_V2_3="0xb89011D7a86E5BBf816A66c9CB30d005D9243b1b"
ENTRYPOINT="0x0000000071727De22E5E9d8BAf0edAc6f37da032"
APNTS="0xBD0710596010a157B88cd141d797E8Ad4bb2306b"
TREASURY="0x411BD567E46C0781248dbB6a9211891C032885e5"

# 从.env提取RPC和私钥
SEPOLIA_RPC_URL=$(grep "^SEPOLIA_RPC_URL=" /Volumes/UltraDisk/Dev2/aastar/env/.env | cut -d'=' -f2- | sed 's/"//g')
PRIVATE_KEY=$(grep "^PRIVATE_KEY=" /Volumes/UltraDisk/Dev2/aastar/env/.env | head -1 | cut -d'=' -f2- | sed 's/"//g')

echo "========================================="
echo "配置SuperPaymasterV2.3"
echo "========================================="
echo ""
echo "Paymaster: $PAYMASTER_V2_3"
echo ""

# 1. setEntryPoint
echo "⚙️  配置EntryPoint..."
cast send $PAYMASTER_V2_3 \
  "setEntryPoint(address)" \
  $ENTRYPOINT \
  --private-key $PRIVATE_KEY \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --legacy

echo "✅ EntryPoint配置完成"
sleep 2

# 2. setAPNTsToken
echo "⚙️  配置aPNTs Token..."
cast send $PAYMASTER_V2_3 \
  "setAPNTsToken(address)" \
  $APNTS \
  --private-key $PRIVATE_KEY \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --legacy

echo "✅ aPNTs Token配置完成"
sleep 2

# 3. setSuperPaymasterTreasury
echo "⚙️  配置Treasury..."
cast send $PAYMASTER_V2_3 \
  "setSuperPaymasterTreasury(address)" \
  $TREASURY \
  --private-key $PRIVATE_KEY \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --legacy

echo "✅ Treasury配置完成"
echo ""
echo "========================================="
echo "✅ 所有配置完成!"
echo "========================================="

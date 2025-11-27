#!/bin/bash
# 配置SuperPaymasterV2_3（使用shared-config v0.3.4地址）

set -e

PAYMASTER_V2_3="0x081084612AAdFdbe135A24D933c440CfA2C983d2"
ENTRY_POINT="0x0000000071727De22E5E9d8BAf0edAc6f37da032"
APNTS_TOKEN="0xBD0710596010a157B88cd141d797E8Ad4bb2306b"
TREASURY="0x411BD567E46C0781248dbB6a9211891C032885e5"

SEPOLIA_RPC_URL=$(grep "^SEPOLIA_RPC_URL=" /Volumes/UltraDisk/Dev2/aastar/env/.env | cut -d'=' -f2- | sed 's/"//g')
PRIVATE_KEY=$(grep "^PRIVATE_KEY=" /Volumes/UltraDisk/Dev2/aastar/env/.env | head -1 | cut -d'=' -f2- | sed 's/"//g')

echo "========================================="
echo "配置SuperPaymasterV2_3"
echo "========================================="
echo ""
echo "SuperPaymasterV2_3: $PAYMASTER_V2_3"
echo "EntryPoint: $ENTRY_POINT"
echo "aPNTsToken: $APNTS_TOKEN"
echo "Treasury: $TREASURY"
echo ""

# 配置EntryPoint
echo "⚙️  配置EntryPoint..."
cast send $PAYMASTER_V2_3 \
  "setEntryPoint(address)" \
  $ENTRY_POINT \
  --private-key $PRIVATE_KEY \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --legacy

echo "  ✅ EntryPoint配置成功"
sleep 2

# 配置aPNTsToken
echo ""
echo "⚙️  配置aPNTsToken..."
cast send $PAYMASTER_V2_3 \
  "setAPNTsToken(address)" \
  $APNTS_TOKEN \
  --private-key $PRIVATE_KEY \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --legacy

echo "  ✅ aPNTsToken配置成功"
sleep 2

# 配置Treasury
echo ""
echo "⚙️  配置Treasury..."
cast send $PAYMASTER_V2_3 \
  "setTreasury(address)" \
  $TREASURY \
  --private-key $PRIVATE_KEY \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --legacy

echo "  ✅ Treasury配置成功"

echo ""
echo "========================================="
echo "✅ SuperPaymasterV2_3配置完成!"
echo "========================================="
echo ""
echo "Etherscan: https://sepolia.etherscan.io/address/$PAYMASTER_V2_3"

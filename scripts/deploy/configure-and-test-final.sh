#!/bin/bash
# SuperPaymaster V2 Final Configuration and Testing Script
# 一键完成所有配置和测试步骤

set -e  # Exit on error

# 加载环境变量
source .env

# 合约地址
NEW_PAYMASTER="0x34671Bf95159bbDAb12Ac1DA8dbdfEc5D5dC1c24"
ENTRYPOINT="0x0000000071727De22E5E9d8BAf0edAc6f37da032"
APNTS_TOKEN="0xBD0710596010a157B88cd141d797E8Ad4bb2306b"
TREASURY="0x411BD567E46C0781248dbB6a9211891C032885e5"
GT_TOKEN="0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc"
XPNT_TOKEN="0xfb56CB85C9a214328789D3C92a496d6AA185e3d3"
AA_ACCOUNT="0x57b2e6f08399c276b2c1595825219d29990d0921"

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║   SuperPaymaster V2 Final Configuration & Testing        ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "📍 New Paymaster: $NEW_PAYMASTER"
echo "📍 Network: Sepolia"
echo ""

# ====================================
# Step 1: Configure Contract
# ====================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Configuring Contract"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "1.1 Setting EntryPoint..."
cast send $NEW_PAYMASTER "setEntryPoint(address)" \
  $ENTRYPOINT \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy
echo "✅ EntryPoint configured"

echo ""
echo "1.2 Setting aPNTs Token..."
cast send $NEW_PAYMASTER "setAPNTsToken(address)" \
  $APNTS_TOKEN \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy
echo "✅ aPNTs Token configured"

echo ""
echo "1.3 Setting Treasury..."
cast send $NEW_PAYMASTER "setSuperPaymasterTreasury(address)" \
  $TREASURY \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy
echo "✅ Treasury configured"

# ====================================
# Step 2: Approve Tokens
# ====================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Approving Tokens"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "2.1 Approving GT (50 GT)..."
cast send $GT_TOKEN "approve(address,uint256)" \
  $NEW_PAYMASTER \
  50000000000000000000 \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy
echo "✅ GT approved"

echo ""
echo "2.2 Approving aPNTs (200 aPNTs)..."
cast send $APNTS_TOKEN "approve(address,uint256)" \
  $NEW_PAYMASTER \
  200000000000000000000 \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy
echo "✅ aPNTs approved"

# ====================================
# Step 3: Register Operator
# ====================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3: Registering Operator"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "3.1 Calling registerOperatorWithAutoStake..."
cast send $NEW_PAYMASTER \
  "registerOperatorWithAutoStake(uint256,uint256,address[],address,address)" \
  50000000000000000000 \
  200000000000000000000 \
  "[]" \
  $XPNT_TOKEN \
  $TREASURY \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy
echo "✅ Operator registered with 50 GT + 200 aPNTs"

# ====================================
# Step 4: Initialize Price Cache
# ====================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 4: Initializing Price Cache"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "4.1 Calling updatePriceCache..."
cast send $NEW_PAYMASTER "updatePriceCache()" \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy
echo "✅ Price cache initialized"

# 验证缓存
echo ""
echo "4.2 Verifying price cache..."
cast call $NEW_PAYMASTER "cachedPrice()(int256,uint256,uint80,uint8)" \
  --rpc-url $SEPOLIA_RPC_URL

# ====================================
# Step 5: AA Account Approve
# ====================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5: AA Account Approve"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "5.1 Encoding approve calldata..."
APPROVE_CALLDATA=$(cast calldata "approve(address,uint256)" \
  $NEW_PAYMASTER \
  115792089237316195423570985008687907853269984665640564039457584007913129639935)

echo "5.2 Executing from AA account..."
cast send $AA_ACCOUNT \
  "execute(address,uint256,bytes)" \
  $XPNT_TOKEN \
  0 \
  $APPROVE_CALLDATA \
  --private-key $OWNER2_PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy
echo "✅ AA account approved new paymaster"

# 验证allowance
echo ""
echo "5.3 Verifying allowance..."
cast call $XPNT_TOKEN "allowance(address,address)(uint256)" \
  $AA_ACCOUNT \
  $NEW_PAYMASTER \
  --rpc-url $SEPOLIA_RPC_URL

# ====================================
# Step 6: Run Final Test
# ====================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 6: Running Final Optimized Test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "6.1 Creating test script for v2.2..."
cp scripts/gasless-test/test-gasless-viem-v1-optimized.js \
   scripts/gasless-test/test-gasless-viem-v2-final.js

# 更新脚本中的paymaster地址
sed -i.bak "s/0xD6aa17587737C59cbb82986Afbac88Db75771857/0x34671Bf95159bbDAb12Ac1DA8dbdfEc5D5dC1c24/g" \
  scripts/gasless-test/test-gasless-viem-v2-final.js

echo "✅ Test script created"

echo ""
echo "6.2 Running gasless transaction test..."
node scripts/gasless-test/test-gasless-viem-v2-final.js

# ====================================
# Summary
# ====================================
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║              Configuration Complete! 🎉                   ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "✅ All steps completed successfully:"
echo "  1. ✅ Contract configured (EntryPoint, aPNTs, Treasury)"
echo "  2. ✅ Tokens approved (GT, aPNTs)"
echo "  3. ✅ Operator registered"
echo "  4. ✅ Price cache initialized"
echo "  5. ✅ AA account approved"
echo "  6. ✅ Final test executed"
echo ""
echo "📊 Check test results above for final gas optimization metrics"
echo ""
echo "Next: Review GAS_OPTIMIZATION_REPORT.md for complete analysis"
echo ""

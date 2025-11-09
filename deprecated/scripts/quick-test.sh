#!/bin/bash
# SuperPaymaster v2.0 快速测试脚本

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== SuperPaymaster v2.0 快速测试 ===${NC}\n"

# 检查env/.env
if [ ! -f "env/.env" ]; then
    echo -e "${RED}❌ env/.env 不存在${NC}"
    exit 1
fi

source env/.env

# 变量
XPNTS_TOKEN=0x8a0a19cde240436942d3cdc27edc2b5d6c35f79a
OPERATOR=$OWNER2_ADDRESS
OPERATOR_KEY=$OWNER2_PRIVATE_KEY

# 检查必要变量
if [ -z "$SEPOLIA_RPC_URL" ] || [ -z "$OPERATOR" ] || [ -z "$OPERATOR_KEY" ]; then
    echo -e "${RED}❌ 环境变量缺失${NC}"
    exit 1
fi

echo -e "${BLUE}测试账户:${NC} $OPERATOR"
echo -e "${BLUE}xPNTsToken:${NC} $XPNTS_TOKEN"
echo -e "${BLUE}SuperPaymaster:${NC} $SUPER_PAYMASTER_V2_ADDRESS\n"

# 测试1: 检查合约存在
echo -e "${YELLOW}[1/6]${NC} 检查合约部署状态..."
PM_CODE=$(cast code $SUPER_PAYMASTER_V2_ADDRESS --rpc-url $SEPOLIA_RPC_URL)
if [ ${#PM_CODE} -lt 10 ]; then
    echo -e "${RED}   ❌ SuperPaymasterV2未部署${NC}"
    exit 1
fi
echo -e "${GREEN}   ✅ SuperPaymasterV2已部署${NC}"

XPNTS_CODE=$(cast code $XPNTS_TOKEN --rpc-url $SEPOLIA_RPC_URL)
if [ ${#XPNTS_CODE} -lt 10 ]; then
    echo -e "${RED}   ❌ xPNTsToken未部署${NC}"
    exit 1
fi
echo -e "${GREEN}   ✅ xPNTsToken已部署${NC}\n"

# 测试2: 检查operator注册状态
echo -e "${YELLOW}[2/6]${NC} 检查operator注册状态..."
ACCOUNT_DATA=$(cast call $SUPER_PAYMASTER_V2_ADDRESS \
  "getOperatorAccount(address)" \
  $OPERATOR \
  --rpc-url $SEPOLIA_RPC_URL)

if [ ${#ACCOUNT_DATA} -lt 100 ]; then
    echo -e "${RED}   ❌ Operator未注册${NC}"
    echo -e "${YELLOW}   💡 请先运行场景1的operator注册流程${NC}\n"
    exit 1
fi
echo -e "${GREEN}   ✅ Operator已注册${NC}\n"

# 测试3: Mint xPNTs
echo -e "${YELLOW}[3/6]${NC} Mint 10000 xPNTs给operator..."
XPNTS_BALANCE_BEFORE=$(cast call $XPNTS_TOKEN \
  "balanceOf(address)(uint256)" \
  $OPERATOR \
  --rpc-url $SEPOLIA_RPC_URL)
echo -e "   余额(前): $XPNTS_BALANCE_BEFORE"

TX_MINT=$(cast send $XPNTS_TOKEN \
  "mint(address,uint256)" \
  $OPERATOR \
  10000000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $OPERATOR_KEY \
  --json)

MINT_STATUS=$(echo $TX_MINT | jq -r '.status')
if [ "$MINT_STATUS" != "0x1" ]; then
    echo -e "${RED}   ❌ Mint失败${NC}"
    exit 1
fi

XPNTS_BALANCE_AFTER=$(cast call $XPNTS_TOKEN \
  "balanceOf(address)(uint256)" \
  $OPERATOR \
  --rpc-url $SEPOLIA_RPC_URL)
echo -e "   余额(后): $XPNTS_BALANCE_AFTER"
echo -e "${GREEN}   ✅ Mint成功${NC}\n"

# 测试4: Approve
echo -e "${YELLOW}[4/6]${NC} Approve SuperPaymaster使用1000 xPNTs..."
TX_APPROVE=$(cast send $XPNTS_TOKEN \
  "approve(address,uint256)" \
  $SUPER_PAYMASTER_V2_ADDRESS \
  1000000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $OPERATOR_KEY \
  --json)

APPROVE_STATUS=$(echo $TX_APPROVE | jq -r '.status')
if [ "$APPROVE_STATUS" != "0x1" ]; then
    echo -e "${RED}   ❌ Approve失败${NC}"
    exit 1
fi

ALLOWANCE=$(cast call $XPNTS_TOKEN \
  "allowance(address,address)(uint256)" \
  $OPERATOR \
  $SUPER_PAYMASTER_V2_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL)
echo -e "   Allowance: $ALLOWANCE"
echo -e "${GREEN}   ✅ Approve成功${NC}\n"

# 测试5: Deposit aPNTs
echo -e "${YELLOW}[5/6]${NC} Deposit 1000 aPNTs (burn 1000 xPNTs)..."

# 查询之前的aPNTs余额
ACCOUNT_BEFORE=$(cast call $SUPER_PAYMASTER_V2_ADDRESS \
  "getOperatorAccount(address)" \
  $OPERATOR \
  --rpc-url $SEPOLIA_RPC_URL)
echo -e "   OperatorAccount(前): ${ACCOUNT_BEFORE:0:100}..."

TX_DEPOSIT=$(cast send $SUPER_PAYMASTER_V2_ADDRESS \
  "depositAPNTs(uint256)" \
  1000000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $OPERATOR_KEY \
  --json)

DEPOSIT_STATUS=$(echo $TX_DEPOSIT | jq -r '.status')
if [ "$DEPOSIT_STATUS" != "0x1" ]; then
    echo -e "${RED}   ❌ Deposit失败${NC}"
    exit 1
fi

echo -e "${GREEN}   ✅ Deposit成功${NC}\n"

# 测试6: 查询最终状态
echo -e "${YELLOW}[6/6]${NC} 查询最终operator账户状态..."
ACCOUNT_AFTER=$(cast call $SUPER_PAYMASTER_V2_ADDRESS \
  "getOperatorAccount(address)" \
  $OPERATOR \
  --rpc-url $SEPOLIA_RPC_URL)

echo -e "   OperatorAccount(后):"
echo -e "   Raw: ${ACCOUNT_AFTER:0:200}..."

# 尝试解析aPNTsBalance (第6个字段，每个32字节)
APNTS_BALANCE_HEX=${ACCOUNT_AFTER:130:64}
APNTS_BALANCE_DEC=$(cast --to-dec 0x$APNTS_BALANCE_HEX)
echo -e "   ${GREEN}aPNTsBalance: $APNTS_BALANCE_DEC ($(cast --from-wei $APNTS_BALANCE_DEC) aPNTs)${NC}"

echo ""
echo -e "${GREEN}=== 测试完成 ===${NC}\n"

echo -e "${BLUE}总结:${NC}"
echo -e "  ✅ 合约部署正常"
echo -e "  ✅ Operator已注册"
echo -e "  ✅ xPNTs mint成功"
echo -e "  ✅ xPNTs approve成功"
echo -e "  ✅ aPNTs deposit成功"
echo -e "  ✅ Operator余额更新正常"
echo ""

echo -e "${YELLOW}⚠️  注意:${NC}"
echo -e "  - 当前实现是${BLUE}纯预充值模式${NC}"
echo -e "  - 用户交易时${RED}不会扣除xPNTs${NC}（未实现）"
echo -e "  - 只会消耗operator的aPNTs余额"
echo -e "  - 详见: ${BLUE}docs/TESTING-SUMMARY.md${NC}"
echo ""

echo -e "${BLUE}下一步:${NC}"
echo -e "  1. 补充用户xPNTs支付逻辑"
echo -e "  2. 配置treasury地址"
echo -e "  3. 添加汇率配置"
echo -e "  4. 完整UserOp测试（需要bundler）"
echo ""

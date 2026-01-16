#!/bin/bash

# SuperPaymaster V2 Main Flow Test Runner
# 按顺序执行6个测试步骤

set -e  # 遇到错误立即退出

echo "=================================================="
echo "SuperPaymaster V2 Main Flow Test"
echo "=================================================="
echo ""

# 检查环境变量
if [ ! -f .env ]; then
    echo "❌ Error: .env file not found"
    echo "Please create .env file with required variables"
    exit 1
fi

# 加载环境变量
source .env

# RPC URL
RPC_URL="https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N"

# 日志目录
LOG_DIR="logs/v2-test-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

echo "📝 Logs will be saved to: $LOG_DIR"
echo ""

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 执行单个步骤
run_step() {
    local step_num=$1
    local step_name=$2
    local script_name=$3

    echo ""
    echo "=================================================="
    echo "Step $step_num: $step_name"
    echo "=================================================="
    echo ""

    local log_file="$LOG_DIR/step${step_num}.log"

    if forge script "script/v2/$script_name" \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --slow \
        -vvv 2>&1 | tee "$log_file"; then
        echo -e "${GREEN}✅ Step $step_num completed successfully${NC}"
        return 0
    else
        echo -e "${RED}❌ Step $step_num failed${NC}"
        echo "Check log: $log_file"
        return 1
    fi
}

# 执行只读步骤（不需要broadcast）
run_view_step() {
    local step_num=$1
    local step_name=$2
    local script_name=$3

    echo ""
    echo "=================================================="
    echo "Step $step_num: $step_name"
    echo "=================================================="
    echo ""

    local log_file="$LOG_DIR/step${step_num}.log"

    if forge script "script/v2/$script_name" \
        --rpc-url "$RPC_URL" \
        -vvv 2>&1 | tee "$log_file"; then
        echo -e "${GREEN}✅ Step $step_num completed successfully${NC}"
        return 0
    else
        echo -e "${RED}❌ Step $step_num failed${NC}"
        echo "Check log: $log_file"
        return 1
    fi
}

# 执行所有步骤
echo -e "${YELLOW}Starting V2 main flow test...${NC}"
echo ""

# Step 1: Setup
if ! run_step 1 "Setup & Configuration" "Step1_Setup.s.sol"; then
    exit 1
fi

echo ""
echo -e "${YELLOW}⚠️  IMPORTANT: Update .env with APNTS_TOKEN_ADDRESS${NC}"
echo "Press Enter when ready to continue..."
read

# Step 2: Operator Register
if ! run_step 2 "Operator Registration" "Step2_OperatorRegister.s.sol"; then
    exit 1
fi

echo ""
echo -e "${YELLOW}⚠️  IMPORTANT: Update .env with OPERATOR_XPNTS_TOKEN_ADDRESS${NC}"
echo "Press Enter when ready to continue..."
read

# Step 3: Operator Deposit
if ! run_step 3 "Operator Deposit aPNTs" "Step3_OperatorDeposit.s.sol"; then
    exit 1
fi

# Step 4: User Preparation
if ! run_step 4 "User Preparation" "Step4_UserPrep.s.sol"; then
    exit 1
fi

# Step 5: User Transaction
if ! run_step 5 "User Transaction Simulation" "Step5_UserTransaction.s.sol"; then
    exit 1
fi

# Step 6: Verification (view only)
if ! run_view_step 6 "Final Verification" "Step6_Verification.s.sol"; then
    exit 1
fi

echo ""
echo "=================================================="
echo -e "${GREEN}🎉 All steps completed successfully!${NC}"
echo "=================================================="
echo ""
echo "Logs saved in: $LOG_DIR"
echo ""
echo "Next steps:"
echo "1. Review the verification report in step6.log"
echo "2. Test with real EntryPoint integration"
echo "3. Test PaymasterV4 compatibility"
echo ""

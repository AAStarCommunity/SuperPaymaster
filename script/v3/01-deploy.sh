#!/bin/bash
# SuperPaymaster V3 测试 - 阶段 1: 合约部署

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"
LOG_DIR="$SCRIPT_DIR/logs"

# 创建目录
mkdir -p "$CONFIG_DIR" "$LOG_DIR"

echo "🚀 阶段 1: 部署 V3 核心合约..."
echo ""

# 检查 Anvil 是否运行
if ! curl -s http://127.0.0.1:8545 > /dev/null 2>&1; then
    echo "❌ 错误: Anvil 未运行！"
    echo "   请先运行: anvil"
    exit 1
fi

echo "✅ Anvil 连接成功"
echo ""

# 部署合约
echo "📝 开始部署合约..."
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# 使用 forge script 部署
forge script script/v3/SetupV3.s.sol:SetupV3 \
    --rpc-url http://127.0.0.1:8545 \
    --broadcast \
    --slow \
    2>&1 | tee "$LOG_DIR/01-deploy.log"

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo ""
    echo "❌ 部署失败！"
    echo "   查看日志: $LOG_DIR/01-deploy.log"
    exit 1
fi

echo ""
echo "✅ 合约部署成功！"
echo ""

# 验证 config.json 存在
if [ ! -f "script/v3/config.json" ]; then
    echo "❌ 错误: config.json 未生成"
    exit 1
fi

# 复制 config.json 到 config 目录
cp script/v3/config.json "$CONFIG_DIR/deployed.json"

# 验证合约
echo "🔍 验证部署的合约..."
node "$SCRIPT_DIR/helpers/verify-deployment.js"

if [ $? -ne 0 ]; then
    echo "❌ 合约验证失败"
    exit 1
fi

echo ""
echo "✅ 阶段 1 完成！"
echo "   输出文件: $CONFIG_DIR/deployed.json"
echo ""

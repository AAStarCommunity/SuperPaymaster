#!/bin/bash
# V3 Core Build Script
# 只编译 V3 核心合约,跳过历史版本和测试合约

set -e

echo "========================================="
echo "Building V3 Core Contracts Only"
echo "========================================="
echo ""
echo "📦 V3 Core Directories:"
echo "  - contracts/src/core"
echo "  - contracts/src/modules"
echo "  - contracts/src/tokens"
echo "  - contracts/src/paymasters/superpaymaster/v3"
echo "  - contracts/src/paymasters/v4"
echo ""

# Change to contracts directory
cd "$(dirname "$0")/contracts" || exit 1

# Clean build
echo "🧹 Cleaning previous build..."
forge clean

# Build with v3-only profile
echo "🔨 Building V3 contracts..."
FOUNDRY_PROFILE=v3-only forge build

if [ "$1" == "test" ]; then
    echo -e "\n🧪 Running V3 Core Tests..."
    FOUNDRY_PROFILE=v3-only forge test
fi

echo ""
echo "✅ Build complete!"
echo ""
echo "📊 Build artifacts:"
ls -lh out/ | head -10
echo ""
echo "💡 Tip: Use 'forge build' for full build (includes tests)"
echo "💡 Tip: Use 'forge build --profile v3-only' for V3-only build"

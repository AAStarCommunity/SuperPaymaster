#!/bin/bash

# ==============================================================================
# ABI Extraction Script for SuperPaymaster V3/V4
# ------------------------------------------------------------------------------
# 此脚本自动从 out/ 目录提取部署清单中核心合约的 ABI
# 并将其保存到 abis/ 目录，以便前端和 SDK 使用。
# ==============================================================================

set -e

# 定义目标目录
OUTPUT_DIR="abis"
mkdir -p "$OUTPUT_DIR"

# 定义需要提取的核心合约列表 (对应标准化部署清单)
CONTRACTS=(
    "Registry"
    "SuperPaymasterV3"
    "GToken"
    "GTokenStaking"
    "MySBT"
    "xPNTsToken"
    "xPNTsFactory"
    "PaymasterFactory"
    "PaymasterV4_2"
    "ReputationSystemV3"
    "BLSAggregatorV3"
    "DVTValidatorV3"
    "BLSValidator"
)

echo "🔍 Starting ABI extraction for V3/V4..."

for CONTRACT in "${CONTRACTS[@]}"; do
    # 查找对应的 JSON 文件
    # Foundry 的路径通常是 out/ContractName.sol/ContractName.json
    FILE=$(find out -name "${CONTRACT}.json" | head -n 1)
    
    if [ -f "$FILE" ]; then
        echo "✅ Extracting ABI for $CONTRACT..."
        # 使用 jq 提取 abi 字段并格式化
        jq '.abi' "$FILE" > "$OUTPUT_DIR/${CONTRACT}.json"
    else
        echo "❌ Warning: Could not find build artifact for $CONTRACT. Did you run 'forge build'?"
    fi
done

echo "✨ ABI extraction complete. Files saved in $OUTPUT_DIR/"

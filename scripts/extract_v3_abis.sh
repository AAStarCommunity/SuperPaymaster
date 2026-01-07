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
    "SuperPaymaster"
    "GToken"
    "GTokenStaking"
    "MySBT"
    "xPNTsToken"
    "xPNTsFactory"
    "PaymasterFactory"
    "Paymaster"
    "ReputationSystem"
    "BLSAggregator"
    "DVTValidator"
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

echo "📄 Generating ABI manifest (abi.config.json)..."
CONFIG_FILE="$OUTPUT_DIR/abi.config.json"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# 计算整体哈希 (排除生成的 config 本身)
TOTAL_HASH=$(find "$OUTPUT_DIR" -name "*.json" ! -name "abi.config.json" -type f -exec shasum -a 256 {} + | sort | shasum -a 256 | awk '{print $1}')

# 初始化 JSON
echo "{" > "$CONFIG_FILE"
echo "  \"description\": \"SuperPaymaster Contract ABIs Manifest\", " >> "$CONFIG_FILE"
echo "  \"source\": \"SuperPaymaster/contracts/src\", " >> "$CONFIG_FILE"
echo "  \"buildTime\": \"$TIMESTAMP\", " >> "$CONFIG_FILE"
echo "  \"totalHash\": \"$TOTAL_HASH\", " >> "$CONFIG_FILE"
echo "  \"files\": [" >> "$CONFIG_FILE"

# 遍历文件添加列表
FILES=($(ls "$OUTPUT_DIR"/*.json | grep -v "abi.config.json"))
LEN=${#FILES[@]}
for (( i=0; i<${LEN}; i++ )); do
    F=${FILES[$i]}
    FNAME=$(basename "$F")
    FHASH=$(shasum -a 256 "$F" | awk '{print $1}')
    COMMA=","
    if [ $i -eq $((LEN-1)) ]; then COMMA=""; fi
    echo "    { \"name\": \"$FNAME\", \"hash\": \"$FHASH\" }$COMMA" >> "$CONFIG_FILE"
done

echo "  ]" >> "$CONFIG_FILE"
echo "}" >> "$CONFIG_FILE"

echo "✨ ABI extraction and manifest generation complete. Files saved in $OUTPUT_DIR/"

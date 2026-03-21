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
    # Foundry 的路径通常是 out/ContractName.sol/ContractName.json
    # 如果存在多个匹配（例如 wrapper），优先选择非 core 目录下的，或者更完整的
    FILE=$(find out -name "${CONTRACT}.json" -not -path "*/core/*" | head -n 1)
    if [ -z "$FILE" ]; then
        FILE=$(find out -name "${CONTRACT}.json" | head -n 1)
    fi
    
    if [ -f "$FILE" ]; then
        echo "✅ Extracting ABI & Bytecode for $CONTRACT from $FILE..."
        # 提取 abi 和 bytecode.object 并合并为 JSON
        jq '{abi: .abi, bytecode: .bytecode.object}' "$FILE" > "$OUTPUT_DIR/${CONTRACT}.json"
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

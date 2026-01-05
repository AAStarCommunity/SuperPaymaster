#!/bin/bash

# ==============================================================================
# Final Sync Script: SuperPaymaster -> AAStar SDK
# ==============================================================================

set -e

SDK_DIR="../aastar-sdk"
ABI_DEST="$SDK_DIR/packages/core/src/abis"
CONFIG_DEST="$SDK_DIR"

echo "🔄 [1/3] Extracting latest ABIs..."
./scripts/extract_v3_abis.sh

echo "📦 [2/3] Syncing ABIs to $ABI_DEST..."
mkdir -p "$ABI_DEST"
cp abis/*.json "$ABI_DEST/"

echo "⚙️  [3/3] Syncing Network Configs to $CONFIG_DEST..."
# 同步所有 deployments 目录下的 config.*.json 到 SDK 根目录
cp deployments/config.*.json "$CONFIG_DEST/"

# 注意：.env 文件通常包含本地私钥，不建议跨目录直接 cp 覆盖，
# 但可以检查 SDK 侧是否存在对应的 .env，如果不存在则提示用户。
NETWORKS=("anvil" "sepolia")
for NET in "${NETWORKS[@]}"; do
    if [ ! -f "$SDK_DIR/.env.$NET" ]; then
        echo "⚠️  Warning: $SDK_DIR/.env.$NET not found. You may need to create it manually for secrets."
    fi
done

echo "✨ All-In-One Sync Complete!"
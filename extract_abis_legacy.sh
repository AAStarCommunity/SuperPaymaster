#!/bin/bash
# Extract ABIs from Foundry build output to aastar-sdk root abis/ directory
# 用途：为不依赖SDK的纯脚本回归测试提供ABI
# Usage: ./extract_abis_legacy.sh

DEST_DIR="../aastar-sdk/abis"

mkdir -p "$DEST_DIR"

# Contract name mapping: Forge output name -> Legacy ABI name (without V3 suffix)
# Format: "ForgeOutput:LegacyName" pairs
CONTRACTS="SuperPaymasterV3:SuperPaymaster ReputationSystemV3:ReputationSystem DVTValidatorV3:DVTValidator BLSAggregatorV3:BLSAggregator Registry:Registry GToken:GToken GTokenStaking:GTokenStaking MySBT:MySBT PaymasterFactory:PaymasterFactory xPNTsFactory:xPNTsFactory"

for pair in $CONTRACTS; do
  forge_name=$(echo $pair | cut -d':' -f1)
  legacy_name=$(echo $pair | cut -d':' -f2)
  
  file=$(find out -name "$forge_name.json" -type f 2>/dev/null | head -1)
  if [ -n "$file" ]; then
    cat "$file" | jq '.abi' > "$DEST_DIR/$legacy_name.json"
    echo "✅ Extracted $legacy_name ABI (legacy)"
  else
    echo "❌ $forge_name.json not found in Forge output"
  fi
done

echo ""
echo "📦 Legacy ABIs extracted to: $DEST_DIR"
echo "   (For non-SDK regression tests)"
#!/bin/bash
# Extract ABIs from Foundry build output to SDK
# Usage: ./extract_abis.sh [--dest <destination>]
# Compatible with bash 3.x (macOS default)

DEST_DIR="${1:---dest}"
shift
if [ "$DEST_DIR" = "--dest" ]; then
  DEST_DIR="${1:-../aastar-sdk/packages/core/src/abis}"
else
  DEST_DIR="../aastar-sdk/packages/core/src/abis"
fi

mkdir -p "$DEST_DIR"

# Contract name mapping: Forge output name -> SDK ABI name (without V3 suffix)
# Format: "ForgeOutput:SDKName" pairs
CONTRACTS="SuperPaymasterV3:SuperPaymaster ReputationSystemV3:ReputationSystem DVTValidatorV3:DVTValidator BLSAggregatorV3:BLSAggregator Registry:Registry GToken:GToken GTokenStaking:GTokenStaking MySBT:MySBT PaymasterFactory:PaymasterFactory xPNTsFactory:xPNTsFactory"

for pair in $CONTRACTS; do
  forge_name=$(echo $pair | cut -d':' -f1)
  sdk_name=$(echo $pair | cut -d':' -f2)
  
  file=$(find out -name "$forge_name.json" -type f 2>/dev/null | head -1)
  if [ -n "$file" ]; then
    cat "$file" | jq '.abi' > "$DEST_DIR/$sdk_name.json"
    echo "✅ Extracted $sdk_name ABI"
  else
    echo "❌ $forge_name.json not found in Forge output"
  fi
done
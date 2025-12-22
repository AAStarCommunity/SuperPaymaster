#!/bin/bash
mkdir -p ../aastar-sdk/abis
for contract in Registry GToken GTokenStaking SuperPaymasterV3 MySBT ReputationSystemV3 DVTValidatorV3 BLSAggregatorV3 PaymasterFactory xPNTsFactory; do
  file=$(find out -name "$contract.json" -type f)
  if [ -n "$file" ]; then
    cat "$file" | jq '.abi' > "../aastar-sdk/abis/$contract.abi.json"
    echo "✅ Extracted $contract ABI"
  else
    echo "❌ $contract.json not found"
  fi
done
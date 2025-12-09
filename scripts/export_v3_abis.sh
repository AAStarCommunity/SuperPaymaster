#!/bin/bash
# Export V3 ABIs to shared-config
# Run this from projects/SuperPaymaster directory

TARGET_DIR="../aastar-shared-config/src/abis"
mkdir -p $TARGET_DIR

echo "Exporting Registry..."
forge inspect contracts/src/paymasters/v3/core/Registry.sol:Registry abi > $TARGET_DIR/Registry.json

echo "Exporting GTokenStaking..."
forge inspect contracts/src/paymasters/v3/core/GTokenStaking.sol:GTokenStaking abi > $TARGET_DIR/GTokenStaking.json

echo "Exporting MySBT..."
forge inspect contracts/src/paymasters/v3/tokens/MySBT.sol:MySBT abi > $TARGET_DIR/MySBT.json

echo "Done. ABIs exported to $TARGET_DIR"

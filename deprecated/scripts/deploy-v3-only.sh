#!/bin/bash
# Deploy V3 contracts (Settlement + PaymasterV3) and complete setup

set -e

cd "$(dirname "$0")/.."
source .env.v3

echo "==================================="
echo "V3 Complete Deployment & Setup"
echo "==================================="

# Step 1: Deploy contracts
echo ""
echo "Step 1: Deploying Settlement and PaymasterV3..."
./scripts/deploy-v3-contracts.sh

# Read deployed addresses
SETTLEMENT=$(jq -r '.settlement' deployments/v3-sepolia-latest.json)
PAYMASTER=$(jq -r '.paymasterV3' deployments/v3-sepolia-latest.json)

echo ""
echo "Deployed contracts:"
echo "  Settlement: $SETTLEMENT"
echo "  PaymasterV3: $PAYMASTER"

# Verify versions
echo ""
echo "Verifying contract versions..."
SETTLEMENT_VERSION=$(cast call "$SETTLEMENT" "VERSION()(string)" --rpc-url "$SEPOLIA_RPC_URL")
PAYMASTER_VERSION=$(cast call "$PAYMASTER" "VERSION()(string)" --rpc-url "$SEPOLIA_RPC_URL")
echo "  Settlement version: $SETTLEMENT_VERSION"
echo "  PaymasterV3 version: $PAYMASTER_VERSION"

# Step 2: Register in Registry
echo ""
echo "Step 2: Registering PaymasterV3 in Registry..."
./scripts/register-paymaster.sh "$PAYMASTER" 100 "SuperPaymasterV3-v1.0.1"

# Step 3: Fund Paymaster
echo ""
echo "Step 3: Funding PaymasterV3..."
./scripts/fund-paymaster.sh "$PAYMASTER" 0.02 0.02

# Step 4: Update .env.v3
echo ""
echo "Step 4: Updating .env.v3..."
sed -i.bak "s/^SETTLEMENT_CONTRACT=.*/SETTLEMENT_CONTRACT=\"$SETTLEMENT\"/" .env.v3
sed -i.bak "s/^SETTLEMENT_ADDRESS=.*/SETTLEMENT_ADDRESS=\"$SETTLEMENT\"/" .env.v3
sed -i.bak "s/^PAYMASTER_V3=.*/PAYMASTER_V3=\"$PAYMASTER\"/" .env.v3
sed -i.bak "s/^PAYMASTER_V3_ADDRESS=.*/PAYMASTER_V3_ADDRESS=\"$PAYMASTER\"/" .env.v3
sed -i.bak "s/^PAYMASTER_ADDRESS=.*/PAYMASTER_ADDRESS=\"$PAYMASTER\"/" .env.v3
rm .env.v3.bak

echo ""
echo "==================================="
echo "Deployment Complete!"
echo "==================================="
echo ""
echo "Contract Addresses:"
echo "  Registry: $SUPER_PAYMASTER"
echo "  Settlement: $SETTLEMENT"
echo "  PaymasterV3: $PAYMASTER"
echo ""
echo "Next: Run test with:"
echo "  node scripts/check-config.js"
echo "  node scripts/submit-via-entrypoint.js"
echo ""

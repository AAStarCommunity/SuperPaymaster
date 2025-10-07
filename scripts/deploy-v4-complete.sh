#!/bin/bash
# Complete deployment script for PaymasterV4
# This script deploys, configures, registers and funds PaymasterV4

set -e

cd "$(dirname "$0")/.."

echo "==================================="
echo "PaymasterV4 Complete Deployment"
echo "==================================="

# Load environment
source .env.v3

# Configuration
ENTRY_POINT=$ENTRYPOINT_V07
OWNER_ADDRESS=$OWNER_ADDRESS
TREASURY_ADDRESS=$OWNER_ADDRESS
GAS_TO_USD_RATE=4500000000000000000000  # 4500e18 = $4500/ETH
PNT_PRICE_USD=20000000000000000         # 0.02e18 = $0.02/PNT
SERVICE_FEE_RATE=200                     # 2% (200 bps)
MAX_GAS_COST_CAP=1000000000000000000    # 1e18 = 1 ETH
MIN_TOKEN_BALANCE=10000000000000000000  # 10e18 = 10 PNT
SBT_ADDRESS=$SBT_CONTRACT_ADDRESS
GAS_TOKEN_ADDRESS=$GAS_TOKEN_ADDRESS
REGISTRY_ADDRESS=$SUPER_PAYMASTER

echo ""
echo "Configuration:"
echo "  EntryPoint: $ENTRY_POINT"
echo "  Owner: $OWNER_ADDRESS"
echo "  Treasury: $TREASURY_ADDRESS"
echo "  Registry: $REGISTRY_ADDRESS"
echo "  SBT: $SBT_ADDRESS"
echo "  GasToken: $GAS_TOKEN_ADDRESS"
echo ""

# Step 1: Deploy PaymasterV4
echo "Step 1: Deploying PaymasterV4..."
forge script script/deploy-paymaster-v4.s.sol:DeployPaymasterV4 \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --legacy \
  -vv

# Extract deployed address from broadcast JSON
PAYMASTER_V4_ADDRESS=$(jq -r '.transactions[0].contractAddress' broadcast/deploy-paymaster-v4.s.sol/11155111/run-latest.json)

if [ "$PAYMASTER_V4_ADDRESS" = "null" ] || [ -z "$PAYMASTER_V4_ADDRESS" ]; then
    echo "Error: Failed to extract PaymasterV4 address"
    exit 1
fi

echo "✓ PaymasterV4 deployed at: $PAYMASTER_V4_ADDRESS"
echo ""

# Step 2: Register in Registry
echo "Step 2: Registering PaymasterV4 in Registry..."
export REGISTER_PRIVATE_KEY="0x${SuperPaymaster_Owner_Private_Key}"

cast send "$REGISTRY_ADDRESS" \
  "registerPaymaster(address,uint256,string)" \
  "$PAYMASTER_V4_ADDRESS" \
  "$SERVICE_FEE_RATE" \
  "PaymasterV4-Direct" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$REGISTER_PRIVATE_KEY" \
  --legacy

echo "✓ PaymasterV4 registered in Registry"
echo ""

# Step 3: Add Stake
echo "Step 3: Adding stake to PaymasterV4..."
STAKE_AMOUNT="0.05"

cast send "$PAYMASTER_V4_ADDRESS" \
  "addStake(uint32)" \
  86400 \
  --value "${STAKE_AMOUNT}ether" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --legacy

echo "✓ Added $STAKE_AMOUNT ETH stake"
echo ""

# Step 4: Add Deposit to EntryPoint
echo "Step 4: Adding deposit to EntryPoint..."
DEPOSIT_AMOUNT="0.05"

cast send "$ENTRY_POINT" \
  "depositTo(address)" \
  "$PAYMASTER_V4_ADDRESS" \
  --value "${DEPOSIT_AMOUNT}ether" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --legacy

echo "✓ Added $DEPOSIT_AMOUNT ETH deposit"
echo ""

# Step 5: Verify configuration
echo "Step 5: Verifying deployment..."
echo ""
echo "Checking PaymasterV4 configuration:"
cast call "$PAYMASTER_V4_ADDRESS" "owner()(address)" --rpc-url "$SEPOLIA_RPC_URL"
cast call "$PAYMASTER_V4_ADDRESS" "treasury()(address)" --rpc-url "$SEPOLIA_RPC_URL"
cast call "$PAYMASTER_V4_ADDRESS" "gasToUSDRate()(uint256)" --rpc-url "$SEPOLIA_RPC_URL"
cast call "$PAYMASTER_V4_ADDRESS" "pntPriceUSD()(uint256)" --rpc-url "$SEPOLIA_RPC_URL"
cast call "$PAYMASTER_V4_ADDRESS" "serviceFeeRate()(uint256)" --rpc-url "$SEPOLIA_RPC_URL"

echo ""
echo "Checking EntryPoint deposit:"
cast call "$ENTRY_POINT" "balanceOf(address)(uint256)" "$PAYMASTER_V4_ADDRESS" --rpc-url "$SEPOLIA_RPC_URL"

echo ""
echo "==================================="
echo "✓ Deployment Complete!"
echo "==================================="
echo ""
echo "PaymasterV4 Address: $PAYMASTER_V4_ADDRESS"
echo "EntryPoint: $ENTRY_POINT"
echo "Registry: $REGISTRY_ADDRESS"
echo ""
echo "View on Etherscan:"
echo "  https://sepolia.etherscan.io/address/$PAYMASTER_V4_ADDRESS"
echo ""
echo "Next steps:"
echo "  1. Update .env.v3 with PAYMASTER_V4_ADDRESS=$PAYMASTER_V4_ADDRESS"
echo "  2. Run integration tests"
echo "  3. Monitor transactions"
echo ""

# Save deployment info
cat > deployments/paymaster-v4-deployment.txt <<EOF
PaymasterV4 Deployment Summary
==============================

Deployment Date: $(date)
Network: Sepolia (Chain ID: 11155111)

Addresses:
  PaymasterV4: $PAYMASTER_V4_ADDRESS
  EntryPoint: $ENTRY_POINT
  Registry: $REGISTRY_ADDRESS
  Owner: $OWNER_ADDRESS
  Treasury: $TREASURY_ADDRESS
  SBT: $SBT_ADDRESS
  GasToken: $GAS_TOKEN_ADDRESS

Configuration:
  Gas to USD Rate: $GAS_TO_USD_RATE (4500e18 = \$4500/ETH)
  PNT Price USD: $PNT_PRICE_USD (0.02e18 = \$0.02/PNT)
  Service Fee Rate: $SERVICE_FEE_RATE bps (2%)
  Max Gas Cost Cap: $MAX_GAS_COST_CAP (1 ETH)
  Min Token Balance: $MIN_TOKEN_BALANCE (10 PNT)

Funding:
  Stake: $STAKE_AMOUNT ETH
  Deposit: $DEPOSIT_AMOUNT ETH

Etherscan:
  https://sepolia.etherscan.io/address/$PAYMASTER_V4_ADDRESS

Status: ✓ Deployed and Configured
EOF

echo "Deployment summary saved to: deployments/paymaster-v4-deployment.txt"

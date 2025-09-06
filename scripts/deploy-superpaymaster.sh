#!/bin/bash

# Deploy SuperPaymaster contracts to Sepolia
# Usage: ./scripts/deploy-superpaymaster.sh

set -e

# Get the script directory and project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Change to project root
cd "$PROJECT_ROOT"

# Source environment variables
source .env

echo "🚀 Deploying SuperPaymaster contracts to Sepolia..."
forge script script/DeploySuperpaymaster.s.sol:DeploySuperpaymaster --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast

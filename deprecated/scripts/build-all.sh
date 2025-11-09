#!/bin/bash

# Build all contracts (SuperPaymaster and singleton-paymaster)
# Usage: ./scripts/build-all.sh

set -e

# Get the script directory and project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Change to project root
cd "$PROJECT_ROOT"

echo "🏗️ Building all contracts..."
echo ""

echo "📦 Building SuperPaymaster contracts..."
forge build

echo ""
echo "📦 Building singleton-paymaster contracts..."
"$SCRIPT_DIR/compile-singleton-paymaster.sh"

echo ""
echo "✅ All contracts built successfully!"
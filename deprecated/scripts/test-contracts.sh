#!/bin/bash

# Run tests for SuperPaymaster contracts
# Usage: ./scripts/test-contracts.sh

set -e

# Get the script directory and project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Change to project root
cd "$PROJECT_ROOT"

echo "🧪 Running SuperPaymaster contract tests..."
forge test -vv

echo "✅ All tests passed!"
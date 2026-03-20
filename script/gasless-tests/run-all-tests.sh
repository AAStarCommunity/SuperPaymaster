#!/bin/bash

###############################################################################
# Run All Gasless Transfer Tests
#
# Executes all three test cases sequentially:
# 1. PaymasterV4 + xPNTs
# 2. SuperPaymasterV2 + xPNTs1
# 3. SuperPaymasterV2 + xPNTs2
#
# Configuration is read from .env.sepolia in the project root
###############################################################################

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║       Running All Gasless Transfer Test Cases            ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Check if env file exists (allow override via ENV_FILE variable)
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/.env.sepolia}"
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: Configuration file not found at $ENV_FILE"
    echo "   Set ENV_FILE to override, e.g.: ENV_FILE=.env.sepolia ./run-all-tests.sh"
    exit 1
fi

# Export all variables from the env file for child node processes
set -a
source "$ENV_FILE"
set +a

echo "✅ Configuration file found: $ENV_FILE"
echo ""

# Test Case 1
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 Test Case 1: PaymasterV4 + xPNTs"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if node "$SCRIPT_DIR/test-case-1-paymasterv4.js"; then
    echo "✅ Test Case 1: PASSED"
else
    echo "❌ Test Case 1: FAILED"
    exit 1
fi
echo ""
echo ""

# Test Case 2
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 Test Case 2: SuperPaymasterV2 + xPNTs1"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if node "$SCRIPT_DIR/test-case-2-superpaymaster-xpnts1.js"; then
    echo "✅ Test Case 2: PASSED"
else
    echo "❌ Test Case 2: FAILED"
    exit 1
fi
echo ""
echo ""

# Test Case 3
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 Test Case 3: SuperPaymasterV2 + xPNTs2"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if node "$SCRIPT_DIR/test-case-3-superpaymaster-xpnts2.js"; then
    echo "✅ Test Case 3: PASSED"
else
    echo "❌ Test Case 3: FAILED"
    exit 1
fi
echo ""

# Summary
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║              All Tests Completed Successfully!            ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "Summary:"
echo "  ✅ Test Case 1: PaymasterV4 + xPNTs"
echo "  ✅ Test Case 2: SuperPaymasterV2 + xPNTs1"
echo "  ✅ Test Case 3: SuperPaymasterV2 + xPNTs2"
echo ""
echo "All gasless transfer tests passed! 🎉"

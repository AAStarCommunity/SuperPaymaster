#!/bin/bash

###############################################################################
# Run All Gasless Transfer Tests
#
# Executes all three test cases sequentially:
# 1. PaymasterV4 + xPNTs
# 2. SuperPaymasterV2 + xPNTs1
# 3. SuperPaymasterV2 + xPNTs2
#
# Configuration is read from /Volumes/UltraDisk/Dev2/aastar/env/.env
###############################################################################

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║       Running All Gasless Transfer Test Cases            ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Check if env file exists
ENV_FILE="/Volumes/UltraDisk/Dev2/aastar/env/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: Configuration file not found at $ENV_FILE"
    exit 1
fi

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

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
#
# Results are saved to script/gasless-tests/results/<timestamp>_run-all-tests.md
###############################################################################

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

# Set up results directory and timestamped result file
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"
RUN_TIMESTAMP=$(date "+%Y-%m-%d_%H-%M-%S")
RUN_DATE=$(date "+%Y-%m-%d %H:%M:%S")
RESULT_FILE="$RESULTS_DIR/${RUN_TIMESTAMP}_run-all-tests.md"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Export all variables from the env file for child node processes
set -a
source "$ENV_FILE"
set +a

echo "✅ Configuration file found: $ENV_FILE"
echo ""

# ── Pre-flight setup: refresh price caches + top up balances ─────────────────
# PaymasterV4 and SuperPaymaster validate via Chainlink price feeds. If the price
# cache has expired (priceStalenessThreshold ~70 min), validatePaymasterUserOp
# returns a past validUntil → EntryPoint rejects with AA32. Run setup first.
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚙️  Pre-flight: Refreshing price caches & checking balances"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if node "$SCRIPT_DIR/setup-gasless.js"; then
    echo "✅ Pre-flight setup complete — price caches refreshed."
else
    SETUP_EXIT=$?
    echo "⚠️  Pre-flight setup failed (exit $SETUP_EXIT) — price caches may be stale."
    echo "   Tests may fail with AA32 if prices have expired. Continuing anyway."
fi
echo ""

# Test Case 1
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 Test Case 1: PaymasterV4 + xPNTs"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
node "$SCRIPT_DIR/test-case-1-paymasterv4.js" 2>&1 | tee "$TEMP_DIR/tc1.log"
TC1_EXIT=${PIPESTATUS[0]}
TC1_TX=$(grep -oE "TX Hash: 0x[0-9a-fA-F]+" "$TEMP_DIR/tc1.log" | tail -1 | awk '{print $NF}')
TC1_URL=$(grep -oE "Etherscan: https://[^ ]+" "$TEMP_DIR/tc1.log" | tail -1 | awk '{print $NF}')
if [ $TC1_EXIT -eq 0 ]; then
    TC1_STATUS="✅ PASS"
    echo "✅ Test Case 1: PASSED"
else
    TC1_STATUS="❌ FAIL"
    echo "❌ Test Case 1: FAILED"
fi
echo ""
echo ""

# Test Case 2
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 Test Case 2: SuperPaymasterV2 + xPNTs1"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
# TC2 uses Account A (same as TC1) because TEST_AA_ACCOUNT_ADDRESS_B is a Kernel
# (ZeroDev) account that requires raw-hash signing rather than EIP-191. SimpleAccount
# (Account A) is compatible with EIP-191 and is the reference implementation.
TEST_AA_ACCOUNT_ADDRESS_B="$TEST_AA_ACCOUNT_ADDRESS_A" node "$SCRIPT_DIR/test-case-2-superpaymaster-xpnts1-fixed.js" 2>&1 | tee "$TEMP_DIR/tc2.log"
TC2_EXIT=${PIPESTATUS[0]}
TC2_TX=$(grep -oE "TX Hash: 0x[0-9a-fA-F]+" "$TEMP_DIR/tc2.log" | tail -1 | awk '{print $NF}')
TC2_URL=$(grep -oE "Etherscan: https://[^ ]+" "$TEMP_DIR/tc2.log" | tail -1 | awk '{print $NF}')
if [ $TC2_EXIT -eq 0 ]; then
    TC2_STATUS="✅ PASS"
    echo "✅ Test Case 2: PASSED"
else
    TC2_STATUS="❌ FAIL"
    echo "❌ Test Case 2: FAILED"
fi
echo ""
echo ""

# Test Case 3
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 Test Case 3: SuperPaymasterV2 + xPNTs2"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
# TC3 uses Account A (same override logic as TC2 — Account C is Kernel/ZeroDev).
TEST_AA_ACCOUNT_ADDRESS_C="$TEST_AA_ACCOUNT_ADDRESS_A" node "$SCRIPT_DIR/test-case-3-superpaymaster-xpnts2.js" 2>&1 | tee "$TEMP_DIR/tc3.log"
TC3_EXIT=${PIPESTATUS[0]}
TC3_TX=$(grep -oE "TX Hash: 0x[0-9a-fA-F]+" "$TEMP_DIR/tc3.log" | tail -1 | awk '{print $NF}')
TC3_URL=$(grep -oE "Etherscan: https://[^ ]+" "$TEMP_DIR/tc3.log" | tail -1 | awk '{print $NF}')
if [ $TC3_EXIT -eq 0 ]; then
    TC3_STATUS="✅ PASS"
    echo "✅ Test Case 3: PASSED"
else
    TC3_STATUS="❌ FAIL"
    echo "❌ Test Case 3: FAILED"
fi
echo ""
echo ""

# Test Case 4
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 Test Case 4: SuperPaymaster Credit/Debt Path"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
node "$SCRIPT_DIR/test-case-4-superpaymaster-credit-path.js" 2>&1 | tee "$TEMP_DIR/tc4.log"
TC4_EXIT=${PIPESTATUS[0]}
TC4_TX=$(grep -oE "TX Hash: 0x[0-9a-fA-F]+" "$TEMP_DIR/tc4.log" | tail -1 | awk '{print $NF}')
TC4_URL=$(grep -oE "Etherscan: https://[^ ]+" "$TEMP_DIR/tc4.log" | tail -1 | awk '{print $NF}')
if [ $TC4_EXIT -eq 0 ]; then
    TC4_STATUS="✅ PASS"
    echo "✅ Test Case 4: PASSED"
elif [ $TC4_EXIT -eq 2 ]; then
    TC4_STATUS="⏭️  SKIP"
    echo "⏭️  Test Case 4: SKIPPED (no credit available — run A1+D2 first)"
else
    TC4_STATUS="❌ FAIL"
    echo "❌ Test Case 4: FAILED"
fi
echo ""

# ── Write result file ────────────────────────────────────────────────────────
SP_ADDR=$(cat "$PROJECT_ROOT/deployments/config.sepolia.json" 2>/dev/null | grep '"superPaymaster"' | grep -oE '0x[0-9a-fA-F]+' | head -1 || echo "N/A")
APNTS_ADDR=$(cat "$PROJECT_ROOT/deployments/config.sepolia.json" 2>/dev/null | grep '"aPNTs"' | grep -oE '0x[0-9a-fA-F]+' | head -1 || echo "N/A")

cat > "$RESULT_FILE" <<MARKDOWN
# Gasless Test Run — $RUN_DATE

## Environment
- Network: Sepolia
- Config: deployments/config.sepolia.json
- SuperPaymaster: $SP_ADDR
- aPNTs: $APNTS_ADDR

## Results

| Test | Status | TX Hash | Etherscan |
|------|--------|---------|-----------|
| TC1: PaymasterV4 + xPNTs | $TC1_STATUS | ${TC1_TX:-N/A} | ${TC1_URL:-N/A} |
| TC2: SuperPaymaster + xPNTs1 | $TC2_STATUS | ${TC2_TX:-N/A} | ${TC2_URL:-N/A} |
| TC3: SuperPaymaster + xPNTs2 | $TC3_STATUS | ${TC3_TX:-N/A} | ${TC3_URL:-N/A} |
| TC4: SP Credit/Debt Path | $TC4_STATUS | ${TC4_TX:-N/A} | ${TC4_URL:-N/A} |

## Summary
$(PASS=true; for ec in $TC1_EXIT $TC2_EXIT $TC3_EXIT; do [ $ec -ne 0 ] && PASS=false; done; $PASS && echo "All tests PASSED ✅" || echo "Some tests FAILED ❌")
MARKDOWN

# Summary banner
if [ $TC1_EXIT -eq 0 ] && [ $TC2_EXIT -eq 0 ] && [ $TC3_EXIT -eq 0 ]; then
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║              All Tests Completed Successfully!            ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Summary:"
    echo "  ✅ Test Case 1: PaymasterV4 + xPNTs"
    echo "  ✅ Test Case 2: SuperPaymasterV2 + xPNTs1"
    echo "  ✅ Test Case 3: SuperPaymasterV2 + xPNTs2"
    echo "  $TC4_STATUS Test Case 4: SP Credit/Debt Path"
    echo ""
    echo "Core gasless transfer tests passed! 🎉"
else
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                  Some Tests FAILED                       ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Summary:"
    echo "  $TC1_STATUS Test Case 1: PaymasterV4 + xPNTs"
    echo "  $TC2_STATUS Test Case 2: SuperPaymasterV2 + xPNTs1"
    echo "  $TC3_STATUS Test Case 3: SuperPaymasterV2 + xPNTs2"
    echo "  $TC4_STATUS Test Case 4: SP Credit/Debt Path"
fi

echo ""
echo "📁 Results saved to: $RESULT_FILE"

# Exit with failure if any core test failed (TC4 skip=2 is acceptable)
if [ $TC1_EXIT -ne 0 ] || [ $TC2_EXIT -ne 0 ] || [ $TC3_EXIT -ne 0 ] || ([ $TC4_EXIT -ne 0 ] && [ $TC4_EXIT -ne 2 ]); then
    exit 1
fi

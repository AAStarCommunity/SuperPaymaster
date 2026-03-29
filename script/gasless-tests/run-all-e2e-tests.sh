#!/bin/bash

###############################################################################
# Run All E2E Tests
#
# Executes all test groups in dependency order:
# 1. Preflight checks (contracts, balances)
# 2. Foundation: A1 (registry roles), A2 (registry queries)
# 3. Operator: B1 (config), B2 (deposit/withdraw)
# 4. Negative: C1 (SuperPaymaster), C2 (PaymasterV4)
# 5. Reputation & Credit: D1, D2
# 6. Pricing & Fees: E1, E2
# 7. Staking & Slash: F1, F2
# 8. Legacy gasless: test-case-1/2/3
#
# Each test failure does NOT abort the run; summary printed at end.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo ""
echo "================================================================"
echo "  SuperPaymaster - Full E2E Test Suite"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"
echo ""

# Load env
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/.env.sepolia}"
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: Configuration file not found at $ENV_FILE${NC}"
    echo "  Set ENV_FILE to override: ENV_FILE=.env.sepolia ./run-all-e2e-tests.sh"
    exit 1
fi

set -a
source "$ENV_FILE"
set +a
echo -e "${GREEN}Configuration loaded: $ENV_FILE${NC}"
echo ""

# Results tracking
declare -a TEST_NAMES
declare -a TEST_RESULTS
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

run_test() {
    local name="$1"
    local cmd="$2"
    TOTAL=$((TOTAL + 1))

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  [$TOTAL] $name${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if eval "$cmd"; then
        TEST_NAMES+=("$name")
        TEST_RESULTS+=("PASS")
        PASSED=$((PASSED + 1))
        echo -e "${GREEN}  [$TOTAL] $name: PASSED${NC}"
    else
        TEST_NAMES+=("$name")
        TEST_RESULTS+=("FAIL")
        FAILED=$((FAILED + 1))
        echo -e "${RED}  [$TOTAL] $name: FAILED${NC}"
    fi
}

# ─────────────────────────────────────────────────────────────
# Phase 0: Preflight Checks
# ─────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Phase 0: Preflight Checks"
echo "================================================================"

run_test "Check Contracts"  "node $SCRIPT_DIR/check-contracts.js"
run_test "Check Balances"   "node $SCRIPT_DIR/check-balances.js"

# ─────────────────────────────────────────────────────────────
# Phase 1: Foundation (Registry)
# ─────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Phase 1: Foundation - Registry"
echo "================================================================"

run_test "A1: Registry Roles"    "node $SCRIPT_DIR/test-group-A1-registry-roles.js"
run_test "A2: Registry Queries"  "node $SCRIPT_DIR/test-group-A2-registry-queries.js"

# ─────────────────────────────────────────────────────────────
# Phase 2: Operator Management
# ─────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Phase 2: Operator Management"
echo "================================================================"

run_test "B1: Operator Config"           "node $SCRIPT_DIR/test-group-B1-operator-config.js"
run_test "B2: Operator Deposit/Withdraw" "node $SCRIPT_DIR/test-group-B2-operator-deposit-withdraw.js"

# ─────────────────────────────────────────────────────────────
# Phase 3: Negative / Boundary Cases
# ─────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Phase 3: Negative / Boundary Cases"
echo "================================================================"

run_test "C1: SuperPaymaster Negative" "node $SCRIPT_DIR/test-group-C1-gasless-negative.js"
run_test "C2: PaymasterV4 Negative"    "node $SCRIPT_DIR/test-group-C2-paymasterv4-negative.js"

# ─────────────────────────────────────────────────────────────
# Phase 4: Reputation & Credit
# ─────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Phase 4: Reputation & Credit"
echo "================================================================"

run_test "D1: Reputation Rules"  "node $SCRIPT_DIR/test-group-D1-reputation-rules.js"
run_test "D2: Credit Tiers"      "node $SCRIPT_DIR/test-group-D2-credit-tiers.js"

# ─────────────────────────────────────────────────────────────
# Phase 5: Pricing & Fees
# ─────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Phase 5: Pricing & Fees"
echo "================================================================"

run_test "E1: Pricing & Oracle"  "node $SCRIPT_DIR/test-group-E1-pricing-oracle.js"
run_test "E2: Protocol Fees"     "node $SCRIPT_DIR/test-group-E2-protocol-fees.js"

# ─────────────────────────────────────────────────────────────
# Phase 6: Staking & Slash
# ─────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Phase 6: Staking & Slash"
echo "================================================================"

run_test "F1: Staking Queries"  "node $SCRIPT_DIR/test-group-F1-staking-queries.js"
run_test "F2: Slash History"    "node $SCRIPT_DIR/test-group-F2-slash-queries.js"

# ─────────────────────────────────────────────────────────────
# Phase 7: V5.3 Agent Economy Scenarios
# ─────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Phase 7: V5.3 Agent Economy Scenarios"
echo "================================================================"

run_test "G1: Reputation-Gated Sponsorship"          "node $SCRIPT_DIR/test-group-G1-reputation-gated-sponsorship.js"
run_test "G2: Agent Identity Sponsorship (ERC-8004)"  "node $SCRIPT_DIR/test-group-G2-agent-identity-sponsorship.js"
run_test "G3: Credit Tier Escalation"                "node $SCRIPT_DIR/test-group-G3-credit-tier-escalation.js"

# ─────────────────────────────────────────────────────────────
# Phase 8: Legacy Gasless Transfer Tests
# ─────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Phase 8: Legacy Gasless Transfer Tests"
echo "================================================================"

run_test "Gasless: PaymasterV4"            "node $SCRIPT_DIR/test-case-1-paymasterv4.js"
run_test "Gasless: SuperPaymaster xPNTs1"  "node $SCRIPT_DIR/test-case-2-superpaymaster-xpnts1-fixed.js"
run_test "Gasless: SuperPaymaster xPNTs2"  "node $SCRIPT_DIR/test-case-3-superpaymaster-xpnts2.js"

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────
echo ""
echo ""
echo "================================================================"
echo "  E2E Test Suite Summary"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"
echo ""

for i in "${!TEST_NAMES[@]}"; do
    if [ "${TEST_RESULTS[$i]}" = "PASS" ]; then
        echo -e "  ${GREEN}PASS${NC}  ${TEST_NAMES[$i]}"
    else
        echo -e "  ${RED}FAIL${NC}  ${TEST_NAMES[$i]}"
    fi
done

echo ""
echo "────────────────────────────────────────────────────────────────"
echo -e "  Total: $TOTAL  |  ${GREEN}Passed: $PASSED${NC}  |  ${RED}Failed: $FAILED${NC}"
echo "────────────────────────────────────────────────────────────────"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All E2E tests passed!${NC}"
    exit 0
else
    echo -e "${RED}$FAILED test(s) failed.${NC}"
    exit 1
fi

#!/bin/bash
# Run Echidna Fuzzing Tests for All Core Contracts
# Usage: ./run-all-echidna-tests.sh

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CONFIG_FILE="echidna-all-contracts.yaml"
RESULTS_DIR="echidna-results"

echo -e "${BLUE}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Echidna Fuzzing Test Suite - All Core Contracts  ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
echo ""

# Create results directory
mkdir -p "$RESULTS_DIR"

# Test contracts array
declare -a CONTRACTS=(
    "contracts/echidna/GTokenStakingInvariants.sol"
    "contracts/echidna/MySBT_v2_4_0_Invariants.sol"
    "contracts/echidna/SuperPaymasterV2Invariants.sol"
    "contracts/echidna/IntegrationInvariants.sol"
)

declare -a CONTRACT_NAMES=(
    "GTokenStakingInvariants"
    "MySBT_v2_4_0_Invariants"
    "SuperPaymasterV2Invariants"
    "IntegrationInvariants"
)

declare -a NAMES=(
    "GTokenStaking"
    "MySBT_v2.4.0"
    "SuperPaymasterV2"
    "Integration"
)

# Function to run test
run_test() {
    local contract=$1
    local contract_name=$2
    local name=$3
    local log_file="$RESULTS_DIR/${name}-$(date +%Y%m%d-%H%M%S).log"

    echo -e "${YELLOW}┌─────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}│ Testing: ${name}${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────────${NC}"
    echo "Contract: $contract"
    echo "Target: $contract_name"
    echo "Config: $CONFIG_FILE"
    echo "Log: $log_file"
    echo ""

    # Run echidna
    if echidna "$contract" \
        --contract "$contract_name" \
        --config "$CONFIG_FILE" \
        2>&1 | tee "$log_file"; then
        echo -e "${GREEN}✅ ${name} - PASSED${NC}"
        echo ""
        return 0
    else
        echo -e "${RED}❌ ${name} - FAILED${NC}"
        echo "See log: $log_file"
        echo ""
        return 1
    fi
}

# Track results
PASSED=0
FAILED=0
TOTAL=${#CONTRACTS[@]}

# Run all tests
for i in "${!CONTRACTS[@]}"; do
    if run_test "${CONTRACTS[$i]}" "${CONTRACT_NAMES[$i]}" "${NAMES[$i]}"; then
        ((PASSED++))
    else
        ((FAILED++))
    fi
done

# Summary
echo -e "${BLUE}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                  Test Summary                      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Total Tests:  ${TOTAL}"
echo -e "${GREEN}Passed:       ${PASSED}${NC}"
if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Failed:       ${FAILED}${NC}"
else
    echo -e "Failed:       ${FAILED}"
fi
echo ""

# Exit with appropriate code
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}🎉 All tests passed!${NC}"
    echo ""
    echo "Results saved in: $RESULTS_DIR/"
    exit 0
else
    echo -e "${RED}⚠️  Some tests failed!${NC}"
    echo ""
    echo "Check logs in: $RESULTS_DIR/"
    exit 1
fi

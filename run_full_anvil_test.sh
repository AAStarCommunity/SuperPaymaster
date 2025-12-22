#!/bin/bash
set -e

echo "🚀 SuperPaymaster V3 - Complete Anvil Test Suite"
echo "=================================================="

# Colors
GREEN='\033[0.32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Step 1: Build Contracts
echo -e "\n${YELLOW}📦 Step 1: Building contracts...${NC}"
cd "$(dirname "$0")"
forge clean
forge build
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Build failed!${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Build successful${NC}"

# Step 2: Start Anvil
echo -e "\n${YELLOW}⛓️  Step 2: Starting Anvil...${NC}"
pkill anvil || true
sleep 2
anvil --port 8545 --chain-id 31337 > /tmp/anvil_test.log 2>&1 &
ANVIL_PID=$!
sleep 3

# Verify Anvil is running
if ! curl -s http://127.0.0.1:8545 > /dev/null; then
    echo -e "${RED}❌ Anvil failed to start!${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Anvil running (PID: $ANVIL_PID)${NC}"

# Step 3: Deploy Contracts
echo -e "\n${YELLOW}🚢 Step 3: Deploying contracts to Anvil...${NC}"
export PRIVATE_KEY_JASON=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

forge script script/v3/SetupV3.s.sol \
  --tc SetupV3 \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key $PRIVATE_KEY_JASON

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Deployment failed!${NC}"
    kill $ANVIL_PID
    exit 1
fi
echo -e "${GREEN}✅ Deployment successful${NC}"

# Step 4: Extract ABIs
echo -e "\n${YELLOW}📄 Step 4: Extracting ABIs...${NC}"
if [ -f "scripts/extract_abis.sh" ]; then
    ./scripts/extract_abis.sh
    echo -e "${GREEN}✅ ABIs extracted${NC}"
else
    echo -e "${YELLOW}⚠️  extract_abis.sh not found, skipping...${NC}"
fi

# Step 5: Run Tests
echo -e "\n${YELLOW}🧪 Step 5: Running test suite...${NC}"
cd ../aastar-sdk

PASSED=0
FAILED=0
TOTAL=0

# Core Tests (必须通过)
echo -e "\n${YELLOW}=== Core Tests ===${NC}"

tests=(
    "06_local_test_v3_admin.ts:Admin Module"
    "06_local_test_v3_funding.ts:Funding Module"
    "06_local_test_v3_execution.ts:Execution Module"
    "09_local_test_community_simple.ts:Community Verification"
)

for test_info in "${tests[@]}"; do
    IFS=':' read -r test_file test_name <<< "$test_info"
    TOTAL=$((TOTAL + 1))
    echo -e "\n${YELLOW}Running: $test_name${NC}"
    
    if pnpm ts-node scripts/$test_file 2>&1 | tee /tmp/test_$test_file.log; then
        echo -e "${GREEN}✅ $test_name PASSED${NC}"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}❌ $test_name FAILED${NC}"
        FAILED=$((FAILED + 1))
    fi
done

# Extended Tests (可选)
echo -e "\n${YELLOW}=== Extended Tests ===${NC}"

extended_tests=(
    "06_local_test_v3_reputation.ts:Reputation System"
    "06_local_test_v3_full.ts:Full Flow"
    "07_local_test_v3_audit.ts:Audit"
    "08_local_test_registry_lifecycle.ts:Registry Lifecycle"
)

for test_info in "${extended_tests[@]}"; do
    IFS=':' read -r test_file test_name <<< "$test_info"
    TOTAL=$((TOTAL + 1))
    echo -e "\n${YELLOW}Running: $test_name${NC}"
    
    if [ -f "scripts/$test_file" ]; then
        if pnpm ts-node scripts/$test_file 2>&1 | tee /tmp/test_$test_file.log; then
            echo -e "${GREEN}✅ $test_name PASSED${NC}"
            PASSED=$((PASSED + 1))
        else
            echo -e "${YELLOW}⚠️  $test_name FAILED (non-critical)${NC}"
            FAILED=$((FAILED + 1))
        fi
    else
        echo -e "${YELLOW}⚠️  $test_file not found, skipping...${NC}"
    fi
done

# Cleanup
echo -e "\n${YELLOW}🧹 Cleaning up...${NC}"
cd ..
kill $ANVIL_PID 2>/dev/null || true
echo -e "${GREEN}✅ Anvil stopped${NC}"

# Summary
echo -e "\n=================================================="
echo -e "${YELLOW}📊 Test Summary${NC}"
echo -e "=================================================="
echo -e "Total Tests: $TOTAL"
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
COVERAGE=$((PASSED * 100 / TOTAL))
echo -e "Coverage: ${COVERAGE}%"

if [ $FAILED -eq 0 ]; then
    echo -e "\n${GREEN}🎉 All tests passed!${NC}"
    exit 0
else
    echo -e "\n${YELLOW}⚠️  Some tests failed. Check logs in /tmp/test_*.log${NC}"
    exit 1
fi

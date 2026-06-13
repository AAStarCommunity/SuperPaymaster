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
# 8. V5.3 Agent Economy: G1, G2, G3
# 9. DVT / BLS / Reputation Infrastructure: H1, H2
# 10. Legacy gasless: test-case-1/2/3
# 11. Streaming & x402 Settlement: MicroPaymentChannel, x402 EIP-3009
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

# Redundant tx-broadcast fallback. READS still use the primary RPC from .env
# (e.g. Alchemy — the production endpoint we keep under test), but every tx is
# ALSO pushed to this public RPC so a primary that accepts-but-doesn't-propagate
# can't strand it (root cause of the "stuck in mempool" failures on 2026-06-13).
# Override or clear with E2E_BROADCAST_RPCS="" to test the primary RPC in isolation.
export E2E_BROADCAST_RPCS="${E2E_BROADCAST_RPCS:-https://ethereum-sepolia-rpc.publicnode.com}"
echo -e "${GREEN}Tx broadcast fallback: ${E2E_BROADCAST_RPCS:-<primary only>}${NC}"
echo ""

# Results tracking
# EXIT CODE CONVENTION (lesson learned 2026-05-13):
#   0 = PASS   — test ran and assertions passed (UserOp confirmed on-chain)
#   1 = FAIL   — test ran but failed (TX reverted, assertion failed)
#   2 = SKIP   — precondition not met (zero balance, network error, missing config)
# NEVER treat exit 0 as PASS unless the test actually executed its core logic.
# Using bare `return` inside an async main() exits with 0 — always use process.exit(2)
# for any early-exit / skip path to avoid silent false positives in this runner.
declare -a TEST_NAMES
declare -a TEST_RESULTS
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
INDEX=0  # display counter over ALL tests (incl. filtered) so [N] labels match the full suite

# Staged-run controls — debug a subset without re-running all 37 tests (each ~30-90s).
# A stuck/slow test no longer blocks iteration: run just the phase you care about.
#   START_AT=30   run from test #30 onward (skip earlier ones)
#   ONLY="x402"   run only tests whose name matches this substring (case-insensitive)
# Both default to "run everything". Combine with TEST_TIMEOUT to bound each test.
START_AT="${START_AT:-1}"
ONLY="${ONLY:-}"

# Idempotent skip-if-passed (project requirement): once a test passes against the
# CURRENT deployment it need not re-run — a green on-chain result proves the
# contract meets its design.
#   SKIP_PASSED=1  skip tests already recorded green for this deployment (fast)
#   FRESH=1        ignore + reset the cache, run everything from scratch
# Default (neither set): run everything, but record each green so a later
# SKIP_PASSED run can skip it.
#
# The cache is keyed by a hash of the ENTIRE deployment config (every contract
# address), NOT just the SuperPaymaster address. A redeploy of any dependency
# (aPNTs, PaymasterV4, Registry, …) that leaves SuperPaymaster's address unchanged
# would otherwise silently reuse stale green results against incompatible
# contracts. Any address/config change rotates the fingerprint → full re-run.
SKIP_PASSED="${SKIP_PASSED:-}"
FRESH="${FRESH:-}"
DEPLOY_CONFIG="$PROJECT_ROOT/deployments/config.sepolia.json"
DEPLOY_FINGERPRINT=$( { shasum -a 256 "$DEPLOY_CONFIG" 2>/dev/null || sha256sum "$DEPLOY_CONFIG" 2>/dev/null; } | awk '{print substr($1,1,16)}' )
[ -z "$DEPLOY_FINGERPRINT" ] && DEPLOY_FINGERPRINT="unknown"
PASSED_STATE_FILE="$SCRIPT_DIR/results/.passed-${DEPLOY_FINGERPRINT}.txt"
mkdir -p "$SCRIPT_DIR/results"
[ -n "$FRESH" ] && rm -f "$PASSED_STATE_FILE"

# Per-test hard timeout (seconds). A single test whose TX gets stuck in the
# Sepolia mempool must NOT hang the whole suite — see lesson 2026-06-13. macOS
# ships no `timeout(1)`, so we use a perl alarm wrapper: fork the command, kill
# it (TERM then KILL) when the alarm fires, and return 124 like GNU timeout.
# Override per run with: TEST_TIMEOUT=420 ./run-all-e2e-tests.sh
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"

run_with_timeout() {
    local secs="$1"
    local cmd="$2"
    perl -e '
        my $t = shift @ARGV;
        my $pid = fork();
        if (!defined $pid) { die "fork failed: $!\n"; }
        if ($pid == 0) { exec(@ARGV); exit 127; }
        local $SIG{ALRM} = sub {
            kill("TERM", $pid);
            sleep 3;
            kill("KILL", $pid);
            waitpid($pid, 0);
            exit 124;
        };
        alarm($t);
        waitpid($pid, 0);
        alarm(0);
        exit($? >> 8);
    ' "$secs" /bin/sh -c "$cmd"
}

run_test() {
    local name="$1"
    local cmd="$2"
    INDEX=$((INDEX + 1))

    # Staged-run filters: skip tests before START_AT, or not matching ONLY.
    if [ "$INDEX" -lt "$START_AT" ]; then return; fi
    if [ -n "$ONLY" ] && ! echo "$name" | grep -qi "$ONLY"; then return; fi

    # Idempotent cache: if this test already passed for the current contracts,
    # skip it (counts as PASS) unless FRESH was requested.
    if [ -n "$SKIP_PASSED" ] && [ -z "$FRESH" ] && grep -qxF "$name" "$PASSED_STATE_FILE" 2>/dev/null; then
        TOTAL=$((TOTAL + 1))
        TEST_NAMES+=("$name")
        TEST_RESULTS+=("PASS")
        PASSED=$((PASSED + 1))
        echo ""
        echo -e "${GREEN}  [$INDEX] $name: CACHED-PASS (verified earlier for these contracts; FRESH=1 to re-run)${NC}"
        return
    fi

    TOTAL=$((TOTAL + 1))

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  [$INDEX] $name${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # About to actually run: drop any stale green record so a regression never
    # stays cached. It is re-added below only if the test passes again.
    if [ -f "$PASSED_STATE_FILE" ] && grep -qxF "$name" "$PASSED_STATE_FILE" 2>/dev/null; then
        grep -vxF "$name" "$PASSED_STATE_FILE" > "$PASSED_STATE_FILE.tmp" || true
        mv "$PASSED_STATE_FILE.tmp" "$PASSED_STATE_FILE"
    fi

    run_with_timeout "$TEST_TIMEOUT" "$cmd"
    local exit_code=$?

    TEST_NAMES+=("$name")
    if [ $exit_code -eq 0 ]; then
        TEST_RESULTS+=("PASS")
        PASSED=$((PASSED + 1))
        # Record this green so a later SKIP_PASSED run can skip it.
        grep -qxF "$name" "$PASSED_STATE_FILE" 2>/dev/null || echo "$name" >> "$PASSED_STATE_FILE"
        echo -e "${GREEN}  [$INDEX] $name: PASSED${NC}"
    elif [ $exit_code -eq 2 ]; then
        TEST_RESULTS+=("SKIP")
        SKIPPED=$((SKIPPED + 1))
        echo -e "${YELLOW}  [$INDEX] $name: SKIPPED (precondition not met)${NC}"
    elif [ $exit_code -eq 124 ]; then
        # Hard timeout — treat as FAIL so it is never mistaken for a clean pass,
        # but the suite continues to the next test instead of hanging forever.
        TEST_RESULTS+=("FAIL")
        FAILED=$((FAILED + 1))
        echo -e "${RED}  [$INDEX] $name: TIMEOUT after ${TEST_TIMEOUT}s (killed; TX likely stuck in mempool)${NC}"
    else
        TEST_RESULTS+=("FAIL")
        FAILED=$((FAILED + 1))
        echo -e "${RED}  [$INDEX] $name: FAILED (exit $exit_code)${NC}"
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
run_test "B3: configureOperator v2 (2-arg, PR#200)" "node $SCRIPT_DIR/test-group-B3-configure-operator-v2.js"
run_test "B4: SP Governance Admin"               "node $SCRIPT_DIR/test-group-B4-sp-governance.js"
run_test "B5: Dry Run & Pending Debt"            "node $SCRIPT_DIR/test-group-B5-dry-run-pending-debt.js"

# ─────────────────────────────────────────────────────────────
# Phase 3: Negative / Boundary Cases
# ─────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Phase 3: Negative / Boundary Cases"
echo "================================================================"

sleep 5  # Let RPC recover after B2 heavy deposit/withdraw TXs
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
sleep 5  # Let RPC recover between pricing tests
run_test "E2: Protocol Fees"     "node $SCRIPT_DIR/test-group-E2-protocol-fees.js"
run_test "E3: aPNTs Exchange Rate Accounting (PR#200)" "node $SCRIPT_DIR/test-group-E3-apnts-exchange-rate.js"
run_test "E4: repayDebt & Exchange Rate Settlement"    "node $SCRIPT_DIR/test-group-E4-repay-debt-exchange-rate.js"

# ─────────────────────────────────────────────────────────────
# Phase 6: Staking & Slash
# ─────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Phase 6: Staking & Slash"
echo "================================================================"

run_test "F1: Staking Queries"       "node $SCRIPT_DIR/test-group-F1-staking-queries.js"
run_test "F2: Slash History"         "node $SCRIPT_DIR/test-group-F2-slash-queries.js"
run_test "F3: Staking & Registry Admin" "node $SCRIPT_DIR/test-group-F3-staking-registry-admin.js"

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
# Phase 8: DVT / BLS / Reputation Infrastructure
# ─────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Phase 8: DVT / BLS / Reputation Infrastructure"
echo "================================================================"

run_test "H1: DVT & BLS Aggregator Queries"                    "node $SCRIPT_DIR/test-group-H1-dvt-bls-queries.js"
run_test "H2: ReputationSystem Community Scoring & BLS Sync"   "node $SCRIPT_DIR/test-group-H2-reputation-sync.js"

# ─────────────────────────────────────────────────────────────
# Phase 9: Legacy Gasless Transfer Tests
# ─────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Phase 9: Legacy Gasless Transfer Tests"
echo "================================================================"

# Run pre-flight setup to ensure all prerequisites are met before gasless tests.
# This funds PaymasterV4 deposits, tops up operator balances, and refreshes the
# Chainlink price cache in SuperPaymaster. Safe to run repeatedly (idempotent).
echo ""
echo -e "${YELLOW}  Running pre-flight setup for gasless tests...${NC}"
if node "$SCRIPT_DIR/setup-gasless.js"; then
    echo -e "${GREEN}  Setup complete — all prerequisites met.${NC}"
else
    SETUP_EXIT=$?
    echo -e "${RED}  Setup failed (exit $SETUP_EXIT) — gasless tests may fail due to missing prerequisites.${NC}"
    echo -e "${YELLOW}  Continuing anyway (test results will reflect actual state).${NC}"
fi

sleep 15  # Extended pause to let RPC rate limit window reset after heavy test groups
run_test "Gasless: PaymasterV4"            "node $SCRIPT_DIR/test-case-1-paymasterv4.js"
sleep 5
# TC2/TC3 override Account B/C with Account A — Kernel/ZeroDev accounts (B,C) use raw-hash
# signing which is incompatible with EIP-191; SimpleAccount (A) works correctly.
run_test "Gasless: SuperPaymaster xPNTs1"  "TEST_AA_ACCOUNT_ADDRESS_B=\"\$TEST_AA_ACCOUNT_ADDRESS_A\" node $SCRIPT_DIR/test-case-2-superpaymaster-xpnts1-fixed.js"
sleep 5
run_test "Gasless: SuperPaymaster xPNTs2"  "TEST_AA_ACCOUNT_ADDRESS_C=\"\$TEST_AA_ACCOUNT_ADDRESS_A\" node $SCRIPT_DIR/test-case-3-superpaymaster-xpnts2.js"
sleep 5
run_test "Gasless: SP Credit/Debt Path"   "node $SCRIPT_DIR/test-case-4-superpaymaster-credit-path.js"

# ─────────────────────────────────────────────────────────────
# Phase 10: Streaming & x402 Settlement
# ─────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Phase 10: Streaming & x402 Settlement"
echo "================================================================"

sleep 5
run_test "MicroPaymentChannel: Open / Settle / Close"  "node $SCRIPT_DIR/test-micropayment-channel.js"
sleep 5
run_test "x402: EIP-3009 Settlement"                    "node $SCRIPT_DIR/test-x402-eip3009-settlement.js"
sleep 5
run_test "x402: Direct Settle (C-02 signed auth)"       "node $SCRIPT_DIR/test-x402-direct-settle.js"
sleep 5
run_test "BLS: Permissionless Switch (H-02)"            "node $SCRIPT_DIR/test-bls-permissionless-switch.js"

# ─────────────────────────────────────────────────────────────
# Phase 11: PaymasterV4 Lifecycle
# ─────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Phase 11: PaymasterV4 Lifecycle"
echo "================================================================"

sleep 5
run_test "P2: PaymasterV4 Lifecycle (deposit/withdraw/activate)" "node $SCRIPT_DIR/test-group-P2-paymasterv4-lifecycle.js"

# ─────────────────────────────────────────────────────────────
# Phase 12: xPNTs Token Admin
# ─────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Phase 12: xPNTs Token Admin"
echo "================================================================"

sleep 5
run_test "X1: xPNTs Token Admin (limits/spenders/exchange-rate)" "node $SCRIPT_DIR/test-group-X1-xpnts-admin.js"

# ─────────────────────────────────────────────────────────────
# Phase 13: Beta.3 Audit Fix Verification (H-1 Credit Ceiling + H-2 Emergency Halt)
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}── Phase 13: Beta.3 Audit Fix Verification ──────────────────────────────────────${NC}"
run_test "I1: Credit Ceiling H-1 Fix"              "node $SCRIPT_DIR/test-group-I1-credit-ceiling-h1.js"
run_test "I2: Emergency Halt H-2 Fix"              "node $SCRIPT_DIR/test-group-I2-emergency-halt-h2.js"

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
    elif [ "${TEST_RESULTS[$i]}" = "SKIP" ]; then
        echo -e "  ${YELLOW}SKIP${NC}  ${TEST_NAMES[$i]}"
    else
        echo -e "  ${RED}FAIL${NC}  ${TEST_NAMES[$i]}"
    fi
done

echo ""
echo "────────────────────────────────────────────────────────────────"
echo -e "  Total: $TOTAL  |  ${GREEN}Passed: $PASSED${NC}  |  ${RED}Failed: $FAILED${NC}  |  ${YELLOW}Skipped: $SKIPPED${NC}"
echo "────────────────────────────────────────────────────────────────"
echo ""

# ── Write result file ────────────────────────────────────────────────────────
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"
E2E_RESULT_FILE="$RESULTS_DIR/$(date '+%Y-%m-%d_%H-%M-%S')_run-all-e2e-tests.md"
SP_ADDR=$(cat "$PROJECT_ROOT/deployments/config.sepolia.json" 2>/dev/null | grep '"superPaymaster"' | grep -oE '0x[0-9a-fA-F]+' | head -1 || echo "N/A")
APNTS_ADDR=$(cat "$PROJECT_ROOT/deployments/config.sepolia.json" 2>/dev/null | grep '"aPNTs"' | grep -oE '0x[0-9a-fA-F]+' | head -1 || echo "N/A")

{
  echo "# E2E Test Run — $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""
  echo "## Environment"
  echo "- Network: Sepolia"
  echo "- SuperPaymaster: $SP_ADDR"
  echo "- aPNTs: $APNTS_ADDR"
  echo ""
  echo "## Results"
  echo ""
  echo "| # | Test | Status |"
  echo "|---|------|--------|"
  for i in "${!TEST_NAMES[@]}"; do
    idx=$((i + 1))
    if [ "${TEST_RESULTS[$i]}" = "PASS" ]; then
      echo "| $idx | ${TEST_NAMES[$i]} | ✅ PASS |"
    elif [ "${TEST_RESULTS[$i]}" = "SKIP" ]; then
      echo "| $idx | ${TEST_NAMES[$i]} | ⏭️  SKIP |"
    else
      echo "| $idx | ${TEST_NAMES[$i]} | ❌ FAIL |"
    fi
  done
  echo ""
  echo "## Summary"
  echo "- Total: $TOTAL | Passed: $PASSED | Failed: $FAILED | Skipped: $SKIPPED"
  if [ $FAILED -gt 0 ]; then
    echo "- **$FAILED test(s) FAILED ❌**"
  elif [ $SKIPPED -gt 0 ]; then
    echo "- **PASS WITH SKIPS ⏭️ — $SKIPPED test(s) INCONCLUSIVE (not executed/verified). NOT a clean pass.**"
    echo "- A skip means a test could not run or a load-bearing write was skipped — re-run after the mempool clears to get a definitive result."
  else
    echo "- **All tests PASSED ✅ (clean — 0 skipped)**"
  fi
} > "$E2E_RESULT_FILE"

echo ""
echo "📁 Results saved to: $E2E_RESULT_FILE"
echo ""

if [ $FAILED -gt 0 ]; then
    echo -e "${RED}$FAILED test(s) failed.${NC}"
    exit 1
elif [ $SKIPPED -gt 0 ]; then
    # No hard failures, but skips mean the run is NOT a definitive all-green.
    # Exit 2 (not 0) so a CI gate / caller never mistakes an inconclusive run for
    # a clean pass — e.g. a run where every test skipped must not merge green.
    # CI that wants to tolerate transient skips can explicitly treat exit 2 as soft.
    echo -e "${YELLOW}PASS WITH SKIPS: $SKIPPED test(s) inconclusive (exit 2). Re-run after mempool clears for a definitive result.${NC}"
    exit 2
else
    echo -e "${GREEN}All E2E tests passed (clean — 0 skipped)!${NC}"
    exit 0
fi

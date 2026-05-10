#!/bin/bash
# ==============================================================================
# SuperPaymaster Full Regression Suite (Modular Orchestrator)
# 1. deploy-core: Phase 1 (Core Infra + Audit)
# 2. prepare-test: Phase 1.5 (Test Account Prep + Audit)
# ==============================================================================

ENV="anvil"
FORCE_DEPLOY=false
CUSTOM_TIMEOUT=300

while [[ $# -gt 0 ]]; do
    case $1 in
        --env) ENV="$2"; shift 2 ;;
        --force) FORCE_DEPLOY=true; shift ;;
        --timeout) CUSTOM_TIMEOUT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="logs/${TIMESTAMP}-${ENV}-regression.log"
mkdir -p logs

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_section() {
    local title=$1
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    echo -e "${CYAN}>> $title${NC}"
    echo -e "${CYAN}------------------------------------------------------------${NC}"
}

echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║       SUPERPAYMASTER -> MODULAR REGRESSION FLOW              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

# PHASE 1: Core Infrastructure
log_section "STEP 1: Core Infrastructure Deployment & Audit"
FORCE_FLAG=""
[ "$FORCE_DEPLOY" = true ] && FORCE_FLAG="--force"
./deploy-core "$ENV" $FORCE_FLAG | tee -a "$LOG_FILE"
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo -e "${RED}Phase 1 failed. Check logs.${NC}"
    exit 1
fi

# PHASE 1.5: Test Account Preparation
log_section "STEP 2: Test Account Preparation & Audit"
./prepare-test "$ENV" | tee -a "$LOG_FILE"
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo -e "${RED}Phase 2 failed. Check logs.${NC}"
    exit 1
fi

echo -e "\n${GREEN}✅ MODULAR REGRESSION SUCCESS!${NC}"
echo "Full log: $LOG_FILE"
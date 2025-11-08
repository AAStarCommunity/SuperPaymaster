#!/bin/bash
# Echidna 24-Hour Fuzzing Test Runner
# Usage: ./run-echidna-24h.sh [start|stop|status|logs]

set -e

ECHIDNA_LOG="echidna-24h-run.log"
ECHIDNA_PID_FILE=".echidna.pid"
ECHIDNA_CONFIG="echidna-long-run.yaml"
ECHIDNA_CONTRACT="contracts/echidna/GTokenStakingInvariants.sol"
ECHIDNA_TARGET="GTokenStakingInvariants"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

function start_fuzzing() {
    if [ -f "$ECHIDNA_PID_FILE" ] && kill -0 $(cat "$ECHIDNA_PID_FILE") 2>/dev/null; then
        echo -e "${YELLOW}⚠️  Echidna is already running (PID: $(cat $ECHIDNA_PID_FILE))${NC}"
        exit 1
    fi

    echo -e "${GREEN}🚀 Starting Echidna 24-hour fuzzing test...${NC}"
    echo "Contract: $ECHIDNA_CONTRACT"
    echo "Target: $ECHIDNA_TARGET"
    echo "Config: $ECHIDNA_CONFIG"
    echo "Log file: $ECHIDNA_LOG"
    echo ""
    echo -e "${YELLOW}⏰ This will run for 24 hours (86400 seconds)${NC}"
    echo -e "${YELLOW}📊 Test limit: 1,000,000 executions${NC}"
    echo ""

    # Start Echidna in background with nohup
    nohup echidna "$ECHIDNA_CONTRACT" \
        --contract "$ECHIDNA_TARGET" \
        --config "$ECHIDNA_CONFIG" \
        > "$ECHIDNA_LOG" 2>&1 &

    # Save PID
    echo $! > "$ECHIDNA_PID_FILE"

    echo -e "${GREEN}✅ Echidna started successfully!${NC}"
    echo "PID: $(cat $ECHIDNA_PID_FILE)"
    echo ""
    echo "Commands:"
    echo "  ./run-echidna-24h.sh status  - Check running status"
    echo "  ./run-echidna-24h.sh logs    - Tail logs (live)"
    echo "  ./run-echidna-24h.sh stop    - Stop fuzzing"
}

function stop_fuzzing() {
    if [ ! -f "$ECHIDNA_PID_FILE" ]; then
        echo -e "${YELLOW}⚠️  No running Echidna process found${NC}"
        exit 1
    fi

    PID=$(cat "$ECHIDNA_PID_FILE")

    if kill -0 $PID 2>/dev/null; then
        echo -e "${YELLOW}🛑 Stopping Echidna (PID: $PID)...${NC}"
        kill $PID
        rm "$ECHIDNA_PID_FILE"
        echo -e "${GREEN}✅ Echidna stopped${NC}"
    else
        echo -e "${RED}❌ Echidna process not running${NC}"
        rm "$ECHIDNA_PID_FILE"
    fi
}

function show_status() {
    if [ ! -f "$ECHIDNA_PID_FILE" ]; then
        echo -e "${RED}❌ Echidna is not running${NC}"
        exit 1
    fi

    PID=$(cat "$ECHIDNA_PID_FILE")

    if kill -0 $PID 2>/dev/null; then
        echo -e "${GREEN}✅ Echidna is running${NC}"
        echo "PID: $PID"
        echo ""

        # Show runtime
        if [ "$(uname)" == "Darwin" ]; then
            # macOS
            START_TIME=$(ps -p $PID -o lstart=)
            echo "Started: $START_TIME"
        else
            # Linux
            ELAPSED=$(ps -p $PID -o etime=)
            echo "Elapsed: $ELAPSED"
        fi

        echo ""
        echo "Recent log entries:"
        tail -20 "$ECHIDNA_LOG"

        echo ""
        echo -e "${YELLOW}💡 Use './run-echidna-24h.sh logs' for live tail${NC}"
    else
        echo -e "${RED}❌ Echidna process died (PID: $PID)${NC}"
        rm "$ECHIDNA_PID_FILE"
        echo ""
        echo "Last 50 lines of log:"
        tail -50 "$ECHIDNA_LOG"
    fi
}

function show_logs() {
    if [ ! -f "$ECHIDNA_LOG" ]; then
        echo -e "${RED}❌ Log file not found: $ECHIDNA_LOG${NC}"
        exit 1
    fi

    echo -e "${GREEN}📋 Tailing Echidna logs (Ctrl+C to exit)...${NC}"
    tail -f "$ECHIDNA_LOG"
}

function show_progress() {
    if [ ! -f "$ECHIDNA_LOG" ]; then
        echo -e "${RED}❌ Log file not found${NC}"
        exit 1
    fi

    echo -e "${GREEN}📊 Echidna Progress Report${NC}"
    echo "=========================="
    echo ""

    # Extract coverage info
    echo "Coverage:"
    grep -i "coverage\|instr\|corpus" "$ECHIDNA_LOG" | tail -5

    echo ""
    echo "Test Status:"
    grep -i "echidna_\|passing\|failed" "$ECHIDNA_LOG" | tail -10

    echo ""
    echo "Last Update:"
    tail -3 "$ECHIDNA_LOG"
}

# Main command dispatcher
case "${1:-}" in
    start)
        start_fuzzing
        ;;
    stop)
        stop_fuzzing
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    progress)
        show_progress
        ;;
    *)
        echo "Echidna 24-Hour Fuzzing Test Runner"
        echo ""
        echo "Usage: $0 {start|stop|status|logs|progress}"
        echo ""
        echo "Commands:"
        echo "  start     - Start 24-hour fuzzing test (background)"
        echo "  stop      - Stop running fuzzing test"
        echo "  status    - Check current status and recent logs"
        echo "  logs      - Tail logs in real-time"
        echo "  progress  - Show progress summary"
        echo ""
        exit 1
        ;;
esac

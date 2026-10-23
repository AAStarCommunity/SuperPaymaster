#!/bin/bash
# R2-F4 §4.4: the same G re-run as run_g.sh, under --isolate --gas-limit 100000000000.
# Usage: scripts/run_g_isolate.sh <log dir>
ISOLATE=1 exec "$(dirname "$0")/run_g.sh" "$@"

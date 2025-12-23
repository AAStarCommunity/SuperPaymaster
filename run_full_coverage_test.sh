#!/bin/bash
# Wrapper script to run the full SDK regression/coverage suite
echo "🚀 Starting Comprehensive Business Scenario Coverage Audit..."
cd "$(dirname "$0")/../aastar-sdk"
./run_full_regression.sh

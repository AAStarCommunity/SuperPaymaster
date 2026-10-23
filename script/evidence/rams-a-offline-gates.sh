#!/bin/bash
# Offline Cancun + Prague gates for the route-A branch. Usage: bash script/evidence/rams-a-offline-gates.sh <scratch dir>
set -uo pipefail
S="$1"; L=docs/design/aoa-balance-mode/data/rams-a/review-3-offline-gates.log
F=~/.foundry/bin/forge
{
printf 'Offline gates UTC: %s\nCommit: %s\nDirty paths (excluding this log): %s\nforge: %s\nshell: %s\n' "$(date -u +%FT%TZ)" "$(git rev-parse HEAD)" "$(git status --porcelain | grep -v review-3-offline-gates.log | wc -l | tr -d ' ')" "$($F --version | head -1)" "$BASH_VERSION"
echo '== Cancun: forge test --offline'
$F test --offline > "$S/cancun.full" 2>&1; rc=$?
grep -E '^Ran [0-9]+ test suites|^\[FAIL|Suite result: FAILED' "$S/cancun.full"; echo "cancun rc=$rc"
echo '== Prague: forge test --offline --evm-version prague'
$F test --offline --evm-version prague --out "$S/out-prague" --cache-path "$S/cache-prague" > "$S/prague.full" 2>&1; rc=$?
grep -E '^Ran [0-9]+ test suites|^\[FAIL|Suite result: FAILED' "$S/prague.full"; echo "prague rc=$rc"
} > "$L" 2>&1
cat "$L"

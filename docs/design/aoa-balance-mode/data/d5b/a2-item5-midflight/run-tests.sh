#!/usr/bin/env bash
# Re-run the A2 item 5 suites (Cancun + Prague) and archive the logs. Run from the repo root.
# Fail-closed: every forge run's exit status is recorded; the script exits 1 if ANY run exits non-zero
# or if a run's log lacks a "Suite result: ok" line / contains "FAIL".
# OUT may be overridden (used by selftest-fail-closed.sh).
set -uo pipefail
FORGE=${FORGE:-$(command -v forge || echo "$HOME/.foundry/bin/forge")}
OUT=${OUT:-docs/design/aoa-balance-mode/data/d5b/a2-item5-midflight/results}
mkdir -p "$OUT"
"$FORGE" --version > "$OUT/forge-version.txt" || { echo "forge --version failed"; exit 1; }

FAILED=0
check() { # name, exit code, log
  local name=$1 rc=$2 log=$3
  if [ "$rc" -ne 0 ]; then echo "$name: FAIL (forge exit $rc)"; FAILED=1; return; fi
  if ! grep -q "Suite result: ok" "$log" || grep -q "FAIL" "$log"; then echo "$name: FAIL (log check)"; FAILED=1; return; fi
  echo "$name: ok"
}

NEW="SuperPaymasterRc1Rc2MidBundleTest"
"$FORGE" test --match-contract "$NEW" -vv > "$OUT/rc1rc2-cancun.log" 2>&1; check "rc1rc2 cancun" $? "$OUT/rc1rc2-cancun.log"
"$FORGE" test --match-contract "$NEW" -vv --evm-version prague > "$OUT/rc1rc2-prague.log" 2>&1; check "rc1rc2 prague" $? "$OUT/rc1rc2-prague.log"
# 5.4.2 (live Sepolia impl) -> rc.2 forward, verbose
V="SuperPaymasterV542ToRc2MidBundleTest"
"$FORGE" test --match-contract "$V" -vv > "$OUT/v542rc2-cancun.log" 2>&1; check "v542rc2 cancun" $? "$OUT/v542rc2-cancun.log"
"$FORGE" test --match-contract "$V" -vv --evm-version prague > "$OUT/v542rc2-prague.log" 2>&1; check "v542rc2 prague" $? "$OUT/v542rc2-prague.log"
# the existing mid-bundle / fee-snapshot suites together with the new ones (regression)
M='UpgradeRace|FeeSnapshot|Rc1Rc2MidBundle|V542ToRc2MidBundle'
"$FORGE" test --match-contract "$M" > "$OUT/related-cancun.log" 2>&1; check "related cancun" $? "$OUT/related-cancun.log"
"$FORGE" test --match-contract "$M" --evm-version prague > "$OUT/related-prague.log" 2>&1; check "related prague" $? "$OUT/related-prague.log"

if [ "$FAILED" -ne 0 ]; then echo "RESULT: FAILED"; exit 1; fi
echo "RESULT: ALL OK"

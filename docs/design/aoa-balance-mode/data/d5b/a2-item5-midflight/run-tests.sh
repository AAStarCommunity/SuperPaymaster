#!/usr/bin/env bash
# Re-run the A2 item 5 suites (Cancun + Prague) and archive the logs. Run from the repo root.
set -u
FORGE=${FORGE:-$(command -v forge || echo "$HOME/.foundry/bin/forge")}
OUT=docs/design/aoa-balance-mode/data/d5b/a2-item5-midflight/results
mkdir -p "$OUT"
"$FORGE" --version > "$OUT/forge-version.txt"
# the new rc.1 <-> rc.2 suite alone, verbose
"$FORGE" test --match-contract SuperPaymasterRc1Rc2MidBundleTest -vv > "$OUT/rc1rc2-cancun.log" 2>&1; echo "rc1rc2 cancun exit $?"
"$FORGE" test --match-contract SuperPaymasterRc1Rc2MidBundleTest -vv --evm-version prague > "$OUT/rc1rc2-prague.log" 2>&1; echo "rc1rc2 prague exit $?"
# the existing mid-bundle / fee-snapshot suites together with the new one (regression)
M='UpgradeRace|FeeSnapshot|Rc1Rc2MidBundle'
"$FORGE" test --match-contract "$M" > "$OUT/related-cancun.log" 2>&1; echo "related cancun exit $?"
"$FORGE" test --match-contract "$M" --evm-version prague > "$OUT/related-prague.log" 2>&1; echo "related prague exit $?"

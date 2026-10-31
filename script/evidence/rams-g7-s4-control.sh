#!/usr/bin/env bash
# S-4 positive control: with the top fixed sample moved to SETTLE + 1, the success-band assertion must fail.
# Usage: script/evidence/rams-g7-s4-control.sh <out.log>   (clean tree; restores the test file)
set -euo pipefail
LOG=${1:?log}; F=contracts/test/v2/SuperPaymasterV55Fuzz.t.sol
STABLE=${STABLE_FORGE:-$HOME/.foundry/bin/forge}
test -z "$(git status --porcelain)" || { echo "tree not clean" >&2; exit 2; }
FROM='uint256[4] memory d = [uint256(1), 2_000, 10_000, 40_000];'
TO='uint256[4] memory d = [uint256(1), 2_000, 10_000, 1];'
test "$(grep -cF "$FROM" "$F")" = 1
trap 'git checkout -- "$F"' EXIT
{ echo "head $(git rev-parse HEAD)"; "$STABLE" --version | head -1; } > "$LOG"
rc=0; "$STABLE" test --offline --match-test test_G2_noOOGBand_fixed_points_above_settle -vv >> "$LOG" 2>&1 || rc=$?
test "$rc" = 0 || { echo "unmutated run failed" >&2; exit 1; }
python3 -I -c 'import sys;p,a,b=sys.argv[1:];s=open(p).read();assert s.count(a)==1;open(p,"w").write(s.replace(a,b))' "$F" "$FROM" "$TO"
rc=0; "$STABLE" test --offline --match-test test_G2_noOOGBand_fixed_points_above_settle -vv >> "$LOG" 2>&1 || rc=$?
git checkout -- "$F"; trap - EXIT
test "$rc" != 0 && grep -q "FAIL: SETTLE + 40k settles: the success band is sampled" "$LOG" || { echo "control not killed" >&2; exit 1; }
test -z "$(git status --porcelain)"
echo "S-4 control: unmutated PASS; top sample at SETTLE + 1 FAIL on the success-band assertion; restored" | tee -a "$LOG"

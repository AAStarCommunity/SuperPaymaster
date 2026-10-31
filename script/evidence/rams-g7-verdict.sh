#!/usr/bin/env bash
# Judge a rams-g7-rerun.sh output dir: exit 0 only if every run has the expected outcome.
# Usage: script/evidence/rams-g7-verdict.sh <rerun-out-dir>
set -euo pipefail
D=${1:?dir}
fail() { echo "VERDICT FAIL: $*" >&2; exit 1; }
summary() { grep -E "tests passed, [0-9]+ failed" "$D/$1.log" | tail -1; }
fails() { grep -E '^\[FAIL' "$D/$1.log" | grep -oE '\] [A-Za-z0-9_]+\(' | sed 's/^\] //; s/($//' | sort -u; }
grep -qx "restored; tree clean" "$D/exits.txt" || fail "source not restored"
for r in cancun-forge171 prague-forge171; do
  summary $r | grep -qE " 0 failed," || fail "$r: $(summary $r)"
  grep -qx "$r exit 0" "$D/exits.txt" || fail "$r exit code"
done
EXPECTED_AMS="test_G2_coverage_replay_fixed_seeds
test_G2_coverage_replay_floor_params
testFuzz_G2_I8_I9_I10_conservation
testFuzz_G2_floor_params
test_rule_under_all_floor_params
test_settle_floor_keeps_no_oog_band"
[ "$(fails amsterdam)" = "$(sort <<<"$EXPECTED_AMS")" ] || fail "amsterdam failing set differs: $(fails amsterdam | tr '\n' ' ')"
summary amsterdam | grep -qE " 6 failed," || fail "amsterdam: $(summary amsterdam)"
for r in mutation-m1-d5b-cancun mutation-m1-d5b-amsterdam; do
  [ "$(fails $r)" = "test_d5b_forward_mid_bundle_upgrade_with_extension_calls" ] || fail "$r: mutation not killed by the forward test"
  grep -q "forward: no victim postOp fails" "$D/$r.log" || fail "$r: killed by an unexpected assertion"
done
echo "VERDICT PASS: $(summary cancun-forge171 | grep -oE '[0-9]+ tests passed.*') | $(summary prague-forge171 | grep -oE '[0-9]+ tests passed.*') | amsterdam expected 6 | M-1 killed on both engines"

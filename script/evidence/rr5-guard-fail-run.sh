#!/usr/bin/env bash
# RR-5 evidence: run SuperPaymasterRR5GuardFail.t.sol on three engines and two guard mutations, then judge.
# Usage: script/evidence/rr5-guard-fail-run.sh <empty-out-dir>   (clean tree; restores the source)
set -euo pipefail
OUT=${1:?out dir}
[ ! -e "$OUT" ] || [ -z "$(ls -A "$OUT")" ] || { echo "out dir must be empty" >&2; exit 2; }
STABLE=${STABLE_FORGE:-$HOME/.foundry/bin/forge}
AMS=${AMS_FORGE:-$HOME/Dev/aastar/tools/foundry-rams/nightly-4e8874b/forge}
T=contracts/test/v2/SuperPaymasterRR5GuardFail.t.sol
SRC=contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol
test -z "$(git status --porcelain)" || { echo "tree not clean" >&2; exit 2; }
mkdir -p "$OUT"
{ echo "head $(git rev-parse HEAD)"; "$STABLE" --version | head -1; "$AMS" --version | head -1; } > "$OUT/head.txt"
run() { local name=$1 rc=0; shift; "$@" > "$OUT/$name.log" 2>&1 || rc=$?; echo "$name exit $rc" >> "$OUT/exits.txt"; }
run cancun "$STABLE" test --offline --match-path "$T" -vv
run prague "$STABLE" test --offline --match-path "$T" -vv --evm-version prague
run amsterdam "$AMS" test --offline --no-isolate --match-path "$T" -vv --evm-version prague --hardfork amsterdam
# trace of the CREDIT 600k case, to locate the Amsterdam non-guard failure
run amsterdam-credit-600k-trace "$AMS" test --offline --no-isolate --match-path "$T" --match-contract SuperPaymasterRR5GuardCreditTest \
  --match-test test_RR5_snapshot_not_live_bound -vvvv --evm-version prague --hardfork amsterdam
GUARD='if (gasleft() < (snapSettle == 0 ? LEGACY_SETTLE_GAS_BOUND : snapSettle)) revert PostOpGasTooLow();'
test "$(grep -cF "$GUARD" "$SRC")" = 1
trap 'git checkout -- "$SRC"' EXIT
mutate() { python3 -I -c 'import sys;p,a,b=sys.argv[1:];s=open(p).read();assert s.count(a)==1;open(p,"w").write(s.replace(a,b))' "$SRC" "$GUARD" "$1"; }
mutate ''
run mutation-delete-guard "$STABLE" test --offline --match-path "$T" -vv
git checkout -- "$SRC"
mutate 'if (gasleft() < _gasParams.settleGasBound) revert PostOpGasTooLow();'
run mutation-live-bound "$STABLE" test --offline --match-path "$T" -vv
git checkout -- "$SRC"; trap - EXIT
test -z "$(git status --porcelain -- contracts)" && echo "restored; tree clean" >> "$OUT/exits.txt"
fail() { echo "VERDICT FAIL: $*" >&2; exit 1; }
fails() { grep -E '^\[FAIL' "$OUT/$1.log" | grep -oE '\] [A-Za-z0-9_]+\(' | sed 's/^\] //; s/($//' | sort -u; }
for r in cancun prague; do
  grep -qE "10 tests passed, 0 failed, 0 skipped" "$OUT/$r.log" || fail "$r not 10/0/0"
  grep -qx "$r exit 0" "$OUT/exits.txt" || fail "$r exit"
done
# Amsterdam is recorded, not required to pass: a non-guard failure band above the guard is an open finding.
grep -qE "tests passed, [0-9]+ failed" "$OUT/amsterdam.log" || fail "amsterdam produced no summary"
grep -q "scan first settled call gas" "$OUT/amsterdam.log" || fail "amsterdam scan did not run"
# record where the CREDIT 600k frame fails (expected while the finding is open: OOG after settleCredit returns)
python3 -I - "$OUT/amsterdam-credit-600k-trace.log" > "$OUT/amsterdam-credit-600k-location.txt" <<'PYEOF'
import sys
lines = open(sys.argv[1]).read().splitlines()
post = [i for i, l in enumerate(lines) if "SuperPaymaster" in l and "::postOp(" in l]
if not post: sys.exit("no postOp frame in trace")
i = post[-1]; seg = lines[i:i + 40]
ret = next((k for k, l in enumerate(seg) if "settleCredit" in l), None)
oog = next((k for k, l in enumerate(seg) if "[OutOfGas]" in l), None)
print("last postOp frame:", lines[i].split("::postOp(")[0].strip())
print("settleCredit line:", seg[ret].split("::settleCredit(")[0].strip() if ret is not None else None)
print("settleCredit returned:", any("CreditSettled" in l for l in seg))
print("OutOfGas line:", seg[oog].strip() if oog is not None else None)
print("OOG after settleCredit:", ret is not None and oog is not None and oog > ret)
PYEOF
[ -n "$(fails mutation-delete-guard)" ] || fail "deleting the guard was not detected"
fails mutation-live-bound | grep -qx test_RR5_snapshot_not_live_bound || fail "live-bound mutation not killed by the snapshot test"
{ echo "VERDICT PASS (stable engines; Amsterdam recorded)"; for r in cancun prague amsterdam; do echo "$r: $(grep -E 'tests passed' "$OUT/$r.log" | tail -1)"; echo "  $r red: $(fails $r | tr '\n' ' ')"; grep -E 'Ran 1 test for|Ran [0-9]+ tests for|call gas|2k steps' "$OUT/$r.log" | sed "s/^/  $r /"; done
  cat "$OUT/amsterdam-credit-600k-location.txt"; echo "mutation-delete-guard red: $(fails mutation-delete-guard | tr '\n' ' ')"; echo "mutation-live-bound red: $(fails mutation-live-bound | tr '\n' ' ')"; } | tee "$OUT/verdict.txt"

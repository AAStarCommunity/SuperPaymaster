#!/usr/bin/env bash
# Judge a nosubsidy-attribution-run.sh output dir on its content, not only exit codes.
# Usage: script/evidence/nosubsidy-attribution-verdict.sh <run-dir>
set -euo pipefail
D=${1:?dir}
fail() { echo "VERDICT FAIL: $*" >&2; exit 1; }
for r in matrix-cancun matrix-prague matrix-amsterdam matrix-stable-prague matrix-stable-cancun probe-amsterdam probe-prague; do
  grep -qx "$r exit 0" "$D/exits.txt" || fail "$r did not pass"
done
for f in matrix-cancun matrix-prague matrix-amsterdam matrix-stable-prague matrix-stable-cancun; do
  grep -qE "5 tests passed, 0 failed, 0 skipped" "$D/$f.log" || fail "$f: not 5/0/0"
done
python3 -I - "$D" <<'PYEOF' || fail "matrix summary incomplete or stable controls disagree"
import json, re, sys
d = sys.argv[1]
s = json.load(open(f"{d}/matrix-summary.json"))
counts = {k.rsplit("/", 1)[-1]: len(v) for k, v in s.items()}
want = {"matrix-cancun.log": 12, "matrix-prague.log": 12, "matrix-amsterdam.log": 12}
if counts != want: sys.exit(f"frame counts {counts}")
# every postOp frame gas in the stable controls must equal the nightly frame for the same runtime
def frames(path):
    return [int(m) for m in re.findall(r"\[(\d+)\] SuperPaymaster[^\n]*::postOp\(", open(path).read())]
for name in ("matrix-cancun", "matrix-prague", "matrix-amsterdam", "matrix-stable-cancun", "matrix-stable-prague"):
    n = len(frames(f"{d}/{name}.log"))
    if n != 12: sys.exit(f"{name}: {n} SP postOp frames, expected 12")
for rt in ("cancun", "prague"):
    a, b = frames(f"{d}/matrix-{rt}.log"), frames(f"{d}/matrix-stable-{rt}.log")
    if a != b: sys.exit(f"{rt}: nightly {a} vs stable {b}")
PYEOF
# the saved summary must be exactly what analyze.py derives from the saved logs
EV=$(cd "$(dirname "$0")/../.." && pwd)/docs/design/aoa-balance-mode/data/nosubsidy-attribution
( cd "$D" && python3 -I "$EV/analyze.py" matrix-cancun.log matrix-prague.log matrix-amsterdam.log ) > "$D/.summary-recheck.json"
python3 -I - "$D" <<'PYEOF' || { rm -f "$D/.summary-recheck.json"; fail "matrix-summary.json does not match the logs"; }
import json, sys
d = sys.argv[1]
a = json.load(open(f"{d}/matrix-summary.json")); b = json.load(open(f"{d}/.summary-recheck.json"))
key = lambda m: {k.rsplit("/", 1)[-1]: v for k, v in m.items()}
if key(a) != key(b): sys.exit(1)
PYEOF
rm -f "$D/.summary-recheck.json"
for rt in amsterdam prague; do
  grep -qE "emit Checkpoint\(beforeGas: [0-9]+ .*afterGas: [0-9]+" "$D/state-gas-probe-$rt.log" || fail "probe-$rt has no checkpoint"
done
grep -qx "counterexample exit 1" "$D/exits.txt" || fail "counterexample no longer fails"
grep -q "1827511012226570 < 1838299350952020" "$D/counterexample-result.log" || fail "counterexample values changed"
echo "VERDICT PASS: 5 matrix runs 5/0/0; 12 frames per nightly runtime; stable frames equal nightly; probe checkpoints present; counterexample reproduces exactly"

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
for rt in ("cancun", "prague"):
    a, b = frames(f"{d}/matrix-{rt}.log"), frames(f"{d}/matrix-stable-{rt}.log")
    if len(a) != 12 or a != b: sys.exit(f"{rt}: nightly {a} vs stable {b}")
PYEOF
for rt in amsterdam prague; do
  grep -qE "emit Checkpoint\(beforeGas: [0-9]+ .*afterGas: [0-9]+" "$D/state-gas-probe-$rt.log" || fail "probe-$rt has no checkpoint"
done
grep -qx "counterexample exit 1" "$D/exits.txt" || fail "counterexample no longer fails"
grep -q "1827511012226570 < 1838299350952020" "$D/counterexample-result.log" || fail "counterexample values changed"
echo "VERDICT PASS: 5 matrix runs 5/0/0; 12 frames per nightly runtime; stable frames equal nightly; probe checkpoints present; counterexample reproduces exactly"

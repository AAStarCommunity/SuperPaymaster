#!/usr/bin/env bash
# Rerun the vendored M3 reproduction kit from a clean committed HEAD, outside the work tree.
# Usage: script/evidence/m3-reproduction-run.sh <out-dir> [python ...]
# For each interpreter: manifest check, unit tests, self-test, generate stat_results, same-engine
# self-compare, and compare against DSR's published reference (only pythonVersion may differ).
set -euo pipefail
OUT=${1:?out dir}; shift; PYS=("${@:-python3}")
test -z "$(git status --porcelain)" || { echo "tree not clean" >&2; exit 2; }
[ ! -e "$OUT" ] || [ -z "$(ls -A "$OUT")" ] || { echo "out dir must be empty" >&2; exit 2; }
KIT=script/a6-collector/reproduction
REF_PATH=script/a6-collector/reproduction-results/dsr-0b030b54-stat_results.json
SHA=$(git rev-parse HEAD)
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
echo "head $SHA" > "$OUT/head.txt"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# Kit and reference both come from the same captured commit, never from the work tree.
git archive "$SHA" "$KIT" "$REF_PATH" | tar -x -C "$WORK"
REF="$WORK/$REF_PATH"
# Acceptance predicate, shared by every interpreter and by the control below.
cat > "$WORK/accept.py" <<'PYEOF'
import json, os, re, sys
self_path, log_path, out_path, code, label = sys.argv[1:6]
# explicit checks, not assert: they must hold under PYTHONOPTIMIZE too
self_c = json.load(open(self_path))["statResultsComparison"]
if not (self_c["match"] and not self_c["mismatches"]): sys.exit(f"self-compare failed: {self_c}")
log = open(log_path).read()
if code == "0":
    c = json.load(open(out_path))["statResultsComparison"]
    if not (c["match"] and not c["mismatches"]): sys.exit(f"vs-dsr failed: {c}")
    print(f"{label}: self-compare {self_c['checkedFields']} fields; vs DSR reference exact ({c['checkedFields']} fields)")
else:
    if code != "1": sys.exit(f"{label}: compare exited {code}, not the comparison-failure exit 1")
    if os.path.exists(out_path): sys.exit("a failed compare must not leave a report")
    # the whole log must be exactly one comparison error naming only pythonVersion
    try:
        payload = json.loads(log)
    except ValueError:
        sys.exit(f"{label}: compare log is not a single JSON payload")
    m = re.fullmatch(r"stat_results comparison failed: (\[.*\])", (payload.get("errors") or [""])[0]) if isinstance(payload, dict) else None
    diffs = json.loads(m.group(1)) if m else None
    ok = (set(payload) == {"status", "errors"} and payload["status"] == "FAIL" and len(payload["errors"]) == 1
          and isinstance(diffs, list) and len(diffs) == 1
          and re.fullmatch(r"root\.statisticalConfig\.pythonVersion: computed='[0-9.]+' != external='[0-9.]+'", diffs[0]))
    if not ok: sys.exit(f"{label}: vs-dsr differs beyond pythonVersion: {log[-2000:]}")
    print(f"{label}: self-compare {self_c['checkedFields']} fields; vs DSR reference differs only in pythonVersion")
PYEOF
cd "$WORK/$KIT"
for PY in "${PYS[@]}"; do
  V=$("$PY" -c 'import platform;print(platform.python_version())'); D="$OUT/py$V"; mkdir -p "$D"
  "$PY" -I -c '
import hashlib, json, os, sys
m = json.load(open("MANIFEST.json"))["files"]
have = {os.path.relpath(os.path.join(r, f)) for r, _, fs in os.walk(".") for f in fs} - {"MANIFEST.json"}
bad = [f for f, h in m.items() if hashlib.sha256(open(f, "rb").read()).hexdigest() != h]
if bad or have != set(m): sys.exit(f"manifest mismatch: bad={bad} extra={sorted(have - set(m))} missing={sorted(set(m) - have)}")
print(f"manifest ok: {len(m)} files")' > "$D/manifest.log" 2>&1
  "$PY" -B -m unittest -v scripts/test_aoa_m3_stats.py scripts/test_gate_stats_from_csv.py > "$D/unittest.log" 2>&1
  "$PY" -B scripts/aoa_m3_selftest.py > "$D/selftest.log" 2>&1
  "$PY" -B scripts/gate/stats_from_csv.py --m3-package data/receive.json \
    --json-out "$D/stat_results.json" --latex-out "$D/tables.tex" > "$D/generate.log" 2>&1
  "$PY" -B scripts/gate/stats_from_csv.py --m3-package data/receive.json \
    --compare-stat-results "$D/stat_results.json" --json-out "$D/self-compare.json" > "$D/self-compare.log" 2>&1
  rc=0
  "$PY" -B scripts/gate/stats_from_csv.py --m3-package data/receive.json \
    --compare-stat-results "$REF" --json-out "$D/vs-dsr.json" > "$D/vs-dsr.log" 2>&1 || rc=$?
  echo "vs-dsr exit $rc" > "$D/vs-dsr.exit"
  "$PY" -I "$WORK/accept.py" "$D/self-compare.json" "$D/vs-dsr.log" "$D/vs-dsr.json" "$rc" "py$V"
done | tee "$OUT/summary.txt"
# Control: a one-digit change in the reference must be reported next to (not hidden by) a version difference.
PY=${PYS[0]}; C="$OUT/control-tampered-reference"; mkdir -p "$C"
"$PY" -I - "$REF" "$C/ref.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
m = d["arms"]["SP"]["actualGasUsed"]
m["meanExact"] = m["meanExact"][:-1] + ("1" if m["meanExact"][-1] != "1" else "2")
d["statisticalConfig"]["pythonVersion"] = "0.0.0"
json.dump(d, open(sys.argv[2], "w"))
PYEOF
code=0
"$PY" -B scripts/gate/stats_from_csv.py --m3-package data/receive.json \
  --compare-stat-results "$C/ref.json" --json-out "$C/out.json" > "$C/compare.log" 2>&1 || code=$?
test "$code" -ne 0
grep -q 'root.arms.SP.actualGasUsed.meanExact:' "$C/compare.log"
grep -q 'root.statisticalConfig.pythonVersion:' "$C/compare.log"
# ...and the acceptance predicate itself must refuse that compare.
V0=$("$PY" -c 'import platform;print(platform.python_version())')
prc=0
"$PY" -I "$WORK/accept.py" "$OUT/py$V0/self-compare.json" "$C/compare.log" "$C/out.json" "$code" control > "$C/accept.log" 2>&1 || prc=$?
test "$prc" -ne 0
grep -q 'differs beyond pythonVersion' "$C/accept.log"
echo "control: tampered reference rejected by the compare (exit $code) and by the acceptance predicate (exit $prc)" | tee -a "$OUT/summary.txt"
(cd "$OUT" && find . -type f ! -name SHA256SUMS | sort | xargs shasum -a 256 > SHA256SUMS)

#!/usr/bin/env bash
# Rerun the vendored M3 reproduction kit from a clean committed HEAD, outside the work tree.
# Usage: script/evidence/m3-reproduction-run.sh <out-dir> [python ...]
# For each interpreter: manifest check, unit tests, self-test, generate stat_results, same-engine
# self-compare, and compare against DSR's published reference (only pythonVersion may differ).
set -euo pipefail
OUT=${1:?out dir}; shift; PYS=("${@:-python3}")
test -z "$(git status --porcelain)" || { echo "tree not clean" >&2; exit 2; }
KIT=script/a6-collector/reproduction
REF=$(pwd)/script/a6-collector/reproduction-results/dsr-0b030b54-stat_results.json
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
echo "head $(git rev-parse HEAD)" > "$OUT/head.txt"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
git archive HEAD "$KIT" | tar -x -C "$WORK"
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
  set +e
  "$PY" -B scripts/gate/stats_from_csv.py --m3-package data/receive.json \
    --compare-stat-results "$REF" --json-out "$D/vs-dsr.json" > "$D/vs-dsr.log" 2>&1
  echo "vs-dsr exit $?" > "$D/vs-dsr.exit"; set -e
  "$PY" -I - "$D" "$V" <<'PYEOF'
import json, re, sys
d, v = sys.argv[1], sys.argv[2]
self_c = json.load(open(f"{d}/self-compare.json"))["statResultsComparison"]
assert self_c["match"] and not self_c["mismatches"], self_c
log = open(f"{d}/vs-dsr.log").read()
code = open(f"{d}/vs-dsr.exit").read().split()[-1]
if code == "0":
    c = json.load(open(f"{d}/vs-dsr.json"))["statResultsComparison"]
    assert c["match"] and not c["mismatches"], c
    print(f"py{v}: self-compare {self_c['checkedFields']} fields; vs DSR reference exact ({c['checkedFields']} fields)")
else:
    diffs = re.findall(r"root\.[^:]+:", log)
    assert diffs == ["root.statisticalConfig.pythonVersion:"], log[-2000:]
    print(f"py{v}: self-compare {self_c['checkedFields']} fields; vs DSR reference differs only in pythonVersion")
PYEOF
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
set +e
"$PY" -B scripts/gate/stats_from_csv.py --m3-package data/receive.json \
  --compare-stat-results "$C/ref.json" --json-out "$C/out.json" > "$C/compare.log" 2>&1
code=$?; set -e
test "$code" -ne 0
grep -q 'root.arms.SP.actualGasUsed.meanExact:' "$C/compare.log"
grep -q 'root.statisticalConfig.pythonVersion:' "$C/compare.log"
echo "control: tampered reference rejected (exit $code), numeric and version mismatches both listed" | tee -a "$OUT/summary.txt"
(cd "$OUT" && find . -type f ! -name SHA256SUMS | sort | xargs shasum -a 256 > SHA256SUMS)

#!/usr/bin/env bash
# Workbench path for CC-127 (AOA-SP-02): archived collector run -> to-aoa-m3-receive.mjs -> DSR's checker.
#
#   script/a6-collector/aoa-m3-receive-controls.sh <path/to/DSR/scripts/aoa_m3_check.py> <out-dir>
#
# Inputs are the archived local-anvil runs (rehearsal data, not A6). Exports positive and n50, runs the DSR checker
# on them and on the archived failure fixtures, then on tampered copies of the n50 package. Writes
# <out-dir>/results.tsv (control, expected, observed status, first error) and exits non-zero if any row differs
# from its expectation. Tampering edits a copy; the exported originals are untouched.
set -euo pipefail
CHECK=${1:?path to aoa_m3_check.py}; OUT=${2:?out dir}
HERE=$(cd "$(dirname "$0")" && pwd); DATA="$HERE/../../docs/design/aoa-balance-mode/data/a6-gauge-local"
[ ! -e "$OUT" ] || [ -z "$(ls -A "$OUT")" ] || { echo "out dir not empty: $OUT" >&2; exit 2; }
mkdir -p "$OUT"
TSV="$OUT/results.tsv"; printf 'control\texpected\tobserved\tfirst_error\n' > "$TSV"
bad=0
row() { # control expected receive.json expected-groups
  local res status err
  res=$(python3 "$CHECK" "$3" --expected "$4" 2>/dev/null || true)
  status=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$res")
  err=$(python3 -c 'import json,sys;e=json.loads(sys.argv[1])["errors"];print(e[0] if e else "")' "$res")
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$status" "$err" >> "$TSV"
  [ "$status" = "$2" ] || bad=1
}
for run in positive n50-mechanism a-exec-revert b-drop-op c-wrong-hash; do
  node "$HERE/to-aoa-m3-receive.mjs" "$DATA/$run.jsonl" "$OUT/$run" > "$OUT/$run.export.log"
done
row positive OFFLINE_STRUCTURE_PASS "$OUT/positive/receive.json" 1
row n50-mechanism OFFLINE_STRUCTURE_PASS "$OUT/n50-mechanism/receive.json" 50
for f in a-exec-revert b-drop-op c-wrong-hash; do row "$f" FAIL "$OUT/$f/receive.json" 1; done
# d-tamper-b stopped before read-back: the exporter itself must refuse it.
if node "$HERE/to-aoa-m3-receive.mjs" "$DATA/d-tamper-b.jsonl" "$OUT/d-tamper-b" > "$OUT/d-tamper-b.export.log" 2>&1; then
  printf 'd-tamper-b\tEXPORT_REFUSED\tEXPORTED\t\n' >> "$TSV"; bad=1
else
  printf 'd-tamper-b\tEXPORT_REFUSED\tEXPORT_REFUSED\t%s\n' "$(tail -1 "$OUT/d-tamper-b.export.log")" >> "$TSV"
fi
# Tampered copies of the n50 package.
tamper() { # name python-edit
  rm -rf "$OUT/t-$1"; cp -R "$OUT/n50-mechanism" "$OUT/t-$1"
  python3 - "$OUT/t-$1" <<EOF
import json, sys, pathlib
root = pathlib.Path(sys.argv[1]); p = root / 'receive.json'; pkg = json.loads(p.read_text())
inc = [a for a in pkg['attempts'] if a['included']]
$2
p.write_text(json.dumps(pkg, indent=1) + '\n')
EOF
  row "t-$1" FAIL "$OUT/t-$1/receive.json" 50
}
tamper raw-file-edited "f = root / inc[0]['uoeFile']; f.write_text(f.read_text().replace('true', 'false'))"
tamper uoe-deleted "(root / inc[0]['uoeFile']).unlink()"
tamper duplicate-userop "dup = dict(inc[0]); dup['attemptId'] += '/dup'; pkg['attempts'].append(dup)"
tamper chain-changed "inc[0]['chainId'] = 1"
tamper arm-missing "pkg['attempts'].remove(inc[0])"
tamper injected-in-typical "inc[0]['injectedScenario'] = 'postop-revert'"
tamper settlement-unverified "inc[0]['settlementVerified'] = False"
cat "$TSV"
exit $bad

#!/usr/bin/env bash
# Workbench path for CC-127 (AOA-SP-02): archived collector run -> to-aoa-m3-receive.mjs -> DSR's checker.
#
#   script/a6-collector/aoa-m3-receive-controls.sh <path/to/DSR/scripts/aoa_m3_check.py> <out-dir>
#
# Inputs are the archived local-anvil runs (rehearsal data, not A6). Exports positive and n50, runs the DSR checker
# on them and on the archived failure fixtures, then on tampered copies of the n50 package. Writes
# <out-dir>/results.tsv (control, expected, observed status, first error) and exits non-zero unless every row has
# the expected status AND, for a negative control, the expected diagnostic among the checker's errors (a positive
# control must have none). Tampering edits a copy; the exported originals are untouched.
set -euo pipefail
CHECK=${1:?path to aoa_m3_check.py}; OUT=${2:?out dir}
HERE=$(cd "$(dirname "$0")" && pwd); DATA="$HERE/../../docs/design/aoa-balance-mode/data/a6-gauge-local"
[ ! -e "$OUT" ] || [ -z "$(ls -A "$OUT")" ] || { echo "out dir not empty: $OUT" >&2; exit 2; }
mkdir -p "$OUT"
TSV="$OUT/results.tsv"; printf 'control\texpected\tobserved\tfirst_error\n' > "$TSV"
bad=0
ERRDIR=$(mktemp -d); trap 'rm -rf "$ERRDIR"' EXIT  # checker stderr captures; removed on any exit

verdict() { # checker-json required-diagnostic -> "diagnostic-ok<TAB>status<TAB>first-error"
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1]); errs = d.get("errors", []); status = d["status"]
except Exception:  # no or garbled verdict: record the row as failed instead of aborting the whole run
    print(False, "NO_JSON", "", sep="\t"); sys.exit(0)
want = sys.argv[2]
ok = any(want in e for e in errs) if want else not errs
print(ok, status, errs[0] if errs else "", sep="\t")  # first-error last: may be empty
PY
}

row() { # control expected-status receive.json expected-groups required-diagnostic ("" = none)
  local res status err ok
  # The checker exits 0 for a pass and 1 for FAIL. An uncaught Python exception also exits 1, so exit code alone
  # cannot tell FAIL from a crash: a traceback on stderr, or any code other than 0/1, marks the row a crash.
  local code=0 errf="$ERRDIR/stderr"
  res=$(python3 "$CHECK" "$3" --expected "$4" 2>"$errf") || code=$?
  IFS=$'\t' read -r ok status err < <(verdict "$res" "$5")
  if [ "$code" -gt 1 ]; then ok=False; status="CHECKER_EXIT_$code"; fi
  # Any traceback form, including "+ Exception Group Traceback (most recent call last)".
  if grep -q 'Traceback (most recent call last)' "$errf"; then ok=False; status="CHECKER_CRASH"; fi
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$status" "$err" >> "$TSV"
  if [ "$status" != "$2" ] || [ "$ok" != True ]; then
    echo "control $1: status $status (want $2), diagnostic '$5' present=$ok" >&2; bad=1
  fi
}

for run in positive n50-mechanism a-exec-revert b-drop-op c-wrong-hash; do
  node "$HERE/to-aoa-m3-receive.mjs" "$DATA/$run.jsonl" "$OUT/$run" > "$OUT/$run.export.log"
done
row positive OFFLINE_STRUCTURE_PASS "$OUT/positive/receive.json" 1 ""
row n50-mechanism OFFLINE_STRUCTURE_PASS "$OUT/n50-mechanism/receive.json" 50 ""
for f in a-exec-revert b-drop-op c-wrong-hash; do
  row "$f" FAIL "$OUT/$f/receive.json" 1 "expected 1 matched groups, found 0"
done

# d-tamper-b stopped before read-back: the exporter itself must refuse it, for that reason.
if node "$HERE/to-aoa-m3-receive.mjs" "$DATA/d-tamper-b.jsonl" "$OUT/d-tamper-b" > "$OUT/d-tamper-b.export.log" 2>&1; then
  printf 'd-tamper-b\tEXPORT_REFUSED\tEXPORTED\t\n' >> "$TSV"; bad=1
else
  msg=$(tail -1 "$OUT/d-tamper-b.export.log")
  printf 'd-tamper-b\tEXPORT_REFUSED\tEXPORT_REFUSED\t%s\n' "$msg" >> "$TSV"
  if [[ "$msg" != *"no start/end passport"* ]]; then echo "control d-tamper-b: unexpected refusal: $msg" >&2; bad=1; fi
fi

tamper() { # name required-diagnostic edit-file
  rm -rf "$OUT/t-$1"; cp -R "$OUT/n50-mechanism" "$OUT/t-$1"
  python3 "$HERE/aoa-m3-tamper.py" "$OUT/t-$1" "$1"
  row "t-$1" FAIL "$OUT/t-$1/receive.json" 50 "$2"
}
tamper raw-file-edited "hash mismatch: "
tamper uoe-deleted "missing archive: "
tamper duplicate-userop "duplicate UserOp identity"
tamper chain-changed "mismatched chainId"
tamper arm-missing "require exactly one SP/VPM/TPM"
tamper injected-in-typical "injected sample in typical group"
tamper settlement-unverified "settlement/state not verified"
tamper bundler-config-differs "mismatched bundlerConfigHash"
cat "$TSV"
exit $bad

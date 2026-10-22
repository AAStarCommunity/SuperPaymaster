#!/usr/bin/env bash
# R-AMS-2: copy an ams-g1-run.sh work dir into amsterdam/<variant>/ (as g1-collect.sh does for cases/),
# run the §3.4 access check on the captured traces, and tabulate the gas probe (ams-report.mjs).
# Usage: G1_DEPLOY_JSON=docs/.../amsterdam/<variant>/deploy.json script/b-layer/ams-g1-collect.sh <workDir> <a|b>
set -euo pipefail
W="$1"; V="$2"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
C="$ROOT/docs/design/aoa-balance-mode/b-layer/amsterdam/$V"
mkdir -p "$C"
read -r -a LABELS <<< "${G1_BUNDLERS:-rundler alto altoMulti}"
TRACE_ARGS=(); PAIRS=()
for l in "${LABELS[@]}"; do
  gzip -9 -c "$W/$l-traces.jsonl" > "$C/$l-traces.jsonl.gz"
  cp "$W/$l-results.json" "$C/$l-results.json"
  sed 's/\x1b\[[0-9;]*m//g' "$W/$l-cases.log" | grep -v "Terminated" > "$C/$l-cases.log" || true
  for t in "$W/$l-traces.jsonl".tracer-*.js; do [ -e "$t" ] && cp "$t" "$C/$l-bundler-tracer-$(basename "$t" | sed 's/.*tracer-//')"; done
  TRACE_ARGS+=("$W/$l-traces.jsonl"); PAIRS+=("$l=$W/$l-traces.jsonl")
done
[ -f "$W/rundler.log" ] && sed 's/\x1b\[[0-9;]*m//g' "$W/rundler.log" | grep -E "INFO|WARN|ERROR" | grep -v "received new head" > "$C/rundler-events.log" || true
for l in "${LABELS[@]}"; do [ "$l" = rundler ] && continue
  sed 's/\x1b\[[0-9;]*m//g' "$W/$l.log" | grep -E '"(message|shortMessage)": "' | grep -v "custom error 0x091cd005" | sort | uniq -c > "$C/$l-errors.log" || true
done
sed 's/\x1b\[[0-9;]*m//g' "$W/deploy.log" > "$C/deploy.log"
cp "$W/deploy-receipts.json" "$C/deploy-receipts.json"; cp "$W/receipts.log" "$C/receipts.log"
cp "$W/setup.log" "$C/setup.log"; cp "$W/calibration.json" "$C/calibration.json"; cp "$W/versions.txt" "$C/versions.txt"
if [ -f "$W/gasparams.log" ]; then cp "$W/gasparams.log" "$C/gasparams.log"; fi
node "$ROOT/script/b-layer/access-check.mjs" "$C/setup.json" "$C/access-check.json" "${TRACE_ARGS[@]}" > "$C/access-check.txt" 2>&1 || echo "access-check exited $?" >> "$C/access-check.txt"
node "$ROOT/script/b-layer/g1-op070.mjs" "$C/setup.json" "$C/b8-op070.json" "${PAIRS[@]}" >/dev/null 2>&1 || echo "g1-op070 failed" >&2
node "$ROOT/script/b-layer/ams-report.mjs" "$W" "$C/matrix.md" "$C/matrix.json"
# the full Rundler / Alto process logs; anything above 5 MB is committed gzipped
for l in "${LABELS[@]}"; do sed 's/\x1b\[[0-9;]*m//g' "$W/$l.log" > "$C/$l-bundler.log"; done
for f in "$C"/*.log "$C"/*.json; do
  if [ "$(stat -c %s "$f")" -gt 5242880 ]; then gzip -9 -f "$f"; fi
done

ls -la "$C"

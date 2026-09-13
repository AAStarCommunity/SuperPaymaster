#!/usr/bin/env bash
# D5 gate G1 — copy a g1-run.sh work dir into the committed evidence folder (compressed traces,
# raw bundler responses, the bundler tracers as captured, key log lines) and run the §3.4 check.
# Usage: script/b-layer/g1-collect.sh <workDir>
set -euo pipefail
W="$1"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
C="$ROOT/docs/design/aoa-balance-mode/b-layer/cases"
mkdir -p "$C"
LABELS=(rundler alto altoMulti)
TRACE_ARGS=(); PAIRS=()
for l in "${LABELS[@]}"; do
  gzip -9 -c "$W/$l-traces.jsonl" > "$C/$l-traces.jsonl.gz"
  cp "$W/$l-results.json" "$C/$l-results.json"
  sed 's/\x1b\[[0-9;]*m//g' "$W/$l-cases.log" | grep -v "Terminated" > "$C/$l-cases.log" || true
  for t in "$W/$l-traces.jsonl".tracer-*.js; do cp "$t" "$C/$l-bundler-tracer-$(basename "$t" | sed 's/.*tracer-//')"; done
  TRACE_ARGS+=("$W/$l-traces.jsonl"); PAIRS+=("$l=$W/$l-traces.jsonl")
done
# Rundler: its INFO events (bundle composition, rejections, entity removal) — no ANSI
sed 's/\x1b\[[0-9;]*m//g' "$W/rundler.log" | grep -E "INFO|WARN|ERROR" | grep -v "received new head" > "$C/rundler-events.log" || true
# Alto: the error messages it returned / logged (its full JSON log is several MB)
for l in alto altoMulti; do
  sed 's/\x1b\[[0-9;]*m//g' "$W/$l.log" | grep -E '"message": "' | grep -v "custom error 0x091cd005" | sort | uniq -c > "$C/$l-errors.log" || true
done
tail -40 "$W/deploy.log" > "$C/deploy.log"
cp "$W/setup.log" "$C/setup.log"
node "$ROOT/script/b-layer/access-check.mjs" "$C/setup.json" "$C/access-check.json" "${TRACE_ARGS[@]}" --control | tee "$C/access-check.txt"
node "$ROOT/script/b-layer/g1-op070.mjs" "$C/setup.json" "$C/b8-op070.json" "${PAIRS[@]}" >/dev/null
ls -la "$C"

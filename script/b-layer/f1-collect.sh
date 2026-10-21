#!/usr/bin/env bash
# F1 — copy an f1-run.sh work dir into docs/design/aoa-balance-mode/b-layer/cases/f1/ and run the
# analyses (account-frame §2.3 check on the guarded runs; TokenPaymaster access pattern).
# Usage: script/b-layer/f1-collect.sh <workDir>
set -euo pipefail
W="$1"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
C="$ROOT/docs/design/aoa-balance-mode/b-layer/cases/f1"
mkdir -p "$C"
LABELS=(rundler-tpm alto-tpm rundler-gSig alto-gSig rundler-gRev alto-gRev rundler-sp3 alto-sp3 rundlerSSMC1-sp3 rundlerSSMC1-tpm)
for l in "${LABELS[@]}"; do
  gzip -9 -c "$W/$l-traces.jsonl" > "$C/$l-traces.jsonl.gz"
  cp "$W/$l-results.json" "$C/$l-results.json"
  sed 's/\x1b\[[0-9;]*m//g' "$W/$l-cases.log" > "$C/$l-cases.log"
  case "$l" in
    rundler*) sed 's/\x1b\[[0-9;]*m//g' "$W/$l.log" | grep -E "INFO|WARN|ERROR" | grep -v "received new head" > "$C/$l-events.log" || true ;;
    alto*) sed 's/\x1b\[[0-9;]*m//g' "$W/$l.log" | grep -E '"message": "' | grep -v "custom error 0x091cd005" | sort | uniq -c > "$C/$l-errors.log" || true ;;
  esac
done
cp "$W/f1-setup.log" "$C/f1-setup.log"
tail -20 "$W/deploy.log" > "$C/deploy.log"
# §2.3 row "account (unstaked)" check on the guarded-account runs (+ positive control on G1's traces is in cases/)
ACCESS_LABELS='^g(Sig|Rev)' node "$ROOT/script/b-layer/access-check.mjs" "$C/setup.json" "$C/access-check-guard.json" \
  "$W/rundler-gSig-traces.jsonl" "$W/rundler-gRev-traces.jsonl" "$W/alto-gSig-traces.jsonl" "$W/alto-gRev-traces.jsonl" | tee "$C/access-check-guard.txt"
node "$ROOT/script/b-layer/f1-analyze.mjs" "$C/setup.json" "$C/tpm-access.json" '^tpm' \
  "$W/rundler-tpm-traces.jsonl" "$W/alto-tpm-traces.jsonl" | tee "$C/tpm-access.txt"
PAIRS=(); for l in "${LABELS[@]}"; do PAIRS+=("$l=$W/$l-traces.jsonl"); done
node "$ROOT/script/b-layer/f1-joint.mjs" "$C/joint-handleops.json" "${PAIRS[@]}" | tee "$C/joint-handleops.txt"
ls -la "$C"

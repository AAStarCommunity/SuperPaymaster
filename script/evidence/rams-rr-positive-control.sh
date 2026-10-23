#!/usr/bin/env bash
# R2-F3 positive control runner. Read-only; the archive URL comes from RPC_FILE and is never printed.
# Usage: RPC_FILE=... NIGHTLY_ANVIL=... ANVIL_186=... ANVIL_171=... bash script/evidence/rams-rr-positive-control.sh
set -euo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/../.."
: "${RPC_FILE:?}" "${NIGHTLY_ANVIL:?}" "${ANVIL_186:?}" "${ANVIL_171:?}"
FROM="${FROM:-11974600}"; TO="${TO:-11975000}"
OUT="${OUT_DIR:-docs/design/aoa-balance-mode/data/rams-rr}"
mkdir -p "$OUT"
redact() { sed -E 's#(https?|wss?)://[^[:space:]"]*#<redacted>#g'; }
{
  printf 'R2-F3 RR positive control UTC: %s\nCommit: %s\nDirty paths: %s\nRange: [%s, %s)\n' \
    "$(date -u +%FT%TZ)" "$(git rev-parse HEAD)" "$(git status --porcelain -- script | wc -l | tr -d ' ')" "$FROM" "$TO"
  python3 script/evidence/rams-rr-scan.py "$FROM" "$TO" "$OUT/scan.json" 10
  # bash 3.2 (macOS) has no mapfile; tx hashes contain no whitespace.
  TX=( $(python3 -c "import json;print(' '.join(json.load(open('$OUT/scan.json'))['picked']))") )
  HF=amsterdam python3 script/evidence/rams-rr-replay.py "$NIGHTLY_ANVIL" "$OUT/replay-nightly-926eb1d.json" "${TX[@]}"
  HF=amsterdam python3 script/evidence/rams-rr-replay.py "$ANVIL_186" "$OUT/replay-v1.8.6.json" "${TX[@]}"
  # Instrument control: a pre-Amsterdam engine must NOT reproduce RR gasUsed.
  HF=prague python3 script/evidence/rams-rr-replay.py "$ANVIL_171" "$OUT/replay-v1.7.1-prague.json" "${TX[@]:0:3}"
} 2>&1 | redact | tee "$OUT/run.log"

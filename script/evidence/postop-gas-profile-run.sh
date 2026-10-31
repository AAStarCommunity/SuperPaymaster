#!/usr/bin/env bash
set -euo pipefail
OUT=${1:?Usage: postop-gas-profile-run.sh EMPTY_OUT_DIR}
if [[ -e "$OUT" && -n "$(ls -A "$OUT")" ]]; then echo 'Output directory must be empty' >&2; exit 2; fi
mkdir -p "$OUT"
if ! python3 script/evidence/postop-gas-profile-run.py "$OUT"; then
  echo 'VERDICT FAIL: command, test count, or measurement check failed' | tee "$OUT/verdict.txt"
  exit 1
fi
python3 script/evidence/postop-gas-profile-verify.py "$OUT"

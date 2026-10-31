#!/usr/bin/env bash
set -euo pipefail
python3 script/evidence/postop-multiop-run.py "${1:?Usage: postop-multiop-run.sh EMPTY_OUT_DIR}"
python3 contracts/test/postop_multiop_evidence_test.py "$1"

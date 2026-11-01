#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 script/evidence/tuple-validation-run.py "$@"

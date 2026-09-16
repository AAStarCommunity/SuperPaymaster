#!/usr/bin/env bash
# D5c-1 — negative / positive controls for the verdict authority (see verify-selftest.py for the
# list). usage (repo root): script/halmos/verify-selftest.sh [--no-real]
# The archived log (docs/design/aoa-balance-mode/data/halmos/verify-selftest.log) is itself a
# mandatory verify item: it must be the output of THESE scripts (sha256 in its first line).
exec python3 script/halmos/verify-selftest.py "$@"

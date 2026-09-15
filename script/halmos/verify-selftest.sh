#!/usr/bin/env bash
# D5c-1 — negative / positive controls for the verification runners (see verify-selftest.py for the
# list: P1-P3, N1-N19, O1-O2). usage (repo root): script/halmos/verify-selftest.sh [--no-real]
exec python3 script/halmos/verify-selftest.py "$@"

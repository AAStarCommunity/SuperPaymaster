#!/usr/bin/env bash
# D5c-1 — one group at a time (see run-all-d5c1.sh for the groups and the fixed Halmos profiles),
# or `verify`: no Halmos run, only the verdict over the existing evidence (D5C1_ROOT / D5C1_EXPECT /
# D5C1_TREE_ROOT / D5C1_REQUIRED environment overrides are honoured; used by verify-selftest.py).
# usage (repo root): script/halmos/run-step-d5c1.sh <group|verify> [jobs]
# Exit code: 0 only if every child ran and verify-d5c1.py reports every expectation met.
set -uo pipefail
G="$1"; J="${2:-6}"
H="$(cd "$(dirname "$0")" && pwd)"
if [ "$G" = verify ]; then
  if [ -n "${D5C1_FILTER:-}" ]; then python3 "$H/verify-d5c1.py" --filter "$D5C1_FILTER"; else python3 "$H/verify-d5c1.py"; fi
  V=$?
  echo "STEP-DONE verify (verify rc=$V)"
  exit $V
fi
"$H/run-all-d5c1.sh" "$G" "$J"

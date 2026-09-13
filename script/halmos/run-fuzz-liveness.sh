#!/usr/bin/env bash
# D5c-1 — liveness of the fuzz substitutes (D5c1BoundedFuzz.t.sol). Positive control first: the
# UNMUTATED suite must be all green (>= 10,000 runs each). Then, under each mutation, the named fuzz
# test(s) must go red, and the source must be restored to its pristine sha256. Run in a scratch copy.
# usage: script/halmos/run-fuzz-liveness.sh <out_dir>
# Exit code: that of verify-d5c1.py --only fuzz (0 iff all of the above hold), or 3 on a failed revert.
set -uo pipefail
o="$1"; mkdir -p "$o"
F="$HOME/.foundry/bin/forge"
"$F" test --match-path contracts/test/halmos/D5c1BoundedFuzz.t.sol > "$o/fuzz-bounded-partitions.log" 2>&1
echo "== unmutated: $(grep -E 'Suite result' "$o/fuzz-bounded-partitions.log" | tail -1)"
for m in M-I2 M-PULL M-BURNALL; do
  python3 script/halmos/d5c1-mutations.py apply "$m" > "$o/$m.apply.txt" || { echo "APPLY-FAILED $m"; exit 3; }
  cp "cache/d5c1-mutations/$m.diff" "$o/"
  "$F" test --match-path contracts/test/halmos/D5c1BoundedFuzz.t.sol > "$o/$m.fuzz.log" 2>&1
  python3 script/halmos/d5c1-mutations.py revert "$m" >> "$o/$m.fuzz.log" || { echo "REVERT-FAILED $m"; exit 3; }
  echo "== $m"; grep -E "^\[(PASS|FAIL)" "$o/$m.fuzz.log" | cut -c1-110 | sort -u
done
python3 script/halmos/verify-d5c1.py --only fuzz --fuzz-dir "$o"

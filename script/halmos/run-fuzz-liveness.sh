#!/usr/bin/env bash
# D5c-1 — liveness of the fuzz substitutes (D5c1BoundedFuzz.t.sol): under each mutation the fuzz
# suite must go red on the targeted function. Run in a scratch copy of the tree.
# usage: script/halmos/run-fuzz-liveness.sh <out_dir>
set -uo pipefail
o="$1"; mkdir -p "$o"
for m in M-I2 M-PULL M-BURNALL; do
  python3 script/halmos/d5c1-mutations.py apply "$m" > "$o/$m.apply.txt"
  cp "cache/d5c1-mutations/$m.diff" "$o/"
  "$HOME/.foundry/bin/forge" test --match-path contracts/test/halmos/D5c1BoundedFuzz.t.sol > "$o/$m.fuzz.log" 2>&1
  python3 script/halmos/d5c1-mutations.py revert "$m" >> "$o/$m.fuzz.log"
  echo "== $m"; grep -E "^\[(PASS|FAIL)" "$o/$m.fuzz.log" | cut -c1-110 | sort -u
done

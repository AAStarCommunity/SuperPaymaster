#!/usr/bin/env bash
# D5c-1 — liveness of the fuzz substitutes (D5c1BoundedFuzz.t.sol; MintRepayLemmaFuzzTest for lemma M). Positive control first: the
# UNMUTATED suite must be all green (>= 10,000 runs each). Then, under each mutation, the named fuzz
# test(s) must go red, and the source must be restored to its pristine sha256.
# Run in the git checkout (the unmutated run must be bound to a clean tree: dirty_src == 0) and only
# when no Halmos evidence run is in progress there: the mutations edit contracts/src IN PLACE (a trap
# reverts them on any exit).
# usage: script/halmos/run-fuzz-liveness.sh <out_dir>   (normally data/halmos/fuzz-liveness)
# Exit code: that of verify-d5c1.py --only fuzz (0 iff all of the above hold), or 3 on a failed revert.
set -uo pipefail
o="$1"; mkdir -p "$o"
F="$HOME/.foundry/bin/forge"
FUZZ="^(D5c1BoundedFuzzTest|MintRepayLemmaFuzzTest)$"   # the fuzz substitutes of the bounded partitions / lemma M
[ -z "$(git status --porcelain contracts/src)" ] || { echo "DIRTY contracts/src — refusing"; exit 3; }
cur=""
trap '[ -n "$cur" ] && python3 script/halmos/d5c1-mutations.py revert "$cur"' EXIT
"$F" test --match-path "contracts/test/halmos/*.t.sol" --match-contract "$FUZZ" > "$o/fuzz-bounded-partitions.log" 2>&1
python3 script/halmos/d5c1_binding.py xpnts --line >> "$o/fuzz-bounded-partitions.log"
echo "== unmutated: $(grep -E 'Suite result' "$o/fuzz-bounded-partitions.log" | tail -1)"
for m in M-I2 M-PULL M-BURNALL M-REPAY; do
  cur="$m"
  python3 script/halmos/d5c1-mutations.py apply "$m" > "$o/$m.apply.txt" || { echo "APPLY-FAILED $m"; exit 3; }
  cp "cache/d5c1-mutations/$m.diff" "$o/"
  "$F" test --match-path "contracts/test/halmos/*.t.sol" --match-contract "$FUZZ" > "$o/$m.fuzz.log" 2>&1
  python3 script/halmos/d5c1_binding.py xpnts --line >> "$o/$m.fuzz.log"          # mutated tree
  python3 script/halmos/d5c1-mutations.py revert "$m" >> "$o/$m.fuzz.log" || { echo "REVERT-FAILED $m"; exit 3; }
  cur=""
  "$F" build > /dev/null 2>&1
  python3 script/halmos/d5c1_binding.py xpnts > "$o/$m.restored.json"            # must equal the pristine tree
  echo "== $m"; grep -E "^\[(PASS|FAIL)" "$o/$m.fuzz.log" | cut -c1-110 | sort -u
done
python3 script/halmos/verify-d5c1.py --only fuzz --fuzz-dir "$o"

#!/usr/bin/env bash
# In-place mutation runner for the route-A rehearsal (replaces the temp-worktree runner, whose first run was
# INVALID: the temp worktree lacked the uncommitted test files and its submodule clone failed).
# Applies each Mn.diff (from $D) to the tracked file, runs its target test (targets.tsv) on the fork, then restores
# the file with git. Env: FORGE, RPC (archive fork RPC), FORK_BLOCK, OPERATORS. The fork RPC URL is never logged.
# Exit status is not a verdict; read summary.tsv (CONTROL must be GREEN, every Mn KILLED).
set -u
D="${1:-docs/design/aoa-balance-mode/data/rams-a/mutations-run2}"; OUT="${2:-docs/design/aoa-balance-mode/data/rams-a/mutations-run2}"; F="$FORGE"
run() { SEPOLIA_FORK_RPC="$RPC" FORK_BLOCK="$FORK_BLOCK" OPERATORS="$OPERATORS" FOUNDRY_ISOLATE=false FOUNDRY_DISABLE_NIGHTLY_WARNING=1 \
  "$F" test --match-path 'contracts/test/rams/RamsARouteRehearsal.t.sol' --match-test "$1" --no-isolate --hardfork amsterdam -vv 2>&1 | sed -E 's#https?://[^ ]*#<url>#g'; }
printf 'ID\tTARGET\tRESULT\tFIRST_FAIL\n' > "$OUT/summary.tsv"
run 'test_A' > "$OUT/CONTROL.log"; c=$(grep -c '^\[PASS\]' "$OUT/CONTROL.log"); f=$(grep -c '^\[FAIL' "$OUT/CONTROL.log")
printf 'CONTROL\tall\t%s\t%s pass / %s fail\n' "$([ $f = 0 ] && [ $c -ge 9 ] && echo GREEN || echo BROKEN)" "$c" "$f" >> "$OUT/summary.tsv"
for n in $(seq 1 10); do
  m="M$n"; diff="$D/$m.diff"; tgt=$(grep -m1 '^+++ ' "$diff" | sed -E 's#^\+\+\+ [^ ]*/worktree/([^ 	]*).*#\1#')
  test=$(awk -F'\t' -v m="$m" '$1==m{print $2}' "$D/targets.tsv")
  [ -n "$test" ] || { printf '%s\t-\tNO-TARGET\t-\n' "$m" >> "$OUT/summary.tsv"; continue; }
  if ! patch -s "$tgt" < "$diff" > "$OUT/$m.patch.txt" 2>&1; then printf '%s\t%s\tPATCH-FAILED\t-\n' "$m" "$test" >> "$OUT/summary.tsv"; git checkout -q -- "$tgt"; continue; fi
  [ "$D" = "$OUT" ] || cp "$diff" "$OUT/$m.diff"
  run "$test" > "$OUT/$m.log"
  if grep -q "^\[FAIL.*$test" "$OUT/$m.log"; then r=KILLED; elif grep -q "^\[PASS\] $test" "$OUT/$m.log"; then r=SURVIVED; else r=INVALID; fi
  ff=$(grep -m1 "^\[FAIL" "$OUT/$m.log" | cut -c1-160)
  printf '%s\t%s\t%s\t%s\n' "$m" "$test" "$r" "${ff:--}" >> "$OUT/summary.tsv"
  git checkout -q -- "$tgt"
done
git diff --quiet -- contracts/test/rams && echo "tree restored" >> "$OUT/summary.tsv"

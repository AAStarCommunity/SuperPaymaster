#!/usr/bin/env bash
# D5c-1 — run one source mutation end to end (apply -> Halmos checks -> forge scenario test -> revert).
#
# usage (from the root of a checkout, typically a scratch copy so the main tree's evidence runs
# never compile mutated source):
#   script/halmos/run-mutation.sh <MUT_ID> <out_dir> <scenario_test_regex> <spec>...
#   spec = Contract:check_function:core|ext[:only]   (only = partition label filter, e.g. settleLocked)
#          or   Contract:unpartitioned               (whole contract, one halmos process)
# Halmos runs use --early-exit: the question is only WHICH predicate goes red; the forge scenario
# test must go red too (the mutation really changes behaviour in the targeted scenario).
# Exit code: 0 only if the mutation is KILLED as expected — judged by verify-d5c1.py --only mutations
# against the expectation table (named Halmos check/partition FAIL with a counterexample, named
# scenario test red with the named message) — AND the source is restored to its pristine sha256.
# Revert always runs (trap), and a failed revert is exit 3.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH" PYTHONUNBUFFERED=1
mid="$1"; out="$2"; scen="$3"; shift 3
mkdir -p "$out"
python3 script/halmos/d5c1-mutations.py apply "$mid" | tee "$out/apply.txt" || { echo "APPLY-FAILED"; exit 3; }
reverted=0
restore() { [ $reverted -eq 1 ] && return; reverted=1
  python3 script/halmos/d5c1-mutations.py revert "$mid" | tee -a "$out/summary.txt" || { echo "REVERT-FAILED"; exit 3; }; }
trap restore EXIT
cp "cache/d5c1-mutations/$mid.diff" "$out/$mid.diff"
export D5C1_TREE="D5c-1 tree + mutation $mid (see $mid.diff)"
# harness artifacts without an AST (left by a plain forge build) would make halmos skip them
for d in out/APNTsCappedHalmos.t.sol out/XPNTsV2Halmos.t.sol out/XPNTsV2HalmosProbe.sol; do
  [ -d "$d" ] || continue
  python3 -c 'import json,sys,glob; sys.exit(0 if all("ast" in json.load(open(f)) for f in glob.glob(sys.argv[1]+"/*.json")) else 1)' "$d" || rm -rf "$d"
done
# the exact build halmos performs (AST + storageLayout + metadata), so the partition driver reads
# the MUTATED ABI (e.g. a selector added by the mutation) before it launches any part
forge build --ast --extra-output storageLayout metadata > "$out/build.log" 2>&1 || { echo "BUILD-FAILED"; exit 3; }
fam=xpnts; [ "$mid" = M-CAP1 ] && fam=apnts
python3 script/halmos/d5c1_binding.py "$fam" > "$out/binding-mutated.json"   # the mutated tree + its build
for spec in "$@"; do
  IFS=: read -r c f a o <<<"$spec"
  if [ "$f" = unpartitioned ]; then
    python3 script/halmos/d5c1_binding.py "$fam" --line > "$out/$c.log"
    halmos --contract "$c" --panic-error-codes '*' >> "$out/$c.log" 2>&1
    echo "$c: exit $? $(grep -cE 'FAIL\]' "$out/$c.log") FAIL lines" | tee -a "$out/summary.txt"
    python3 script/halmos/d5c1_binding.py "$fam" --line >> "$out/$c.log"
  else
    extra=()
    [ -n "${o:-}" ] && extra=(--only "$o")
    python3 script/halmos/run-partitioned.py "$c" "$f" "$a" "$out/$c.$f" --jobs 3 --part-wall-cap-s 600 "${extra[@]}" \
      -- --default-bytes-lengths 0,65 --early-exit | tail -1 | sed "s#^#$c.$f: #" | tee -a "$out/summary.txt"
  fi
done
forge test --match-path contracts/test/halmos/D5c1Replay.t.sol --match-test "$scen" -vv > "$out/scenario.log" 2>&1
echo "scenario ($scen): exit $? ; $(grep -E 'Suite result' "$out/scenario.log" | tail -1)" | tee -a "$out/summary.txt"
python3 script/halmos/d5c1_binding.py "$fam" --line >> "$out/scenario.log"
restore
trap - EXIT
forge build > "$out/build-restored.log" 2>&1 || { echo "BUILD-FAILED (restored)"; exit 3; }
python3 script/halmos/d5c1_binding.py "$fam" > "$out/binding-restored.json"   # must equal the pristine tree
python3 script/halmos/verify-d5c1.py --only mutations --mutations-dir "$(dirname "$out")" --filter "$mid"

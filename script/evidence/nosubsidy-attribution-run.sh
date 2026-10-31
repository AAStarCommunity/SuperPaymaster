#!/usr/bin/env bash
# Regenerate the no-subsidy attribution evidence from a clean committed HEAD (commands.md, scripted).
# Usage: script/evidence/nosubsidy-attribution-run.sh <empty-out-dir> <archive-dir-for-large-trace>
set -euo pipefail
OUT=${1:?out dir}; ARCH=${2:?archive dir}
[ ! -e "$OUT" ] || [ -z "$(ls -A "$OUT")" ] || { echo "out dir must be empty" >&2; exit 2; }
test -z "$(git status --porcelain)" || { echo "tree not clean" >&2; exit 2; }
mkdir -p "$OUT" "$ARCH"; OUT=$(cd "$OUT" && pwd); ARCH=$(cd "$ARCH" && pwd)
N=${AMS_FORGE:-$HOME/Dev/aastar/tools/foundry-rams/nightly-4e8874b/forge}
STABLE=${STABLE_FORGE:-$HOME/.foundry/bin/forge}
EV=docs/design/aoa-balance-mode/data/nosubsidy-attribution
T=contracts/test/v2/SuperPaymasterPostOpGasMatrix.t.sol
{ echo "head $(git rev-parse HEAD)"; "$N" --version | head -1; "$STABLE" --version | head -1; } > "$OUT/engines.txt"
OPS=SLOAD,SSTORE,TLOAD,TSTORE,LOG1,LOG2,LOG3,LOG4
for rt in cancun prague amsterdam; do
  rc=0; "$N" test --offline --no-isolate --fuzz-seed 0x5eed --evm-version prague --hardfork "$rt" \
    --disable-external-identification --match-path "$T" --match-test '^test_matrix_' -vvvvv --opcodes "$OPS" \
    > "$OUT/matrix-$rt.log" 2>&1 || rc=$?; echo "matrix-$rt exit $rc" >> "$OUT/exits.txt"
done
for rt in prague cancun; do
  rc=0; "$STABLE" test --offline --fuzz-seed 0x5eed --evm-version "$rt" --match-path "$T" --match-test '^test_matrix_' -vvvv \
    > "$OUT/matrix-stable-$rt.log" 2>&1 || rc=$?; echo "matrix-stable-$rt exit $rc" >> "$OUT/exits.txt"
done
P=$(mktemp -d); trap 'rm -rf "$P"' EXIT; mkdir -p "$P/test"; cp "$EV/StateGasProbe.sol" "$P/test/StateGas.t.sol"
for rt in amsterdam prague; do
  rc=0; "$N" test --root "$P" --offline --use 0.8.33 --no-isolate --evm-version prague --hardfork "$rt" \
    --disable-external-identification -vvvvv --opcodes SSTORE,GAS,PUSH0,PUSH1,SWAP1,SWAP2,DUP1,DUP2,POP \
    > "$OUT/state-gas-probe-$rt.log" 2>&1 || rc=$?; echo "probe-$rt exit $rc" >> "$OUT/exits.txt"
done
# the original counterexample must still fail exactly as recorded (the test file is unchanged)
rc=0; "$N" test --offline --no-isolate --fuzz-seed 0x5eed --evm-version prague --hardfork amsterdam \
  --disable-external-identification --match-path contracts/test/v2/SuperPaymasterV55Fuzz.t.sol \
  --match-contract '^SuperPaymasterV55FuzzTest$' --match-test '^test_G2_coverage_replay_fixed_seeds' \
  -vvvvv --opcodes "$OPS" > "$ARCH/counterexample-final-amsterdam.log" 2>&1 || rc=$?
echo "counterexample exit $rc" >> "$OUT/exits.txt"
grep '^\[FAIL' "$ARCH/counterexample-final-amsterdam.log" > "$OUT/counterexample-result.log" || true
shasum -a 256 "$ARCH/counterexample-final-amsterdam.log" | sed "s#  .*/#  #" > "$OUT/external-trace.sha256"
python3 -I "$EV/analyze.py" "$OUT"/matrix-{cancun,prague,amsterdam}.log > "$OUT/matrix-summary.json"
fail() { echo "VERDICT FAIL: $*" >&2; exit 1; }
for r in matrix-cancun matrix-prague matrix-amsterdam matrix-stable-prague matrix-stable-cancun probe-amsterdam probe-prague; do
  grep -qx "$r exit 0" "$OUT/exits.txt" || fail "$r did not pass"
done
grep -qx "counterexample exit 1" "$OUT/exits.txt" || fail "counterexample no longer fails"
grep -q "1827511012226570 < 1838299350952020" "$OUT/counterexample-result.log" || fail "counterexample values changed"
test -z "$(git status --porcelain --untracked-files=no)" || fail "tracked files changed"
echo "VERDICT PASS: matrix 3 runtimes + 2 stable controls pass; probe ok; counterexample reproduces exactly" | tee "$OUT/verdict.txt"

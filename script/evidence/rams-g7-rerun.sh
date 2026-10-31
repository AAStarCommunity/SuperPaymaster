#!/usr/bin/env bash
# Re-run the G-7 acceptance suites from a clean committed HEAD and record the review mutations.
# Usage: script/evidence/rams-g7-rerun.sh <out-dir>   (needs a clean tree; restores every mutation)
set -euo pipefail
OUT=${1:?out dir}
[ ! -e "$OUT" ] || [ -z "$(ls -A "$OUT")" ] || { echo "out dir must be empty" >&2; exit 2; }
mkdir -p "$OUT"
STABLE=${STABLE_FORGE:-$HOME/.foundry/bin/forge}
AMS=${AMS_FORGE:-$HOME/Dev/aastar/tools/foundry-rams/nightly-4e8874b/forge}
test -z "$(git status --porcelain)" || { echo "tree not clean" >&2; exit 2; }
HEAD_SHA=$(git rev-parse HEAD); echo "head $HEAD_SHA" > "$OUT/head.txt"
"$STABLE" --version | head -1 >> "$OUT/head.txt"; "$AMS" --version | head -1 >> "$OUT/head.txt"
COMMON=(test --offline --fuzz-seed 0x5eed -vv)
# forge 1.7.1 has no --no-isolate (it is the default there); the nightly needs it explicitly.
AMS_COMMON=(test --offline --no-isolate --fuzz-seed 0x5eed -vv)
run() { local name=$1 rc=0; shift; "$@" > "$OUT/$name.log" 2>&1 || rc=$?; echo "$name exit $rc" >> "$OUT/exits.txt"
  grep -qE "tests passed, [0-9]+ failed" "$OUT/$name.log" || { echo "$name: no test summary (exit $rc)" >&2; exit 3; }; }
run cancun-forge171 "$STABLE" "${COMMON[@]}"
run prague-forge171 "$STABLE" "${COMMON[@]}" --evm-version prague
run amsterdam "$AMS" "${AMS_COMMON[@]}" --evm-version prague --hardfork amsterdam
# M-1 mutation: the postOp entry guard reads the live settle bound instead of the validation snapshot.
SRC=contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol
FROM='uint256 snapSettle = uint32(snap >> 32);'; TO='uint256 snapSettle = _gasParams.settleGasBound;'
test "$(grep -cF "$FROM" "$SRC")" = 1
trap 'git checkout -- "$SRC"' EXIT
sed -i '' "s/$(printf '%s' "$FROM" | sed 's/[][\/.*^$]/\\&/g')/$TO/" "$SRC"
grep -qF "$TO" "$SRC"
D5B=contracts/test/v2/SuperPaymasterD5bUpgradeRace.t.sol
run mutation-m1-d5b-cancun "$STABLE" test --offline --match-path "$D5B" -vv
run mutation-m1-d5b-amsterdam "$AMS" test --offline --match-path "$D5B" -vv --evm-version prague --hardfork amsterdam
git checkout -- "$SRC"; trap - EXIT
test -z "$(git status --porcelain)"
echo "restored; tree clean" >> "$OUT/exits.txt"
"$(dirname "$0")/rams-g7-verdict.sh" "$OUT" | tee "$OUT/verdict.txt"

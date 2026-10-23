#!/usr/bin/env bash
# Local patches only; fork execution requires caller-provided archive RPC and inventory.
set -euo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/../.."
D="${1:-docs/design/aoa-balance-mode/data/rams-a/mutations-def4}"
OUT="${2:-$D}"
forge_bin="${FORGE:-forge}"
export SEPOLIA_FORK_RPC="${SEPOLIA_FORK_RPC:-${RPC:-}}"
export FOUNDRY_ISOLATE=false
if [[ -n "$SEPOLIA_FORK_RPC" ]]; then
    : "${FORK_BLOCK:?Set FORK_BLOCK}" "${OPERATORS:?Supply complete operator inventory}"
    unset FOUNDRY_OFFLINE
else
    export FOUNDRY_OFFLINE=true
fi
source script/evidence/rams-a-header.sh
mkdir -p "$OUT"
target='contracts/test/rams/RamsARouteRehearsal.t.sol'
baseline=$(mktemp)
git show "HEAD:$target" > "$baseline"
if ! cmp -s "$baseline" "$target"; then
    printf 'Refusing mutation run: %s differs from HEAD. Commit the reviewed baseline before running.\n' "$target" >&2
    rm -f "$baseline"
    exit 1
fi
trap 'cp "$baseline" "$target"; rm -f "$baseline"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
run() {
    local args=(test --match-path "$target" --match-test "$1" --no-isolate --hardfork amsterdam -vv)
    { rams_header "${args[@]}"; "$forge_bin" "${args[@]}"; } 2>&1 |
        rams_redact
}
printf 'ID\tTARGET\tRESULT\tFIRST_FAIL\n' > "$OUT/summary.tsv"
run '^test_A' > "$OUT/CONTROL.log" || true
c=$(awk '/^\[PASS\]/{n++} END{print n+0}' "$OUT/CONTROL.log")
f=$(awk '/^\[FAIL/{n++} END{print n+0}' "$OUT/CONTROL.log")
expected_count=$(grep -c 'function test_A' "$baseline")
control=BROKEN
if [[ "$f" = 0 && "$c" = "$expected_count" ]]; then control=GREEN; fi
printf 'CONTROL\tall\t%s\t%s pass / %s fail\n' "$control" "$c" "$f" >> "$OUT/summary.tsv"
failed=0
while IFS=$'\t' read -r m test expected; do
    cp "$baseline" "$target"
    if ! patch --batch --fuzz=0 -s "$target" < "$D/$m.diff" > "$OUT/$m.patch.txt" 2>&1; then
        printf '%s\t%s\tPATCH-FAILED\t-\n' "$m" "$test" >> "$OUT/summary.tsv"
        failed=1; continue
    fi
    [[ "$D" = "$OUT" ]] || cp "$D/$m.diff" "$OUT/$m.diff"
    # forge matches --match-test against the full signature, e.g. test_X(), so anchor with \(\)$
    run "^${test}\\(\\)\$" > "$OUT/$m.log" || true
    # Only the FIRST failure of this exact target test determines the verdict.
    ff=$(awk -v t="$test(" '/^\[FAIL/ && index($0,t){print; exit}' "$OUT/$m.log")
    if [[ -n "$ff" ]]; then
        if [[ "$ff" == *"$expected"* ]]; then r=KILLED; else r=WRONG-ASSERTION; fi
    elif grep -q "^\\[PASS\\] ${test}(" "$OUT/$m.log"; then r=SURVIVED
    else r=INVALID; fi
    printf '%s\t%s\t%s\t%s\n' "$m" "$test" "$r" "${ff:--}" >> "$OUT/summary.tsv"
    [[ "$r" = KILLED ]] || failed=1
done < "$D/targets.tsv"
cp "$baseline" "$target"
[[ "$control" = GREEN && "$failed" = 0 ]]

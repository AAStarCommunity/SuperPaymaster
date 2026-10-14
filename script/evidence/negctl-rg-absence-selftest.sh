#!/usr/bin/env bash
# Exercise the URL check from the base revision and the current scanner without RPC or Forge.
set -uo pipefail
for tool in git grep rg bash ln mktemp mkdir chmod shasum rm cat; do
  command -v "$tool" >/dev/null 2>&1 || { echo "required tool missing: $tool" >&2; exit 2; }
done
W="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$W"
OUT=docs/design/aoa-balance-mode/data/cc125-rg-negctl
mkdir -p "$OUT"
OLDREF=$(git rev-parse origin/feat/aoa-balance-mode-5.5.0)
old_line=$(git show "$OLDREF:script/evidence/a2-read-failclosed-negctl.sh" | grep -F "if rg -l 'https?://' \"\$D\"")
[ -n "$old_line" ] || { echo "old URL check not found" >&2; exit 2; }
rg_bin=$(command -v rg)
tmp=$(mktemp -d)
trap 'chmod 700 "$tmp/scan-error/closed" 2>/dev/null || :; rm -r "$tmp"' EXIT
mkdir "$tmp/no-rg" "$tmp/with-rg" "$tmp/missing-rg-url" "$tmp/missing-rg-clean" "$tmp/rg-url" "$tmp/scan-error" "$tmp/scan-error/closed" "$tmp/rg-hidden-url" "$tmp/rg-binary-url"
ln -s "$(command -v bash)" "$tmp/no-rg/bash"
ln -s "$(command -v grep)" "$tmp/no-rg/grep"
ln -s "$(command -v bash)" "$tmp/with-rg/bash"
ln -s "$(command -v grep)" "$tmp/with-rg/grep"
ln -s "$rg_bin" "$tmp/with-rg/rg"
printf 'https://example.invalid/injected\n' > "$tmp/missing-rg-url/input.txt"
printf 'plain text\n' > "$tmp/missing-rg-clean/input.txt"
printf 'https://example.invalid/injected\n' > "$tmp/rg-url/input.txt"
printf 'plain text\n' > "$tmp/scan-error/closed/input.txt"
chmod 000 "$tmp/scan-error/closed"
# rg skips hidden and binary files by default; the old check missed both.
printf 'https://example.invalid/hidden\n' > "$tmp/rg-hidden-url/.hidden.log"
printf 'bin\000https://example.invalid/binary\n' > "$tmp/rg-binary-url/blob.bin"

TABLE="$OUT/results.tsv"
LOG="$OUT/results.log"
printf 'case\told_exit\tnew_exit\tscanner\n' > "$TABLE"
printf 'old_ref=%s\nnew_source=script/evidence/check-url-residue.sh\n' "$OLDREF" > "$LOG"
failures=0
run_case() {
  local name="$1" path="$2" dir="$3" want_old="$4" want_new="$5" old_rc new_rc
  PATH="$path" D="$dir" bash -c 'eval "$1"' bash "$old_line" > "$tmp/old.out" 2>&1
  old_rc=$?
  PATH="$path" bash script/evidence/check-url-residue.sh "$dir" > "$tmp/new.out" 2>&1
  new_rc=$?
  printf '%s\t%s\t%s\t%s\n' "$name" "$old_rc" "$new_rc" "${path##*/}" >> "$TABLE"
  printf '%s: old=%s new=%s (expected %s/%s)\n' "$name" "$old_rc" "$new_rc" "$want_old" "$want_new" >> "$LOG"
  if [ "$old_rc" -ne "$want_old" ] || [ "$new_rc" -ne "$want_new" ]; then
    printf '%s: unexpected exit codes\n' "$name" >> "$LOG"
    failures=$((failures+1))
  fi
}
run_case missing-rg-url "$tmp/no-rg" "$tmp/missing-rg-url" 0 1
run_case missing-rg-clean "$tmp/no-rg" "$tmp/missing-rg-clean" 0 0
run_case rg-url "$tmp/with-rg" "$tmp/rg-url" 1 1
run_case scan-error "$tmp/with-rg" "$tmp/scan-error" 0 2
run_case rg-hidden-url "$tmp/with-rg" "$tmp/rg-hidden-url" 0 1
run_case rg-binary-url "$tmp/with-rg" "$tmp/rg-binary-url" 0 1
run_case no-rg-hidden-url "$tmp/no-rg" "$tmp/rg-hidden-url" 0 1
printf 'failures=%s\n' "$failures" >> "$LOG"
(cd "$OUT" && shasum -a 256 results.tsv results.log > EVIDENCE.sha256)
cat "$TABLE"
[ "$failures" -eq 0 ]

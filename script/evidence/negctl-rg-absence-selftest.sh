#!/usr/bin/env bash
# Compare the old URL gate with the current scanner and exercise rehearsal call sites.
set -uo pipefail
for tool in git grep bash ln mktemp mkdir chmod shasum rm cat env python3 awk find; do
  command -v "$tool" >/dev/null 2>&1 || { echo "required tool missing: $tool" >&2; exit 2; }
done
W="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$W"
OUT=docs/design/aoa-balance-mode/data/cc125-rg-negctl
mkdir -p "$OUT"
OLDREF=$(git rev-parse origin/feat/aoa-balance-mode-5.5.0)
old_line=$(git show "$OLDREF:script/evidence/a2-read-failclosed-negctl.sh" | grep -F "if rg -l 'https?://' \"\$D\"")
[ -n "$old_line" ] || { echo "old URL check not found" >&2; exit 2; }
rg_bin=$(command -v rg || true)
[ -n "$rg_bin" ] || rg_bin=/Applications/Codex.app/Contents/Resources/rg
[ -x "$rg_bin" ] || { echo "required tool missing: rg" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'chmod 700 "$tmp/scan-error/closed" 2>/dev/null || :; rm -r "$tmp"' EXIT
mkdir "$tmp/no-rg" "$tmp/with-rg"
# Link real executables: a version-manager shim (e.g. pyenv) cannot run inside the restricted PATH.
real_tool() {
  if [ "$1" = python3 ]; then python3 -c 'import os,sys; print(os.path.realpath(sys.executable))'
  else command -v "$1"; fi
}
for tool in bash grep env find mktemp rm python3; do
  ln -s "$(real_tool "$tool")" "$tmp/no-rg/$tool"
  ln -s "$(real_tool "$tool")" "$tmp/with-rg/$tool"
done
ln -s "$rg_bin" "$tmp/with-rg/rg"
for name in missing-rg-url missing-rg-clean rg-url scan-error rg-hidden-url rg-binary-url config-glob config-size uppercase escaped double-escaped bare-prefix file-link dir-link broken-link loop grep-options git-ignored harness-url harness-clean; do mkdir "$tmp/$name"; done
mkdir "$tmp/scan-error/closed" "$tmp/linked-dir"
printf 'https://example.invalid/injected\n' > "$tmp/missing-rg-url/input.txt"
printf 'plain text\n' > "$tmp/missing-rg-clean/input.txt"
printf 'https://example.invalid/injected\n' > "$tmp/rg-url/input.txt"
printf 'plain text\n' > "$tmp/scan-error/closed/input.txt"
chmod 000 "$tmp/scan-error/closed"
printf 'https://example.invalid/hidden\n' > "$tmp/rg-hidden-url/.hidden.log"
printf 'bin\000https://example.invalid/binary\n' > "$tmp/rg-binary-url/blob.bin"
printf 'https://example.invalid/config\n' > "$tmp/config-glob/input.log"
printf 'https://example.invalid/config\n' > "$tmp/config-size/input.txt"
printf 'HTTPS://example.invalid/upper\n' > "$tmp/uppercase/input.txt"
printf 'https:\\/\\/example.invalid/escaped\n' > "$tmp/escaped/input.txt"
printf 'https:\\\\/\\\\/example.invalid/double\n' > "$tmp/double-escaped/input.txt"
printf 'see https:// later\n' > "$tmp/bare-prefix/input.txt"
printf 'https://example.invalid/file-link\n' > "$tmp/linked-file.txt"
ln -s "$tmp/linked-file.txt" "$tmp/file-link/link.txt"
printf 'https://example.invalid/dir-link\n' > "$tmp/linked-dir/input.txt"
ln -s "$tmp/linked-dir" "$tmp/dir-link/link"
ln -s "$tmp/no-such-file" "$tmp/broken-link/dangling"
ln -s "$tmp/loop" "$tmp/loop/ancestor"
printf 'https://example.invalid/grep-options\n' > "$tmp/grep-options/input.log"
git init -q "$tmp/git-ignored"
printf '*.log\n' > "$tmp/git-ignored/.gitignore"
printf 'https://example.invalid/ignored\n' > "$tmp/git-ignored/input.log"
printf '%s\n' '--glob=!*.log' > "$tmp/glob.rgconf"
printf '%s\n' '--max-filesize=1' > "$tmp/size.rgconf"
printf 'https://example.invalid/harness\n' > "$tmp/harness-url/input.txt"
printf 'plain text\n' > "$tmp/harness-clean/input.txt"
TABLE="$OUT/results.tsv"; LOG="$OUT/results.log"
printf 'case\told_exit\tnew_exit\tscanner\n' > "$TABLE"
printf 'old_ref=%s\nnew_source=script/evidence/check-url-residue.sh\n' "$OLDREF" > "$LOG"
failures=0
run_case() {
  local name="$1" path="$2" dir="$3" want_old="$4" want_new="$5" config="${6:-}" options="${7:-}" old_rc new_rc
  PATH="$path" D="$dir" RIPGREP_CONFIG_PATH="$config" GREP_OPTIONS="$options" bash -c 'eval "$1"' bash "$old_line" > "$tmp/old.out" 2>&1
  old_rc=$?
  PATH="$path" RIPGREP_CONFIG_PATH="$config" GREP_OPTIONS="$options" bash script/evidence/check-url-residue.sh "$dir" > "$tmp/new.out" 2>&1
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
run_case config-glob "$tmp/with-rg" "$tmp/config-glob" 0 1 "$tmp/glob.rgconf"
run_case config-size "$tmp/with-rg" "$tmp/config-size" 0 1 "$tmp/size.rgconf"
run_case uppercase "$tmp/with-rg" "$tmp/uppercase" 0 1
run_case grep-uppercase "$tmp/no-rg" "$tmp/uppercase" 0 1
run_case escaped "$tmp/with-rg" "$tmp/escaped" 0 1
run_case grep-escaped "$tmp/no-rg" "$tmp/escaped" 0 1
run_case double-escaped "$tmp/with-rg" "$tmp/double-escaped" 0 1
run_case grep-double-escaped "$tmp/no-rg" "$tmp/double-escaped" 0 1
run_case bare-prefix "$tmp/with-rg" "$tmp/bare-prefix" 1 1
run_case grep-bare-prefix "$tmp/no-rg" "$tmp/bare-prefix" 0 1
run_case file-link "$tmp/with-rg" "$tmp/file-link" 0 1
run_case grep-file-link "$tmp/no-rg" "$tmp/file-link" 0 1
run_case dir-link "$tmp/with-rg" "$tmp/dir-link" 0 1
run_case grep-dir-link "$tmp/no-rg" "$tmp/dir-link" 0 1
run_case broken-link "$tmp/with-rg" "$tmp/broken-link" 0 2
run_case grep-broken-link "$tmp/no-rg" "$tmp/broken-link" 0 2
run_case loop "$tmp/with-rg" "$tmp/loop" 0 2
run_case grep-loop "$tmp/no-rg" "$tmp/loop" 0 2
run_case grep-options "$tmp/no-rg" "$tmp/grep-options" 0 1 '' '--exclude=*'
run_case git-ignored "$tmp/with-rg" "$tmp/git-ignored" 0 1
# Run the exact source line so both invocation and exit propagation are checked.
call_line=$(grep -Fx '    bash script/evidence/check-url-residue.sh "$D" || exit $?' script/evidence/a2-read-failclosed-negctl.sh)
if [ -z "$call_line" ]; then echo 'harness URL gate missing' >> "$LOG"; failures=$((failures+1)); fi
if [ -n "$call_line" ]; then
  for name in harness-url harness-clean; do
    want=0; [ "$name" = harness-url ] && want=1
    D="$tmp/$name" bash -c "$call_line" > "$tmp/harness.out" 2>&1
    rc=$?
    printf '%s\tNA\t%s\tharness-call\n' "$name" "$rc" >> "$TABLE"
    [ "$rc" -eq "$want" ] || failures=$((failures+1))
  done
fi
# Execute the inline Python redactor from the harness against URL forms and links.
redactor_line=$(grep -Fx "    python3 - \"\$D\" <<'PY' || exit \$?" script/evidence/a2-read-failclosed-negctl.sh)
if [ -z "$redactor_line" ]; then echo 'harness redactor missing' >> "$LOG"; failures=$((failures+1)); fi
awk '/^import os, pathlib, re, sys$/{copy=1} copy && /^PY$/{exit} copy{print}' script/evidence/a2-read-failclosed-negctl.sh > "$tmp/redactor.py"
mkdir "$tmp/redact" "$tmp/redact/inside" "$tmp/redact-target"
printf 'HTTPS://example.invalid/upper https:\\/\\/example.invalid/escaped https:\\\\/\\\\/example.invalid/double see https:// later\n' > "$tmp/redact/input.log"
printf 'HTTPS://example.invalid/inside\n' > "$tmp/redact/inside/input.log"
printf 'HTTPS://example.invalid/outside\n' > "$tmp/redact-target/input.log"
ln -s "$tmp/redact/inside" "$tmp/redact/linked"
python3 "$tmp/redactor.py" "$tmp/redact" > "$tmp/redactor.out" 2>&1
redactor_rc=$?
bash script/evidence/check-url-residue.sh "$tmp/redact" > "$tmp/redactor-scan.out" 2>&1
scan_rc=$?
if [ "$redactor_rc" -ne 0 ] || [ "$scan_rc" -ne 0 ] || [ "$(grep -o '<redacted-rpc>' "$tmp/redact/input.log" | wc -l | tr -d ' ')" -ne 4 ] || ! grep -Fq '<redacted-rpc>' "$tmp/redact/inside/input.log"; then
  failures=$((failures+1))
fi
printf 'redactor-uppercase-escaped-double-bare-internal\tNA\t%s\tpython-redactor\n' "$redactor_rc" >> "$TABLE"
ln -s "$tmp/redact-target" "$tmp/redact/outside"
python3 "$tmp/redactor.py" "$tmp/redact" > "$tmp/redactor-outside.out" 2>&1
outside_rc=$?
bash script/evidence/check-url-residue.sh "$tmp/redact" > "$tmp/redactor-outside-scan.out" 2>&1
outside_scan_rc=$?
if [ "$outside_rc" -eq 0 ] || [ "$outside_scan_rc" -ne 1 ] || ! grep -Fq 'HTTPS://example.invalid/outside' "$tmp/redact-target/input.log"; then
  failures=$((failures+1))
fi
printf 'redactor-outside-link\tNA\t%s\tpython-redactor\n' "$outside_rc" >> "$TABLE"
for source_file in script/evidence/d5b-fork-rehearsal.sh scripts/d5b-anvil-rehearsal.sh; do
  grep -Fq 'script/evidence/require-revert.sh"' "$source_file" || failures=$((failures+1))
done
for spec in 'revert:1:0:Error: execution reverted' 'connection-refused:1:2:Error: error sending request: Connection refused' 'exit-2:2:2:Error: execution reverted' 'exit-126:126:2:Error: execution reverted' 'exit-127:127:2:Error: execution reverted' 'exit-130:130:2:Error: execution reverted' 'compiler-source:1:2:Error: Compiler run failed: revert Unauthorized();' 'compiler-reverted:1:2:Error: Compiler run failed: execution reverted' 'readfile-trace:1:2:└─ ← [Revert] vm.readFile: failed to open file' 'readfile-summary:1:2:Error: script failed: vm.readFile: failed to open file' 'forge-expected:1:0:Error: script failed: roles attestation: missing (set TL_ROLES_ATTESTATION)' 'forge-wrong-reason:1:2:Error: script failed: DefaultArtifacts: missing' 'forge-readfile:1:2:Error: script failed: vm.readFile: failed to open file'; do
  IFS=: read -r name command_rc want message <<< "$spec"
  expected='execution reverted'
  case "$name" in forge-*) expected='roles attestation: missing' ;; esac
  FAKE_RC="$command_rc" FAKE_MESSAGE="$message" bash -c 'source script/evidence/require-revert.sh; fake() { printf "%s\n" "$FAKE_MESSAGE"; return "$FAKE_RC"; }; require_revert "$1" "$2" "$3" fake' bash "$tmp/neg.log" "$name" "$expected" > "$tmp/negative.out" 2>&1
  rc=$?
  printf 'must-fail-%s\tNA\t%s\tshared-helper\n' "$name" "$rc" >> "$TABLE"
  [ "$rc" -eq "$want" ] || failures=$((failures+1))
done
# Exercise each readiness loop with an always-failing cast and a no-op sleep.
mkdir "$tmp/ready"
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/fake-cast"
chmod +x "$tmp/fake-cast"
for kind in fork anvil; do
  source_file=script/evidence/d5b-fork-rehearsal.sh
  [ "$kind" = anvil ] && source_file=scripts/d5b-anvil-rehearsal.sh
  awk '/^anvil_ready=0$/{copy=1} copy{print} copy && /^if \[ "\$anvil_ready" -ne 1 \]; then/{exit}' "$source_file" > "$tmp/$kind-ready.sh"
  CAST="$tmp/fake-cast" OUT="$tmp/ready" RPC=http://127.0.0.1:1 bash -c 'cast() { return 1; }; sleep() { :; }; source "$1"' bash "$tmp/$kind-ready.sh" > "$tmp/ready.out" 2>&1
  rc=$?
  printf 'anvil-wait-%s\tNA\t%s\treadiness-loop\n' "$kind" "$rc" >> "$TABLE"
  [ "$rc" -eq 1 ] || failures=$((failures+1))
done
printf 'failures=%s\n' "$failures" >> "$LOG"
(cd "$OUT" && shasum -a 256 results.tsv results.log > EVIDENCE.sha256)
cat "$TABLE"
[ "$failures" -eq 0 ]

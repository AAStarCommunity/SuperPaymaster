#!/usr/bin/env bash
# Old-vs-new negative controls for the fail-closed reads of a2-full-rehearsal.sh (DSR CC-125 466d42d1 ①).
#
# For every injection, the SAME injection is applied to two versions of the script and BOTH exit codes are
# recorded (real readings):
#   old = script/evidence/a2-full-rehearsal.sh at <old ref> (default: merge 252ffe38, i.e. as merged by #462)
#   new = script/evidence/a2-full-rehearsal.sh at HEAD (must be committed: the run refuses a dirty script)
# What is executed is the script's PREAMBLE — every line before `if stage_on 0; then`, taken verbatim from
# that version with `git show`: provenance, build == attestation, the two-endpoint pre-state cross-check
# (xread), the local anvil fork and the fork-block-hash / Safe checks. That is where the reads under test
# live, and it lets each reading take ~1 min instead of a full run. The preamble runs unmodified; the harness
# only (a) defines a `cast` shell function in front of it that injects the fault and otherwise forwards to the
# real binary, and (b) appends a neutral verdict: exit 0 iff the in-shell FAILURES counter is 0 AND
# rehearsal.log has no "!!!" line (both versions write "!!!" for every fail()).
#
# Injections (all LOCAL: the fault is produced by the shim, nothing is sent anywhere):
#   none                  positive control: no fault -> both versions must exit 0
#   both-empty            block-hash read answers "" (exit 0) on endpoint A, endpoint B AND the local fork
#   both-empty-endpoints  block-hash read answers "" (exit 0) on endpoints A and B only (local fork real)
#   both-fail             block-hash read exits 1 ("Error: ...") on endpoint A, endpoint B AND the local fork
#   single-endpoint-fail  EVERY read on endpoint B exits 1; endpoint A and the fork are healthy
#   ill-typed             SP.owner() answers 0x1234 (not 20 bytes) on both endpoints, exit 0
#
# LOCAL ONLY: the public RPC is used only as anvil --fork-url and for the preamble's read-only pre-state
# reads; nothing is broadcast. RPC URLs / keys are never written to the output.
# Usage: script/evidence/a2-read-failclosed-negctl.sh <env file with RPC_URL> <fork block> <out dir> [old ref]
set -uo pipefail
ENVFILE="$1"; FORK_BLOCK="$2"; OUTROOT="$3"; OLDREF="${4:-252ffe38}"
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
W="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$W"
S=script/evidence/a2-full-rehearsal.sh
git diff --quiet HEAD -- "$S" "$0" || { echo "refusing: $S or this harness has uncommitted changes"; exit 2; }
mkdir -p "$OUTROOT"; OUTROOT="$(cd "$OUTROOT" && pwd)"
NEWREF=$(git rev-parse HEAD); OLDFULL=$(git rev-parse "$OLDREF")
SHIM='
# ---- injection shim (harness, not part of either script) ----
cast() {
  local url="" a prev="" ep=local ishash=0
  for a in "$@"; do [ "$prev" = --rpc-url ] && url="$a"; prev="$a"; done
  [ -n "${RPC_URL_FORK:-}" ] && [ "$url" = "$RPC_URL_FORK" ] && ep=A
  [ -n "${RPC_URL_X:-}" ] && [ "$url" = "$RPC_URL_X" ] && ep=B
  [ "$1" = block ] && [[ " $* " == *" --field hash "* ]] && ishash=1
  case "$A2_INJ" in
    both-empty) [ $ishash = 1 ] && { echo "[inject] $ep block hash -> empty, exit 0" >> "$A2_INJ_LOG"; return 0; } ;;
    both-empty-endpoints) [ $ishash = 1 ] && [ $ep != local ] && { echo "[inject] $ep block hash -> empty, exit 0" >> "$A2_INJ_LOG"; return 0; } ;;
    both-fail) [ $ishash = 1 ] && { echo "[inject] $ep block hash -> exit 1" >> "$A2_INJ_LOG"; echo "Error: injected: connection refused" >&2; return 1; } ;;
    single-endpoint-fail) [ $ep = B ] && { echo "[inject] B $1 -> exit 1" >> "$A2_INJ_LOG"; echo "Error: injected: endpoint B unreachable" >&2; return 1; } ;;
    ill-typed) [ $ep != local ] && [ "$1" = call ] && [ "$3" = "owner()(address)" ] && [ "$(echo "$2" | tr A-F a-f)" = "$(echo "$SP" | tr A-F a-f)" ] && { echo "[inject] $ep SP.owner() -> 0x1234" >> "$A2_INJ_LOG"; echo 0x1234; return 0; } ;;
  esac
  command cast "$@"
}
'
VERDICT='
# ---- neutral verdict (harness) ----
NB=$(grep -c "!!!" "$OUT/rehearsal.log")
echo "HARNESS VERDICT: FAILURES=$FAILURES bang-lines=$NB"
[ "$FAILURES" -eq 0 ] && [ "$NB" -eq 0 ]
'
build_harness() { # <ref> <file>
  { echo '#!/usr/bin/env bash'; echo "$SHIM"
    git show "$1:$S" | awk '/^if stage_on 0; then/{exit} {print}'
    echo "$VERDICT"; } > "$2"
}
TABLE="$OUTROOT/negctl-table.tsv"
printf 'injection\told(%s) exit\tnew(%s) exit\told decisive lines\tnew decisive lines\n' "${OLDFULL:0:8}" "${NEWREF:0:8}" > "$TABLE"
PORT=28640
for inj in none both-empty both-empty-endpoints both-fail single-endpoint-fail ill-typed; do
  RC_old=""; RC_new=""
  for ver in old new; do
    ref=$([ $ver = old ] && echo "$OLDFULL" || echo "$NEWREF")
    H="$W/script/evidence/.negctl-harness-$ver.sh"; build_harness "$ref" "$H"
    D="$OUTROOT/$inj/$ver"; rm -rf "$D"; mkdir -p "$D"
    PORT=$((PORT+1))
    A2_INJ=$inj A2_INJ_LOG="$D/injections.log" A2_PORT=$PORT bash "$H" "$ENVFILE" "$FORK_BLOCK" "$D" all > "$D/console.log" 2>&1
    rc=$?
    if [ $ver = old ]; then RC_old=$rc; else RC_new=$rc; fi
    rm -f "$H"
    sed -i '' -E 's#https?://[^ ]*(alchemy|infura)[^ ]*#<redacted-rpc>#g' "$D/console.log"
    echo "$inj $ver ($ref) exit $rc" | tee -a "$OUTROOT/negctl-summary.log"
  done
  od=$(grep -hE 'CHECK \[(pre-state|fork block hash)|!!!' "$OUTROOT/$inj/old/rehearsal.log" 2>/dev/null | sed 's/^ *//' | cut -c1-110 | paste -sd'|' -)
  nd=$(grep -hE 'CHECK \[(pre-state|fork block hash)|!!!' "$OUTROOT/$inj/new/rehearsal.log" 2>/dev/null | sed 's/^ *//' | cut -c1-110 | head -8 | paste -sd'|' -)
  printf '%s\t%s\t%s\t%s\t%s\n' "$inj" "$RC_old" "$RC_new" "$od" "$nd" >> "$TABLE"
done
echo "# old ref $OLDFULL, new ref $NEWREF, fork block $FORK_BLOCK" >> "$OUTROOT/negctl-summary.log"
cat "$OUTROOT/negctl-summary.log"

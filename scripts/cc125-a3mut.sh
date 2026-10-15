#!/usr/bin/env bash
# CC-125 A-3 negative-control liveness: one positive run of the test file, then in-place source
# mutations of contracts/src, each restored and sha256-checked.
#
# Hardened successor of docs/design/aoa-balance-mode/data/d5c1-rc2-rerun/scripts/cc125-a3mut.sh.
# That archived copy is kept byte-identical because EVIDENCE.sha256 of the rc2 rerun pins it; it
# is the record of what was run, not a tool to re-run. Differences:
#   - no hard-coded absolute paths: work tree and output dir are args / env with defaults;
#   - an EXIT/INT/TERM/HUP trap attempts to restore each mutated file from git and checks
#     its sha256 against the value captured before mutation; restoration failure exits 99;
#     SIGKILL, power loss, or a failed restore can leave mutated production source behind;
#   - refuses to start when contracts/src has local changes (the restore baseline is HEAD);
#   - mutation sets are selectable (MUTSET=a3 | hsp | all).
#
# Usage: scripts/cc125-a3mut.sh [WORKTREE] [OUTDIR]
#   WORKTREE  git checkout to run in       (env CC125_WORKTREE, default: repo root of this script)
#   OUTDIR    where the *.log files go     (env CC125_OUT, default: ${TMPDIR:-/tmp}/cc125-a3mut)
#   MUTSET    a3 (D5c1A3Negatives, M-A3G/R/S) | hsp (D5c1A3HistoricalSP, M-HSP*) | all (default a3)
#   FORGE_ARGS extra args for every forge test run (e.g. "--evm-version prague")
set -uo pipefail
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="${1:-${CC125_WORKTREE:-$(git -C "$HERE" rev-parse --show-toplevel)}}"
O="${2:-${CC125_OUT:-${TMPDIR:-/tmp}/cc125-a3mut}}"
MUTSET="${MUTSET:-a3}"
FARGS=(); [ -n "${FORGE_ARGS:-}" ] && read -r -a FARGS <<< "$FORGE_ARGS"

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

mkdir -p "$O"; cd "$W" || { echo "cannot cd to $W" >&2; exit 2; }
C=contracts/src/tokens/v2/xPNTsTokenV2.sol
E=contracts/src/tokens/v2/xPNTsTokenV2Ext.sol
FILES=("$C" "$E")
if [ -n "$(git status --porcelain -- contracts/src)" ]; then
  echo "contracts/src is dirty; refusing to mutate (restore baseline is HEAD)" >&2; exit 2
fi
# bash 3.2 compatible (macOS /bin/bash): parallel indexed arrays, no associative arrays
H0=(); for f in "${FILES[@]}"; do H0+=("$(sha "$f")"); done
h0() { local i; for i in "${!FILES[@]}"; do [ "${FILES[$i]}" = "$1" ] && { echo "${H0[$i]}"; return; }; done; }

restore() {
  local rc=$? ok=1
  for f in "${FILES[@]}"; do
    git checkout -- "$f"
    if [ "$(sha "$f")" = "$(h0 "$f")" ]; then echo "# restored $f sha256 $(h0 "$f")"; else echo "RESTORE-MISMATCH $f" >&2; ok=0; fi
  done
  [ "$ok" = 1 ] && echo RESTORED-OK || { echo RESTORE-FAILED >&2; rc=99; }
  exit "$rc"
}
trap restore EXIT
trap 'exit 130' INT TERM HUP

run_tests() { # testfile log
  { echo "# cmd: forge test --match-path $1 -vv ${FARGS[*]+"${FARGS[*]}"}"; } >> "$2"
  forge test --match-path "$1" -vv ${FARGS[@]+"${FARGS[@]}"} >> "$2" 2>&1; echo "# exit_code: $?" >> "$2"
}

positive() { # testfile tag
  local L="$O/$2.log"
  { echo "# head: $(git rev-parse HEAD)"; echo "# forge: $(forge --version | head -1)";
    echo "# test sha256: $(sha "$1")  $1"; echo "# git status --porcelain:"; git status --porcelain; } > "$L"
  run_tests "$1" "$L"
}

mut() { # id file test old new
  local id="$1" f="$2" t="$3" old="$4" new="$5" L="$O/$1.log"
  python3 -c 'import sys;p,o,n=sys.argv[1:];s=open(p).read();assert s.count(o)==1,"anchor";open(p,"w").write(s.replace(o,n))' "$f" "$old" "$new" \
    || { echo "APPLY FAILED $id" >&2; exit 3; }
  { echo "# mutation $id on $f"; git diff -- "$f"; } > "$L"
  run_tests "$t" "$L"
  git checkout -- "$f"
  local h; h=$(sha "$f")
  echo "# restored sha256: $h  $f" >> "$L"
  [ "$h" = "$(h0 "$f")" ] || { echo "RESTORE-MISMATCH after $id" >&2; exit 4; }
}

TA=contracts/test/halmos/D5c1A3Negatives.t.sol
TH=contracts/test/halmos/D5c1A3HistoricalSP.t.sol

if [ "$MUTSET" = a3 ] || [ "$MUTSET" = all ]; then
  positive "$TA" a3-negatives
  mut M-A3G "$C" "$TA" 'if (c.genesisSpender == c.superPaymaster) revert InvalidAddress(c.genesisSpender);' '// M-A3G: equality check removed'
  mut M-A3R "$E" "$TA" '            autoApprovedSpenders[sp] = false;
            emit AutoApprovedSpenderRemoved(sp);' '            // M-A3R: removal on rotation dropped'
  # state write only (the event still fires): isolates the autoApprovedSpenders assertion
  mut M-A3S "$E" "$TA" '            autoApprovedSpenders[sp] = false;
            emit AutoApprovedSpenderRemoved(sp);' '            emit AutoApprovedSpenderRemoved(sp); // M-A3S: state write dropped, event kept'
fi
if [ "$MUTSET" = hsp ] || [ "$MUTSET" = all ]; then
  positive "$TH" a3-historical-sp
  # activateSpender historicalSP guard removed
  mut M-HSP-ACT "$E" "$TH" '        if (historicalSP[spender]) revert InvalidAddress(spender);' '        // M-HSP-ACT: historicalSP guard removed'
  # proposeSpender: only the historicalSP term removed (current-SP term kept)
  mut M-HSP-PROP "$E" "$TH" 'if (spender == address(0) || spender == SUPERPAYMASTER_ADDRESS || historicalSP[spender]) {' 'if (spender == address(0) || spender == SUPERPAYMASTER_ADDRESS) { // M-HSP-PROP'
  # rotation path (shared by activateSP and emergencySwitchToStandby)
  mut M-HSP-ESWS "$E" "$TH" '            autoApprovedSpenders[sp] = false;
            emit AutoApprovedSpenderRemoved(sp);' '            emit AutoApprovedSpenderRemoved(sp); // M-HSP-ESWS: state write dropped, event kept'
  mut M-HSP-ESWH "$E" "$TH" '        historicalSP[sp] = true;
        if (autoApprovedSpenders[sp]) {' '        // M-HSP-ESWH: historicalSP mark dropped
        if (autoApprovedSpenders[sp]) {'
fi

git status --porcelain
for f in "$O"/*.log; do echo "== $f"; grep -E "^\[(PASS|FAIL)|^# exit_code|^Suite|^# restored" "$f"; done

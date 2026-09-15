#!/usr/bin/env bash
# D5c-1 — run one Halmos harness and keep a self-describing log.
#
# usage: script/halmos/run-d5c1.sh <ContractName> <log-file> [extra halmos args...]
#   e.g. script/halmos/run-d5c1.sh APNTsCappedHalmosTest docs/design/aoa-balance-mode/data/halmos/cap1.log
#
# Fixed options (every bound is recorded in the log header and in D5c-1-halmos.md):
#   --panic-error-codes '*'   any Panic raised by the HARNESS itself (not by the token, whose
#                             reverts are caught by the low-level call) counts as a failure, so an
#                             arithmetic slip in an assertion can never silently drop a path.
# Halmos compiles with plain `forge build` (no FOUNDRY_PROFILE) = [profile.default].
set -euo pipefail
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
export PYTHONUNBUFFERED=1   # per-test result lines reach the log as soon as they are printed
contract="$1"; shift
log="$1"; shift
mkdir -p "$(dirname "$log")"
{
  echo "# D5c-1 halmos run"
  echo "# date_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# git_head: $(git rev-parse HEAD)  dirty_src: $(git status --porcelain contracts/src | wc -l | tr -d ' ')"
  echo "# halmos: $(halmos --version 2>&1)"
  echo "# forge: $(forge --version 2>&1 | head -1)"
  echo "# FOUNDRY_PROFILE: ${FOUNDRY_PROFILE:-<unset> (= default)}"
  echo "# command: halmos --contract $contract --panic-error-codes '*' $*"
} > "$log"
fam=xpnts; case "$contract" in APNTsCapped*) fam=apnts ;; esac
python3 script/halmos/d5c1_binding.py "$fam" --line >> "$log"   # header binding (before the run)
echo >> "$log"
# A plain `forge build` / `forge test` writes the harness artifacts WITHOUT an AST, and forge's
# cache then keeps them when halmos runs `forge build --ast`, so halmos would skip the harness
# ("KeyError: 'ast'"). Dropping the harness artifacts forces forge to rebuild just those files.
for d in out/APNTsCappedHalmos.t.sol out/XPNTsV2Halmos.t.sol out/XPNTsV2HalmosProbe.sol; do
  [ -d "$d" ] || continue
  if ! python3 -c 'import json,sys,glob; sys.exit(0 if all("ast" in json.load(open(f)) for f in glob.glob(sys.argv[1]+"/*.json")) else 1)' "$d"; then
    rm -rf "$d"
  fi
done
start=$(date +%s)
set +e
halmos --contract "$contract" --panic-error-codes '*' "$@" >> "$log" 2>&1
rc=$?
set -e
end=$(date +%s)
echo >> "$log"
echo "# exit_code: $rc  wall_seconds: $((end - start))" >> "$log"
python3 script/halmos/d5c1_binding.py "$fam" --line >> "$log"   # trailer binding (after halmos' build)
tail -n 40 "$log"
exit $rc

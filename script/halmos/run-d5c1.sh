#!/usr/bin/env bash
# D5c-1 — run one Halmos harness (unpartitioned) and keep a self-describing log.
#
# usage: script/halmos/run-d5c1.sh <ContractName> <log-file> <profile> [match-test-regex]
#   e.g. script/halmos/run-d5c1.sh APNTsCappedHalmosTest docs/design/aoa-balance-mode/data/halmos/cap1.log cap1
#
# The Halmos arguments come ONLY from d5c1_binding.PROFILES (<profile>; `<name>-fail` adds
# --early-exit and is for expected-FAIL items only) via d5c1_binding.halmos_argv, and are recorded
# in the `# meta:` header line that verify-d5c1.py binds the log to. Fixed in every profile:
#   --panic-error-codes '*'   any Panic raised by the HARNESS itself (not by the token, whose
#                             reverts are caught by the low-level call) counts as a failure, so an
#                             arithmetic slip in an assertion can never silently drop a path.
# Halmos compiles with plain `forge build` (no FOUNDRY_PROFILE) = [profile.default].
set -euo pipefail
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
export PYTHONUNBUFFERED=1   # per-test result lines reach the log as soon as they are printed
contract="$1"; log="$2"; profile="$3"; mt="${4:-}"
H="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$(dirname "$log")"
fam=xpnts; case "$contract" in APNTsCapped*) fam=apnts ;; esac
argv_json=$(python3 -c 'import sys,json; sys.path.insert(0,sys.argv[1]); import d5c1_binding as B
print(json.dumps(B.halmos_argv(sys.argv[2], sys.argv[3], match_test=sys.argv[4] or None)))' "$H" "$contract" "$profile" "$mt")
{
  echo "# D5c-1 halmos run"
  python3 -c 'import sys,json; sys.path.insert(0,sys.argv[1]); import d5c1_binding as B
print(B.meta_line(runner="run-d5c1", contract=sys.argv[2], argv=json.loads(sys.argv[3]), profile=sys.argv[4], wall_cap_s=B.WALL_CAP_S))' \
    "$H" "$contract" "$argv_json" "$profile"
  echo "# date_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# halmos: $(halmos --version 2>&1)"
  echo "# forge: $(forge --version 2>&1 | head -1)"
  echo "# FOUNDRY_PROFILE: ${FOUNDRY_PROFILE:-<unset> (= default)}"
  echo "# tree_note: ${D5C1_TREE:--}"
} > "$log"
python3 "$H/d5c1_binding.py" "$fam" --line >> "$log"   # header binding (before the run)
echo >> "$log"
# A plain `forge build` / `forge test` writes the harness artifacts WITHOUT an AST, and forge's
# cache then keeps them when halmos runs `forge build --ast`, so halmos would skip the harness
# ("KeyError: 'ast'"). Dropping the harness artifacts forces forge to rebuild just those files.
for d in out/APNTsCappedHalmos.t.sol out/XPNTsV2Halmos.t.sol out/XPNTsV2HalmosProbe.sol out/MintRepayLemma.t.sol; do
  [ -d "$d" ] || continue
  if ! python3 -c 'import json,sys,glob; sys.exit(0 if all("ast" in json.load(open(f)) for f in glob.glob(sys.argv[1]+"/*.json")) else 1)' "$d"; then
    rm -rf "$d"
  fi
done
start=$(date +%s)
set +e
# hard wall cap (d5c1_binding.WALL_CAP_S); the exit status of a killed run is recorded as-is
python3 - "$log" "$argv_json" <<'PY'
import json, os, signal, subprocess, sys
sys.path.insert(0, os.path.join(os.getcwd(), "script/halmos"))
import d5c1_binding as B
log, argv = sys.argv[1], json.loads(sys.argv[2])
with open(log, "a") as f:
    p = subprocess.Popen(["halmos"] + argv, stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        rc = p.wait(timeout=B.WALL_CAP_S)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL); rc = p.wait()
        f.write(f"\n# WALL-CAP: killed after {B.WALL_CAP_S} s\n")
sys.exit(rc if rc >= 0 else 128 - rc)
PY
rc=$?
set -e
[ $rc -gt 128 ] && rc=$((128 - rc))   # report a signal kill as the negative number Popen gives
end=$(date +%s)
echo >> "$log"
echo "# exit_code: $rc  wall_seconds: $((end - start))" >> "$log"
python3 "$H/d5c1_binding.py" "$fam" --line --contract "$contract" >> "$log"   # trailer (after halmos' build)
grep -E '^\S*\[(PASS|FAIL|TIMEOUT|ERROR)\]|^# exit_code' "$log" | tail -n 10
exit 0

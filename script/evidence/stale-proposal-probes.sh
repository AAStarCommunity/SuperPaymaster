#!/usr/bin/env bash
# Gate-removal probes for the DVT stale-proposal exemption, closing readback and pointer gates.
# Each probe replaces one gate with `pass` (or drops the sibling level comparison) in a scratch
# copy of manifest_exec.py, runs the named controls, and requires them to turn red by an
# assertion failure (FAILED with failures=N and no errors=): an exception elsewhere is not
# evidence that the forbidden state was accepted.
# Limitation: controls assert the gate *name*, so a removal can turn red because a later gate
# rejects the same state under another name. A red probe proves the control is bound to that
# gate; it does not by itself prove the state would otherwise be accepted end to end.
# Usage: script/evidence/stale-proposal-probes.sh   (from repo root; set A3A_ENGINE_DIR as in CI)
set -u
cd "$(git rev-parse --show-toplevel)"
src=script/upgrade/manifest_exec.py
git diff --quiet HEAD -- "$src" || { echo "refusing: $src has uncommitted changes"; exit 1; }
bak=$(mktemp "${TMPDIR:-/tmp}/manifest_exec.XXXXXX") || { echo "mktemp failed"; exit 1; }
cp "$src" "$bak" && cmp -s "$src" "$bak" || { echo "backup failed; source untouched"; rm -f "$bak"; exit 1; }
# Restore from HEAD (the source is clean) and keep the backup if that fails.
log=$(mktemp "${TMPDIR:-/tmp}/stale-probes.XXXXXX") || { echo "mktemp failed"; rm -f "$bak"; exit 1; }
restore() {
  # Nothing may interrupt the restore itself; the source comes back before any other cleanup.
  trap '' INT TERM
  if git checkout -q HEAD -- "$src" && cmp -s "$src" "$bak"; then rm -f "$bak"
  else echo "RESTORE FAILED; backup kept at $bak"; rm -f "$log"; exit 1; fi
  rm -f "$log"
}
# Every reset must reproduce HEAD byte for byte, or later probes would run on an earlier mutation.
reset() { git checkout -q HEAD -- "$src" && cmp -s "$src" "$bak" || { echo "RESET FAILED"; exit 1; }; }
trap restore EXIT
# A signal must restore the source promptly: the suite runs as a background child awaited with an interruptible
# `wait` (not inside $(...), where bash defers traps until the child ends); on INT/TERM it is terminated and reaped,
# then exit runs the EXIT trap.
child=
on_signal() { if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null; fi; exit 1; }
trap on_signal INT TERM
pending=
tests='-k stale_dvt -k unsigned_dvt -k dvt_closing -k old_pointers'
status=0
run() {
  # A fresh log per run: a failed redirect must not leave an earlier probe's result to be read as this one's.
  rm -f "$log" || { echo "LOG RESET FAILED"; exit 1; }
  # Between `&` and `child=$!` a signal only marks pending; it is handled once the child is known.
  trap 'pending=1' INT TERM
  python3 -B script/upgrade/test_manifest_exec.py $tests > "$log" 2>&1 &
  child=$!
  trap on_signal INT TERM
  [ -z "$pending" ] || on_signal
  wait "$child"; rc=$?; child=
  # unittest exits 0 (OK) or 1 (FAILED); anything else (no interpreter, redirect failure, crash) is not a result.
  case "$rc" in 0|1) ;; *) echo "SUITE DID NOT RUN (rc=$rc)"; exit 1;; esac
  grep -qE '^Ran [0-9]+ test' "$log" || { echo "SUITE DID NOT RUN (no Ran line)"; exit 1; }
  R=$(grep -E '^(OK|FAILED)' "$log" | tail -1)
}
run; base=$R; echo "baseline: $base"; case "$base" in OK*) ;; *) echo "baseline not green"; exit 1;; esac
red() { case "$1" in *errors=*) return 1;; FAILED*failures=*) return 0;; *) return 1;; esac; }
for gate in dvt_stale_next_id dvt_proposal_inventory dvt_stale_proposal_listed dvt_stale_proposal_shape \
            dvt_stale_sibling_executed dvt_stale_open_set closing_registry_pointer closing_dvt_pointer \
            closing_committee_pointer closing_dvt_activity \
            closing_stale_unexecuted old_pointer pointer_owner; do
  reset
  python3 - "$src" "$gate" <<'PY' || { echo "MUTATION FAILED: $gate"; exit 1; }
import sys
p, g = sys.argv[1:]
lines = open(p).read().split('\n')
hits = [i for i, l in enumerate(lines) if f"a.need('{g}'" in l]
assert len(hits) == 1, (g, hits)
l = lines[hits[0]]
lines[hits[0]] = l[:len(l)-len(l.lstrip())] + 'pass'
open(p, 'w').write('\n'.join(lines))
PY
  run; r=$R; echo "remove $gate -> $r"; red "$r" || status=1
done
reset
python3 - "$src" <<'PY' || { echo "MUTATION FAILED: sibling level"; exit 1; }
import sys
p = sys.argv[1]; s = open(p).read()
old = "(peer[0], peer[1], peer[3], peer[5]), (w[0], w[1], 1, evidence)"
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, "(peer[0], peer[3], peer[5]), (w[0], 1, evidence)"))
PY
run; r=$R; echo "drop sibling level -> $r"; red "$r" || status=1
echo "PROBES_ALL_RED=$((1-status))"
exit $status

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
restore() {
  if git checkout -q HEAD -- "$src" && cmp -s "$src" "$bak"; then rm -f "$bak"
  else echo "RESTORE FAILED; backup kept at $bak"; exit 1; fi
}
# Every reset must reproduce HEAD byte for byte, or later probes would run on an earlier mutation.
reset() { git checkout -q HEAD -- "$src" && cmp -s "$src" "$bak" || { echo "RESET FAILED"; exit 1; }; }
trap restore EXIT
# A signal must still restore the source: exit (and so run the EXIT trap) on INT/TERM.
trap 'exit 1' INT TERM
tests='-k stale_dvt -k unsigned_dvt -k dvt_closing -k old_pointers'
status=0
run() { python3 -B script/upgrade/test_manifest_exec.py $tests 2>&1 | grep -E '^(OK|FAILED)' | tail -1; }
base=$(run); echo "baseline: $base"; case "$base" in OK*) ;; *) echo "baseline not green"; exit 1;; esac
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
  r=$(run); echo "remove $gate -> $r"; red "$r" || status=1
done
reset
python3 - "$src" <<'PY' || { echo "MUTATION FAILED: sibling level"; exit 1; }
import sys
p = sys.argv[1]; s = open(p).read()
old = "(peer[0], peer[1], peer[3], peer[5]), (w[0], w[1], 1, evidence)"
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, "(peer[0], peer[3], peer[5]), (w[0], 1, evidence)"))
PY
r=$(run); echo "drop sibling level -> $r"; red "$r" || status=1
echo "PROBES_ALL_RED=$((1-status))"
exit $status

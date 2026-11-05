#!/usr/bin/env bash
# Gate-removal probes for the DVT stale-proposal exemption, closing readback and pointer gates.
# Each probe replaces one gate with `pass` (or drops the sibling level comparison) in a scratch
# copy of manifest_exec.py, runs the named controls, and requires them to turn red.
# Usage: script/evidence/stale-proposal-probes.sh   (from repo root; set A3A_ENGINE_DIR as in CI)
set -u
cd "$(git rev-parse --show-toplevel)"
src=script/upgrade/manifest_exec.py
bak=$(mktemp "${TMPDIR:-/tmp}/manifest_exec.XXXXXX")
cp "$src" "$bak"
trap 'cp "$bak" "$src"; rm -f "$bak"' EXIT
tests='-k stale_dvt -k dvt_closing -k old_pointers'
status=0
run() { python3 -B script/upgrade/test_manifest_exec.py $tests 2>&1 | grep -E '^(OK|FAILED)' | tail -1; }
base=$(run); echo "baseline: $base"; case "$base" in OK*) ;; *) echo "baseline not green"; exit 1;; esac
for gate in dvt_stale_proposal_listed dvt_stale_proposal_shape dvt_stale_sibling_executed dvt_stale_next_id \
            closing_dvt_pointer closing_dvt_next_id closing_stale_unexecuted old_pointer pointer_owner; do
  cp "$bak" "$src"
  python3 - "$src" "$gate" <<'PY'
import sys
p, g = sys.argv[1:]
lines = open(p).read().split('\n')
hits = [i for i, l in enumerate(lines) if f"a.need('{g}'" in l]
assert len(hits) == 1, (g, hits)
l = lines[hits[0]]
lines[hits[0]] = l[:len(l)-len(l.lstrip())] + 'pass'
open(p, 'w').write('\n'.join(lines))
PY
  r=$(run); echo "remove $gate -> $r"; case "$r" in FAILED*) ;; *) status=1;; esac
done
cp "$bak" "$src"
python3 - "$src" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "(peer[0], peer[1], peer[3], peer[5]), (w[0], w[1], 1, evidence)"
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, "(peer[0], peer[3], peer[5]), (w[0], 1, evidence)"))
PY
r=$(run); echo "drop sibling level -> $r"; case "$r" in FAILED*) ;; *) status=1;; esac
echo "PROBES_ALL_RED=$((1-status))"
exit $status

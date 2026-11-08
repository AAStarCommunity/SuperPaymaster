#!/bin/zsh
# Usage: run-all-6j.sh <worktree> <outdir>  — all suites + probe drivers, both engines.
# Changes vs run-all-6e.sh (d21042ad triage, TRIAGE.md):
#  - every driver runs from the repo root (fixture paths are repo-root relative)
#  - probe_typed_gates runs --discover before --probes (expected: passed=82 total=88 blocked=6, rc=1)
#  - probe_phase_c_gates base 645ff3a1 (the base recorded in COMMIT6_RESULTS.md)
#  - probe_finite_gate_blockers / probe_finite_gate_labels are superseded helpers: run, tagged INFO
wt=$1; out=$2; mkdir -p $out; cd $wt
S=$out/SUMMARY.txt
echo "HEAD=$(git rev-parse HEAD) dirty=$(git status --porcelain | wc -l | tr -d ' ')" > $S
TESTS=(script/upgrade/test_*.py script/a3a/test_a3a_exec.py script/a3a/test_a3a_send.py script/upgrade/audit/test_audit_findings.py script/upgrade/audit/check_expected_failure_causes.py)
for e in bin nightly; do
  if [ $e = bin ]; then export A3A_ENGINE_DIR=$HOME/.foundry/bin; else unset A3A_ENGINE_DIR; fi
  echo "[$e] engine=$(${A3A_ENGINE_DIR:-$HOME/.foundry/bin}/forge --version 2>/dev/null | head -1)" >> $S
  for t in $TESTS; do
    log=$out/$e-$(basename $t .py).log
    python3 -B $t > $log 2>&1 </dev/null; rc=$?
    echo "[$e] $t rc=$rc :: $(grep -E '^Ran ' $log | tail -1) :: $(grep -E '^(OK|FAILED|FINDINGS|[A-Z0-9_]+ (PASS|FAIL))' $log | tail -1)" >> $S
  done
  python3 -B script/upgrade/probe_typed_gates.py --discover $out/$e-typed > $out/$e-probe_typed_gates-discover.log 2>&1 </dev/null
  echo "[$e] probe_typed_gates --discover rc=$? :: $(tail -1 $out/$e-probe_typed_gates-discover.log)" >> $S
  for p in script/upgrade/probe_*.py script/evidence/enduser_mapping_probes.py script/evidence/inventory_replay_probes.py script/evidence/registry_ast_probes.py; do
    n=$(basename $p .py); args=(); tag=""
    case $n in
      probe_phase_c_gates) args=(645ff3a1);;
      probe_typed_gates) args=(--probes $out/$e-typed);;
      probe_finite_gate_blockers|probe_finite_gate_labels) tag=" [INFO superseded, see TRIAGE.md]";;
    esac
    log=$out/$e-$n.log
    python3 -B $p $args > $log 2>&1 </dev/null; rc=$?
    echo "[$e] $n rc=$rc$tag :: $(tail -1 $log)" >> $S
  done
  python3 -B script/upgrade/probe_gate_dsr2.py --remaining > $out/$e-probe_gate_dsr2-remaining.log 2>&1 </dev/null; echo "[$e] probe_gate_dsr2 --remaining rc=$? :: $(tail -1 $out/$e-probe_gate_dsr2-remaining.log)" >> $S
  python3 -B script/evidence/stale_proposal_probes.py > $out/$e-stale.log 2>&1 </dev/null; echo "[$e] stale rc=$? :: $(tail -1 $out/$e-stale.log)" >> $S
  python3 -B script/evidence/audit605_probes.py --jobs 2 > $out/$e-audit605.log 2>&1 </dev/null; echo "[$e] audit605 rc=$? :: $(tail -1 $out/$e-audit605.log)" >> $S
done
unset A3A_ENGINE_DIR
python3 -B script/upgrade/gate_rename_ast_diff.py 2acc71af HEAD > $out/ast-diff.log 2>&1; echo "ast-diff rc=$? :: $(tail -1 $out/ast-diff.log)" >> $S
echo "HEAD_AFTER=$(git rev-parse HEAD) dirty=$(git status --porcelain | wc -l | tr -d ' ')" >> $S
echo DONE >> $S

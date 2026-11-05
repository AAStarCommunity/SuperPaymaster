#!/usr/bin/env python3
"""Phase C gate-removal probes: suppress one named gate, require its control to turn red.

Production files are never modified: the probe replaces a3a_exec.need for exactly one gate
name with a no-op ("replace the gate with pass") and runs that gate's named control. The
control must have passed first, and the suppressed gate must actually have been reached.
The script also scans manifest_exec.py against a base revision and fails if a newly added
gate literal has no probe case.
"""
import sys
sys.dont_write_bytecode = True
import io
import re
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch
import test_manifest_exec as base_tests
import test_manifest_phase_c as tests

a = tests.a
P, L, S = tests.PhaseCTests, tests.LiveGateTests, tests.SnapshotControlTests
CASES = [(P, 'test_build_'+g, g) for g in tests.BUILD_CASES]
CASES += [(P, 'test_rebuild_'+g, g) for g in tests.REBUILD_CASES]
CASES += [(tests.BaselineGateTests, 'test_build_'+g, g) for g in
          ('C12_constructor_abi', 'C14_constructor_abi', 'C_baseline_commit_F1TestToken')]
CASES += [(L, 'test_live_'+g, g) for g in tests.LIVE_CASES]
CASES += [(L, 'test_precheck_'+g, g.split('__')[0]) for g in tests.PRECHECK_CASES]
CASES += [(L, 'test_funding_'+g, g.split('__')[0]) for g in tests.FUNDING_CASES]
CASES += [
    (P, 'test_pin_price_zero', 'C_price_bound'),
    (P, 'test_stage_c_boundary_and_prefix', 'prefix_boundary'),
    (P, 'test_stage_c_prefix_must_end_in_phase_c', 'prefix_boundary_last'),
    (P, 'test_stage_c_artifact_never_final', 'final_stage'),
    (P, 'test_collect_phase_c_pending_nonce', 'phase_c_pending_nonce_owner'),
    (L, 'test_accounting', 'C_accounting'),
    (L, 'test_owner_gas_bound', 'C_owner_gas_bound'),
    (L, 'test_budget_owner_shortfall', 'budget_owner'),
    (L, 'test_handover_requires_phase_c', 'handover_dependencies'),
    (S, 'test_control_must_fire_named_gate', 'X_gate'),
    (S, 'test_control_must_fire_named_gate', 'X_restore'),
    (S, 'test_control_slot_readback', 'C_control_slot'),
    (S, 'test_control_slot_readback', 'C_control_layout_cachedPrice'),
    (base_tests.ManifestTests, 'test_rehearsal_phase_c_controls_complete', 'phase_c_controls_complete'),
    (base_tests.ManifestTests, 'test_rehearsal_after_6d_accounting', 'after_6d_accounting'),
    (base_tests.ManifestTests, 'test_rehearsal_accounting_unchanged_since_phase_c', 'accounting_unchanged_since_phase_c'),
    (base_tests.ManifestTests, 'test_rehearsal_funding_rechecked_after_phase_c', 'C_funding_bundler'),
    # #605 audit fixes and #606 L1 (DSR 2026-11-05): gates added outside Phase C, bound to their named controls.
    (base_tests.ManifestTests, 'test_pin_pending_token_eta', 'pin_pending_token_eta'),
    (base_tests.ManifestTests, 'test_collect_direct_fake_chain', 'old_aggregator_slash_policy_admin'),
    (base_tests.ManifestTests, 'test_dvt_closing_binds_pointer_and_stale_proposals', 'closing_registry_pointer'),
    (base_tests.ManifestTests, 'test_dvt_closing_binds_pointer_and_stale_proposals', 'closing_committee_pointer'),
    (base_tests.F05ExecuteB4Gates, 'test_B4_timestamp', 'B4_timestamp'),
]
CASES += [(base_tests.ManifestTests, 'test_'+gate, gate) for gate in
          ('old_timelock_holds_nothing', 'old_timelock_tl_roles', 'old_timelock_authority', 'old_timelock_safe')]
CASES += [(base_tests.isolation_tests.OldOwnerIsolationTests, 'test_legacy_timelock_source_targets', 'old_owner_source_targets')]
GATE = re.compile(r"""a\.(?:need|exact_keys)\(\s*['"]([A-Za-z0-9_]+)['"]""")
# Gate literals whose control is a whole family (name+'_gate', name+'_restore').
FAMILIES = {'_gate': 'X_gate', '_restore': 'X_restore'}


def run(cls, name, gate=None):
    original = a.need
    suppressed = []

    def without_gate(actual, *args, **kwargs):
        if actual == gate:
            suppressed.append(actual)
            return None
        return original(actual, *args, **kwargs)

    stream = io.StringIO()
    with patch.object(a, 'need', side_effect=without_gate):
        # A suite (not a bare case) so class fixtures (setUpClass) run.
        result = unittest.TextTestRunner(stream=stream).run(unittest.TestSuite([cls(name)]))
    return result.wasSuccessful(), bool(suppressed), stream.getvalue()


def new_gates(base):
    path = 'script/upgrade/manifest_exec.py'
    root = Path(__file__).resolve().parents[2]
    old = subprocess.run(['git', 'show', base+':'+path], cwd=root, capture_output=True, text=True, check=True).stdout
    current = (root/path).read_text()
    return sorted(set(GATE.findall(current))-set(GATE.findall(old)))


def covered(gate, names):
    if gate in names:
        return True
    if gate.endswith('_'):
        return any(n.startswith(gate) for n in names)
    return False


def main(argv):
    base = argv[1] if len(argv) > 1 else 'origin/main'
    names = {g for _, _, g in CASES} | {'_gate', '_restore'}
    missing = [g for g in new_gates(base) if not covered(g, names)]
    rows = []
    for cls, name, gate in CASES:
        ok, _, log = run(cls, name)
        if not ok:
            # A control that fails without suppression proves nothing about its gate.
            print(f'BASELINE FAILED {name}\n{log}', file=sys.stderr)
            return 1
        ok, reached, log = run(cls, name, gate)
        rows.append((cls.__name__+'.'+name, gate, 'PASS', 'red' if not ok and reached else
                     'NOT REACHED' if not reached else 'GREEN (gate not load-bearing)'))
    print('| Control | Suppressed gate | Baseline | Gate removed |')
    print('|---|---|---|---|')
    for row in rows:
        print('| %s | `%s` | %s | %s |' % row)
    bad = [r for r in rows if r[3] != 'red']
    print(f'PHASE_C_GATE_PROBES {"PASS" if not bad and not missing else "FAIL"} '
          f'{len(rows)-len(bad)}/{len(rows)} red; uncovered new gates: {missing}')
    return 1 if bad or missing else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
